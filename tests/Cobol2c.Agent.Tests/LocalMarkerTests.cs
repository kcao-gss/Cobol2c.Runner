using Xunit;

namespace Cobol2c.Agent.Tests;

/// <summary>
/// Unit tests for LocalMarkerPoller -- the started.txt/finished.txt polling logic.
/// Writes real marker files to a temp dir; no batch or TA process runs.
/// </summary>
public class LocalMarkerTests
{
    private static string MakeTempDir()
    {
        var dir = Path.Combine(Path.GetTempPath(), $"Cobol2c.Marker_{Guid.NewGuid():N}");
        Directory.CreateDirectory(dir);
        return dir;
    }

    /// <summary>finished.txt with correct token -> Completed=true within deadline.</summary>
    [Fact]
    public async Task FinishedWithToken_ReturnsCompleted()
    {
        var dir = MakeTempDir();
        try
        {
            const string token   = "test-run-token";
            var started  = Path.Combine(dir, "started.txt");
            var finished = Path.Combine(dir, "finished.txt");

            await File.WriteAllTextAsync(started, "[STARTED]");
            _ = Task.Run(async () => { await Task.Delay(200); await File.WriteAllTextAsync(finished, token); });

            var result = await LocalMarkerPoller.PollAsync(
                dir, token, hardDeadlineSeconds: 10, idleLimitSeconds: 60,
                pollIntervalMs: 50, CancellationToken.None);

            Assert.True(result.Completed);
            Assert.False(result.TimedOut);
            Assert.False(result.Idle);
        }
        finally { Directory.Delete(dir, recursive: true); }
    }

    /// <summary>
    /// finished.txt starts with a stale token; poller keeps polling until the correct token appears.
    /// We overwrite the file from the main test task after launching the poll.
    /// </summary>
    [Fact]
    public async Task StaleToken_KeepsPollingUntilCorrect()
    {
        var dir = MakeTempDir();
        try
        {
            const string correct  = "correct-token";
            var started  = Path.Combine(dir, "started.txt");
            var finished = Path.Combine(dir, "finished.txt");

            await File.WriteAllTextAsync(started, "[STARTED]");
            await File.WriteAllTextAsync(finished, "stale-token");

            // Start poll in background; overwrite finished.txt with correct token after 200ms
            var pollTask = LocalMarkerPoller.PollAsync(
                dir, correct, hardDeadlineSeconds: 10, idleLimitSeconds: 60,
                pollIntervalMs: 50, CancellationToken.None);

            await Task.Delay(200);
            await File.WriteAllTextAsync(finished, correct);

            var result = await pollTask;
            Assert.True(result.Completed);
        }
        finally { Directory.Delete(dir, recursive: true); }
    }

    /// <summary>Hard deadline expires before finished.txt -> TimedOut=true.</summary>
    [Fact]
    public async Task HardDeadline_ReturnsTimedOut()
    {
        var dir = MakeTempDir();
        try
        {
            await File.WriteAllTextAsync(Path.Combine(dir, "started.txt"), "[STARTED]");

            var result = await LocalMarkerPoller.PollAsync(
                dir, "never-written", hardDeadlineSeconds: 1, idleLimitSeconds: 60,
                pollIntervalMs: 50, CancellationToken.None);

            Assert.False(result.Completed);
            Assert.True(result.TimedOut);
        }
        finally { Directory.Delete(dir, recursive: true); }
    }

    /// <summary>started.txt idle for idleLimit -> Idle=true (TA crash simulation).</summary>
    [Fact]
    public async Task StartedIdle_ReturnsIdle()
    {
        var dir = MakeTempDir();
        try
        {
            await File.WriteAllTextAsync(Path.Combine(dir, "started.txt"), "[STARTED]");
            await Task.Delay(50);

            var result = await LocalMarkerPoller.PollAsync(
                dir, "no-finish", hardDeadlineSeconds: 10, idleLimitSeconds: 1,
                pollIntervalMs: 50, CancellationToken.None);

            Assert.False(result.Completed);
            Assert.True(result.Idle);
        }
        finally { Directory.Delete(dir, recursive: true); }
    }
}