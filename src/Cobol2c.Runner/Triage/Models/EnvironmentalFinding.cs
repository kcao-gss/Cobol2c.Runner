namespace Cobol2c.Runner.Triage.Models;

/// <summary>
/// A TC that failed on 1..N-1 machines under unanimous adjudication — not a confirmed regression.
/// Reported separately so the operator can see which TCs are flaky and on which machines.
/// </summary>
public class EnvironmentalFinding
{
    /// <summary>TC number, e.g. "27510".</summary>
    public string TC { get; set; } = "";

    /// <summary>Machines on which this TC produced a comparable failure (Cobol2C fail, reference pass).</summary>
    public string[] FailedOn { get; set; } = [];

    /// <summary>Machines on which this TC passed or was not comparable (reference also failed).</summary>
    public string[] PassedOn { get; set; } = [];
}
