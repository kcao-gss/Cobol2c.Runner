using Cobol2c.Runner.Jobs;

namespace Cobol2c.Runner.Ta;

public interface ITaExecutor
{
    /// <summary>
    /// Execute a TA test job and return paths to the resulting artefacts.
    /// Mock impl returns pre-baked fixture paths; real impl runs Invoke-TaRun.ps1.
    /// </summary>
    Task<TaRunResult> ExecuteAsync(TestJob job, CancellationToken ct);
}
