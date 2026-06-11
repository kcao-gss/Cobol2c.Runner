using Cobol2c.Runner.Configuration;
using Cobol2c.Runner.Jobs;
using Microsoft.Extensions.Options;

namespace Cobol2c.Runner.Ta;

/// <summary>
/// Production executor: shells out to Invoke-TaRun.ps1, which reuses the run-ta-tests skill logic
/// (schtasks, SMB, TA CLI) to run tests on a real VM and return the resulting log paths.
/// Only functional on the GSS network box; requires VPN + creds in config/secrets.
/// </summary>
public class PowerShellTaExecutor : ITaExecutor
{
    private readonly PowerShellHost _ps;
    private readonly string _scriptPath;

    public PowerShellTaExecutor(PowerShellHost ps, IOptions<RunnerOptions> opts)
    {
        _ps = ps;
        _scriptPath = Path.Combine(
            Path.GetFullPath(opts.Value.ScriptsPath),
            "Invoke-TaRun.ps1");
    }

    public async Task<TaRunResult> ExecuteAsync(TestJob job, CancellationToken ct)
    {
        var args = new[]
        {
            "-Suite",   job.Suite,
            "-Machine", job.Machine,
            "-Tcs",     string.Join(",", job.Tcs),
            "-Logging", job.Logging ? "true" : "false"
        };

        return await _ps.RunScriptAsync<TaRunResult>(_scriptPath, args, ct);
    }
}
