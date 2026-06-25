#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# TaHeadless.Tests.ps1 — unit tests for the headless unattended pipeline additions:
#   1. console-park.ps1 session-id parse logic (including Disc session / blank SESSIONNAME)
#   2. Suite-aware keyword construction in New-TABatch
#   3. (removed) -Headless RDP routing — RDP re-login + -Headless path removed in 34d8f92;
#      VMs use console auto-logon. TaRecovery.Tests.ps1 covers Invoke-VMRecovery behavior.
#   4. New-TABatch regression guards: {variation} strip from -t, cmdkey emission

BeforeAll {
    $script:repoRoot  = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $script:scriptDir = Join-Path $script:repoRoot 'src\Cobol2c.Runner\scripts'
    Import-Module (Join-Path $script:scriptDir 'TaRecovery.psm1') -Force
}

# =============================================================================
# 1. console-park.ps1 session-id parse logic
#
# The parse is a two-liner in console-park.ps1 that we replicate here as a helper
# (same regex) so tests run offline without deploying to a real VM.
# =============================================================================
Describe 'console-park session-id parse' {
    BeforeAll {
        # Replicate the exact regex used in console-park.ps1.
        # The lookbehind on \s{2,} ensures we skip ordinals embedded in SESSIONNAME
        # (e.g. the "0" in "rdp-tcp#0"), since those are not preceded by 2+ spaces.
        function Parse-ParkSessionId ([string[]]$QwinstaLines) {
            $taLine = $QwinstaLines | Where-Object { $_ -match '(?i)\bta01\b' } | Select-Object -First 1
            $m = [regex]::Match("$taLine", '(?<=\s{2,})(\d+)(?=\s)')
            if ($m.Success) { return $m.Groups[1].Value } else { return $null }
        }

        # Typical qwinsta output — active RDP session
        $script:activeOutput = @(
            ' SESSIONNAME       USERNAME                 ID  STATE   TYPE        DEVICE',
            ' >rdp-tcp#0        TA01                      1  Active  rdpwd'
        )

        # Disconnected session: SESSIONNAME column is blank, columns shift left
        $script:discOutput = @(
            ' SESSIONNAME       USERNAME                 ID  STATE   TYPE        DEVICE',
            '                   TA01                      2  Disc'
        )

        # Disconnected session with a numeric session ID of 3 — verify correct extraction
        $script:discOutput3 = @(
            ' SESSIONNAME       USERNAME                 ID  STATE   TYPE        DEVICE',
            ' services          services                  0  Disc',
            '                   TA01                      3  Disc'
        )

        # No TA01 session present
        $script:noTa01 = @(
            ' SESSIONNAME       USERNAME                 ID  STATE   TYPE        DEVICE',
            ' >rdp-tcp#0        Administrator             1  Active  rdpwd'
        )

        # Multiple sessions; TA01 is not the first line
        $script:multiSession = @(
            ' SESSIONNAME       USERNAME                 ID  STATE   TYPE        DEVICE',
            ' >rdp-tcp#0        Administrator             1  Active  rdpwd',
            '                   TA01                      4  Disc'
        )
    }

    It 'extracts id=1 from an active RDP session' {
        Parse-ParkSessionId $script:activeOutput | Should -Be '1'
    }

    It 'extracts id=2 from a Disc session with blank SESSIONNAME' {
        Parse-ParkSessionId $script:discOutput | Should -Be '2'
    }

    It 'extracts id=3 when multiple sessions exist and TA01 is Disc' {
        Parse-ParkSessionId $script:discOutput3 | Should -Be '3'
    }

    It 'returns $null when no TA01 session is present' {
        Parse-ParkSessionId $script:noTa01 | Should -Be $null
    }

    It 'extracts id=4 from a multi-session list where TA01 is not first' {
        Parse-ParkSessionId $script:multiSession | Should -Be '4'
    }
}

# =============================================================================
# 2. Suite-aware keyword construction in New-TABatch
#
# Rules (per spec and manager skill):
#   SP2V6:      "new program,batch,2023[,log],without service"       (new program; NO c2c)
#   Cobol2C:    "new program,batch,2023[,log],without service,c2c"   (new program AND c2c)
#   Production: "batch,2023[,log],without service"                   (neither)
# =============================================================================
Describe 'New-TABatch — suite-aware keyword construction' {
    BeforeAll {
        $script:repoRoot2  = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
        $script:scriptDir2 = Join-Path $script:repoRoot2 'src\Cobol2c.Runner\scripts'

        $script:testEntry = @(
            [pscustomobject]@{
                tc   = '99999'
                rep  = 'Sales'
                prj  = 'Sales'
                path = '/Production/2023 version/Order Entry/Shipments/99999_OE_Test {new program}'
            }
        )

        # Helper: dot-source Invoke-TaRun.ps1 for a given suite and call New-TABatch
        function Get-Keywords ([string]$BatchSuite, [bool]$Log = $true) {
            # Re-dot-source each time so $Suite and $BatchSuite match correctly
            . (Join-Path $script:scriptDir2 'Invoke-TaRun.ps1') `
                -Suite $BatchSuite -Machine 'TEST-KW' -Tcs '99999' `
                -Ta01Pw 'pw' -AutoRecover 'true'
            $bat = New-TABatch -Base '\\fake\base' -Tests $script:testEntry `
                               -IsLogging $Log -HtmlDir 'C:\Logs\TEST-KW' `
                               -RunToken 'tok' -BatchSuite $BatchSuite
            # Extract the KEYWORDS line value
            if ($bat -match 'set KEYWORDS=(.+)') { return $matches[1].Trim() } else { return '' }
        }
    }

    Context 'SP2V6 suite' {
        It 'includes "new program" prefix' {
            $kw = Get-Keywords 'SP2V6'
            $kw | Should -Match '^new program,'
        }
        It 'does NOT include ",c2c"' {
            $kw = Get-Keywords 'SP2V6'
            $kw | Should -Not -Match ',c2c'
        }
        It 'includes "without service"' {
            $kw = Get-Keywords 'SP2V6'
            $kw | Should -Match 'without service'
        }
    }

    Context 'Cobol2C suite' {
        It 'includes "new program" prefix' {
            $kw = Get-Keywords 'Cobol2C'
            $kw | Should -Match '^new program,'
        }
        It 'appends ",c2c"' {
            $kw = Get-Keywords 'Cobol2C'
            $kw | Should -Match ',c2c$'
        }
        It 'includes "without service"' {
            $kw = Get-Keywords 'Cobol2C'
            $kw | Should -Match 'without service'
        }
    }

    Context 'Production suite' {
        It 'does NOT include "new program"' {
            $kw = Get-Keywords 'Production'
            $kw | Should -Not -Match 'new program'
        }
        It 'does NOT include "c2c"' {
            $kw = Get-Keywords 'Production'
            $kw | Should -Not -Match 'c2c'
        }
        It 'includes "without service"' {
            $kw = Get-Keywords 'Production'
            $kw | Should -Match 'without service'
        }
    }

    Context 'logging flag' {
        It 'SP2V6 with logging includes ",log,"' {
            $kw = Get-Keywords 'SP2V6' $true
            $kw | Should -Match ',log,'
        }
        It 'SP2V6 without logging omits ",log,"' {
            $kw = Get-Keywords 'SP2V6' $false
            $kw | Should -Not -Match ',log,'
        }
    }
}

# =============================================================================
# 3. -Headless flag routing tests REMOVED (34d8f92).
#    RDP re-login + Enter-ConsoleSession/Connect-TA01Rdp deleted from TaRecovery.psm1;
#    VMs use console auto-logon always. TaRecovery.Tests.ps1 covers Invoke-VMRecovery.
# =============================================================================

# =============================================================================
# 4. New-TABatch regression guards — {variation} strip from -t and -r; cmdkey emission
# =============================================================================
Describe 'New-TABatch — regression guards (variation strip + cmdkey)' {
    BeforeAll {
        $script:repoRoot4  = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
        $script:scriptDir4 = Join-Path $script:repoRoot4 'src\Cobol2c.Runner\scripts'

        . (Join-Path $script:scriptDir4 'Invoke-TaRun.ps1') `
            -Suite 'SP2V6' -Machine 'TEST-REG' -Tcs '99999' -Ta01Pw 'pw' -AutoRecover 'true'

        $script:regTests = @(
            [pscustomobject]@{
                tc   = '27510'
                rep  = 'Inventory'
                prj  = 'Inventory'
                path = '/Production/2023 version/Inventory/Inventory Parts/27510_Inv_Add Cross Reference records {new program}'
            }
        )
        $script:regBat = New-TABatch -Base '\\srv\TAShare\SP2V6' -Tests $script:regTests `
                                     -IsLogging $true -HtmlDir 'C:\Logs\TEST-REG' `
                                     -RunToken 'tok999' -BatchSuite 'SP2V6'
    }

    It 'strips {new program} from the -t tree path argument' {
        # No -t argument may carry a {variation} brace
        $script:regBat | Should -Not -Match '-t "[^"]*\{'
    }

    It 'strips {variation} from the -r result-name argument' {
        $script:regBat | Should -Not -Match '-r "[^"]*\{'
    }

    It 'emits cmdkey for the 172.16.60.6 env-share credential' {
        $script:regBat | Should -Match 'cmdkey\s+/add:172\.16\.60\.6'
    }

    It '-t still contains the base tree path (not truncated to root)' {
        $script:regBat | Should -Match '-t "/Production/2023 version/Inventory'
    }

    It 'emits a ta execute line' {
        $script:regBat | Should -Match 'ta execute'
    }
}
