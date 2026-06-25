using Cobol2c.Runner.Ta;

namespace Cobol2c.Agent;

/// <summary>
/// Seam for running Invoke-LocalRun.ps1 for a single TC.
/// The real implementation shells out via PowerShellHost;
/// tests inject a fake.
/// </summary>
public interface IScriptRunner
{
    Task<TaRunResult> RunAsync(
        string suite,
        int    tc,
        bool   logging,
        string manifestPath,
        string localBase,
        CancellationToken ct);
}
