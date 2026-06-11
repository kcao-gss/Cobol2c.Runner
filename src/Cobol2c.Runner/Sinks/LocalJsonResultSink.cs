using System.Text.Json;
using Cobol2c.Runner.Configuration;
using Cobol2c.Runner.Jobs;
using Cobol2c.Runner.Triage.Models;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Cobol2c.Runner.Sinks;

/// <summary>
/// PoC result sink: writes the TriageResult JSON and markdown report to ./out/.
/// Swap for HttpResultSink to POST results to the Launchpad dashboard API.
/// </summary>
public class LocalJsonResultSink : IResultSink
{
    private static readonly JsonSerializerOptions _jsonOpts = new() { WriteIndented = true };

    private readonly string _outDir;
    private readonly ILogger<LocalJsonResultSink> _logger;

    public LocalJsonResultSink(IOptions<RunnerOptions> opts, ILogger<LocalJsonResultSink> logger)
    {
        _outDir = Path.GetFullPath(opts.Value.OutputPath);
        _logger = logger;
        Directory.CreateDirectory(_outDir);
    }

    public async Task SaveAsync(TestJob job, TriageResult triage, string report, CancellationToken ct)
    {
        var jsonPath   = Path.Combine(_outDir, $"{job.Id}.json");
        var reportPath = Path.Combine(_outDir, $"{job.Id}-report.md");

        await File.WriteAllTextAsync(jsonPath, JsonSerializer.Serialize(triage, _jsonOpts), ct);
        await File.WriteAllTextAsync(reportPath, report, ct);

        _logger.LogInformation(
            "Saved triage result → {JsonPath}", jsonPath);
        _logger.LogInformation(
            "Saved bug report   → {ReportPath}", reportPath);
    }
}
