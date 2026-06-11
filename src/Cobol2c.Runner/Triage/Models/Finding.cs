namespace Cobol2c.Runner.Triage.Models;

/// <summary>
/// Triage result for one TC that failed under Cobol2C but passed under the reference suite.
/// </summary>
public class Finding
{
    public string TC { get; set; } = "";

    /// <summary>True = failed Cobol2C AND passed reference (clean A/B regression).</summary>
    public bool Comparable { get; set; }

    /// <summary>Crash evidence extracted from the Cobol2C CoreLog. Null if no CoreLog was available.</summary>
    public CrashSignature? Crash { get; set; }

    /// <summary>First point where the Cobol2C flow sequence diverges from the reference. Null if one log was unavailable.</summary>
    public FlowDivergence? FlowDivergence { get; set; }
}
