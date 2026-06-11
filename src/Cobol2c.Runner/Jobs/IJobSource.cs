namespace Cobol2c.Runner.Jobs;

public interface IJobSource
{
    /// <summary>Returns the next pending job, or null if the queue is empty.</summary>
    Task<TestJob?> PollAsync(CancellationToken ct);

    /// <summary>Mark the job done and move it out of the queue.</summary>
    Task CompleteJobAsync(TestJob job, CancellationToken ct);

    /// <summary>Mark the job failed (moves to failed/ directory in the local impl).</summary>
    Task FailJobAsync(TestJob job, string reason, CancellationToken ct);
}
