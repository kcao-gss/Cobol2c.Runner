<#
.SYNOPSIS
One-time per-VM admin setup for Cobol2c.Runner remote-push. Run as admin ON the target VM.

This script CANNOT be run remotely. LocalAccountTokenFilterPolicy is what blocks remote admin
token elevation on non-domain (workgroup) machines, so you must be in a local or console session
when running this. The easiest approach: RDP to the VM, open PowerShell as admin, paste this path.

Idempotent - safe to run multiple times. Re-run after a VM reimage or pool reassignment.

Why each step is needed:
  1. LocalAccountTokenFilterPolicy=1
     Without this, Windows filters the admin token for network logons on non-domain machines
     (KB951016). schtasks /create /s <vm> with a local admin account is ACCESS DENIED even
     though SMB (net use) works fine. This registry key removes that filter.

  2. Remote Scheduled Tasks Management firewall rule
     schtasks /s uses RPC: TCP 135 (endpoint mapper) + dynamic RPC ports. This built-in
     rule group opens the correct ports so schtasks /query (and /create, /run) reach the
     remote Task Scheduler service.

  3. Apps share -> C:\Apps  (with TA-CMD subfolder)
     Cobol2c.Runner copies the TA batch file via:
       net use \\<vm>\Apps /user:<vm>\TA01 <password>
       Copy-Item <bat> -> \\<vm>\Apps\TA-CMD
     Without the 'Apps' share, net use fails with error 67 (bad network name).

IMPORTANT: VMs in the pool reboot daily at ~6:30 PM and are reassigned.
This setup survives reboots but is lost on a reimage.
Durable fix: bake these three steps into the golden VM image so every VM is pre-provisioned.
This script is the manual fallback for a fresh or reassigned VM.
#>

#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'

Write-Host '=== Cobol2c.Runner VM Setup ===' -ForegroundColor Cyan
Write-Host "Running on: $env:COMPUTERNAME" -ForegroundColor Cyan
Write-Host ''

# 1. Remove workgroup UAC network token filtering
Write-Host '1. Setting LocalAccountTokenFilterPolicy = 1 ...' -ForegroundColor Yellow
$regKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
Set-ItemProperty -Path $regKey -Name 'LocalAccountTokenFilterPolicy' -Value 1 -Type DWord -Force
$actual = (Get-ItemProperty -Path $regKey -Name 'LocalAccountTokenFilterPolicy').LocalAccountTokenFilterPolicy
if ($actual -ne 1) { throw "Failed to set LocalAccountTokenFilterPolicy. Got: $actual" }
Write-Host "   OK: LocalAccountTokenFilterPolicy = $actual" -ForegroundColor Green

# 2. Enable the Remote Scheduled Tasks Management firewall rule group
Write-Host "2. Enabling 'Remote Scheduled Tasks Management' firewall rule ..." -ForegroundColor Yellow
Enable-NetFirewallRule -DisplayGroup 'Remote Scheduled Tasks Management' -ErrorAction Stop
$rules = @(Get-NetFirewallRule -DisplayGroup 'Remote Scheduled Tasks Management' -ErrorAction SilentlyContinue)
Write-Host "   OK: $($rules.Count) rule(s) enabled." -ForegroundColor Green

# 3. Ensure C:\Apps\TA-CMD exists and is shared as 'Apps'
Write-Host '3. Creating C:\Apps\TA-CMD ...' -ForegroundColor Yellow
$appsDir = 'C:\Apps'
$cmdDir  = 'C:\Apps\TA-CMD'
$null = New-Item -ItemType Directory -Force -Path $appsDir
$null = New-Item -ItemType Directory -Force -Path $cmdDir
Write-Host "   OK: $cmdDir exists." -ForegroundColor Green

Write-Host "   Checking 'Apps' share ..." -ForegroundColor Yellow
$existingShare = Get-SmbShare -Name 'Apps' -ErrorAction SilentlyContinue
if ($existingShare) {
    Write-Host "   OK: 'Apps' share already exists -> $($existingShare.Path)" -ForegroundColor Green
} else {
    New-SmbShare -Name 'Apps' -Path $appsDir -FullAccess 'TA01' -ErrorAction Stop
    Write-Host "   OK: 'Apps' share created -> $appsDir" -ForegroundColor Green
}

# Ensure TA01 has full control (NTFS) so batch copy succeeds even if share access is locked
Write-Host '   Granting TA01 FullControl on C:\Apps ...' -ForegroundColor Yellow
$acl  = Get-Acl -Path $appsDir
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    'TA01', 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
$acl.SetAccessRule($rule)
Set-Acl -Path $appsDir -AclObject $acl
Write-Host '   OK: TA01 has FullControl on C:\Apps.' -ForegroundColor Green

# 4. RDP-signing cert for Connect-TA01Rdp / auto-recovery
# NOTE: This step provisions the CONTROLLER machine's cert store, not the VM's.
#       Run Setup-Vm.ps1 on the CONTROLLER (not the VM) for this step to take effect.
#       Without this cert, Connect-TA01Rdp still works but mstsc will show a publisher-unknown
#       dialog that can block unattended VM re-login during auto-recovery.
Write-Host '4. Provisioning RDP-signing cert in Cert:\CurrentUser\My ...' -ForegroundColor Yellow
$certSubject = 'CN=TGFTA-RDP-Signing'
$existingCert = Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue |
                Where-Object { $_.Subject -eq $certSubject -and $_.NotAfter -gt (Get-Date) } |
                Select-Object -First 1
if ($existingCert) {
    Write-Host "   OK: Cert already present (thumbprint $($existingCert.Thumbprint), expires $($existingCert.NotAfter.ToString('yyyy-MM-dd')))." -ForegroundColor Green
} else {
    $cert = New-SelfSignedCertificate `
        -Subject         $certSubject `
        -CertStoreLocation 'Cert:\CurrentUser\My' `
        -KeyUsage        DigitalSignature `
        -Type            CodeSigningCert `
        -NotAfter        (Get-Date).AddYears(10)
    Write-Host "   OK: Created $certSubject (thumbprint $($cert.Thumbprint), expires $($cert.NotAfter.ToString('yyyy-MM-dd')))." -ForegroundColor Green
}

Write-Host ''
Write-Host "=== Setup complete on $env:COMPUTERNAME ===" -ForegroundColor Cyan
Write-Host ''
Write-Host 'Verify from the controller host:' -ForegroundColor White
Write-Host "  Test-NetConnection $env:COMPUTERNAME -Port 445   # TcpTestSucceeded: True" -ForegroundColor Gray
Write-Host "  Test-NetConnection $env:COMPUTERNAME -Port 135   # TcpTestSucceeded: True" -ForegroundColor Gray
Write-Host "  net use \\$env:COMPUTERNAME\Apps /user:$env:COMPUTERNAME\TA01 Testarchitect01" -ForegroundColor Gray
Write-Host "  schtasks /query /s $env:COMPUTERNAME /u $env:COMPUTERNAME\TA01 /p Testarchitect01" -ForegroundColor Gray
Write-Host ''
Write-Host 'IMPORTANT: This setup survives reboots but is lost on VM reimage/reassignment.' -ForegroundColor Yellow
Write-Host 'For permanent provisioning, bake steps 1-3 into the golden VM image.' -ForegroundColor Yellow
Write-Host 'Re-run step 4 on the CONTROLLER after a profile reset or cert expiry.' -ForegroundColor Yellow
