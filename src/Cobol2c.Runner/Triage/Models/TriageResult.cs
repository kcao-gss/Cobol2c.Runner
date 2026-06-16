namespace Cobol2c.Runner.Triage.Models;

/// <summary>
/// Deserialized output of Invoke-Triage.ps1 (the ConvertTo-Json object it emits to stdout).
/// When ConfirmationRuns > 1, ConfirmationAdjudicator merges N per-machine results into one
/// combined TriageResult; Findings contains only confirmed regressions (unanimous), while
/// EnvironmentalFindings lists TCs that failed on some but not all machines.
/// </summary>
public class TriageResult
{
    public bool HasRegressions { get; set; }
    public int ComparableCount { get; set; }
    public int NotComparableCount { get; set; }
    public Finding[] Findings { get; set; } = [];

    /// <summary>
    /// TCs that failed on 1..N-1 machines (not all) — environmental/flaky, not confirmed regressions.
    /// Empty when ConfirmationRuns == 1 (single-machine mode).
    /// </summary>
    public EnvironmentalFinding[] EnvironmentalFindings { get; set; } = [];
}
