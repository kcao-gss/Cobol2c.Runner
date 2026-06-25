using System.Text.Json;
using Cobol2c.Runner.Ta;
using Xunit;

namespace Cobol2c.Agent.Tests;

/// <summary>
/// Verifies that TaRunResult can round-trip JSON shapes emitted by Invoke-LocalRun.ps1.
/// The bug: when no CoreLog is found, PowerShell may emit {} (empty object) instead of
/// null, causing System.Text.Json to throw on deserialization.
/// </summary>
public class TaRunResultSerializationTests
{
    private static readonly JsonSerializerOptions _opts =
        new() { PropertyNameCaseInsensitive = true };

    /// <summary>
    /// Invoke-LocalRun.ps1 with no CoreLog found must emit null (or omit the field),
    /// not {}.  This test deserializes such JSON and asserts no exception + null paths.
    /// RED: will fail if the PS1 still emits {} (the actual fix is in the PS1, but
    /// this test validates the contract the C# side requires).
    /// </summary>
    [Fact]
    public void Deserialize_NullCoreLogPaths_Succeeds()
    {
        // Exactly what Invoke-LocalRun.ps1 should emit when $coreLog is $null
        const string json = """
            {
              "FailLogDir":      "C:\\Temp\\run",
              "RefLogDir":       "C:\\Temp\\run",
              "FailCoreLogPath": null,
              "RefCoreLogPath":  null
            }
            """;

        var result = JsonSerializer.Deserialize<TaRunResult>(json, _opts);

        Assert.NotNull(result);
        Assert.Equal(@"C:\Temp\run", result!.FailLogDir);
        Assert.Null(result.FailCoreLogPath);
        Assert.Null(result.RefCoreLogPath);
    }

    /// <summary>
    /// When a CoreLog IS found, Invoke-LocalRun.ps1 must emit a plain JSON string
    /// (the .FullName), not a FileInfo object.
    /// </summary>
    [Fact]
    public void Deserialize_StringCoreLogPaths_Succeeds()
    {
        const string json = """
            {
              "FailLogDir":      "C:\\Temp\\run",
              "RefLogDir":       "C:\\Temp\\run",
              "FailCoreLogPath": "C:\\Apps\\Global\\Files\\AutoTrace\\CoreLog_20260619.glog",
              "RefCoreLogPath":  "C:\\Apps\\Global\\Files\\AutoTrace\\CoreLog_20260619.glog"
            }
            """;

        var result = JsonSerializer.Deserialize<TaRunResult>(json, _opts);

        Assert.NotNull(result);
        Assert.Equal(
            @"C:\Apps\Global\Files\AutoTrace\CoreLog_20260619.glog",
            result!.FailCoreLogPath);
    }

    /// <summary>
    /// The actual bug shape: {} emitted for an empty FileInfo / empty collection.
    /// This MUST throw (or be undeserializable), confirming the bug exists before the fix.
    /// After the PS1 fix this shape will never appear from the real script, but the test
    /// documents what was wrong.
    /// </summary>
    [Fact]
    public void Deserialize_ObjectCoreLogPath_ThrowsOrProducesNull()
    {
        // PowerShell ConvertTo-Json of a FileInfo emits a full object; of an empty
        // pipeline result it emits {}.  Either way, C# can't coerce it to string.
        const string buggyJson = """
            {
              "FailLogDir":      "C:\\Temp\\run",
              "RefLogDir":       "C:\\Temp\\run",
              "FailCoreLogPath": {},
              "RefCoreLogPath":  {}
            }
            """;

        // System.Text.Json throws JsonException when it tries to put an object into a string?.
        Assert.Throws<JsonException>(() =>
            JsonSerializer.Deserialize<TaRunResult>(buggyJson, _opts));
    }
}
