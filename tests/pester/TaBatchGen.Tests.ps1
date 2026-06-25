# Verifies New-TABatch (in Invoke-TaRun.ps1) generates a batch with the two SP2V6 fixes
# that bring our pipeline in line with the manager's known-good run-ta-tests skill:
#   1. provisions the 172.16.60.6 env-share credential via cmdkey (else every test aborts at
#      init with "logigear env.xml does not exist" -> whole-fleet 0-pass)
#   2. strips the {new program} variation from the -t tree path (variation is selected at runtime
#      by the comma -kwd keyword set; leaving it in -t pins the base variation -> runs OLD programs)

Describe 'New-TABatch — SP2V6 pipeline fixes' {
    BeforeAll {
        $repoRoot  = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
        $scriptDir = Join-Path $repoRoot 'src\Cobol2c.Runner\scripts'
        $taRunPath = Join-Path $scriptDir 'Invoke-TaRun.ps1'

        # Dot-source: the InvocationName='.' guard skips Assert-VmReady / manifest / run tail.
        . $taRunPath -Suite 'SP2V6' -Machine 'TEST-VM' -Tcs '27510' -Ta01Pw 'pw' -AutoRecover 'true'

        $tests = @(
            [pscustomobject]@{ tc='27510'; rep='Inventory'; prj='Inventory'
                path='/Production/2023 version/Inventory/Inventory Parts/27510_Inv_Add Cross Reference records {new program}' }
        )
        $script:bat = New-TABatch -Base '\\srv\TAShare\SP2V6' -Tests $tests -IsLogging $true `
                                  -HtmlDir 'C:\Logs\TEST-VM' -RunToken 'tok123'
    }

    It 'emits a ta execute line with a -t tree path' {
        $script:bat | Should -Match '-t "/Production/2023 version/Inventory'
    }

    It 'provisions the 172.16.60.6 env-share credential via cmdkey' {
        $script:bat | Should -Match 'cmdkey\s+/add:172\.16\.60\.6'
    }

    It 'strips the {new program} variation from the -t tree path' {
        # no -t argument may carry a {variation} brace (keyword set selects the variation, not the path)
        $script:bat | Should -Not -Match '-t "[^"]*\{'
    }

    It 'still strips the variation from -r (regression guard)' {
        $script:bat | Should -Not -Match '-r "[^"]*\{'
    }

    It 'keeps "new program" in the -kwd keyword set (variation now driven by keyword)' {
        $script:bat | Should -Match 'set KEYWORDS=new program,'
    }
}
