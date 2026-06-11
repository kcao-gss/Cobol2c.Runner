namespace Cobol2c.Runner.Triage.Models;

/// <summary>
/// Where the Cobol2C program-flow sequence first diverges from the reference run.
/// Derived by Get-FlowDivergence in TaTrace.psm1.
/// </summary>
public class FlowDivergence
{
    /// <summary>Zero-based index in the flow sequence where the two runs first differ.</summary>
    public int DivergenceIndex { get; set; }

    /// <summary>The step in the failing (Cobol2C) sequence at the divergence point, e.g. "Entering:MSG100".</summary>
    public string? FailingStep { get; set; }

    /// <summary>The step in the reference sequence at the divergence point, e.g. "Leaving:INV010XR".</summary>
    public string? ReferenceStep { get; set; }

    /// <summary>A window of ±3 steps from the failing sequence around the divergence.</summary>
    public string[] FailingContext { get; set; } = [];
}
