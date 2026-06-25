namespace Cobol2c.Agent;

/// <summary>
/// A single TC verdict recorded during a job run.
/// </summary>
public sealed record TcVerdict(int Tc, string Verdict);

/// <summary>
/// Per-job progress persisted to disk so the agent can resume after a crash.
/// Written when a job starts; updated after each TC completes; deleted on full completion.
/// </summary>
public sealed class JobState
{
    public string JobId         { get; set; } = "";
    public string Suite         { get; set; } = "";
    public List<int> AllTcs     { get; set; } = new();
    public List<TcVerdict> Done { get; set; } = new();
    public List<int> Pending    { get; set; } = new();

    /// <summary>
    /// How many times this job has been resumed after a crash.
    /// Recovery is attempted while RecoveryCount &lt; RecoveryCap.
    /// </summary>
    public int RecoveryCount { get; set; }
}
