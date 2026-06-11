namespace Cobol2c.Runner.Jobs;

/// <summary>
/// Production job source: polls the Launchpad dashboard API using a Job Client
/// (OAuth 2.0 client_credentials / Launchpad M2M auth).
/// Not implemented in the PoC — plug this in when wiring to the cloud dashboard.
/// </summary>
public class HttpJobSource : IJobSource
{
    public Task<TestJob?> PollAsync(CancellationToken ct)
        => throw new NotImplementedException("HttpJobSource is not implemented in the PoC. Set Runner:UseMocks=true.");

    public Task CompleteJobAsync(TestJob job, CancellationToken ct)
        => throw new NotImplementedException();

    public Task FailJobAsync(TestJob job, string reason, CancellationToken ct)
        => throw new NotImplementedException();
}
