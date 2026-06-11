using Cobol2c.Runner.Jobs;
using Cobol2c.Runner.Ta;
using Cobol2c.Runner.Triage.Models;

namespace Cobol2c.Runner.Triage;

public interface ITriageEngine
{
    /// <summary>
    /// Parse TA HTML logs + CoreLog traces to produce structured regression findings.
    /// Internally delegates to Invoke-Triage.ps1 via PowerShellHost.
    /// </summary>
    Task<TriageResult> TriageAsync(TestJob job, TaRunResult run, CancellationToken ct);
}
