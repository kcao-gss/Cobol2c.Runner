# TaRouting.psm1
# Pure routing-config toggle helpers — lifted VERBATIM from regression_test_with_ta/SKILL.md
# §"Toggle helpers" (validated to round-trip exactly).
#
# These functions are TESTED but NOT EXECUTED in the PoC (report-only scope).
# They're included now so Phase-3 routing bisection can plug in without changes.
#
# Routing config format: flat JSON {"<C# class>":"GSSERP.<PGM>"}
#   - key WITH ~  → routing-to-COBOL disabled → runs C# (Cobol2C)
#   - key WITHOUT ~ → routing-to-COBOL ON   → runs original COBOL
#
# Production paths (not used locally):
#   Shared baseline (READ): \\gss2k19rnd.gss.local\TAShare\Cobol2C\GSSCoreModernCodeConfig.tempCache
#   VM override   (WRITE):  \\<machine>\TA01\DataCache\CoreModernCodeConfig.unclearedCache

function Get-RouteKey {
    <#
    .SYNOPSIS
    Find the C# class key in the JSON for a given program (COBOL name or C# class).
    Returns the key WITHOUT its ~ prefix, or $null if not found.
    #>
    param([string]$Json, [string]$Program)
    $pgm = $Program -replace '^GSSERP\.', ''
    # match by COBOL value
    $m = [regex]::Match($Json, '"~?(?<k>[^"]+)":"GSSERP\.' + [regex]::Escape($pgm) + '"')
    if ($m.Success) { return $m.Groups['k'].Value }
    # match by C# class key
    $m2 = [regex]::Match($Json, '"~?' + [regex]::Escape($Program) + '":"')
    if ($m2.Success) { return $Program }
    $null
}

function Use-Cobol {
    <#
    .SYNOPSIS
    Force an EXISTING entry to run COBOL (remove its ~). Idempotent.
    Uses String.Replace (literal) to avoid regex replacement-template expansion
    — a $Key containing $1 or ${name} would corrupt the JSON under -replace.
    #>
    param([string]$Json, [string]$Key)
    $Json.Replace('"~' + $Key + '"', '"' + $Key + '"')
}

function Use-Csharp {
    <#
    .SYNOPSIS
    Restore/add C# routing for an entry (add its ~). Idempotent.
    Uses String.Replace (literal) in the mutation branch for the same reason as Use-Cobol.
    #>
    param([string]$Json, [string]$Key)
    if ($Json -match [regex]::Escape("""~$Key""")) { $Json }
    else { $Json.Replace('"' + $Key + '"', '"~' + $Key + '"') }
}

function Add-CobolRoute {
    <#
    .SYNOPSIS
    Bring an UNLISTED program under routing control, forced to COBOL (no ~).
    Idempotent — does nothing if the C# class is already in the JSON.
    Handles empty-object ({}) correctly — no trailing comma on first entry.
    #>
    param([string]$Json, [string]$Class, [string]$Pgm)
    if ($Json -match [regex]::Escape($Class)) { return $Json }
    $pgm = $Pgm -replace '^GSSERP\.', ''
    # Empty-object guard: Insert would produce {"x":"y",} (invalid JSON).
    if ($Json -match '^\s*\{\s*\}\s*$') { return '{"' + $Class + '":"GSSERP.' + $pgm + '"}' }
    $Json.Insert(1, '"' + $Class + '":"GSSERP.' + $pgm + '",')
}

Export-ModuleMember -Function Get-RouteKey, Use-Cobol, Use-Csharp, Add-CobolRoute
