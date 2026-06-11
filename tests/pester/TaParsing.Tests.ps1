#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# TaParsing.Tests.ps1 — unit tests for Get-TcResults and Get-ComparableFailed

# Top-level BeforeAll: path setup runs during the run phase, not just discovery.
# Pester v5 does NOT carry script-level user variables into BeforeAll/It blocks — only
# automatic variables ($PSScriptRoot, $PSCommandPath) and $script:-scoped vars persist.
BeforeAll {
    $script:repoRoot  = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $script:scriptDir = Join-Path $script:repoRoot 'src\Cobol2c.Runner\scripts'
    $script:fixtures  = Join-Path $script:repoRoot 'fixtures'
    Import-Module (Join-Path $script:scriptDir 'TaParsing.psm1') -Force
}

Describe 'Get-TcResults' {
    Context 'Cobol2C (failing) HTML directory' {
        It 'finds TC 27510 as FAILED (Passed:&nbsp;0)' {
            $results = Get-TcResults -LogDir (Join-Path $script:fixtures 'ta-results\cobol2c')
            $results | Should -HaveCount 1
            $results[0].TC     | Should -Be '27510'
            $results[0].Passed | Should -Be $false
        }
    }

    Context 'Reference (passing) HTML directory' {
        It 'finds TC 27510 as PASSED (Passed:&nbsp;1)' {
            $results = Get-TcResults -LogDir (Join-Path $script:fixtures 'ta-results\reference')
            $results | Should -HaveCount 1
            $results[0].TC     | Should -Be '27510'
            $results[0].Passed | Should -Be $true
        }
    }

    Context 'Empty directory' {
        It 'returns empty collection for a directory with no HTML files' {
            $tmp = New-Item -ItemType Directory -Path (Join-Path $env:TEMP 'ta-empty-test') -Force
            $results = @(Get-TcResults -LogDir $tmp.FullName)
            $results | Should -HaveCount 0
            Remove-Item $tmp.FullName -Recurse -Force
        }
    }
}

Describe 'Get-ComparableFailed' {
    It 'classifies a clean regression (failed Cobol2C, passed reference)' {
        $fail = @([pscustomobject]@{TC='27510'; Passed=$false; File=''})
        $ref  = @([pscustomobject]@{TC='27510'; Passed=$true;  File=''})
        $r = Get-ComparableFailed -FailResults $fail -RefResults $ref
        $r.Comparable    | Should -HaveCount 1
        $r.NotComparable | Should -HaveCount 0
        $r.Comparable[0].TC | Should -Be '27510'
    }

    It 'marks not-comparable when reference also failed' {
        $fail = @([pscustomobject]@{TC='99999'; Passed=$false; File=''})
        $ref  = @([pscustomobject]@{TC='99999'; Passed=$false; File=''})
        $r = Get-ComparableFailed -FailResults $fail -RefResults $ref
        $r.Comparable    | Should -HaveCount 0
        $r.NotComparable | Should -HaveCount 1
    }

    It 'marks not-comparable when TC was not in the reference run at all' {
        $fail = @([pscustomobject]@{TC='11111'; Passed=$false; File=''})
        $ref  = @()
        $r = Get-ComparableFailed -FailResults $fail -RefResults $ref
        $r.Comparable    | Should -HaveCount 0
        $r.NotComparable | Should -HaveCount 1
    }

    It 'handles mixed: one regression, one non-comparable' {
        $fail = @(
            [pscustomobject]@{TC='27510'; Passed=$false; File=''},
            [pscustomobject]@{TC='99999'; Passed=$false; File=''}
        )
        $ref = @([pscustomobject]@{TC='27510'; Passed=$true; File=''})
        $r = Get-ComparableFailed -FailResults $fail -RefResults $ref
        $r.Comparable    | Should -HaveCount 1
        $r.NotComparable | Should -HaveCount 1
    }
}
