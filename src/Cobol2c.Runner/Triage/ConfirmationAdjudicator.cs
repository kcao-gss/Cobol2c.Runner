using Cobol2c.Runner.Triage.Models;

namespace Cobol2c.Runner.Triage;

/// <summary>
/// Applies unanimous adjudication to N per-machine TriageResults.
/// A TC is a confirmed regression only when it fails comparably (Cobol2C fail, reference pass)
/// on ALL machines. Failing on 1..N-1 machines is classified as environmental/flaky.
/// </summary>
public static class ConfirmationAdjudicator
{
    /// <summary>
    /// Merges per-machine triage results into one combined result.
    /// <para>
    ///   Unanimous rule: TC must appear as a <see cref="Finding.Comparable"/> failure on
    ///   every machine to be added to <see cref="TriageResult.Findings"/>. TCs failing on
    ///   1..N-1 machines go to <see cref="TriageResult.EnvironmentalFindings"/> instead.
    /// </para>
    /// </summary>
    /// <param name="machineResults">
    ///   Keys are machine names; values are per-machine triage results from
    ///   <see cref="ITriageEngine.TriageAsync"/>. Must contain at least one entry.
    /// </param>
    public static TriageResult Adjudicate(IReadOnlyDictionary<string, TriageResult> machineResults)
    {
        if (machineResults.Count == 0)
            throw new ArgumentException("Must provide at least one machine result.", nameof(machineResults));

        // Single machine: pass through unchanged — no adjudication needed
        if (machineResults.Count == 1)
            return machineResults.Values.First();

        var allMachines = machineResults.Keys.ToArray();
        int n           = allMachines.Length;

        // All TC numbers that failed comparably on at least one machine
        var failedTcs = machineResults.Values
            .SelectMany(r => r.Findings)
            .Where(f => f.Comparable)
            .Select(f => f.TC)
            .Distinct()
            .ToArray();

        var confirmed    = new List<Finding>();
        var environmental = new List<EnvironmentalFinding>();

        foreach (var tc in failedTcs)
        {
            var failedOn = allMachines
                .Where(m => machineResults[m].Findings.Any(f => f.TC == tc && f.Comparable))
                .ToArray();
            var passedOn = allMachines.Except(failedOn).ToArray();

            if (failedOn.Length == n)
            {
                // Unanimous failure — confirmed regression; take the Finding from the first machine
                var representative = machineResults[failedOn[0]].Findings.First(f => f.TC == tc);
                confirmed.Add(representative);
            }
            else
            {
                // Partial failure — environmental/flaky, suppressed from confirmed regressions
                environmental.Add(new EnvironmentalFinding
                {
                    TC       = tc,
                    FailedOn = failedOn,
                    PassedOn = passedOn
                });
            }
        }

        // Use the highest per-machine counts as the "true" run size (each machine ran the same TCs)
        var combinedComparable    = machineResults.Values.Max(r => r.ComparableCount);
        var combinedNotComparable = machineResults.Values.Max(r => r.NotComparableCount);

        return new TriageResult
        {
            HasRegressions        = confirmed.Count > 0,
            ComparableCount       = combinedComparable,
            NotComparableCount    = combinedNotComparable,
            Findings              = [.. confirmed],
            EnvironmentalFindings = [.. environmental]
        };
    }
}
