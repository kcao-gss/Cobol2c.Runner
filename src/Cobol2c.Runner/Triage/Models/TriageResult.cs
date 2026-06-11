namespace Cobol2c.Runner.Triage.Models;

/// <summary>
/// Deserialized output of Invoke-Triage.ps1 (the ConvertTo-Json object it emits to stdout).
/// </summary>
public class TriageResult
{
    public bool HasRegressions { get; set; }
    public int ComparableCount { get; set; }
    public int NotComparableCount { get; set; }
    public Finding[] Findings { get; set; } = [];
}
