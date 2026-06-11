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
    private readonly string _ta01Pw;

    public PowerShellTaExecutor(PowerShellHost ps, IOptions<RunnerOptions> opts)
    {
        _ps = ps;
        _scriptPath = Path.Combine(
            Path.GetFullPath(opts.Value.ScriptsPath),
            "Invoke-TaRun.ps1");
        _ta01Pw = opts.Value.Ta01Pw
            ?? throw new InvalidOperationException(
                "Runner:Ta01Pw is required when UseMocks=false. Set env var Runner__Ta01Pw.");
    }

    public async Task<TaRunResult> ExecuteAsync(TestJob job, CancellationToken ct)
    {
        var args = new[]
        {
            "-Suite",   job.Suite,
            "-Machine", job.Machine,
            "-Tcs",     string.Join(",", job.Tcs),
            "-Logging", job.Logging ? "true" : "false",
            "-Ta01Pw",  _ta01Pw
        };

        return await _ps.RunScriptAsync<TaRunResult>(_scriptPath, args, ct);
    }
}
