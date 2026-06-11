namespace Cobol2c.Runner.Ta;

/// <summary>
/// Paths to log artefacts produced (or mocked) by a TA test run.
/// The triage engine consumes these paths — it does not discover them.
/// </summary>
public record TaRunResult(
    /// <summary>Directory of *.html result files for the Cobol2C (failing) run.</summary>
    string FailLogDir,

    /// <summary>Directory of *.html result files for the reference (SP2V6/Production) run.</summary>
    string RefLogDir,

    /// <summary>
    /// Path to the AutoTrace CoreLog*.glog file for the Cobol2C run.
    /// Null when logging was off for that run.
    /// </summary>
    string? FailCoreLogPath,

    /// <summary>
    /// Path to the AutoTrace CoreLog*.glog file for the reference run.
    /// Null when logging was off for that run.
    /// </summary>
    string? RefCoreLogPath
);
