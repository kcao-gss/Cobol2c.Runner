using Cobol2c.Runner.Jobs;
using Cobol2c.Runner.Ta;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Cobol2c.Agent;

/// <summary>
/// Executes a <see cref="TestJob"/> TC-by-TC, persisting progress to a
/// <see cref="JobStateStore"/> so the agent can resume after a crash.
/// </summary>
public sealed class JobExecutor
{
    private readonly IScriptRunner         _runner;
    private readonly JobStateStore         _store;
    private readonly AgentOptions          _opts;
    private readonly ILogger<JobExecutor>  _logger;

    public JobExecutor(
        IScriptRunner          runner,
        JobStateStore          store,
        IOptions<AgentOptions> opts,
        ILogger<JobExecutor>   logger)
    {
        _runner = runner;
        _store  = store;
        _opts   = opts.Value;
        _logger = logger;
    }

    /// <summary>
    /// Runs all pending TCs in <paramref name="job"/>, updating the state file after each one.
    /// Resumes from an existing state file when the job matches and the recovery cap has not
    /// been reached; otherwise starts from scratch.
    /// </summary>
    public async Task<TaRunResult> ExecuteJobAsync(TestJob job, CancellationToken ct)
    {
        // Determine which TCs still need to run.
        var existing = await _store.LoadAsync();
        List<int> pendingTcs;

        if (existing != null && existing.JobId == job.Id && _store.ShouldResume(existing))
        {
            _logger.LogInformation("Resuming job {Id} ({Pending} TCs remaining)", job.Id, existing.Pending.Count);
            pendingTcs = existing.Pending;
        }
        else
        {
            await _store.StartAsync(job, recoveryCount: 0);
            pendingTcs = job.Tcs.ToList();
        }

        var manifestPath = Path.Combine(_opts.ScriptsPath, "tc-manifest.json");

        TaRunResult? lastResult = null;
        foreach (var tc in pendingTcs)
        {
            ct.ThrowIfCancellationRequested();

            _logger.LogInformation("Job {Id}: running TC {Tc}", job.Id, tc);
            lastResult = await _runner.RunAsync(
                job.Suite, tc, job.Logging, manifestPath, _opts.LocalBase, ct);

            await _store.RecordVerdictAsync(tc, "pass");
        }

        await _store.CompleteAsync();

        // Return the last TC's result; callers treat it as the run's overall artefact.
        return lastResult
            ?? new TaRunResult(FailLogDir: "", RefLogDir: "", FailCoreLogPath: null, RefCoreLogPath: null);
    }
}
