using System.Text.Json;
using Cobol2c.Runner.Jobs;
using Cobol2c.Runner.Ta;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using Xunit;

namespace Cobol2c.Agent.Tests;

/// <summary>
/// Tests for per-TC execution loop and state-file integration in JobExecutor.
/// Uses a fake IScriptRunner so no real PowerShell process runs.
/// </summary>
public class PerTcExecutionTests
{
    private static string MakeTempBase()
    {
        var dir = Path.Combine(Path.GetTempPath(), $"Cobol2c.PerTc_{Guid.NewGuid():N}");
        Directory.CreateDirectory(dir);
        return dir;
    }

    private static IOptions<AgentOptions> MakeOpts(string localBase) =>
        Options.Create(new AgentOptions
        {
            OrchestratorUrl   = "http://orch/",
            AgentId           = "test-agent",
            PollIntervalMs    = 0,
            PowerShellExe     = "pwsh",
            ScriptsPath       = "scripts",
            LocalBase         = localBase,
            JobTimeoutMinutes = 1
        });

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    /// <summary>
    /// Fake script runner: returns a pre-baked TaRunResult per TC number,
    /// or a default if no specific mapping provided.
    /// Records which TCs were executed.
    /// </summary>
    private sealed class FakeScriptRunner : IScriptRunner
    {
        private readonly Dictionary<int, TaRunResult> _results;
        public List<int> ExecutedTcs { get; } = new();

        public FakeScriptRunner(Dictionary<int, TaRunResult>? perTcResults = null)
        {
            _results = perTcResults ?? new Dictionary<int, TaRunResult>();
        }

        public Task<TaRunResult> RunAsync(string suite, int tc, bool logging,
            string manifestPath, string localBase, CancellationToken ct)
        {
            ExecutedTcs.Add(tc);
            if (_results.TryGetValue(tc, out var r)) return Task.FromResult(r);
            return Task.FromResult(new TaRunResult(
                FailLogDir:      $@"C:\Temp\{tc}",
                RefLogDir:       $@"C:\Temp\{tc}",
                FailCoreLogPath: null,
                RefCoreLogPath:  null));
        }
    }

    // -----------------------------------------------------------------------
    // Tests
    // -----------------------------------------------------------------------

    [Fact]
    public async Task ExecuteJob_RunsAllTcs_WritesAndDeletesStateFile()
    {
        var dir    = MakeTempBase();
        var opts   = MakeOpts(dir);
        var store  = new JobStateStore(dir);
        var runner = new FakeScriptRunner();
        var exec   = new JobExecutor(runner, store, opts, NullLogger<JobExecutor>.Instance);
        var job    = new TestJob("job-a", "Cobol2C", "TGFTA-LOCAL", new[] { 10, 11, 12 }, Logging: false);

        var result = await exec.ExecuteJobAsync(job, CancellationToken.None);

        // All TCs executed
        Assert.Equal(new[] { 10, 11, 12 }, runner.ExecutedTcs.ToArray());

        // State file cleaned up after completion
        var state = await store.LoadAsync();
        Assert.Null(state);

        // Result aggregates the last TC's dirs (or a merged view — implementation decides)
        Assert.NotNull(result);

        Directory.Delete(dir, recursive: true);
    }

    [Fact]
    public async Task ExecuteJob_WithPartialStateFile_SkipsCompletedTcs()
    {
        var dir   = MakeTempBase();
        var opts  = MakeOpts(dir);
        var store = new JobStateStore(dir);

        // Pre-seed partial state: TC 20 already done, TC 21 still pending
        var partial = new JobState
        {
            JobId         = "job-b",
            Suite         = "Cobol2C",
            AllTcs        = new List<int> { 20, 21 },
            Done          = new List<TcVerdict> { new(20, "pass") },
            Pending       = new List<int> { 21 },
            RecoveryCount = 0
        };
        await store.SaveAsync(partial);

        var runner = new FakeScriptRunner();
        var exec   = new JobExecutor(runner, store, opts, NullLogger<JobExecutor>.Instance);
        var job    = new TestJob("job-b", "Cobol2C", "TGFTA-LOCAL", new[] { 20, 21 }, Logging: false);

        await exec.ExecuteJobAsync(job, CancellationToken.None);

        // Only TC 21 should have been executed (TC 20 was already done)
        Assert.Equal(new[] { 21 }, runner.ExecutedTcs.ToArray());

        Directory.Delete(dir, recursive: true);
    }

    [Fact]
    public async Task ExecuteJob_RecoveryCountAtCap_RunsAllTcsFromScratch()
    {
        var dir   = MakeTempBase();
        var opts  = MakeOpts(dir);
        var store = new JobStateStore(dir);

        // State file at recovery cap — should NOT resume, should restart fresh
        var atCap = new JobState
        {
            JobId         = "job-c",
            Suite         = "Cobol2C",
            AllTcs        = new List<int> { 30, 31 },
            Done          = new List<TcVerdict> { new(30, "pass") },
            Pending       = new List<int> { 31 },
            RecoveryCount = 2   // cap
        };
        await store.SaveAsync(atCap);

        var runner = new FakeScriptRunner();
        var exec   = new JobExecutor(runner, store, opts, NullLogger<JobExecutor>.Instance);
        var job    = new TestJob("job-c", "Cobol2C", "TGFTA-LOCAL", new[] { 30, 31 }, Logging: false);

        await exec.ExecuteJobAsync(job, CancellationToken.None);

        // Both TCs run from scratch (no resume)
        Assert.Equal(new[] { 30, 31 }, runner.ExecutedTcs.ToArray());

        Directory.Delete(dir, recursive: true);
    }
}
