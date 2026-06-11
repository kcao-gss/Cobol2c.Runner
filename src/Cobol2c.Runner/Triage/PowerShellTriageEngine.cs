using Cobol2c.Runner.Configuration;
using Cobol2c.Runner.Jobs;
using Cobol2c.Runner.Ta;
using Cobol2c.Runner.Triage.Models;
using Microsoft.Extensions.Options;

namespace Cobol2c.Runner.Triage;

/// <summary>
/// Runs Invoke-Triage.ps1 via PowerShellHost and deserializes the JSON TriageResult.
/// The PS script does the actual parsing (Get-TcResults, Get-FlowDivergence, Get-CrashSignature).
/// </summary>
public class PowerShellTriageEngine : ITriageEngine
{
    private readonly Ta.PowerShellHost _ps;
    private readonly string _scriptPath;

    public PowerShellTriageEngine(Ta.PowerShellHost ps, IOptions<RunnerOptions> opts)
    {
        _ps = ps;
        _scriptPath = Path.Combine(
            Path.GetFullPath(opts.Value.ScriptsPath),
            "Invoke-Triage.ps1");
    }

    public Task<TriageResult> TriageAsync(TestJob job, TaRunResult run, CancellationToken ct)
    {
        var args = new[]
        {
            "-FailLogDir",      run.FailLogDir,
            "-RefLogDir",       run.RefLogDir,
            "-FailCoreLogPath", run.FailCoreLogPath ?? "",
            "-RefCoreLogPath",  run.RefCoreLogPath  ?? ""
        };

        return _ps.RunScriptAsync<TriageResult>(_scriptPath, args, ct);
    }
}
