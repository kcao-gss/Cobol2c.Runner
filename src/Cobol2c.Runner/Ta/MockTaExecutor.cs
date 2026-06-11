using Cobol2c.Runner.Configuration;
using Cobol2c.Runner.Jobs;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Cobol2c.Runner.Ta;

/// <summary>
/// PoC executor: returns pre-baked fixture paths instead of launching a real TA run.
/// Simulates a completed run where:
///   - Cobol2C produced at least one failing HTML + a CoreLog with SYS032→MSG100.
///   - Reference produced a passing HTML + a clean CoreLog with EndTask.
/// Swap for PowerShellTaExecutor when running on the GSS network box.
/// </summary>
public class MockTaExecutor : ITaExecutor
{
    private readonly string _fixturesPath;
    private readonly ILogger<MockTaExecutor> _logger;

    public MockTaExecutor(IOptions<RunnerOptions> opts, ILogger<MockTaExecutor> logger)
    {
        _fixturesPath = Path.GetFullPath(opts.Value.FixturesPath);
        _logger = logger;
    }

    public Task<TaRunResult> ExecuteAsync(TestJob job, CancellationToken ct)
    {
        _logger.LogInformation(
            "[MOCK] Skipping real TA execution for job {JobId} (suite={Suite}, machine={Machine}).",
            job.Id, job.Suite, job.Machine);

        var failLogDir  = Path.Combine(_fixturesPath, "ta-results", "cobol2c");
        var refLogDir   = Path.Combine(_fixturesPath, "ta-results", "reference");
        var failCorelog = Path.Combine(_fixturesPath, "corelogs", "cobol2c", "CoreLog_20260609.glog");
        var refCorelog  = Path.Combine(_fixturesPath, "corelogs", "reference", "CoreLog_20260609.glog");

        var result = new TaRunResult(
            FailLogDir:       failLogDir,
            RefLogDir:        refLogDir,
            FailCoreLogPath:  File.Exists(failCorelog) ? failCorelog : null,
            RefCoreLogPath:   File.Exists(refCorelog)  ? refCorelog  : null
        );

        _logger.LogDebug("Mock TaRunResult: FailLog={FailLog}, RefLog={RefLog}", failLogDir, refLogDir);
        return Task.FromResult(result);
    }
}
