#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# TaTrace.Tests.ps1 — unit tests for Get-CrashSignature and Get-FlowDivergence

# Top-level BeforeAll: path setup runs during the run phase, not just discovery.
# Pester v5 does NOT carry script-level user variables into BeforeAll/It blocks — only
# automatic variables ($PSScriptRoot, $PSCommandPath) and $script:-scoped vars persist.
BeforeAll {
    $script:repoRoot  = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $script:scriptDir = Join-Path $script:repoRoot 'src\Cobol2c.Runner\scripts'
    $script:fixtures  = Join-Path $script:repoRoot 'fixtures'
    Import-Module (Join-Path $script:scriptDir 'TaTrace.psm1') -Force
    $script:failGlog = Join-Path $script:fixtures 'corelogs\cobol2c\CoreLog_20260609.glog'
    $script:refGlog  = Join-Path $script:fixtures 'corelogs\reference\CoreLog_20260609.glog'
}

Describe 'Get-CrashSignature' {
    Context 'Failing Cobol2C CoreLog' {
        BeforeAll { $script:sig = Get-CrashSignature -GlogPath $script:failGlog }

        It 'detects SYS032' {
            $sig.HasSys032 | Should -Be $true
        }

        It 'fires smoking gun (SYS032 followed by MSG100)' {
            $sig.SmokingGun | Should -Be $true
        }

        It 'extracts the COBOL call chain' {
            $sig.CallChain | Should -Be 'INV010XR<-INV010XR<-INVMAIN<-GSSMENU'
        }

        It 'identifies the active C# program at crash' {
            $sig.ActiveCsharpProgram | Should -Be 'INV010XR'
        }

        It 'flags missing EndTask (unclean shutdown)' {
            $sig.HasMissingEndTask | Should -Be $true
        }

        It 'extracts at least one .NET stack frame' {
            $sig.DotNetStack | Should -Not -BeNullOrEmpty
            $sig.DotNetStack[0] | Should -Match 'SemanticDesigns'
        }
    }

    Context 'Reference CoreLog (clean run)' {
        BeforeAll { $script:refSig = Get-CrashSignature -GlogPath $script:refGlog }

        It 'has no SYS032' {
            $refSig.HasSys032 | Should -Be $false
        }

        It 'has EndTask (clean shutdown)' {
            $refSig.HasMissingEndTask | Should -Be $false
        }

        It 'has no smoking gun' {
            $refSig.SmokingGun | Should -Be $false
        }
    }
}

Describe 'Get-FlowDivergence' {
    BeforeAll { $script:div = Get-FlowDivergence -FailGlog $script:failGlog -RefGlog $script:refGlog }

    # Fail seq:  Entering:INV010XR, Entering:INVMAIN, Entering:INV010XR, Entering:MSG100
    # Ref  seq:  Entering:INV010XR, Entering:INVMAIN, Entering:INV010XR, Leaving:INV010XR, ...
    # First difference at index 3

    It 'diverges at step 3' {
        $div.DivergenceIndex | Should -Be 3
    }

    It 'reports correct failing step' {
        $div.FailingStep | Should -Be 'Entering:MSG100'
    }

    It 'reports correct reference step' {
        $div.ReferenceStep | Should -Be 'Leaving:INV010XR'
    }

    It 'returns a non-empty context window' {
        $div.FailingContext | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-CrashSignature — single-line glog' {
    # Regression for the @(Get-Content) fix: without the array-wrap, Get-Content returns a bare
    # string for a one-line file and $lines[$i] does character indexing — HasSys032 always false.
    It 'detects SYS032 when the glog contains exactly one line' {
        $tmpFile = Join-Path $env:TEMP 'single-line-test.glog'
        'AutoTrace | INFO | GSSERP.SYS032.GET-CALL-STACK | 2026-06-09 09:15:05.0000 | 0 | SYS032 | Error' |
            Set-Content -LiteralPath $tmpFile
        try {
            $sig = Get-CrashSignature -GlogPath $tmpFile
            $sig.HasSys032 | Should -Be $true
        } finally {
            Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Get-FlowSeq' {
    It 'returns only Entering/Leaving events' {
        $seq = @(Get-FlowSeq -GlogPath $script:failGlog)
        $seq | Should -Not -BeNullOrEmpty
        $seq | ForEach-Object { $_ | Should -Match '^(Entering|Leaving):' }
    }

    It 'reference log sequence ends with Leaving entries (no crash)' {
        $seq = @(Get-FlowSeq -GlogPath $script:refGlog)
        $seq[-1] | Should -Match '^Leaving:'
    }
}
