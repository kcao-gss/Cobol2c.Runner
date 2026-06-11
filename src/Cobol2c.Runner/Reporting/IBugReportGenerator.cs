using Cobol2c.Runner.Jobs;
using Cobol2c.Runner.Triage.Models;

namespace Cobol2c.Runner.Reporting;

public interface IBugReportGenerator
{
    /// <summary>Produce a markdown bug report from triage findings.</summary>
    Task<string> GenerateAsync(TestJob job, TriageResult triage, CancellationToken ct);
}
