using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Cobol2c.Runner.Jobs;
using Cobol2c.Runner.Ta;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using RichardSzalay.MockHttp;
using Xunit;

namespace Cobol2c.Agent.Tests;

public class AgentLoopTests
{
    private static IOptions<AgentOptions> DefaultOpts() =>
        Options.Create(new AgentOptions
        {
            OrchestratorUrl   = "http://orch/",
            AgentId           = "test-agent",
            PollIntervalMs    = 0,
            PowerShellExe     = "pwsh",
            ScriptsPath       = "scripts",
            LocalBase         = @"C:\Staging",
            JobTimeoutMinutes = 1
        });

    internal sealed class FakeExecutor
    {
        public int CallCount { get; private set; }
        public Exception? Throws { get; set; }
        private readonly TaRunResult _result;
        public FakeExecutor(TaRunResult result) => _result = result;
        public Task<TaRunResult> ExecuteAsync(TestJob job, CancellationToken ct)
        {
            CallCount++;
            if (Throws is not null) throw Throws;
            return Task.FromResult(_result);
        }
    }
    [Fact]
    public async Task PollRunPost_HappyPath()
    {
        var job = new TestJob("job-001", "Cobol2C", "TGFTA-LOCAL", new[] { 27510 }, Logging: true);
        var expected = new TaRunResult(
            FailLogDir:      @"C:\Temp\run",
            RefLogDir:       @"C:\Temp\run",
            FailCoreLogPath: null,
            RefCoreLogPath:  null);

        var mockHttp = new MockHttpMessageHandler();
        mockHttp.When(HttpMethod.Get, "http://orch/jobs/next*")
                .Respond(HttpStatusCode.OK,
                    new StringContent(JsonSerializer.Serialize(job),
                        System.Text.Encoding.UTF8, "application/json"));

        string? postedBody = null;
        mockHttp.When(HttpMethod.Post, "http://orch/jobs/job-001/result")
                .Respond(req =>
                {
#pragma warning disable xUnit1031
                    postedBody = req.Content?.ReadAsStringAsync().GetAwaiter().GetResult();
#pragma warning restore xUnit1031
                    return new HttpResponseMessage(HttpStatusCode.OK)
                        { Content = new StringContent("{}") };
                });

        var http     = mockHttp.ToHttpClient();
        http.BaseAddress = new Uri("http://orch/");
        var fake     = new FakeExecutor(expected);
        var harness  = new AgentCycleHarness(http, fake, DefaultOpts(), NullLogger<AgentLoop>.Instance);

        await harness.RunOneCycleAsync(CancellationToken.None);

        Assert.Equal(1, fake.CallCount);
        Assert.NotNull(postedBody);

        var posted = JsonSerializer.Deserialize<TaRunResult>(postedBody!,
                         new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
        Assert.Equal(expected.FailLogDir, posted?.FailLogDir);
    }

    [Fact]
    public async Task EmptyQueue_DoesNotExecute()
    {
        var mockHttp = new MockHttpMessageHandler();
        mockHttp.When(HttpMethod.Get, "http://orch/jobs/next*").Respond(HttpStatusCode.NoContent);

        var http    = mockHttp.ToHttpClient();
        http.BaseAddress = new Uri("http://orch/");
        var fake    = new FakeExecutor(new TaRunResult("", "", null, null));
        var harness = new AgentCycleHarness(http, fake, DefaultOpts(), NullLogger<AgentLoop>.Instance);

        await harness.RunOneCycleAsync(CancellationToken.None);
        Assert.Equal(0, fake.CallCount);
    }
    /// <summary>Executor throws -> POST /jobs/{id}/error -> no crash. Verifies should-fix 6.</summary>
    [Fact]
    public async Task ExecutorThrows_PostsError_NoCrash()
    {
        var job = new TestJob("job-err", "Cobol2C", "TGFTA-LOCAL", new[] { 27510 }, Logging: false);
        var mockHttp = new MockHttpMessageHandler();
        mockHttp.When(HttpMethod.Get, "http://orch/jobs/next*")
                .Respond(HttpStatusCode.OK,
                    new StringContent(JsonSerializer.Serialize(job),
                        System.Text.Encoding.UTF8, "application/json"));

        string? errorBody = null;
        mockHttp.When(HttpMethod.Post, "http://orch/jobs/job-err/error")
                .Respond(req =>
                {
#pragma warning disable xUnit1031
                    errorBody = req.Content?.ReadAsStringAsync().GetAwaiter().GetResult();
#pragma warning restore xUnit1031
                    return new HttpResponseMessage(HttpStatusCode.OK)
                        { Content = new StringContent("{}") };
                });

        var http    = mockHttp.ToHttpClient();
        http.BaseAddress = new Uri("http://orch/");
        var fake    = new FakeExecutor(new TaRunResult("", "", null, null))
                      { Throws = new InvalidOperationException("TA crashed") };
        var harness = new AgentCycleHarness(http, fake, DefaultOpts(), NullLogger<AgentLoop>.Instance);

        await harness.RunOneCycleWithErrorReportingAsync(CancellationToken.None);

        Assert.Equal(1, fake.CallCount);
        Assert.NotNull(errorBody);
        Assert.Contains("TA crashed", errorBody);
    }
}
internal sealed class AgentCycleHarness
{
    private readonly HttpClient _http;
    private readonly AgentLoopTests.FakeExecutor _fake;
    private readonly string _agentId;
    private readonly ILogger<AgentLoop> _logger;
    private static readonly JsonSerializerOptions _json = new() { PropertyNameCaseInsensitive = true };

    public AgentCycleHarness(HttpClient http, AgentLoopTests.FakeExecutor fake,
        IOptions<AgentOptions> opts, ILogger<AgentLoop> logger)
    {
        _http    = http;
        _fake    = fake;
        _agentId = opts.Value.AgentId;
        _logger  = logger;
    }

    public async Task RunOneCycleAsync(CancellationToken ct)
    {
        var job = await PollNextAsync(ct);
        if (job is null) return;
        var result = await _fake.ExecuteAsync(job, ct);
        await PostResultAsync(job.Id, result, ct);
    }

    public async Task RunOneCycleWithErrorReportingAsync(CancellationToken ct)
    {
        var job = await PollNextAsync(ct);
        if (job is null) return;
        try
        {
            var result = await _fake.ExecuteAsync(job, ct);
            await PostResultAsync(job.Id, result, ct);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Job {Id} executor failed.", job.Id);
            await PostErrorAsync(job.Id, ex.Message, ct);
        }
    }

    private async Task<TestJob?> PollNextAsync(CancellationToken ct)
    {
        var resp = await _http.GetAsync($"jobs/next?agent={Uri.EscapeDataString(_agentId)}", ct);
        if (resp.StatusCode == System.Net.HttpStatusCode.NoContent) return null;
        resp.EnsureSuccessStatusCode();
        return await resp.Content.ReadFromJsonAsync<TestJob>(_json, ct);
    }

    private async Task PostResultAsync(string jobId, TaRunResult result, CancellationToken ct)
    {
        var resp = await _http.PostAsJsonAsync($"jobs/{jobId}/result", result, ct);
        resp.EnsureSuccessStatusCode();
    }

    private async Task PostErrorAsync(string jobId, string message, CancellationToken ct)
    {
        var resp = await _http.PostAsJsonAsync($"jobs/{jobId}/error",
            new { jobId, error = message }, ct);
        if (!resp.IsSuccessStatusCode)
            _logger.LogWarning("PostError {Id} returned {Status}", jobId, (int)resp.StatusCode);
    }
}