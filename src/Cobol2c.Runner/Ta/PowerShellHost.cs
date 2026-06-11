using System.Diagnostics;
using System.Text.Json;

namespace Cobol2c.Runner.Ta;

/// <summary>
/// Runs a PowerShell script as a child process, captures stdout JSON, and deserializes it.
/// The script must emit a single ConvertTo-Json object to stdout and exit 0 on success.
/// </summary>
public class PowerShellHost
{
    private static readonly JsonSerializerOptions _jsonOpts = new()
    {
        PropertyNameCaseInsensitive = true   // PS ConvertTo-Json emits PascalCase; C# models use PascalCase too
    };

    public async Task<T> RunScriptAsync<T>(string scriptPath, IEnumerable<string> namedArgs, CancellationToken ct)
    {
        var psi = new ProcessStartInfo
        {
            FileName = "pwsh",
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };

        psi.ArgumentList.Add("-NoProfile");
        psi.ArgumentList.Add("-File");
        psi.ArgumentList.Add(scriptPath);
        foreach (var arg in namedArgs)
            psi.ArgumentList.Add(arg);

        using var process = new Process { StartInfo = psi };
        process.Start();

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
