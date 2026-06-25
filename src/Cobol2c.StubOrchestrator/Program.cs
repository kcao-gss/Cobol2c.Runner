using System.Text.Json;
using Cobol2c.Runner.Jobs;
using Cobol2c.Runner.Ta;

// ---- A/B pair of jobs (full TC manifest, Cobol2C vs SP2V6) dispatched in order --------
// Returned one at a time; subsequent GET /jobs/next calls return 204 when empty.
var jobQueue = new System.Collections.Concurrent.ConcurrentQueue<TestJob>(new[]
{
    new TestJob(
        Id:      "ab-cobol2c",
        Suite:   "Cobol2C",
        Machine: Environment.MachineName,
        Tcs:     new[] { 27510, 27513, 27514, 27529, 27533, 27537 },
        Logging: true),
    new TestJob(
        Id:      "ab-sp2v6",
        Suite:   "SP2V6",
        Machine: Environment.MachineName,
        Tcs:     new[] { 27510, 27513, 27514, 27529, 27533, 27537 },
        Logging: true),
});
var resultsDir = Path.Combine(AppContext.BaseDirectory, "results");
Directory.CreateDirectory(resultsDir);

var json = new JsonSerializerOptions { WriteIndented = true, PropertyNameCaseInsensitive = true };

var builder = WebApplication.CreateBuilder(args);
builder.Logging.SetMinimumLevel(LogLevel.Information);
var app = builder.Build();

// GET /jobs/next?agent=<id>
app.MapGet("/jobs/next", (string? agent, ILogger<Program> log) =>
{
    if (!jobQueue.TryDequeue(out var job))
    {
        log.LogInformation("[orch] GET /jobs/next from {Agent} -> 204 (queue empty)", agent);
        return Results.NoContent();
    }
    log.LogInformation("[orch] GET /jobs/next from {Agent} -> dispatching {Id}", agent, job.Id);
    return Results.Ok(job);
});

// POST /jobs/{id}/result -- saves TaRunResult JSON to results/<id>.json
app.MapPost("/jobs/{id}/result", async (string id, HttpRequest req, ILogger<Program> log) =>
{
    TaRunResult? result;
    try { result = await req.ReadFromJsonAsync<TaRunResult>(json); }
    catch (Exception ex)
    {
        log.LogError(ex, "[orch] POST /jobs/{Id}/result -- deserialize failed", id);
        return Results.BadRequest("Invalid TaRunResult JSON.");
    }

    var outPath = Path.Combine(resultsDir, $"{id}.json");
    await File.WriteAllTextAsync(outPath, JsonSerializer.Serialize(result, json));

    log.LogInformation(
        "[orch] Job {Id} result saved. FailLog={FailLog} CoreLog={Core} -> {Out}",
        id, result?.FailLogDir, result?.FailCoreLogPath, outPath);

    return Results.Ok(new { saved = outPath });
});

// POST /jobs/{id}/error -- records executor failures so no job is silently lost
app.MapPost("/jobs/{id}/error", async (string id, HttpRequest req, ILogger<Program> log) =>
{
    string? body = null;
    try
    {
        using var sr = new StreamReader(req.Body);
        body = await sr.ReadToEndAsync();
    }
    catch { /* best-effort read */ }

    var errPath = Path.Combine(resultsDir, $"{id}.error.json");
    await File.WriteAllTextAsync(errPath, body ?? "{}");

    log.LogError("[orch] Job {Id} FAILED on agent. Body saved -> {Path}", id, errPath);
    return Results.Ok(new { saved = errPath });
});

app.Run();

// Expose Program for WebApplicationFactory<Program> in tests
public partial class Program { }