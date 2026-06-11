using System.IO;
using System.Threading;
using System.Threading.Tasks;
using Cobol2c.Runner.Configuration;
using Cobol2c.Runner.Jobs;
using Cobol2c.Runner.Ta;
using Cobol2c.Runner.Triage;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using Xunit;

namespace Cobol2c.Runner.Tests;

/// <summary>
/// Integration tests that run the full triage pipeline using real fixtures and real PowerShell scripts.
/// These tests actually invoke Invoke-Triage.ps1 via PowerShellHost — they prove the scripts work
/// correctly against the synthesized fixture data before touching a real TA VM.
///
/// Prerequisites: pwsh (PowerShell 7+) must be on PATH.
/// </summary>
public class TriagePipelineTests
{
    // Walk up from the test assembly output dir until we find the .sln marker.
    // A fixed number of ".." is fragile to SDK TFM subfolder depth changes.
    private static readonly string RepoRoot = FindRepoRoot();

    private static string FindRepoRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "Cobol2c.Runner.sln")))
            dir = dir.Parent;
        return dir?.FullName
               ?? throw new InvalidOperationException("Cobol2c.Runner.sln not found above test output directory.");
    }

    private static RunnerOptions BuildOptions() => new()
    {
        UseMocks     = true,
        FixturesPath = Path.Combine(RepoRoot, "fixtures"),
        JobsPath     = Path.Combine(RepoRoot, "fixtures", "jobs"),
        OutputPath   = Path.Combine(RepoRoot, "out"),
        // Point at the source scripts dir (not the build output copy) for easier iteration
        ScriptsPath  = Path.Combine(RepoRoot, "src", "Cobol2c.Runner", "scripts")
    };

    private static IOptions<RunnerOptions> Opts(RunnerOptions o) =>
        Microsoft.Extensions.Options.Options.Create(o);

    /// <summary>
    /// Happy path: a regression job produces the expected Finding with SYS032 smoking gun,
    /// correct call chain, and a non-zero flow-divergence index.
    /// </summary>
    [Fact]
    public async Task RegressionFixture_ProducesExpectedFinding()
    {
        var opts = BuildOptions();
        var ps   = new PowerShellHost();
        var mock = new MockTaExecutor(Opts(opts), NullLogger<MockTaExecutor>.Instance);
        var engine = new PowerShellTriageEngine(ps, Opts(opts));

        var job = new TestJob("job-INV010XR", "Cobol2C", "TGFTA-57", new[] { 27510 }, Logging: true);

        var runResult = await mock.ExecuteAsync(job, CancellationToken.None);
        var triage    = await engine.TriageAsync(job, runResult, CancellationToken.None);

        // Overall result
        Assert.True(triage.HasRegressions,         "Expected HasRegressions=true");
        Assert.Equal(1, triage.ComparableCount);
        Assert.Equal(0, triage.NotComparableCount);
        Assert.Single(triage.Findings);

        var f = triage.Findings[0];
        Assert.Equal("27510", f.TC);
        Assert.True(f.Comparable);

        // Crash signature
        Assert.NotNull(f.Crash);
        Assert.True(f.Crash!.HasSys032,     "SYS032 should be present");
        Assert.True(f.Crash.SmokingGun,     "SYS032→MSG100 smoking gun should fire");
        Assert.True(f.Crash.HasMissingEndTask, "EndTask should be missing (unclean shutdown)");
        Assert.Equal("INV010XR<-INV010XR<-INVMAIN<-GSSMENU", f.Crash.CallChain);
        Assert.Equal("INV010XR", f.Crash.ActiveCsharpProgram);
        Assert.NotEmpty(f.Crash.DotNetStack);
        Assert.Contains("SemanticDesigns.Base.ByteEncodeStringWithCount", f.Crash.DotNetStack[0]);

        // Flow divergence
        Assert.NotNull(f.FlowDivergence);
        // Fail seq:  Entering:INV010XR, Entering:INVMAIN, Entering:INV010XR, Entering:MSG100
        // Ref  seq:  Entering:INV010XR, Entering:INVMAIN, Entering:INV010XR, Leaving:INV010XR, ...
        // First difference at index 3
        Assert.Equal(3, f.FlowDivergence!.DivergenceIndex);
        Assert.Equal("Entering:MSG100",     f.FlowDivergence.FailingStep);
        Assert.Equal("Leaving:INV010XR",    f.FlowDivergence.ReferenceStep);
    }

    /// <summary>
    /// Negative path: when both suites pass there are no findings and HasRegressions=false.
    /// Uses a TaRunResult where FailLogDir also contains the passing reference HTML.
    /// </summary>
    [Fact]
    public async Task AllPassingFixture_ProducesNoFinding()
    {
        var opts = BuildOptions();
        var ps   = new PowerShellHost();
        var engine = new PowerShellTriageEngine(ps, Opts(opts));

        var job = new TestJob("job-allpass", "Cobol2C", "TGFTA-57", new[] { 27510 }, Logging: true);

        // Point BOTH dirs at the reference (all-passing) fixture — nothing will be comparable-failed
        var refDir = Path.Combine(opts.FixturesPath, "ta-results", "reference");
        var runResult = new TaRunResult(
            FailLogDir:      refDir,
            RefLogDir:       refDir,
            FailCoreLogPath: null,
            RefCoreLogPath:  null);

        var triage = await engine.TriageAsync(job, runResult, CancellationToken.None);

        Assert.False(triage.HasRegressions, "Expected no regressions when Cobol2C also passes");
        Assert.Empty(triage.Findings);
    }
}
