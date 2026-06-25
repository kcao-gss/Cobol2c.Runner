#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# TaRecovery.Tests.ps1 - unit tests for TaRecovery.psm1 (Test-RdpDropSignature, Get-AffectedTests)
# and the -r stripping logic used in New-TABatch.

BeforeAll {
    $script:repoRoot  = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $script:scriptDir = Join-Path $script:repoRoot 'src\Cobol2c.Runner\scripts'
    Import-Module (Join-Path $script:scriptDir 'TaRecovery.psm1') -Force

    # Minimal HTML fragments reused across contexts
    $script:HTML_PASS = @'
<!DOCTYPE html><html><body>
<td>Passed:&nbsp;1</td><td>Failed:&nbsp;0</td>
</body></html>
'@
    $script:HTML_FAIL_NOSIG = @'
<!DOCTYPE html><html><body>
<td>Passed:&nbsp;0</td><td>Failed:&nbsp;1</td>
<p>Some unrelated error - no maximize or scrollParent markers.</p>
</body></html>
'@
    $script:HTML_FAIL_SIG = @'
<!DOCTYPE html><html><body>
<td>Passed:&nbsp;0</td><td>Failed:&nbsp;1</td>
<p>WARNING: Cannot maximize window &apos;[automation id=mainWindow]&apos;.</p>
<p>No matching UI object found for &quot;[ta class=textblock, name=StatusMsg, anchor=&apos;[ta class=scrollviewer, automation id=scrollParent]&apos;]&quot; within the timeout of &quot;20&quot; seconds.</p>
</body></html>
'@

    # Helper: write an HTML file with a controlled LastWriteTime offset (seconds from now)
    function New-HtmlFixture {
        param([string]$Dir, [string]$Name, [string]$Content, [int]$AgeSecs)
        $path = Join-Path $Dir $Name
        Set-Content -LiteralPath $path -Value $Content -Encoding UTF8
        (Get-Item -LiteralPath $path).LastWriteTime = (Get-Date).AddSeconds(-$AgeSecs)
        $path
    }
}

# -----------------------------------------------------------------------------
Describe '-r run-name strip logic (inline regex from New-TABatch)' {
    # Replicates: $rname = ($leaf -replace '\s*\{[^}]*\}', '').Trim()
    # Ensures the strip is correct before writing it into a batch file.
    BeforeAll {
        function Strip-VariationSuffix ([string]$leaf) {
            ($leaf -replace '\s*\{[^}]*\}', '').Trim()
        }
    }

    It 'strips {new program} suffix, leaving tc_... prefix intact' {
        Strip-VariationSuffix '27510_Inv_Add Cross Reference records {new program}' |
            Should -Be '27510_Inv_Add Cross Reference records'
    }

    It 'result contains no TA CLI reserved chars' {
        $r = Strip-VariationSuffix '27510_Inv_Add Cross Reference records {new program}'
        $r.Contains('{') | Should -Be $false
        $r.Contains('}') | Should -Be $false
    }

    It 'leaf with no variation suffix is returned unchanged' {
        Strip-VariationSuffix '99999_Some Module Name' | Should -Be '99999_Some Module Name'
    }

    It 'strips {2023} suffix' {
        Strip-VariationSuffix '12345_My Module {2023}' | Should -Be '12345_My Module'
    }

    It 'result still starts with tc_... pattern required by set-data-location action' {
        Strip-VariationSuffix '27510_Inv_Add Cross Reference records {new program}' |
            Should -Match '^\d+_'
    }

    It 'trims surrounding whitespace after strip' {
        Strip-VariationSuffix '27510_Inv_Add  {new program}  ' | Should -Be '27510_Inv_Add'
    }
}

# -----------------------------------------------------------------------------
Describe 'Test-RdpDropSignature' {
    BeforeAll {
        $script:tmpBase = Join-Path $env:TEMP 'TaRecoveryTests'
        New-Item -ItemType Directory -Force -Path $script:tmpBase | Out-Null
    }
    AfterAll {
        Remove-Item -LiteralPath $script:tmpBase -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context '3 trailing failures WITH RDP-drop signature' {
        BeforeAll {
            $script:d = Join-Path $script:tmpBase 'sig3'
            New-Item -ItemType Directory -Force -Path $script:d | Out-Null
            New-HtmlFixture $script:d '27510 (result1).html' $script:HTML_FAIL_SIG 30
            New-HtmlFixture $script:d '27511 (result2).html' $script:HTML_FAIL_SIG 20
            New-HtmlFixture $script:d '27512 (result3).html' $script:HTML_FAIL_SIG 10
        }
        It 'returns $true' {
            Test-RdpDropSignature -LogDir $script:d | Should -Be $true
        }
    }

    Context '3 trailing failures WITHOUT the signature markers' {
        BeforeAll {
            $script:d = Join-Path $script:tmpBase 'nosig3'
            New-Item -ItemType Directory -Force -Path $script:d | Out-Null
            New-HtmlFixture $script:d '27510 (result1).html' $script:HTML_FAIL_NOSIG 30
            New-HtmlFixture $script:d '27511 (result2).html' $script:HTML_FAIL_NOSIG 20
            New-HtmlFixture $script:d '27512 (result3).html' $script:HTML_FAIL_NOSIG 10
        }
        It 'returns $false' {
            Test-RdpDropSignature -LogDir $script:d | Should -Be $false
        }
    }

    Context '2 trailing failures then a pass (no 3-consecutive-fail run)' {
        BeforeAll {
            $script:d = Join-Path $script:tmpBase 'failpassfail'
            New-Item -ItemType Directory -Force -Path $script:d | Out-Null
            New-HtmlFixture $script:d '27510 (result1).html' $script:HTML_FAIL_SIG 30
            New-HtmlFixture $script:d '27511 (result2).html' $script:HTML_PASS     20
            New-HtmlFixture $script:d '27512 (result3).html' $script:HTML_FAIL_SIG 10
        }
        It 'returns $false (trailing run is only 1 fail)' {
            Test-RdpDropSignature -LogDir $script:d | Should -Be $false
        }
    }

    Context 'fewer than 3 HTML files total' {
        BeforeAll {
            $script:d = Join-Path $script:tmpBase 'only2'
            New-Item -ItemType Directory -Force -Path $script:d | Out-Null
            New-HtmlFixture $script:d '27510 (result1).html' $script:HTML_FAIL_SIG 20
            New-HtmlFixture $script:d '27511 (result2).html' $script:HTML_FAIL_SIG 10
        }
        It 'returns $false (threshold not reached)' {
            Test-RdpDropSignature -LogDir $script:d | Should -Be $false
        }
    }

    Context 'empty directory' {
        BeforeAll {
            $script:d = Join-Path $script:tmpBase 'empty'
            New-Item -ItemType Directory -Force -Path $script:d | Out-Null
        }
        It 'returns $false' {
            Test-RdpDropSignature -LogDir $script:d | Should -Be $false
        }
    }
}

# -----------------------------------------------------------------------------
Describe 'Get-AffectedTests' {
    BeforeAll {
        $script:tmpBase2 = Join-Path $env:TEMP 'TaRecoveryAffected'
        New-Item -ItemType Directory -Force -Path $script:tmpBase2 | Out-Null

        # AllTests used across contexts
        $script:allTests = @(
            [pscustomobject]@{ tc = '27510'; rep = 'Inventory'; prj = 'Inventory'; path = '/foo/27510_Bar {new program}' }
            [pscustomobject]@{ tc = '27511'; rep = 'Inventory'; prj = 'Inventory'; path = '/foo/27511_Baz {new program}' }
            [pscustomobject]@{ tc = '27512'; rep = 'Inventory'; prj = 'Inventory'; path = '/foo/27512_Qux {new program}' }
        )
    }
    AfterAll {
        Remove-Item -LiteralPath $script:tmpBase2 -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'Trigger A - returns only TCs with RDP-drop signature in their HTML' {
        BeforeAll {
            $script:dA = Join-Path $script:tmpBase2 'trigA'
            New-Item -ItemType Directory -Force -Path $script:dA | Out-Null
            # 27510 has signature; 27511 does not; 27512 has no HTML yet
            New-HtmlFixture $script:dA '27510 (run1).html' $script:HTML_FAIL_SIG  20
            New-HtmlFixture $script:dA '27511 (run1).html' $script:HTML_FAIL_NOSIG 10
        }
        It 'returns only the TC whose HTML matches the signature' {
            $result = Get-AffectedTests -Trigger 'A' -LogDir $script:dA `
                                        -StartedTail '' -AllTests $script:allTests
            @($result).Count | Should -Be 1
            $result[0].tc    | Should -Be '27510'
        }
    }

    Context 'Trigger B - hung TC plus not-yet-run TCs' {
        BeforeAll {
            $script:dB = Join-Path $script:tmpBase2 'trigB'
            New-Item -ItemType Directory -Force -Path $script:dB | Out-Null
            # Only 27510 has a result HTML; 27511 is hung; 27512 never started
            New-HtmlFixture $script:dB '27510 (run1).html' $script:HTML_FAIL_NOSIG 10
        }
        It 'returns the hung TC and the not-run TC' {
            $tail   = '[2026-06-12 10:30:00.00] Running TC 27511 [Inventory/Inventory]: 27511_Baz {new program}'
            $result = Get-AffectedTests -Trigger 'B' -LogDir $script:dB `
                                        -StartedTail $tail -AllTests $script:allTests
            $tcs = @($result | ForEach-Object { $_.tc }) | Sort-Object
            $tcs | Should -Be @('27511', '27512')
        }
    }

    Context 'Trigger B - all TCs have results, only the hung TC re-runs' {
        BeforeAll {
            $script:dB2 = Join-Path $script:tmpBase2 'trigB2'
            New-Item -ItemType Directory -Force -Path $script:dB2 | Out-Null
            New-HtmlFixture $script:dB2 '27510 (run1).html' $script:HTML_FAIL_NOSIG 30
            New-HtmlFixture $script:dB2 '27511 (run1).html' $script:HTML_FAIL_NOSIG 20
            New-HtmlFixture $script:dB2 '27512 (run1).html' $script:HTML_FAIL_NOSIG 10
        }
        It 'returns only the hung TC when all others already have results' {
            $tail   = '[2026-06-12 10:30:00.00] Running TC 27511 [Inventory/Inventory]: 27511_Baz {new program}'
            $result = Get-AffectedTests -Trigger 'B' -LogDir $script:dB2 `
                                        -StartedTail $tail -AllTests $script:allTests
            @($result).Count  | Should -Be 1
            $result[0].tc     | Should -Be '27511'
        }
    }

    Context 'unknown trigger - returns all tests as fallback' {
        It 'returns the full AllTests array unchanged' {
            $tmp    = Join-Path $script:tmpBase2 'empty2'
            New-Item -ItemType Directory -Force -Path $tmp | Out-Null
            $result = Get-AffectedTests -Trigger 'Z' -LogDir $tmp -StartedTail '' -AllTests $script:allTests
            @($result).Count | Should -Be 3
        }
    }
}

# -----------------------------------------------------------------------------
Describe 'Invoke-VmReboot' {
    BeforeAll {
        $script:repoRootVR  = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
        $script:scriptDirVR = Join-Path $script:repoRootVR 'src\Cobol2c.Runner\scripts'
        Import-Module (Join-Path $script:scriptDirVR 'TaRecovery.psm1') -Force
    }

    Context 'happy path - share comes back on first poll' {
        BeforeAll {
            InModuleScope TaRecovery {
                Mock Invoke-RecoveryCmd {}
                Mock Invoke-RecoverySleep {}
                Mock Test-VmSharePath { $true }
            }
        }

        It 'issues shutdown /r for the target machine' {
            Invoke-VmReboot -Machine 'TGFTA-VR1' -Ta01Pw 'pw'

            Should -Invoke Invoke-RecoveryCmd -ModuleName TaRecovery `
                -ParameterFilter { $Command -match 'shutdown /r' -and $Command -match 'TGFTA-VR1' }
        }

        It 'polls the Apps share exactly once (returns true immediately)' {
            Invoke-VmReboot -Machine 'TGFTA-VR1' -Ta01Pw 'pw'

            Should -Invoke Test-VmSharePath -ModuleName TaRecovery `
                -ParameterFilter { $Path -match 'TGFTA-VR1' -and $Path -match 'Apps' } `
                -Times 1 -Exactly
        }

        It 'sleeps exactly 3 times: 45s pre-reboot + 15s poll + 45s auto-logon settle' {
            Invoke-VmReboot -Machine 'TGFTA-VR1' -Ta01Pw 'pw'

            Should -Invoke Invoke-RecoverySleep -ModuleName TaRecovery -Times 3 -Exactly
        }
    }

    Context 'share slow to come back - polls twice before returning true' {
        BeforeAll {
            InModuleScope TaRecovery {
                $script:vrPollCount = 0
                Mock Invoke-RecoveryCmd {}
                Mock Invoke-RecoverySleep {}
                Mock Test-VmSharePath {
                    $script:vrPollCount++
                    $script:vrPollCount -ge 2   # false on first call, true on second
                }
            }
        }

        It 'polls share twice and completes without error' {
            Invoke-VmReboot -Machine 'TGFTA-VR2' -Ta01Pw 'pw'

            Should -Invoke Test-VmSharePath -ModuleName TaRecovery -Times 2 -Exactly
        }
    }
}

# -----------------------------------------------------------------------------
Describe 'Invoke-VMRecovery' {
    BeforeAll {
        $script:repoRoot3  = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
        $script:scriptDir3 = Join-Path $script:repoRoot3 'src\Cobol2c.Runner\scripts'
        Import-Module (Join-Path $script:scriptDir3 'TaRecovery.psm1') -Force
    }

    Context 'happy path - issues end+shutdown, waits for share, lets auto-logon settle' {
        BeforeAll {
            InModuleScope TaRecovery {
                Mock Invoke-RecoveryCmd {}
                Mock Invoke-RecoverySleep {}
                Mock Test-VmSharePath { $true }
            }
        }

        It 'issues schtasks /end -> shutdown /r -> polls share -> sleeps for auto-logon settle' {
            Invoke-VMRecovery -Machine 'TGFTA-REC' -Ta01Pw 'pw' -TaskName 'TestTask'

            Should -Invoke Invoke-RecoveryCmd -ModuleName TaRecovery `
                -ParameterFilter { $Command -match 'schtasks /end' -and $Command -match 'TGFTA-REC' -and $Command -match 'TestTask' }
            Should -Invoke Invoke-RecoveryCmd -ModuleName TaRecovery `
                -ParameterFilter { $Command -match 'shutdown /r' -and $Command -match 'TGFTA-REC' }
            Should -Invoke Test-VmSharePath -ModuleName TaRecovery -Times 1 -Exactly
            # 3 sleeps: 45 (reboot) + 15 (do-until always fires once) + 45 (auto-logon settle)
            Should -Invoke Invoke-RecoverySleep -ModuleName TaRecovery -Times 3 -Exactly
        }
    }

    Context 'share probe returns immediately - completes without error' {
        BeforeAll {
            InModuleScope TaRecovery {
                Mock Invoke-RecoveryCmd {}
                Mock Invoke-RecoverySleep {}
                Mock Test-VmSharePath { $true }
            }
        }

        It 'does not throw' {
            Invoke-VMRecovery -Machine 'TGFTA-SLOW' -Ta01Pw 'pw' -TaskName 'Task2'

            Should -Invoke Invoke-RecoveryCmd -ModuleName TaRecovery -Times 2 -Exactly
        }
    }
}

# -----------------------------------------------------------------------------
Describe 'Invoke-SuiteRun recovery loop (dot-sourced Invoke-TaRun.ps1)' {
    # Dot-source Invoke-TaRun.ps1.  $PSScriptRoot inside the script gives the correct module path.
    # The guard (InvocationName = '.') prevents Assert-VmReady, manifest lookup, and the run tail.
    BeforeAll {
        $script:repoRoot4  = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
        $script:scriptDir4 = Join-Path $script:repoRoot4 'src\Cobol2c.Runner\scripts'
        $script:taRunPath  = Join-Path $script:scriptDir4 'Invoke-TaRun.ps1'

        . $script:taRunPath -Suite 'TestSuite' -Machine 'TEST-VM' -Tcs '99999' `
                             -Ta01Pw 'testpw' -AutoRecover 'true'

        # Invoke-SuiteRun is dot-sourced -> calls live in the test's script scope.
        # Mock without -ModuleName so Pester's test-scope mock intercepts them.
        Mock Connect-VmShare   {}
        Mock Copy-BatToVm      {}
        Mock Invoke-RemoteTask {}
        Mock Remove-RemoteTask {}

        $script:tmpSuiteBase = Join-Path $env:TEMP 'TaSuiteRunTests'
        New-Item -ItemType Directory -Force -Path $script:tmpSuiteBase | Out-Null

        $script:fakeTests = @(
            [pscustomobject]@{ tc = '99999'; rep = 'TestRep'; prj = 'TestPrj'
                               path = '/TestRep/99999_Fake Test' }
        )

        $script:sigHtml  = @'
<!DOCTYPE html><html><body>
<td>Passed:&nbsp;0</td>
<p>WARNING: Cannot maximize window.</p>
<p>No matching UI object found for [ta class=textblock, automation id=scrollParent] within the timeout of "20" seconds.</p>
</body></html>
'@
        $script:passHtml = '<html><body><td>Passed:&nbsp;1</td></body></html>'
    }
    AfterAll {
        Remove-Item -LiteralPath $script:tmpSuiteBase -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'Trigger A detected -> auto-recover -> clean second run returns success' {
        It 'calls Invoke-VMRecovery once and returns the log dir' {
            $global:gLoopDir   = Join-Path $script:tmpSuiteBase 'trigA_test'
            $global:gCallCount = 0
            New-Item -ItemType Directory -Force -Path $global:gLoopDir | Out-Null

            # Invoke-VMRecovery: called from dot-sourced Invoke-SuiteRun -> test-scope mock
            Mock Invoke-VMRecovery { $global:gCallCount++ }

            # Invoke-RemoteTask: first call injects RDP-drop-sig HTML; second (after recovery) injects clean pass.
            Mock Invoke-RemoteTask {
                param([string]$Machine, [string]$Ta01Pw, [string]$TaskName, [string]$BatPath)
                $d = $global:gLoopDir
                if ($global:gCallCount -eq 0) {
                    # First attempt: inject 3 sig HTML files, then write finished.txt with the run token
                    Get-ChildItem -LiteralPath $d -Filter '*.html' -File -ErrorAction SilentlyContinue |
                        ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
                    1..3 | ForEach-Object {
                        $h = Join-Path $d "99999 (result$_).html"
                        Set-Content -LiteralPath $h -Value $script:sigHtml -Encoding UTF8
                        (Get-Item -LiteralPath $h).LastWriteTime = (Get-Date).AddSeconds(-$_ * 5)
                    }
                } else {
                    # Second attempt (after recovery): clean pass HTML
                    Get-ChildItem -LiteralPath $d -Filter '*.html' -File -ErrorAction SilentlyContinue |
                        ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
                    Set-Content -LiteralPath (Join-Path $d '99999 (result1).html') `
                                -Value $script:passHtml -Encoding UTF8
                }
                Set-Content -LiteralPath (Join-Path $d 'finished.txt') -Value $TaskName -Encoding Ascii
            }

            $result = Invoke-SuiteRun -Base '\\fake\base' -SuiteName 'TestSuite' `
                                       -BatName 'fake.bat' -Tests $script:fakeTests `
                                       -HtmlDir $global:gLoopDir -ClearLogs $false

            $global:gCallCount | Should -Be 1
            $result.LogDir     | Should -Be $global:gLoopDir

            Remove-Item -LiteralPath $global:gLoopDir -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Variable -Name gLoopDir, gCallCount -Scope Global -ErrorAction SilentlyContinue
        }
    }

    Context 'recovery cap reached - throws VM WEDGED after 2 recoveries' {
        It 'throws after 3 total attempts (initial + 2 recoveries)' {
            $global:gCapDir   = Join-Path $script:tmpSuiteBase 'cap_test'
            $global:gCapCount = 0
            New-Item -ItemType Directory -Force -Path $global:gCapDir | Out-Null

            Mock Invoke-VMRecovery { $global:gCapCount++ }

            # Every attempt always produces sig HTML so Trigger A fires again
            Mock Invoke-RemoteTask {
                param([string]$Machine, [string]$Ta01Pw, [string]$TaskName, [string]$BatPath)
                $d = $global:gCapDir
                Get-ChildItem -LiteralPath $d -Filter '*.html' -File -ErrorAction SilentlyContinue |
                    ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
                1..3 | ForEach-Object {
                    $h = Join-Path $d "99999 (result$_).html"
                    Set-Content -LiteralPath $h -Value $script:sigHtml -Encoding UTF8
                    (Get-Item -LiteralPath $h).LastWriteTime = (Get-Date).AddSeconds(-$_ * 5)
                }
                Set-Content -LiteralPath (Join-Path $d 'finished.txt') -Value $TaskName -Encoding Ascii
            }

            { Invoke-SuiteRun -Base '\\fake\base' -SuiteName 'TestSuite' `
                               -BatName 'fake.bat' -Tests $script:fakeTests `
                               -HtmlDir $global:gCapDir -ClearLogs $false } |
                Should -Throw -ExpectedMessage '*VM WEDGED*'

            $global:gCapCount | Should -Be 2                  # recovery called twice (cap)
            Should -Invoke Invoke-RemoteTask -Times 3 -Exactly # initial + 2 retry attempts

            Remove-Item -LiteralPath $global:gCapDir -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Variable -Name gCapDir, gCapCount -Scope Global -ErrorAction SilentlyContinue
        }
    }

    Context 'AutoRecover=false - throws immediately, no recovery called' {
        # Invoke-SuiteRun now accepts -RecoveryEnabled as an explicit parameter, so we pass
        # $false directly - no scope manipulation needed.
        It 'throws VM WEDGED without calling Invoke-VMRecovery' {
            $global:gNoRecDir = Join-Path $script:tmpSuiteBase 'no_recover'
            New-Item -ItemType Directory -Force -Path $global:gNoRecDir | Out-Null

            Mock Invoke-VMRecovery {}

            Mock Invoke-RemoteTask {
                param([string]$Machine, [string]$Ta01Pw, [string]$TaskName, [string]$BatPath)
                $d = $global:gNoRecDir
                Get-ChildItem -LiteralPath $d -Filter '*.html' -File -ErrorAction SilentlyContinue |
                    ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
                1..3 | ForEach-Object {
                    $h = Join-Path $d "99999 (result$_).html"
                    Set-Content -LiteralPath $h -Value $script:sigHtml -Encoding UTF8
                    (Get-Item -LiteralPath $h).LastWriteTime = (Get-Date).AddSeconds(-$_ * 5)
                }
                Set-Content -LiteralPath (Join-Path $d 'finished.txt') -Value $TaskName -Encoding Ascii
            }

            { Invoke-SuiteRun -Base '\\fake\base' -SuiteName 'TestSuite' `
                               -BatName 'fake.bat' -Tests $script:fakeTests `
                               -HtmlDir $global:gNoRecDir -ClearLogs $false `
                               -RecoveryEnabled $false } |
                Should -Throw -ExpectedMessage '*VM WEDGED*'

            Should -Invoke Invoke-VMRecovery -Times 0 -Exactly
            Should -Invoke Invoke-RemoteTask -Times 1 -Exactly

            Remove-Item -LiteralPath $global:gNoRecDir -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Variable -Name gNoRecDir -Scope Global -ErrorAction SilentlyContinue
        }
    }
}
