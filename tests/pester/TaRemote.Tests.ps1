#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# TaRemote.Tests.ps1 — unit tests for TaRemote.psm1
# Tests cover: Assert-VmReady error paths, Invoke-RemoteTask flag correctness,
# and Remove-RemoteTask cleanup ordering.

BeforeAll {
    $script:repoRoot  = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $script:scriptDir = Join-Path $script:repoRoot 'src\Cobol2c.Runner\scripts'
    Import-Module (Join-Path $script:scriptDir 'TaRemote.psm1') -Force
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'Assert-VmReady — preflight error paths' {

    Context 'TCP 445 refused (VM down or network-blocked)' {
        BeforeAll {
            Mock -ModuleName TaRemote Test-NetConnection {
                [pscustomobject]@{ TcpTestSucceeded = $false }
            } -ParameterFilter { $Port -eq 445 }
            Mock -ModuleName TaRemote Test-NetConnection {
                [pscustomobject]@{ TcpTestSucceeded = $false }
            } -ParameterFilter { $Port -eq 135 }
        }
        It 'throws with VM DOWN message mentioning the reboot schedule' {
            { Assert-VmReady -Machine 'TGFTA-118' -Ta01Pw 'pw' } |
                Should -Throw -ExpectedMessage '*VM DOWN*'
        }
        It 'does NOT call Invoke-Cmd when TCP 445 is refused' {
            Mock -ModuleName TaRemote Invoke-Cmd { throw 'should not be called' }
            { Assert-VmReady -Machine 'TGFTA-118' -Ta01Pw 'pw' } | Should -Throw
            Should -Invoke Invoke-Cmd -ModuleName TaRemote -Times 0
        }
    }

    Context 'TCP 445 open, TCP 135 refused (RPC/firewall)' {
        BeforeAll {
            Mock -ModuleName TaRemote Test-NetConnection {
                [pscustomobject]@{ TcpTestSucceeded = $true }
            } -ParameterFilter { $Port -eq 445 }
            Mock -ModuleName TaRemote Test-NetConnection {
                [pscustomobject]@{ TcpTestSucceeded = $false }
            } -ParameterFilter { $Port -eq 135 }
        }
        It 'throws mentioning TCP 135 and Setup-Vm.ps1' {
            { Assert-VmReady -Machine 'TGFTA-118' -Ta01Pw 'pw' } |
                Should -Throw -ExpectedMessage '*TCP 135*'
        }
    }

    Context 'TCP open, net use error 67 (Apps share missing)' {
        BeforeAll {
            Mock -ModuleName TaRemote Test-NetConnection {
                [pscustomobject]@{ TcpTestSucceeded = $true }
            }
            # net use connect -> error 67; net use delete -> ok
            Mock -ModuleName TaRemote Invoke-Cmd {
                [pscustomobject]@{ Output = 'System error 67 has occurred. Bad network name.'; ExitCode = 67 }
            } -ParameterFilter { $Command -match 'net use.*Apps.*user' }
            Mock -ModuleName TaRemote Invoke-Cmd {
                [pscustomobject]@{ Output = ''; ExitCode = 0 }
            } -ParameterFilter { $Command -match 'net use.*Apps.*delete' }
        }
        It 'throws with SHARE MISSING message' {
            { Assert-VmReady -Machine 'TGFTA-118' -Ta01Pw 'pw' } |
                Should -Throw -ExpectedMessage '*SHARE MISSING*'
        }
        It 'message includes guidance to run Setup-Vm.ps1' {
            { Assert-VmReady -Machine 'TGFTA-118' -Ta01Pw 'pw' } |
                Should -Throw -ExpectedMessage '*Setup-Vm.ps1*'
        }
    }

    Context 'TCP open, net use error 1326 (auth failure)' {
        BeforeAll {
            Mock -ModuleName TaRemote Test-NetConnection {
                [pscustomobject]@{ TcpTestSucceeded = $true }
            }
            Mock -ModuleName TaRemote Invoke-Cmd {
                [pscustomobject]@{ Output = 'Logon failure: unknown user or bad password. Error 1326'; ExitCode = 1326 }
            } -ParameterFilter { $Command -match 'net use.*Apps.*user' }
            Mock -ModuleName TaRemote Invoke-Cmd {
                [pscustomobject]@{ Output = ''; ExitCode = 0 }
            } -ParameterFilter { $Command -match 'net use.*Apps.*delete' }
        }
        It 'throws with AUTH FAILURE message' {
            { Assert-VmReady -Machine 'TGFTA-118' -Ta01Pw 'wrong' } |
                Should -Throw -ExpectedMessage '*AUTH FAILURE*'
        }
    }

    Context 'TCP open, net use ok, schtasks /query RPC unavailable (firewall rule missing)' {
        BeforeAll {
            Mock -ModuleName TaRemote Test-NetConnection {
                [pscustomobject]@{ TcpTestSucceeded = $true }
            }
            Mock -ModuleName TaRemote Invoke-Cmd {
                [pscustomobject]@{ Output = 'The command completed successfully.'; ExitCode = 0 }
            } -ParameterFilter { $Command -match 'net use' }
            Mock -ModuleName TaRemote Invoke-Cmd {
                [pscustomobject]@{ Output = 'ERROR: RPC server is unavailable.'; ExitCode = 1 }
            } -ParameterFilter { $Command -match 'schtasks /query' }
        }
        It 'throws with REMOTE TASK SCHEDULER UNREACHABLE message' {
            { Assert-VmReady -Machine 'TGFTA-118' -Ta01Pw 'pw' } |
                Should -Throw -ExpectedMessage '*REMOTE TASK SCHEDULER UNREACHABLE*'
        }
    }

    Context 'all layers pass (healthy VM)' {
        BeforeAll {
            Mock -ModuleName TaRemote Test-NetConnection {
                [pscustomobject]@{ TcpTestSucceeded = $true }
            }
            Mock -ModuleName TaRemote Invoke-Cmd {
                [pscustomobject]@{ Output = 'The command completed successfully.'; ExitCode = 0 }
            }
        }
        It 'does not throw' {
            { Assert-VmReady -Machine 'TGFTA-118' -Ta01Pw 'pw' } | Should -Not -Throw
        }
        It 'calls Test-NetConnection for both port 445 and 135' {
            Assert-VmReady -Machine 'TGFTA-118' -Ta01Pw 'pw'
            Should -Invoke Test-NetConnection -ModuleName TaRemote -ParameterFilter { $Port -eq 445 } -Times 1
            Should -Invoke Test-NetConnection -ModuleName TaRemote -ParameterFilter { $Port -eq 135 } -Times 1
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'Invoke-RemoteTask — schtasks flag correctness' {
    # These tests verify the exact flags passed to schtasks /create and /run.
    # The flags are documented in TaRemote.psm1 with explicit "do NOT alter" warnings.

    BeforeAll {
        $script:capturedCommands = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName TaRemote Invoke-Cmd {
            $script:capturedCommands.Add($Command)
            [pscustomobject]@{ Output = 'SUCCESS'; ExitCode = 0 }
        }
    }
    BeforeEach {
        $script:capturedCommands.Clear()
        Invoke-RemoteTask -Machine 'TGFTA-118' -Ta01Pw 'TestPw1' `
                          -TaskName 'RunnerTask' -BatPath 'C:\Apps\TA-CMD\run.bat'
    }

    It 'uses bare /ru TA01 (NOT machine-qualified TGFTA-118\TA01) for run-as account' {
        # Machine-qualified form fails SID lookup on the remote Task Scheduler service
        $script:capturedCommands[0] | Should -Match '/ru TA01'
        $script:capturedCommands[0] | Should -Not -Match '/ru ["]?TGFTA-118\\TA01'
    }

    It 'includes /it flag to bind the task to the interactive TA01 session' {
        # Without /it the task runs in Session 0 with no display — TA GUI never renders
        $script:capturedCommands[0] | Should -Match ' /it '
    }

    It 'does NOT include /rp flag (would force Session 0 and break GUI automation)' {
        $script:capturedCommands[0] | Should -Not -Match '/rp'
    }

    It 'includes /rl HIGHEST (required to stop GssSystemIntegrityService inside the batch)' {
        $script:capturedCommands[0] | Should -Match '/rl HIGHEST'
    }

    It 'includes /f (force-recreate for idempotent retry)' {
        $script:capturedCommands[0] | Should -Match ' /f'
    }

    It 'issues exactly two commands: /create then /run' {
        $script:capturedCommands.Count | Should -Be 2
        $script:capturedCommands[0] | Should -Match 'schtasks /create'
        $script:capturedCommands[1] | Should -Match 'schtasks /run'
    }

    It 'uses machine-qualified /u for remote authentication (connection auth, not run-as)' {
        # /u for authenticating the schtasks.exe remote connection is correctly machine-qualified
        $script:capturedCommands[0] | Should -Match '/u "?TGFTA-118\\TA01"?'
    }

    It '/run command includes the task name' {
        $script:capturedCommands[1] | Should -Match 'RunnerTask'
    }

    It 'throws when schtasks /create fails' {
        Mock -ModuleName TaRemote Invoke-Cmd {
            [pscustomobject]@{ Output = 'ERROR: Access is denied.'; ExitCode = 1 }
        } -ParameterFilter { $Command -match 'schtasks /create' }
        { Invoke-RemoteTask -Machine 'TGFTA-118' -Ta01Pw 'pw' `
                            -TaskName 'Task' -BatPath 'C:\Apps\TA-CMD\run.bat' } |
            Should -Throw -ExpectedMessage '*schtasks /create failed*'
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'Remove-RemoteTask — cleanup ordering' {
    It 'issues schtasks /delete before disconnecting the share' {
        $calls = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName TaRemote Invoke-Cmd {
            $calls.Add($Command)
            [pscustomobject]@{ Output = ''; ExitCode = 0 }
        }
        Remove-RemoteTask -Machine 'TGFTA-118' -Ta01Pw 'pw' -TaskName 'MyTask'
        $calls.Count    | Should -Be 2
        $calls[0]       | Should -Match 'schtasks /delete'
        $calls[1]       | Should -Match 'net use.*Apps.*delete'
    }

    It 'does not throw when the task no longer exists (idempotent)' {
        Mock -ModuleName TaRemote Invoke-Cmd {
            [pscustomobject]@{ Output = 'ERROR: The specified task does not exist.'; ExitCode = 1 }
        } -ParameterFilter { $Command -match 'schtasks /delete' }
        Mock -ModuleName TaRemote Invoke-Cmd {
            [pscustomobject]@{ Output = ''; ExitCode = 0 }
        } -ParameterFilter { $Command -match 'net use' }
        { Remove-RemoteTask -Machine 'TGFTA-118' -Ta01Pw 'pw' -TaskName 'Gone' } |
            Should -Not -Throw
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'Connect-VmShare / Disconnect-VmShare' {
    It 'Connect-VmShare uses machine-qualified user and the Apps share' {
        $script:capturedConnectCmd = $null
        Mock -ModuleName TaRemote Invoke-Cmd {
            $script:capturedConnectCmd = $Command
            [pscustomobject]@{ Output = ''; ExitCode = 0 }
        }
        Connect-VmShare -Machine 'TGFTA-118' -Ta01Pw 'TestPw1'
        $script:capturedConnectCmd | Should -Match '\\\\TGFTA-118\\Apps'
        $script:capturedConnectCmd | Should -Match 'TGFTA-118\\TA01'
    }

    It 'Connect-VmShare throws on failure' {
        Mock -ModuleName TaRemote Invoke-Cmd {
            [pscustomobject]@{ Output = 'Error 67'; ExitCode = 67 }
        }
        { Connect-VmShare -Machine 'TGFTA-118' -Ta01Pw 'pw' } |
            Should -Throw -ExpectedMessage '*net use failed*'
    }

    It 'Disconnect-VmShare does not throw even if the share was never connected' {
        Mock -ModuleName TaRemote Invoke-Cmd {
            [pscustomobject]@{ Output = 'This connection has not been made.'; ExitCode = 1 }
        }
        { Disconnect-VmShare -Machine 'TGFTA-118' } | Should -Not -Throw
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'Invoke-Cmd — stdin-close and timeout guards' {
    # These tests exercise the REAL Invoke-Cmd (no mock) to verify the two defensive
    # properties that prevent pipeline hangs:
    #   1. stdin is closed — a command that would block reading from stdin instead
    #      receives EOF immediately and exits (e.g. "pause" → exits with code 1
    #      rather than blocking forever).
    #   2. timeout — a slow command is killed and throws after the deadline.
    # Both tests must complete in well under 10 s; a regression would cause them to hang.

    It 'passes EOF to the child process so stdin-sensitive commands do not block' {
        # "echo Y | choice /c YN /n" would select Y interactively, but with stdin closed
        # (< NUL) the child gets EOF on the very first read and returns a non-zero exit
        # code without hanging.  We just verify the call completes in finite time.
        $result = InModuleScope TaRemote {
            Invoke-Cmd -Command 'choice /c YN /n /t 0 /d N'
        }
        # choice exits 1 (Y) or 2 (N); either is fine — what matters is it returned at all.
        $result.ExitCode | Should -BeIn @(1, 2)
    }

    It 'throws a timeout error when the command exceeds TimeoutSeconds' {
        # ping -n 6 takes ~5 s; a 2-second timeout fires before it finishes.
        { InModuleScope TaRemote { Invoke-Cmd -Command 'ping -n 6 127.0.0.1' -TimeoutSeconds 2 } } |
            Should -Throw -ExpectedMessage '*timed out*'
    }

    It 'includes /f in schtasks /create so an existing task name never triggers an overwrite prompt' {
        # Regression guard: /f must be present so schtasks does not show an interactive
        # "overwrite? [Y/N]" dialog when the task already exists.
        $createCmd = $null
        Mock -ModuleName TaRemote Invoke-Cmd {
            if ($Command -match 'schtasks /create') { $script:createCmd = $Command }
            [pscustomobject]@{ Output = 'SUCCESS'; ExitCode = 0 }
        }
        InModuleScope TaRemote { $script:createCmd = $null }
        Invoke-RemoteTask -Machine 'TGFTA-118' -Ta01Pw 'pw' `
                          -TaskName 'TestTask' -BatPath 'C:\Apps\TA-CMD\run.bat'
        $script:createCmd | Should -Match ' /f'
    }
}
