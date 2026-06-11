using Cobol2c.Runner.Jobs;
using Cobol2c.Runner.Triage.Models;

namespace Cobol2c.Runner.Sinks;

/// <summary>
/// Production result sink: POSTs the triage result and report to the Launchpad dashboard API.
/// Not implemented in the PoC.
/// </summary>
public class HttpResultSink : IResultSink
{
    public Task SaveAsync(TestJob job, TriageResult triage, string report, CancellationToken ct)
        => throw new NotImplementedException(
            "HttpResultSink is not implemented in the PoC. Set Runner:UseMocks=true.");
}
