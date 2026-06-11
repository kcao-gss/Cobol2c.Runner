using Cobol2c.Runner.Jobs;
using Cobol2c.Runner.Triage.Models;

namespace Cobol2c.Runner.Reporting;

/// <summary>
/// Production report generator: calls the Claude API to produce a narrative bug report
/// from the structured TriageResult. Not implemented in the PoC.
/// Swap in via DI when Runner:UseMocks=false and a Claude API key is available in secrets.
/// </summary>
public class ClaudeBugReportGenerator : IBugReportGenerator
{
    public Task<string> GenerateAsync(TestJob job, TriageResult triage, CancellationToken ct)
        => throw new NotImplementedException(
            "ClaudeBugReportGenerator requires the Claude API. Set Runner:UseMocks=true for the PoC.");
}
