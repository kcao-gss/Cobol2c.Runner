# TaParsing.psm1
# Lifted verbatim from regression_test_with_ta/SKILL.md §Step 2-3.
# Parse TA HTML result files and apply the comparability gate.

function Get-TcResults {
    <#
    .SYNOPSIS
    Scans a directory of TA HTML result files and returns pass/fail status per TC.
    Pass = Passed:&nbsp;[1-9] present in HTML (non-zero Passed count).
    #>
    param([string]$LogDir)
    Get-ChildItem -LiteralPath $LogDir -Filter '*.html' -File -ErrorAction SilentlyContinue |
    ForEach-Object {
        $tc     = if ($_.Name -match '^(\d+)\b') { $matches[1] } else { $_.BaseName }
        $passed = Select-String -LiteralPath $_.FullName -Pattern 'Passed:&nbsp;[1-9]' -Quiet
        [pscustomobject]@{ TC = $tc; Passed = [bool]$passed; File = $_.FullName }
    }
}

function Get-ComparableFailed {
    <#
    .SYNOPSIS
    Applies the comparability gate from SKILL.md §Step 3.
    Comparable = failed under Cobol2C AND passed under the reference suite.
    NotComparable = failed under Cobol2C but ALSO failed (or wasn't run) in reference.
    #>
    param(
        [object[]]$FailResults,
        [object[]]$RefResults
    )

    $refPass = @{}
    $RefResults | Where-Object Passed | ForEach-Object { $refPass[$_.TC] = $true }

    $failed        = $FailResults | Where-Object { -not $_.Passed }
    $comparable    = @($failed | Where-Object {  $refPass.ContainsKey($_.TC) })
    $notComparable = @($failed | Where-Object { -not $refPass.ContainsKey($_.TC) })

    [pscustomobject]@{
        Comparable    = $comparable
        NotComparable = $notComparable
    }
}

Export-ModuleMember -Function Get-TcResults, Get-ComparableFailed
