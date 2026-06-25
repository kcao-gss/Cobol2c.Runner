using Cobol2c.Runner.Jobs;
using Cobol2c.Runner.Ta;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Cobol2c.Agent;

/// <summary>Shells out to Invoke-LocalRun.ps1 via PowerShellHost.</summary>
public class LocalExecutor
{
    private readonly PowerShellHost _ps;
    private readonly string _scriptPath;
    private readonly string _manifestPath;
    private readonly string _localBase;
    private readonly ILogger<LocalExecutor> _logger;

    public LocalExecutor(PowerShellHost ps, IOptions<AgentOptions> opts, ILogger<LocalExecutor> logger)
    {
        var o          = opts.Value;
        var scriptsDir = Path.GetFullPath(o.ScriptsPath);
        _ps           = ps;
        _scriptPath   = Path.Combine(scriptsDir, "Invoke-LocalRun.ps1");
        _manifestPath = Path.Combine(scriptsDir, "tc-manifest.json");
        _localBase    = o.LocalBase;
        _logger       = logger;
    }

    public async Task<TaRunResult> ExecuteAsync(TestJob job, CancellationToken ct)
    {
        _logger.LogInformation(
            "LocalExecutor: job {Id} suite={Suite} tcs={Tcs} localBase={Base}",
            job.Id, job.Suite, string.Join(",", job.Tcs), _localBase);

        var args = new[]
        {
            "-Suite",        job.Suite,
            "-Tcs",          string.Join(",", job.Tcs),
            "-Logging",      job.Logging ? "true" : "false",
            "-ManifestPath", _manifestPath,
            "-LocalBase",    _localBase,
        };
        return await _ps.RunScriptAsync<TaRunResult>(_scriptPath, args, ct);
    }
}