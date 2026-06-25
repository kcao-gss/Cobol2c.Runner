using System.ComponentModel;
using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace Cobol2c.Runner.Ta;

/// <summary>
/// Runs a PowerShell script as a child process, captures stdout JSON, and deserializes it.
/// The script must emit a single ConvertTo-Json object to stdout and exit 0 on success.
///
/// Supports both PowerShell 7+ ("pwsh") and Windows PowerShell 5.1 ("powershell").
/// If the configured exe is not found, the host falls back to the other automatically.
/// Registered via a factory lambda in Program.cs to avoid DI constructor ambiguity.
/// </summary>
public class PowerShellHost
{
    // Mutable so the fallback path can update it and subsequent scripts skip the probe.
    private string _exe;
    private readonly TimeSpan _jobTimeout;

    private static readonly JsonSerializerOptions _jsonOpts = new()
    {
        PropertyNameCaseInsensitive = true   // PS ConvertTo-Json emits PascalCase; C# models use PascalCase too
    };

    /// <summary>
    /// Defaults to "pwsh" (PowerShell 7+). Pass "powershell" for Windows PowerShell 5.1.
    /// Program.cs supplies the configured value from RunnerOptions.PowerShellExe.
    /// jobTimeout controls how long a single script may run before it is killed and the job is
    /// routed to failed/. Defaults to 2 hours (two full 45-min poll cycles + buffer).
    /// </summary>
    public PowerShellHost(string powerShellExe = "pwsh", TimeSpan jobTimeout = default)
    {
        _exe        = powerShellExe;
        _jobTimeout = jobTimeout == default ? TimeSpan.FromHours(2) : jobTimeout;
    }

    public async Task<T> RunScriptAsync<T>(string scriptPath, IEnumerable<string> namedArgs, CancellationToken ct)
    {
        var psi = new ProcessStartInfo
        {
            FileName = _exe,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            // Force UTF-8 on the pipe so non-ASCII log content round-trips correctly on
            // both PS 5.1 (default: system code page) and PS 7 (default: UTF-8 already).
            StandardOutputEncoding = new UTF8Encoding(false),
            StandardErrorEncoding  = new UTF8Encoding(false)
        };

        psi.ArgumentList.Add("-NoProfile");
        psi.ArgumentList.Add("-File");
        psi.ArgumentList.Add(scriptPath);
        foreach (var arg in namedArgs)
            psi.ArgumentList.Add(arg);

        using var process = new Process { StartInfo = psi };

        // Auto-fallback: if the configured exe isn't installed, try the other known shell once.
        // Subsequent calls reuse the cached fallback exe via the updated _exe field.
        try
        {
            process.Start();
        }
        catch (Win32Exception) when (_exe is "pwsh" or "powershell")
        {
            var fallback = _exe == "pwsh" ? "powershell" : "pwsh";
            psi.FileName = _exe = fallback;   // cache so we don't probe on every call
            process.StartInfo = psi;
            process.Start();
        }

        // Link the caller's token with a per-job timeout so a locked/unreachable VM
        // fails fast instead of hanging for the script's full poll loop (~90 min worst case).
        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeoutCts.CancelAfter(_jobTimeout);
        var jobCt = timeoutCts.Token;

        // Read stdout and stderr concurrently to avoid deadlocks on large output
        var stdoutTask = process.StandardOutput.ReadToEndAsync(jobCt);
        var stderrTask = process.StandardError.ReadToEndAsync(jobCt);

        // Kill the child tree if cancellation fires (host shutdown OR our timeout above).
        // Without this, WaitForExitAsync cancels but the pwsh.exe process keeps running.
        bool timedOut = false;
        try
        {
            await process.WaitForExitAsync(jobCt);
        }
        catch (OperationCanceledException)
        {
            timedOut = !ct.IsCancellationRequested;   // true = our timeout, false = host shutdown
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); }
            catch { /* process already gone — ignore */ }
            if (timedOut)
                throw new TimeoutException(
                    $"{Path.GetFileName(scriptPath)} did not complete within {_jobTimeout.TotalMinutes:0} minutes. " +
                    "Check that the target VM is reachable and the TA01 desktop is unlocked.");
            throw;
        }

        var stdout = await stdoutTask;
        var stderr = await stderrTask;

        if (process.ExitCode != 0)
            throw new InvalidOperationException(
                $"pwsh exited {process.ExitCode} running {Path.GetFileName(scriptPath)}.\nstderr: {stderr}");

        try
        {
            return JsonSerializer.Deserialize<T>(stdout, _jsonOpts)
                   ?? throw new InvalidOperationException("Script returned null JSON.");
        }
        catch (JsonException ex)
        {
            throw new InvalidOperationException(
                $"Failed to deserialize output of {Path.GetFileName(scriptPath)}: {ex.Message}\nstdout: {stdout}");
        }
    }
}
