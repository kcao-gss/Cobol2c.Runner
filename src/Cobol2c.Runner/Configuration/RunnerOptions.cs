namespace Cobol2c.Runner.Configuration;

public class RunnerOptions
{
    /// <summary>
    /// When true, uses local mock implementations instead of real TA/HTTP ones.
    /// Set to false on the GSS network box for production.
    /// </summary>
    public bool UseMocks { get; set; } = true;

    /// <summary>Path to the fixtures/ directory (absolute or relative to working dir).</summary>
    public string FixturesPath { get; set; } = "fixtures";

    /// <summary>Directory where LocalFileJobSource watches for *.json job files.</summary>
    public string JobsPath { get; set; } = "fixtures/jobs";

    /// <summary>Directory where LocalJsonResultSink writes output files.</summary>
    public string OutputPath { get; set; } = "out";

    /// <summary>
    /// Directory containing the PowerShell scripts (TaParsing.psm1, Invoke-Triage.ps1, etc.).
    /// Resolved relative to the runner executable when relative.
    /// </summary>
    public string ScriptsPath { get; set; } = "scripts";

    /// <summary>How long to wait between job polls when the queue is empty.</summary>
    public int PollIntervalMs { get; set; } = 2000;

    // --- Production-only settings (ignored when UseMocks = true) ---

    /// <summary>Base URL for the Launchpad dashboard API (e.g. https://cobol2c.globalshopsolutions.dev).</summary>
    public string? DashboardApiUrl { get; set; }

    /// <summary>Launchpad Job Client id for M2M auth (client_credentials flow).</summary>
    public string? JobClientId { get; set; }

    /// <summary>Launchpad Job Client secret. In production, load from environment / Launchpad secrets.</summary>
    public string? JobClientSecret { get; set; }
}
