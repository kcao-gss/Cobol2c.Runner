using Cobol2c.Runner.Configuration;
using Cobol2c.Runner.Jobs;
using Microsoft.Extensions.Options;

namespace Cobol2c.Runner.Ta;

/// <summary>
/// Production executor: shells out to Invoke-TaRun.ps1, which pushes TA test execution to the
/// remote VM via schtasks /s + SMB (same mechanism as the proven run-ta-tests skill).
/// The runner runs on a central controller host; the VM must have TA01 logged in with desktop unlocked.
/// Results (HTML, CoreLogs) are written by the VM to TAShare and read back via UNC.
///
/// Prerequisite: one-time per-VM admin setup via Setup-Vm.ps1
///   (LocalAccountTokenFilterPolicy=1, Remote Scheduled Tasks firewall rule, Apps share + TA-CMD).
/// Requires VPN access to \\gss2k19rnd.gss.local (TAShare reads and result writes).
/// </summary>
public class PowerShellTaExecutor : ITaExecutor
{
    private readonly PowerShellHost _ps;
    private readonly string _scriptPath;
    private readonly string? _ta01Pw;
    private readonly bool _autoRecover;

    public PowerShellTaExecutor(PowerShellHost ps, IOptions<RunnerOptions> opts)
    {
        _ps = ps;
        _scriptPath = Path.Combine(
            Path.GetFullPath(opts.Value.ScriptsPath),
            "Invoke-TaRun.ps1");
        _ta01Pw      = opts.Value.Ta01Pw;
        _autoRecover = opts.Value.AutoRecover;
    }

    public async Task<TaRunResult> ExecuteAsync(TestJob job, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(_ta01Pw))
            throw new InvalidOperationException(
                "Runner:Ta01Pw is required for remote-push execution. " +
                "Set the Runner__Ta01Pw environment variable (the TA01 local account password on the VM).");

        var args = new[]
        {
            "-Suite",        job.Suite,
            "-Machine",      job.Machine,
            "-Tcs",          string.Join(",", job.Tcs),
            "-Logging",      job.Logging ? "true" : "false",
            "-Ta01Pw",       _ta01Pw,
            "-AutoRecover",  _autoRecover ? "true" : "false"
        };

        return await _ps.RunScriptAsync<TaRunResult>(_scriptPath, args, ct);
    }
}
