using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Cobol2c.Runner.Jobs;
using Cobol2c.Runner.Ta;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Cobol2c.Agent;

/// <summary>
/// Main agent loop: GET /jobs/next -> run locally -> POST /jobs/{id}/result.
/// On executor failure, POSTs /jobs/{id}/error so the orchestrator can surface the failure.
/// Runs as a BackgroundService so the host lifecycle controls start/stop.
/// </summary>
public class AgentLoop : BackgroundService
{
    private readonly HttpClient _http;
    private readonly LocalExecutor _executor;
    private readonly TimeSpan _pollInterval;
    private readonly string _agentId;
    private readonly ILogger<AgentLoop> _logger;
    private static readonly JsonSerializerOptions _json = new() { PropertyNameCaseInsensitive = true };

    public AgentLoop(HttpClient http, LocalExecutor executor, IOptions<AgentOptions> opts, ILogger<AgentLoop> logger)
    {
        _http         = http;
        _executor     = executor;
        _pollInterval = TimeSpan.FromMilliseconds(opts.Value.PollIntervalMs);
        _agentId      = opts.Value.AgentId;
        _logger       = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        _logger.LogInformation("Cobol2c.Agent started. AgentId={Id} Poll={Poll}ms",
            _agentId, _pollInterval.TotalMilliseconds);

        while (!ct.IsCancellationRequested)
        {
            TestJob? job = null;
            try
            {
                job = await PollNextJobAsync(ct);
                if (job is null) { await Task.Delay(_pollInterval, ct); continue; }

                _logger.LogInformation("Got job {Id} suite={Suite} tcs={Tcs}",
                    job.Id, job.Suite, string.Join(",", job.Tcs));

                TaRunResult result;
                try
                {
                    result = await _executor.ExecuteAsync(job, ct);
                }
                catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
                catch (Exception ex)
                {
                    // Executor failure: report to orchestrator so the job is not silently lost.
                    _logger.LogError(ex, "Job {Id} executor failed.", job.Id);
                    await PostErrorAsync(job.Id, ex.Message, ct);
                    await Task.Delay(TimeSpan.FromSeconds(5), ct);
                    continue;
                }

                await PostResultAsync(job.Id, result, ct);
                _logger.LogInformation("Job {Id} complete. FailLog={Dir}", job.Id, result.FailLogDir);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { break; }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Job {Id} poll/post failed.", job?.Id ?? "unknown");
                await Task.Delay(TimeSpan.FromSeconds(5), ct);
            }
        }
        _logger.LogInformation("Cobol2c.Agent stopped.");
    }

    private async Task<TestJob?> PollNextJobAsync(CancellationToken ct)
    {
        var resp = await _http.GetAsync($"jobs/next?agent={Uri.EscapeDataString(_agentId)}", ct);
        if (resp.StatusCode == HttpStatusCode.NoContent) return null;
        resp.EnsureSuccessStatusCode();
        return await resp.Content.ReadFromJsonAsync<TestJob>(_json, ct);
    }

    private async Task PostResultAsync(string jobId, TaRunResult result, CancellationToken ct)
    {
        var resp = await _http.PostAsJsonAsync($"jobs/{jobId}/result", result, ct);
        resp.EnsureSuccessStatusCode();
    }

    /// <summary>
    /// Reports an executor failure to the orchestrator.
    /// Best-effort — a failure here is logged but does not crash the loop.
    /// </summary>
    private async Task PostErrorAsync(string jobId, string message, CancellationToken ct)
    {
        try
        {
            var resp = await _http.PostAsJsonAsync($"jobs/{jobId}/error",
                new { jobId, error = message }, ct);
            if (!resp.IsSuccessStatusCode)
                _logger.LogWarning("PostError {Id} returned {Status}", jobId, (int)resp.StatusCode);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "PostError {Id} failed (orchestrator unreachable?)", jobId);
        }
    }
}