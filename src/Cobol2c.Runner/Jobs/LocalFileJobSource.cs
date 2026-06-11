using System.Collections.Concurrent;
using System.Text.Json;
using Cobol2c.Runner.Configuration;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Cobol2c.Runner.Jobs;

/// <summary>
/// PoC job source: watches a local directory for *.json job files.
/// CompleteJob → moves the file to done/.
/// FailJob → moves the file to failed/.
/// Swap for HttpJobSource when wiring to the Launchpad dashboard API.
/// </summary>
public class LocalFileJobSource : IJobSource
{
    private readonly string _jobsDir;
    private readonly string _doneDir;
    private readonly string _failedDir;
    private readonly ILogger<LocalFileJobSource> _logger;

    // Tracks the source path of each in-flight job so MoveJobFile doesn't need to
    // re-enumerate the directory or scan file contents to find it again.
    private readonly ConcurrentDictionary<string, string> _inflight = new();

    private static readonly JsonSerializerOptions _jsonOpts = new() { PropertyNameCaseInsensitive = true };

    public LocalFileJobSource(IOptions<RunnerOptions> opts, ILogger<LocalFileJobSource> logger)
    {
        _jobsDir   = Path.GetFullPath(opts.Value.JobsPath);
        _doneDir   = Path.Combine(_jobsDir, "done");
        _failedDir = Path.Combine(_jobsDir, "failed");
        _logger    = logger;

        Directory.CreateDirectory(_doneDir);
        Directory.CreateDirectory(_failedDir);
    }

    public Task<TestJob?> PollAsync(CancellationToken ct)
    {
        var file = Directory.EnumerateFiles(_jobsDir, "*.json", SearchOption.TopDirectoryOnly).FirstOrDefault();
        if (file is null)
            return Task.FromResult<TestJob?>(null);

        string json;
        try
        {
            json = File.ReadAllText(file);
        }
        catch (IOException ex)
        {
            // File was removed or locked between the enumerate and read (TOCTOU).
            _logger.LogDebug(ex, "Job file {File} unreadable (moved/locked); skipping this poll.", file);
            return Task.FromResult<TestJob?>(null);
        }

        TestJob? job;
        try
        {
            job = JsonSerializer.Deserialize<TestJob>(json, _jsonOpts);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to deserialize job file {File}.", file);
            return Task.FromResult<TestJob?>(null);
        }

        if (job is null)
        {
            _logger.LogWarning("Could not deserialize {File}; skipping.", file);
            return Task.FromResult<TestJob?>(null);
        }

        // Validate required fields so a malformed job doesn't NRE inside Worker.
        if (string.IsNullOrWhiteSpace(job.Id)      ||
            string.IsNullOrWhiteSpace(job.Suite)   ||
            string.IsNullOrWhiteSpace(job.Machine) ||
            job.Tcs is null || job.Tcs.Length == 0)
        {
            _logger.LogWarning("Job file {File} is missing required fields (Id/Suite/Machine/Tcs); moving to failed.", file);
            try { File.Move(file, Path.Combine(_failedDir, Path.GetFileName(file)), overwrite: true); }
            catch (Exception ex) { _logger.LogError(ex, "Could not move invalid job file {File}.", file); }
            return Task.FromResult<TestJob?>(null);
        }

        // Record the source path; Complete/FailJobAsync will use it to move the file.
        _inflight[job.Id] = file;
        _logger.LogInformation("Picked up job {JobId} from {File}", job.Id, file);
        return Task.FromResult<TestJob?>(job);
    }

    public Task CompleteJobAsync(TestJob job, CancellationToken ct)
    {
        MoveJobFile(job.Id, _doneDir);
        _logger.LogInformation("Job {JobId} completed.", job.Id);
        return Task.CompletedTask;
    }

    public Task FailJobAsync(TestJob job, string reason, CancellationToken ct)
    {
        MoveJobFile(job.Id, _failedDir);
        _logger.LogWarning("Job {JobId} failed: {Reason}", job.Id, reason);
        return Task.CompletedTask;
    }

    private void MoveJobFile(string jobId, string targetDir)
    {
        if (!_inflight.TryRemove(jobId, out var src) || !File.Exists(src))
        {
            _logger.LogWarning("No tracked job file for {JobId}; cannot move to {Dir}.", jobId, targetDir);
            return;
        }
        File.Move(src, Path.Combine(targetDir, Path.GetFileName(src)), overwrite: true);
    }
}
