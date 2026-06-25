namespace Cobol2c.Agent;

public sealed record PollResult(bool Completed, bool TimedOut, bool Idle);

/// <summary>
/// Polls local started.txt / finished.txt marker files written by the TA batch.
/// Extracted for unit-testability without a running batch.
///
/// Contract mirrors Invoke-LocalRun.ps1 polling loop:
///   Completed when finished.txt contains exactly token.
///   TimedOut  when hardDeadline elapses before finished.txt appears.
///   Idle      when started.txt stops changing for idleLimit (TA crash signal).
/// </summary>
public static class LocalMarkerPoller
{
    public static async Task<PollResult> PollAsync(
        string htmlDir, string token,
        int hardDeadlineSeconds, int idleLimitSeconds, int pollIntervalMs,
        CancellationToken ct)
    {
        var startedFile  = Path.Combine(htmlDir, "started.txt");
        var finishedFile = Path.Combine(htmlDir, "finished.txt");
        var deadline     = DateTime.UtcNow.AddSeconds(hardDeadlineSeconds);
        var idleLimit    = TimeSpan.FromSeconds(idleLimitSeconds);
        DateTime? lastMtime  = null;
        var lastProgress = DateTime.UtcNow;

        while (DateTime.UtcNow < deadline && !ct.IsCancellationRequested)
        {
            if (File.Exists(finishedFile))
            {
                try
                {
                    string c;
                    using (var fs = new FileStream(finishedFile, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                    using (var sr = new StreamReader(fs))
                        c = await sr.ReadToEndAsync(ct);
                    if (c.Trim() == token)
                        return new PollResult(Completed: true, TimedOut: false, Idle: false);
                }
                catch (IOException) { /* file locked by writer; retry */ }
            }

            if (File.Exists(startedFile))
            {
                try
                {
                    var mtime = File.GetLastWriteTimeUtc(startedFile);
                    if (lastMtime == null || mtime != lastMtime)
                    {
                        lastMtime    = mtime;
                        lastProgress = DateTime.UtcNow;
                    }
                    if (lastMtime.HasValue && (DateTime.UtcNow - lastProgress) > idleLimit)
                        return new PollResult(Completed: false, TimedOut: false, Idle: true);
                }
                catch (IOException) { /* transient; retry */ }
            }

            await Task.Delay(pollIntervalMs, ct);
        }

        return new PollResult(Completed: false, TimedOut: true, Idle: false);
    }
}