using System.Text.Json;
using Cobol2c.Runner.Jobs;
using Cobol2c.Runner.Ta;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using Xunit;

namespace Cobol2c.Agent.Tests;

/// <summary>
/// Unit tests for JobStateStore: persist-on-start, update-on-verdict, delete-on-complete,
/// and resume-pending (the recovery foundation).
/// All tests use a temp dir so no real LocalBase is needed.
/// </summary>
public class JobStateTests
{
    private static string MakeTempBase()
    {
        var dir = Path.Combine(Path.GetTempPath(), $"Cobol2c.State_{Guid.NewGuid():N}");
        Directory.CreateDirectory(dir);
        return dir;
    }

    private static JobStateStore MakeStore(string baseDir) =>
        new JobStateStore(baseDir);

    // -----------------------------------------------------------------------
    // 1. Writing / reading
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Start_WritesStateFile()
    {
        var dir   = MakeTempBase();
        var store = MakeStore(dir);
        var job   = new TestJob("job-001", "Cobol2C", "TGFTA-LOCAL", new[] { 100, 101, 102 }, Logging: true);

        await store.StartAsync(job);

        var state = await store.LoadAsync();
        Assert.NotNull(state);
        Assert.Equal("job-001", state!.JobId);
        Assert.Equal(new[] { 100, 101, 102 }, state.AllTcs);
        Assert.Empty(state.Done);
        Assert.Equal(new[] { 100, 101, 102 }, state.Pending);
        Assert.Equal(0, state.RecoveryCount);

        Directory.Delete(dir, recursive: true);
    }

    [Fact]
    public async Task RecordVerdict_UpdatesDoneAndPending()
    {
        var dir   = MakeTempBase();
        var store = MakeStore(dir);
        var job   = new TestJob("job-002", "Cobol2C", "TGFTA-LOCAL", new[] { 200, 201, 202 }, Logging: false);

        await store.StartAsync(job);
        await store.RecordVerdictAsync(200, "pass");
        await store.RecordVerdictAsync(201, "fail");

        var state = await store.LoadAsync();
        Assert.NotNull(state);
        Assert.Equal(2, state!.Done.Count);
        Assert.Single(state.Pending);
        Assert.Equal(202, state.Pending[0]);
        Assert.Equal("pass", state.Done.First(d => d.Tc == 200).Verdict);
        Assert.Equal("fail", state.Done.First(d => d.Tc == 201).Verdict);

        Directory.Delete(dir, recursive: true);
    }

    [Fact]
    public async Task Complete_DeletesStateFile()
    {
        var dir   = MakeTempBase();
        var store = MakeStore(dir);
        var job   = new TestJob("job-003", "Cobol2C", "TGFTA-LOCAL", new[] { 300 }, Logging: false);

        await store.StartAsync(job);
        await store.CompleteAsync();

        var state = await store.LoadAsync();
        Assert.Null(state);   // file gone

        Directory.Delete(dir, recursive: true);
    }

    // -----------------------------------------------------------------------
    // 2. Recovery: LoadAsync returns state when file exists
    // -----------------------------------------------------------------------

    [Fact]
    public async Task LoadAsync_WithPartialState_ReturnsPendingTcs()
    {
        var dir   = MakeTempBase();
        var store = MakeStore(dir);

        // Write a partial state manually (simulates a prior agent run that crashed after TC 400)
        var partial = new JobState
        {
            JobId         = "job-004",
            Suite         = "Cobol2C",
            AllTcs        = new List<int> { 400, 401, 402 },
            Done          = new List<TcVerdict> { new(400, "pass") },
            Pending       = new List<int> { 401, 402 },
            RecoveryCount = 0
        };
        await store.SaveAsync(partial);

        var loaded = await store.LoadAsync();
        Assert.NotNull(loaded);
        Assert.Equal(new[] { 401, 402 }, loaded!.Pending.ToArray());
        Assert.Equal(1, loaded.Done.Count);

        Directory.Delete(dir, recursive: true);
    }

    [Fact]
    public async Task LoadAsync_NoFile_ReturnsNull()
    {
        var dir   = MakeTempBase();
        var store = MakeStore(dir);

        var state = await store.LoadAsync();
        Assert.Null(state);

        Directory.Delete(dir, recursive: true);
    }

    // -----------------------------------------------------------------------
    // 3. Recovery cap: RecoveryCount >= 2 means abandon (don't resume)
    // -----------------------------------------------------------------------

    [Fact]
    public async Task ShouldResume_RecoveryCountAtCap_ReturnsFalse()
    {
        var dir   = MakeTempBase();
        var store = MakeStore(dir);

        var atCap = new JobState
        {
            JobId         = "job-005",
            Suite         = "Cobol2C",
            AllTcs        = new List<int> { 500 },
            Done          = new List<TcVerdict>(),
            Pending       = new List<int> { 500 },
            RecoveryCount = 2
        };
        await store.SaveAsync(atCap);

        var state = await store.LoadAsync();
        Assert.NotNull(state);
        Assert.False(store.ShouldResume(state!));

        Directory.Delete(dir, recursive: true);
    }

    [Fact]
    public async Task ShouldResume_RecoveryCountBelowCap_ReturnsTrue()
    {
        var dir   = MakeTempBase();
        var store = MakeStore(dir);

        var belowCap = new JobState
        {
            JobId         = "job-006",
            Suite         = "Cobol2C",
            AllTcs        = new List<int> { 600 },
            Done          = new List<TcVerdict>(),
            Pending       = new List<int> { 600 },
            RecoveryCount = 1
        };
        await store.SaveAsync(belowCap);

        var state = await store.LoadAsync();
        Assert.NotNull(state);
        Assert.True(store.ShouldResume(state!));

        Directory.Delete(dir, recursive: true);
    }
}
