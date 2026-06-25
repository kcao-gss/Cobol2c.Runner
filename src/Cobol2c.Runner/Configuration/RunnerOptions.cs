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

    /// <summary>
    /// PowerShell executable used to run scripts. Use "pwsh" for PowerShell 7+ or "powershell"
    /// for the in-box Windows PowerShell 5.1. If the configured exe is not found at startup,
    /// PowerShellHost falls back to the other automatically.
    /// </summary>
    public string PowerShellExe { get; set; } = "pwsh";

    /// <summary>How long to wait between job polls when the queue is empty.</summary>
    public int PollIntervalMs { get; set; } = 2000;

    // --- Production-only settings (ignored when UseMocks = true) ---

    /// <summary>Base URL for the Launchpad dashboard API (e.g. https://cobol2c.globalshopsolutions.dev).</summary>
    public string? DashboardApiUrl { get; set; }

    /// <summary>Launchpad Job Client id for M2M auth (client_credentials flow).</summary>
    public string? JobClientId { get; set; }

    /// <summary>Launchpad Job Client secret. In production, load from environment / Launchpad secrets.</summary>
    public string? JobClientSecret { get; set; }

    /// <summary>
    /// Per-job timeout in minutes. If the PowerShell script does not exit within this window
    /// (e.g. because the VM is locked or unreachable), the job is cancelled and routed to failed/.
    /// Default 120 min covers two full 45-min poll cycles plus buffer.
    /// Override with env var Runner__JobTimeoutMinutes.
    /// </summary>
    public int JobTimeoutMinutes { get; set; } = 180;

    /// <summary>
    /// When true, automatically recovers a wedged VM (Trigger A: RDP-drop signature;
    /// Trigger B: started.txt idle 45+ min) by rebooting, re-logging in TA01, and retrying
    /// only the affected TCs — capped at 2 recoveries per suite run.
    /// When false, throws an actionable error and moves the job to failed/ for manual retry.
    /// Default true. Override with env var Runner__AutoRecover.
    /// </summary>
    public bool AutoRecover { get; set; } = true;

    /// <summary>
    /// Password for the TA01 account on the target VM (same across all TGFTA-### machines).
    /// Load from environment variable Runner__Ta01Pw — never hardcode.
    /// </summary>
    public string? Ta01Pw { get; set; }
}
