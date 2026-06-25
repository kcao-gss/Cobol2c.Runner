namespace Cobol2c.Agent;

public class AgentOptions
{
    /// <summary>Base URL of the orchestrator, e.g. http://localhost:5100</summary>
    public string OrchestratorUrl { get; set; } = "http://localhost:5100";

    /// <summary>Logical agent identifier sent as ?agent= in GET /jobs/next.</summary>
    public string AgentId { get; set; } = Environment.MachineName;

    /// <summary>Milliseconds to sleep when queue is empty.</summary>
    public int PollIntervalMs { get; set; } = 3000;

    /// <summary>PowerShell executable: pwsh (7+) or powershell (5.1).</summary>
    public string PowerShellExe { get; set; } = "pwsh";

    /// <summary>Directory containing Invoke-LocalRun.ps1 and tc-manifest.json.</summary>
    public string ScriptsPath { get; set; } = "scripts";

    /// <summary>Local staging path for TAShare/<Suite> (needs Bin/ + Plugins/ subdirs).</summary>
    public string LocalBase { get; set; } = @"C:\Cobol2c.Staging";

    /// <summary>Per-job timeout in minutes.</summary>
    public int JobTimeoutMinutes { get; set; } = 120;
}