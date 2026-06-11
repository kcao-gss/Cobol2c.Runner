namespace Cobol2c.Runner.Jobs;

/// <summary>
/// A single test run request: run the given TCs on a specific VM against a suite,
/// then triage any regressions and produce a bug report.
/// </summary>
public record TestJob(
    string Id,
    string Suite,      // "Cobol2C" | "SP2V6" | "Production"
    string Machine,    // VM name, e.g. "TGFTA-57"
    int[] Tcs,
    bool Logging
);
