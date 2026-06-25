using Cobol2c.Runner.Configuration;
using Cobol2c.Runner.Jobs;
using Cobol2c.Runner.Reporting;
using Cobol2c.Runner.Sinks;
using Cobol2c.Runner.Ta;
using Cobol2c.Runner.Triage;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Cobol2c.Runner;

/// <summary>
/// Main poll loop: pull job → execute TA → triage → report → sink → complete.
/// All heavy lifting is delegated to the injected interfaces; swapping mocks ↔ real impls
/// requires only a config change (Runner:UseMocks), not a code change.
/// </summary>
public class Worker : BackgroundService
{
    private readonly IJobSource _jobSource;
    private readonly ITaExecutor _executor;
    private readonly ITriageEngine _triage;
    private readonly IBugReportGenerator _reporter;
    private readonly IResultSink _sink;
    private readonly TimeSpan _pollInterval;
    private readonly bool _useMocks;
    private readonly ILogger<Worker> _logger;

    public Worker(
        IJobSource jobSource,
        ITaExecutor executor,
        ITriageEngine triage,
        IBugReportGenerator reporter,
        IResultSink sink,
        IOptions<RunnerOptions> opts,
        ILogger<Worker> logger)
    {
        _jobSource    = jobSource;
        _executor     = executor;
        _triage       = triage;
        _reporter     = reporter;
        _sink         = sink;
        _pollInterval = TimeSpan.FromMilliseconds(opts.Value.PollIntervalMs);
        _useMocks     = opts.Value.UseMocks;
        _logger       = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        _logger.LogInformation("Cobol2c.Runner started. Polling every {Interval}ms.", _pollInterval.TotalMilliseconds);
        _logger.LogInformation("Executor mode: {Mode} ({Executor})",
            _useMocks ? "MOCK" : "REAL", _executor.GetType().Name);

        while (!ct.IsCancellationRequested)
        {
            TestJob? job = null;
            try
            {
                job = await _jobSource.PollAsync(ct);
                if (job is null)
                {
                    await Task.Delay(_pollInterval, ct);
                    continue;
                }

                _logger.LogInformation("Processing job {JobId} ({Suite}/{Machine}, TCs: {Tcs})",
                    job.Id, job.Suite, job.Machine, string.Join(",", job.Tcs));

                var runResult  = await _executor.ExecuteAsync(job, ct);
                var triage     = await _triage.TriageAsync(job, runResult, ct);
                var report     = await _reporter.GenerateAsync(job, triage, ct);
                await _sink.SaveAsync(job, triage, report, ct);
                await _jobSource.CompleteJobAsync(job, ct);

                _logger.LogInformation(
                    "Job {JobId} done. HasRegressions={HasRegressions}, Findings={Count}",
                    job.Id, triage.HasRegressions, triage.Findings.Length);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Job {JobId} failed unexpectedly.", job?.Id ?? "unknown");
                if (job is not null)
                    await _jobSource.FailJobAsync(job, ex.Message, ct);

                // Brief back-off before retrying so a systemic failure doesn't spin
                await Task.Delay(TimeSpan.FromSeconds(5), ct);
            }
        }

        _logger.LogInformation("Cobol2c.Runner stopped.");
    }
}
