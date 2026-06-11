using Cobol2c.Runner.Jobs;
using Cobol2c.Runner.Triage.Models;

namespace Cobol2c.Runner.Sinks;

public interface IResultSink
{
    /// <summary>Persist the triage result and report. Local impl writes to ./out/; production POSTs to the dashboard API.</summary>
    Task SaveAsync(TestJob job, TriageResult triage, string report, CancellationToken ct);
}
