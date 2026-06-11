using System.ComponentModel;
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using Cobol2c.Runner.Configuration;
using Microsoft.Extensions.Options;

namespace Cobol2c.Runner.Ta;

/// <summary>
/// Runs a PowerShell script as a child process, captures stdout JSON, and deserializes it.
/// The script must emit a single ConvertTo-Json object to stdout and exit 0 on success.
///
/// Supports both PowerShell 7+ ("pwsh") and Windows PowerShell 5.1 ("powershell").
/// If the configured exe is not found, the host falls back to the other automatically.
/// </summary>
public class PowerShellHost
{
    // Mutable so the fallback path can update it and subsequent scripts skip the probe.
    private string _exe;

    private static readonly JsonSerializerOptions _jsonOpts = new()
    {
        PropertyNameCaseInsensitive = true   // PS ConvertTo-Json emits PascalCase; C# models use PascalCase too
    };

    /// <summary>DI constructor — picks up Runner:PowerShellExe from config.</summary>
    public PowerShellHost(IOptions<RunnerOptions> opts) : this(opts.Value.PowerShellExe) { }

    /// <summary>
    /// Direct constructor (used by xUnit tests and single-line construction).
    /// Defaults to "pwsh" (PowerShell 7+). Pass "powershell" for Windows PowerShell 5.1.
    /// </summary>
    public PowerShellHost(string powerShellExe = "pwsh") => _exe = powerShellExe;

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

        // Read stdout and stderr concurrently to avoid deadlocks on large output
        var stdoutTask = process.StandardOutput.ReadToEndAsync(ct);
        var stderrTask = process.StandardError.ReadToEndAsync(ct);

        // Kill the child tree if the cancellation token fires before the process exits.
        // Without this, WaitForExitAsync cancels but the pwsh.exe process keeps running.
        try
        {
            await process.WaitForExitAsync(ct);
        }
        catch (OperationCanceledException)
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); }
            catch { /* process already gone — ignore */ }
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
