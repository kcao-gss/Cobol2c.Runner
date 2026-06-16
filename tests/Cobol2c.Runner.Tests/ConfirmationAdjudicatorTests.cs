using Cobol2c.Runner.Triage;
using Cobol2c.Runner.Triage.Models;
using Xunit;

namespace Cobol2c.Runner.Tests;

/// <summary>
/// Unit tests for ConfirmationAdjudicator — verifies the unanimous adjudication rule.
/// </summary>
public class ConfirmationAdjudicatorTests
{
    // Helper: build a TriageResult with a single comparable failure
    private static TriageResult FailResult(string tc) => new()
    {
        HasRegressions = true,
        ComparableCount = 1,
        NotComparableCount = 0,
        Findings = [new Finding { TC = tc, Comparable = true }]
    };

    // Helper: build a TriageResult with no failures
    private static TriageResult PassResult() => new()
    {
        HasRegressions = false,
        ComparableCount = 1,
        NotComparableCount = 0,
        Findings = []
    };

    [Fact]
    public void ThreeMachines_AllFail_IsConfirmedRegression()
    {
        var results = new Dictionary<string, TriageResult>
        {
            ["TGFTA-118"] = FailResult("27510"),
            ["TGFTA-119"] = FailResult("27510"),
            ["TGFTA-120"] = FailResult("27510")
        };

        var combined = ConfirmationAdjudicator.Adjudicate(results);

        Assert.True(combined.HasRegressions);
        Assert.Single(combined.Findings);
        Assert.Equal("27510", combined.Findings[0].TC);
        Assert.Empty(combined.EnvironmentalFindings);
    }

    [Fact]
    public void ThreeMachines_TwoFail_IsEnvironmental()
    {
        var results = new Dictionary<string, TriageResult>
        {
            ["TGFTA-118"] = FailResult("27510"),
            ["TGFTA-119"] = FailResult("27510"),
            ["TGFTA-120"] = PassResult()
        };

        var combined = ConfirmationAdjudicator.Adjudicate(results);

        Assert.False(combined.HasRegressions);
        Assert.Empty(combined.Findings);
        Assert.Single(combined.EnvironmentalFindings);
        var ef = combined.EnvironmentalFindings[0];
        Assert.Equal("27510", ef.TC);
        Assert.Equal(2, ef.FailedOn.Length);
        Assert.Contains("TGFTA-118", ef.FailedOn);
        Assert.Contains("TGFTA-119", ef.FailedOn);
        Assert.Single(ef.PassedOn);
        Assert.Contains("TGFTA-120", ef.PassedOn);
    }

    [Fact]
    public void ThreeMachines_OneFails_IsEnvironmental()
    {
        var results = new Dictionary<string, TriageResult>
        {
            ["TGFTA-118"] = FailResult("27510"),
            ["TGFTA-119"] = PassResult(),
            ["TGFTA-120"] = PassResult()
        };

        var combined = ConfirmationAdjudicator.Adjudicate(results);

        Assert.False(combined.HasRegressions);
        Assert.Empty(combined.Findings);
        Assert.Single(combined.EnvironmentalFindings);
        var ef = combined.EnvironmentalFindings[0];
        Assert.Equal("27510", ef.TC);
        Assert.Single(ef.FailedOn);
        Assert.Equal(2, ef.PassedOn.Length);
    }

    [Fact]
    public void ThreeMachines_NoneFaili_IsPass()
    {
        var results = new Dictionary<string, TriageResult>
        {
            ["TGFTA-118"] = PassResult(),
            ["TGFTA-119"] = PassResult(),
            ["TGFTA-120"] = PassResult()
        };

        var combined = ConfirmationAdjudicator.Adjudicate(results);

        Assert.False(combined.HasRegressions);
        Assert.Empty(combined.Findings);
        Assert.Empty(combined.EnvironmentalFindings);
    }

    [Fact]
    public void SingleMachine_PassesThrough_Unchanged()
    {
        var original = FailResult("27510");
        var results  = new Dictionary<string, TriageResult> { ["TGFTA-118"] = original };

        var combined = ConfirmationAdjudicator.Adjudicate(results);

        // Single-machine path returns the same object without adjudication
        Assert.Same(original, combined);
    }

    [Fact]
    public void DegradedPool_TwoReadyMachines_BothFail_IsConfirmed()
    {
        // If only 2 of 3 requested machines are ready (pool degraded), unanimous still applies
        // to the N that ran — both fail -> confirmed.
        var results = new Dictionary<string, TriageResult>
        {
            ["TGFTA-118"] = FailResult("27510"),
            ["TGFTA-119"] = FailResult("27510")
        };

        var combined = ConfirmationAdjudicator.Adjudicate(results);

        Assert.True(combined.HasRegressions);
        Assert.Single(combined.Findings);
        Assert.Empty(combined.EnvironmentalFindings);
    }

    [Fact]
    public void EmptyResults_ThrowsArgumentException()
    {
        var empty = new Dictionary<string, TriageResult>();
        Assert.Throws<ArgumentException>(() => ConfirmationAdjudicator.Adjudicate(empty));
    }

    [Fact]
    public void MultipleTcs_MixedResults_CorrectlySeparatedIntoConfirmedAndEnvironmental()
    {
        // TC 27510 fails on all 3 -> confirmed
        // TC 27511 fails on 2 of 3 -> environmental
        // TC 27512 fails on 0 of 3 -> pass (absent from both lists)
        var results = new Dictionary<string, TriageResult>
        {
            ["TGFTA-118"] = new TriageResult
            {
                HasRegressions = true, ComparableCount = 3, NotComparableCount = 0,
                Findings = [new Finding { TC = "27510", Comparable = true },
                             new Finding { TC = "27511", Comparable = true }]
            },
            ["TGFTA-119"] = new TriageResult
            {
                HasRegressions = true, ComparableCount = 3, NotComparableCount = 0,
                Findings = [new Finding { TC = "27510", Comparable = true }]
            },
            ["TGFTA-120"] = new TriageResult
            {
                HasRegressions = true, ComparableCount = 3, NotComparableCount = 0,
                Findings = [new Finding { TC = "27510", Comparable = true },
                             new Finding { TC = "27511", Comparable = true }]
            }
        };

        var combined = ConfirmationAdjudicator.Adjudicate(results);

        Assert.True(combined.HasRegressions);
        Assert.Single(combined.Findings);
        Assert.Equal("27510", combined.Findings[0].TC);

        Assert.Single(combined.EnvironmentalFindings);
        Assert.Equal("27511", combined.EnvironmentalFindings[0].TC);
        Assert.Equal(2, combined.EnvironmentalFindings[0].FailedOn.Length);
        Assert.Single(combined.EnvironmentalFindings[0].PassedOn);
        Assert.Contains("TGFTA-119", combined.EnvironmentalFindings[0].PassedOn);
    }
}
