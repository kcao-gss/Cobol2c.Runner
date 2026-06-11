# TaTrace.psm1
# Lifted from regression_test_with_ta/SKILL.md §Step 4-5 (CoreLog reference section).
# Parse AutoTrace CoreLog .glog files: crash extraction and flow-sequence divergence.

# AutoTrace line format (pipe-delimited, 7 fields):
# AutoTrace | <LEVEL> | <FullClassName>.<Member> | <yyyy-MM-dd HH:mm:ss.ffff> | <elapsed-ms> | <EventType> | <message>

function Get-FlowSeq {
    <#
    .SYNOPSIS
    Normalise a CoreLog to the ordered sequence of Entering/Leaving Program events.
    Returns strings like "Entering:INV010XR" or "Leaving:GSSMENU".
    Lifted verbatim from SKILL.md §Step 5 Get-FlowSeq.
    #>
    param([string]$GlogPath)
    Get-Content -LiteralPath $GlogPath | ForEach-Object {
        $p = $_ -split '\|'
        if ($p.Count -lt 7) { return }
        $event = $p[5].Trim()
        if ($event -ne 'Entering Program' -and $event -ne 'Leaving Program') { return }
        # e.g. Entering:INV010XR  (event first word + message second word)
        '{0}:{1}' -f $event.Split(' ')[0], (($p[6].Trim()) -split '\s+')[1]
    }
}

function Get-FlowDivergence {
    <#
    .SYNOPSIS
    Find the first index where the failing (Cobol2C) flow sequence diverges from the reference.
    Returns a pscustomobject matching the FlowDivergence C# model.
    Adapted from SKILL.md §Step 5 divergence loop.
    #>
    param(
        [string]$FailGlog,
        [string]$RefGlog
    )
    $failSeq = @(Get-FlowSeq $FailGlog)
    $refSeq  = @(Get-FlowSeq $RefGlog)

    $i = 0
    $n = [Math]::Min($failSeq.Count, $refSeq.Count)
    while ($i -lt $n -and $failSeq[$i] -eq $refSeq[$i]) { $i++ }

    $contextStart = [Math]::Max(0, $i - 3)
    $contextEnd   = [Math]::Min($failSeq.Count - 1, $i + 3)
    $context      = if ($failSeq.Count -gt 0) { $failSeq[$contextStart..$contextEnd] } else { @() }

    [pscustomobject]@{
        DivergenceIndex = $i
        FailingStep     = if ($i -lt $failSeq.Count) { $failSeq[$i] } else { $null }
        ReferenceStep   = if ($i -lt $refSeq.Count)  { $refSeq[$i] }  else { $null }
        FailingContext   = $context
    }
}

function Get-CrashSignature {
    <#
    .SYNOPSIS
    Extract crash evidence from a Cobol2C CoreLog: SYS032->MSG100 pair, COBOL call chain (STRING:),
    .NET stack frames (Exception Callstack), active C# program, and missing-EndTask flag.
    Adapted from SKILL.md §Step 4 and the CoreLog reference section.
    #>
    param([string]$GlogPath)

    $lines = @(Get-Content -LiteralPath $GlogPath)

    # Missing EndTask = unclean shutdown
    $hasEndTask = ($lines | Select-String -Pattern 'EndTask' -Quiet) -eq $true

    # Find first SYS032 (appears in ClassName field: GSSERP.SYS032.GET-CALL-STACK)
    $sys032Idx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'SYS032') { $sys032Idx = $i; break }
    }

    if ($sys032Idx -lt 0) {
        return [pscustomobject]@{
            HasSys032           = $false
            HasMissingEndTask   = (-not $hasEndTask)
            CallChain           = $null
            DotNetStack         = @()
            ActiveCsharpProgram = $null
            SmokingGun          = $false
        }
    }

    # Scan window after SYS032 for MSG100, STRING:, and .NET stack frames
    $hasMsgAfter = $false
    $callChain   = $null
    $dotNetStack = [System.Collections.Generic.List[string]]::new()
    $windowEnd   = [Math]::Min($lines.Count - 1, $sys032Idx + 50)

    foreach ($line in $lines[$sys032Idx..$windowEnd]) {
        if ($line -match 'MSG100')                    { $hasMsgAfter = $true }
        if ($line -match 'STRING:\s+(\S+)')           { $callChain = $matches[1].Trim() }
        if ($line -match '\bat\s+([\w\.\+<>]+)\(')   { $dotNetStack.Add($matches[1]) }
    }

    # Find nearest PRECEDING "Calling C# Program | <PGM>" routing line (back from SYS032)
    $activeCsharp = $null
    for ($i = $sys032Idx; $i -ge 0; $i--) {
        # "Calling C# Program | INV010XR routed to C# from COBOL"
        if ($lines[$i] -match 'Calling C# Program\s*\|\s*(\w+)') {
            $activeCsharp = $matches[1]; break
        }
        # "Program Routed From C# to COBOL | <C# class> -> GSSERP.<PGM>"
        if ($lines[$i] -match 'Program Routed From C# to COBOL\s*\|\s*([\w\.]+)') {
            $activeCsharp = $matches[1]; break
        }
    }

    [pscustomobject]@{
        HasSys032           = $true
        HasMissingEndTask   = (-not $hasEndTask)
        CallChain           = $callChain
        DotNetStack         = $dotNetStack.ToArray()
        ActiveCsharpProgram = $activeCsharp
        SmokingGun          = $hasMsgAfter
    }
}

Export-ModuleMember -Function Get-FlowSeq, Get-FlowDivergence, Get-CrashSignature
