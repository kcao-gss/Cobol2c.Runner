using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Cobol2c.Runner.Jobs;
using Cobol2c.Runner.Ta;
using Microsoft.AspNetCore.Mvc.Testing;
using Xunit;

namespace Cobol2c.Agent.Tests;

/// <summary>
/// Smoke-tests the stub orchestrator via in-process TestServer (no real network).
/// Each test creates its own factory so jobDispatched always starts false.
/// </summary>
public class OrchestratorTests
{
    private static readonly JsonSerializerOptions _json = new() { PropertyNameCaseInsensitive = true };

    private static WebApplicationFactory<Program> NewFactory() =>
        new WebApplicationFactory<Program>();

    [Fact]
    public async Task GetJobsNext_FirstCall_ReturnsJob()
    {
        await using var factory = NewFactory();
        var client = factory.CreateClient();
        var resp   = await client.GetAsync("/jobs/next?agent=test");
        Assert.Equal(HttpStatusCode.OK, resp.StatusCode);

        var job = await resp.Content.ReadFromJsonAsync<TestJob>(_json);
        Assert.NotNull(job);
        Assert.Equal("ab-cobol2c", job!.Id);
        Assert.Contains(27510, job.Tcs);
    }

    [Fact]
    public async Task GetJobsNext_SecondCall_Returns204()
    {
        await using var factory = NewFactory();
        var client = factory.CreateClient();
        await client.GetAsync("/jobs/next?agent=test");   // consume job 1 (ab-cobol2c)
        await client.GetAsync("/jobs/next?agent=test");   // consume job 2 (ab-sp2v6)
        var resp = await client.GetAsync("/jobs/next?agent=test");
        Assert.Equal(HttpStatusCode.NoContent, resp.StatusCode);
    }

    [Fact]
    public async Task PostResult_ValidBody_Returns200()
    {
        await using var factory = NewFactory();
        var client  = factory.CreateClient();
        var jobResp = await client.GetAsync("/jobs/next?agent=test");
        var job     = await jobResp.Content.ReadFromJsonAsync<TestJob>(_json);

        var result = new TaRunResult(
            FailLogDir:      @"C:\Temp\slice0",
            RefLogDir:       @"C:\Temp\slice0",
            FailCoreLogPath: null,
            RefCoreLogPath:  null);

        var postResp = await client.PostAsJsonAsync($"/jobs/{job!.Id}/result", result);
        Assert.Equal(HttpStatusCode.OK, postResp.StatusCode);
    }
}