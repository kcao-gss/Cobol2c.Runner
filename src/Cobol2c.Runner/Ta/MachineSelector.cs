using Cobol2c.Runner.Configuration;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Cobol2c.Runner.Ta;

/// <summary>
/// Probes machines from the configured pool in parallel and returns the first N that are ready.
/// Used by Worker.cs to select machines for confirmation runs before each job.
/// Each probe calls Test-VmReady.ps1 via PowerShellHost; Assert-VmReady inside the script
/// verifies the Apps share and schtasks RPC are reachable before we commit to a machine.
/// </summary>
public class MachineSelector
{
    private readonly PowerShellHost _ps;
    private readonly string _scriptPath;
    private readonly string? _ta01Pw;
    private readonly ILogger<MachineSelector> _logger;

    public MachineSelector(PowerShellHost ps, IOptions<RunnerOptions> opts, ILogger<MachineSelector> logger)
    {
        _ps = ps;
        _scriptPath = Path.Combine(Path.GetFullPath(opts.Value.ScriptsPath), "Test-VmReady.ps1");
        _ta01Pw     = opts.Value.Ta01Pw;
        _logger     = logger;
    }

    /// <summary>
    /// Returns the first <paramref name="count"/> machines from <paramref name="pool"/> that pass
    /// the readiness probe. All machines are probed in parallel; the first N ready ones are returned.
    /// If fewer than <paramref name="count"/> machines pass, returns however many did — callers
    /// should log and handle the degraded case (fewer confirmation runs than configured).
    /// </summary>
    public async Task<string[]> SelectAsync(string[] pool, int count, CancellationToken ct)
    {
        var probeTasks = pool.Select(m => ProbeOneAsync(m, ct)).ToArray();
        var results    = await Task.WhenAll(probeTasks);

        var ready = results
            .Where(r => r.Ready)
            .Select(r => r.Machine)
            .Take(count)
            .ToArray();

        if (ready.Length < count)
            _logger.LogWarning(
                "Only {Ready}/{Needed} machines ready from pool [{Pool}]. " +
                "Proceeding with reduced confirmation count.",
                ready.Length, count, string.Join(", ", pool));

        return ready;
    }

    private async Task<(string Machine, bool Ready)> ProbeOneAsync(string machine, CancellationToken ct)
    {
        try
        {
            var args   = new[] { "-Machine", machine, "-Ta01Pw", _ta01Pw ?? "" };
            var result = await _ps.RunScriptAsync<MachineReadyResult>(_scriptPath, args, ct);
            if (!result.Ready)
                _logger.LogDebug("Machine {Machine} not ready: {Reason}", machine, result.Reason);
            return (machine, result.Ready);
        }
        catch (Exception ex)
        {
            _logger.LogDebug("Machine {Machine} probe threw: {Message}", machine, ex.Message);
            return (machine, false);
        }
    }
}

/// <summary>JSON model emitted by Test-VmReady.ps1.</summary>
internal sealed class MachineReadyResult
{
    public bool    Ready  { get; set; }
    public string? Reason { get; set; }
}
