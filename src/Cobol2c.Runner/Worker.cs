using Cobol2c.Runner.Configuration;
using Cobol2c.Runner.Jobs;
using Cobol2c.Runner.Reporting;
using Cobol2c.Runner.Sinks;
using Cobol2c.Runner.Ta;
using Cobol2c.Runner.Triage;
using Cobol2c.Runner.Triage.Models;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Cobol2c.Runner;

/// <summary>
/// Main poll loop: pull job → execute TA → triage → report → sink → complete.
/// All heavy lifting is delegated to the injected interfaces; swapping mocks ↔ real impls
/// requires only a config change (Runner:UseMocks), not a code change.
/// When ConfirmationRuns > 1, each job fans out to N machines in parallel; a TC is reported
/// as a regression only if it fails on ALL machines (unanimous adjudication).
/// </summary>
public class Worker : BackgroundService
{
    private readonly IJobSource _jobSource;
    private readonly ITaExecutor _executor;
    private readonly ITriageEngine _triage;
    private readonly IBugReportGenerator _reporter;
    private readonly IResultSink _sink;
    private readonly MachineSelector _machineSelector;
    private readonly TimeSpan _pollInterval;
    private readonly bool _useMocks;
    private readonly int _confirmationRuns;
    private readonly string[] _machinePool;
    private readonly ILogger<Worker> _logger;

    public Worker(
        IJobSource jobSource,
        ITaExecutor executor,
        ITriageEngine triage,
        IBugReportGenerator reporter,
        IResultSink sink,
        MachineSelector machineSelector,
        IOptions<RunnerOptions> opts,
        ILogger<Worker> logger)
    {
        _jobSource        = jobSource;
        _executor         = executor;
        _triage           = triage;
        _reporter         = reporter;
        _sink             = sink;
        _machineSelector  = machineSelector;
        _pollInterval     = TimeSpan.FromMilliseconds(opts.Value.PollIntervalMs);
        _useMocks         = opts.Value.UseMocks;
        _confirmationRuns = opts.Value.ConfirmationRuns;
        _machinePool      = opts.Value.MachinePool;
        _logger           = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        _logger.LogInformation("Cobol2c.Runner started. Polling every {Interval}ms.", _pollInterval.TotalMilliseconds);
        _logger.LogInformation("Executor mode: {Mode} ({Executor}), ConfirmationRuns: {N}",
            _useMocks ? "MOCK" : "REAL", _executor.GetType().Name, _confirmationRuns);

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

                TriageResult triage;
                if (_confirmationRuns > 1)
                    triage = await RunOnMultipleMachinesAsync(job, ct);
                else
                {
                    var runResult = await _executor.ExecuteAsync(job, ct);
                    triage        = await _triage.TriageAsync(job, runResult, ct);
                }

                var report = await _reporter.GenerateAsync(job, triage, ct);
                await _sink.SaveAsync(job, triage, report, ct);
                await _jobSource.CompleteJobAsync(job, ct);

                _logger.LogInformation(
                    "Job {JobId} done. HasRegressions={HasRegressions}, Confirmed={Count}, Environmental={Env}",
                    job.Id, triage.HasRegressions, triage.Findings.Length, triage.EnvironmentalFindings.Length);
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

    /// <summary>
    /// Fans out the job to N machines in parallel. Each machine runs a full A/B suite pair.
    /// Uses ConfirmationAdjudicator to apply the unanimous rule: only TCs that fail on ALL N
    /// machines are reported as regressions; partial failures are classified as environmental.
    /// </summary>
    private async Task<TriageResult> RunOnMultipleMachinesAsync(TestJob job, CancellationToken ct)
    {
        // Select N ready machines. In mock mode, skip the readiness probe — MockTaExecutor
        // ignores machine name and returns the same fixture paths for any machine, so the first
        // N pool entries are sufficient to validate the fan-out wiring.
        string[] machines;
        if (_useMocks)
            machines = _machinePool.Take(_confirmationRuns).ToArray();
        else
            machines = await _machineSelector.SelectAsync(_machinePool, _confirmationRuns, ct);

        if (machines.Length == 0)
            throw new InvalidOperationException(
                $"No machines available from pool [{string.Join(", ", _machinePool)}]. " +
                "Check VPN connectivity and that at least one VM is up.");

        _logger.LogInformation(
            "Job {JobId}: confirmation run on {Count} machine(s): {Machines}",
            job.Id, machines.Length, string.Join(", ", machines));

        // Per-machine TAShare log dirs (TAShare\<Suite>\Logs\<Machine>) isolate artifacts — no UNC collisions
        var perMachineTasks = machines
            .Select(m => RunOneMachineAsync(job with { Machine = m }, ct))
            .ToArray();

        var perMachineResults = await Task.WhenAll(perMachineTasks);

        var resultsByMachine = machines
            .Zip(perMachineResults, (m, r) => (m, r))
            .ToDictionary(x => x.m, x => x.r);

        return ConfirmationAdjudicator.Adjudicate(resultsByMachine);
    }

    private async Task<TriageResult> RunOneMachineAsync(TestJob job, CancellationToken ct)
    {
        _logger.LogDebug("Job {JobId}: starting run on {Machine}", job.Id, job.Machine);
        var runResult = await _executor.ExecuteAsync(job, ct);
        var triage    = await _triage.TriageAsync(job, runResult, ct);
        _logger.LogDebug("Job {JobId} on {Machine}: HasRegressions={HR}, Findings={N}",
            job.Id, job.Machine, triage.HasRegressions, triage.Findings.Length);
        return triage;
    }
}
