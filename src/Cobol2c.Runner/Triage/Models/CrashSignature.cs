namespace Cobol2c.Runner.Triage.Models;

/// <summary>
/// Parsed crash evidence from a Cobol2C AutoTrace CoreLog.
/// Field names match the PascalCase keys emitted by Invoke-Triage.ps1 / ConvertTo-Json.
/// </summary>
public class CrashSignature
{
    /// <summary>True if a SYS032 entry was found in the log.</summary>
    public bool HasSys032 { get; set; }

    /// <summary>True if the log ends without an EndTask marker (unclean shutdown).</summary>
    public bool HasMissingEndTask { get; set; }

    /// <summary>
    /// The COBOL call chain from the STRING: line, e.g. "INV010XR&lt;-INV010XR&lt;-INVMAIN&lt;-GSSMENU".
    /// Leaf program is first.
    /// </summary>
    public string? CallChain { get; set; }

    /// <summary>.NET exception stack frames extracted from the Exception Callstack lines.</summary>
    public string[] DotNetStack { get; set; } = [];

    /// <summary>
    /// The C# program that was active (routed to C#) at the time of the SYS032.
    /// Derived from the nearest preceding "Calling C# Program | &lt;PGM&gt;" line.
    /// </summary>
    public string? ActiveCsharpProgram { get; set; }

    /// <summary>True when SYS032 is immediately followed by MSG100 — the canonical conversion crash pattern.</summary>
    public bool SmokingGun { get; set; }
}
