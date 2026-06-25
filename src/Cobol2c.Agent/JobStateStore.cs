using System.Text.Json;

namespace Cobol2c.Agent;

/// <summary>
/// Reads and writes the agent-job-state.json file under <paramref name="baseDir"/>.
/// The file holds progress for the currently executing job so the agent can resume
/// pending TCs after a crash or restart.
/// </summary>
public sealed class JobStateStore
{
    private static readonly JsonSerializerOptions _json =
        new() { PropertyNameCaseInsensitive = true, WriteIndented = true };

    /// <summary>Maximum recovery attempts before abandoning a stale state file.</summary>
    public const int RecoveryCap = 2;

    private readonly string _path;

    public JobStateStore(string baseDir)
    {
        _path = Path.Combine(baseDir, "agent-job-state.json");
    }

    // Expose the path so callers can log it.
    public string FilePath => _path;

    /// <summary>Returns true when a state file exists and RecoveryCount is below cap.</summary>
    public bool ShouldResume(JobState state) => state.RecoveryCount < RecoveryCap;

    // -----------------------------------------------------------------------
    // Persistence
    // -----------------------------------------------------------------------

    public async Task<JobState?> LoadAsync()
    {
        if (!File.Exists(_path)) return null;
        try
        {
            var json = await File.ReadAllTextAsync(_path);
            return JsonSerializer.Deserialize<JobState>(json, _json);
        }
        catch (Exception)
        {
            // Corrupt file — treat as absent; a fresh run will overwrite it.
            return null;
        }
    }

    public async Task SaveAsync(JobState state)
    {
        var json = JsonSerializer.Serialize(state, _json);
        await File.WriteAllTextAsync(_path, json);
    }

    // -----------------------------------------------------------------------
    // Lifecycle helpers called by JobExecutor
    // -----------------------------------------------------------------------

    /// <summary>Write a fresh state file for a new job (or a restarted-from-scratch job).</summary>
    public async Task StartAsync(Cobol2c.Runner.Jobs.TestJob job, int recoveryCount = 0)
    {
        var state = new JobState
        {
            JobId         = job.Id,
            Suite         = job.Suite,
            AllTcs        = job.Tcs.ToList(),
            Done          = new List<TcVerdict>(),
            Pending       = job.Tcs.ToList(),
            RecoveryCount = recoveryCount
        };
        await SaveAsync(state);
    }

    /// <summary>Mark one TC as finished and persist the updated state.</summary>
    public async Task RecordVerdictAsync(int tc, string verdict)
    {
        var state = await LoadAsync()
            ?? throw new InvalidOperationException("State file missing when recording verdict.");
        state.Done.Add(new TcVerdict(tc, verdict));
        state.Pending.Remove(tc);
        await SaveAsync(state);
    }

    /// <summary>Delete the state file after a job fully completes and its result is POSTed.</summary>
    public Task CompleteAsync()
    {
        if (File.Exists(_path)) File.Delete(_path);
        return Task.CompletedTask;
    }
}
