<#
.SYNOPSIS
One-time per-VM admin setup for Cobol2c.Runner remote-push. Run as admin ON the target VM.

This script CANNOT be run remotely. LocalAccountTokenFilterPolicy is what blocks remote admin
token elevation on non-domain (workgroup) machines, so you must be in a local or console session
when running this. The easiest approach: RDP to the VM, open PowerShell as admin, paste this path.

Idempotent — safe to run multiple times. Re-run after a VM reimage or pool reassignment.

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

param(
    [string]$Ta01Pw = ''   # if provided, used for step-5 LSA autologon non-interactively; else prompts (Read-Host)
)

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

# 5. Autologon via LSA secret (Sysinternals Autologon approach via P/Invoke)
# Stores the password in the LSA private data store so Windows reads it at boot
# without a plaintext DefaultPassword REG_SZ. Also fixes DevicePasswordLessBuildVersion
# which resets AutoAdminLogon to 0 on every boot if left at 0x2.
Write-Host '5. Configuring autologon via LSA secret ...' -ForegroundColor Yellow

if ([string]::IsNullOrEmpty($Ta01Pw)) {
    $autologonPw = Read-Host -Prompt '   Enter TA01 password for autologon (will NOT be echoed)' -AsSecureString
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($autologonPw)
    $plainPw = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
} else {
    $plainPw = $Ta01Pw   # non-interactive: supplied at runtime (not stored)
}

# P/Invoke: LsaStorePrivateData writes to the LSA secret store (SYSTEM/local-admin readable)
$lsaCode = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public class LsaUtil {
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern uint LsaOpenPolicy(ref LSA_UNICODE_STRING SystemName,
        ref LSA_OBJECT_ATTRIBUTES ObjectAttributes, uint DesiredAccess,
        out IntPtr PolicyHandle);

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern uint LsaStorePrivateData(IntPtr PolicyHandle,
        ref LSA_UNICODE_STRING KeyName, ref LSA_UNICODE_STRING PrivateData);

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern uint LsaClose(IntPtr ObjectHandle);

    [StructLayout(LayoutKind.Sequential)]
    public struct LSA_UNICODE_STRING {
        public ushort Length;
        public ushort MaximumLength;
        public IntPtr Buffer;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct LSA_OBJECT_ATTRIBUTES {
        public uint Length;
        public IntPtr RootDirectory;
        public IntPtr ObjectName;
        public uint Attributes;
        public IntPtr SecurityDescriptor;
        public IntPtr SecurityQualityOfService;
    }

    public static uint StorePrivateData(string keyName, string value) {
        var sysName = new LSA_UNICODE_STRING();
        var objAttr = new LSA_OBJECT_ATTRIBUTES { Length = (uint)Marshal.SizeOf(typeof(LSA_OBJECT_ATTRIBUTES)) };

        IntPtr policy;
        uint r = LsaOpenPolicy(ref sysName, ref objAttr, 0x20006 /* POLICY_CREATE_SECRET | POLICY_WRITE */, out policy);
        if (r != 0) return r;

        try {
            byte[] keyBytes = Encoding.Unicode.GetBytes(keyName);
            byte[] valBytes = Encoding.Unicode.GetBytes(value);

            IntPtr keyBuf = Marshal.AllocHGlobal(keyBytes.Length);
            IntPtr valBuf = Marshal.AllocHGlobal(valBytes.Length);
            Marshal.Copy(keyBytes, 0, keyBuf, keyBytes.Length);
            Marshal.Copy(valBytes, 0, valBuf, valBytes.Length);

            var keyStr = new LSA_UNICODE_STRING {
                Length = (ushort)keyBytes.Length,
                MaximumLength = (ushort)keyBytes.Length,
                Buffer = keyBuf
            };
            var valStr = new LSA_UNICODE_STRING {
                Length = (ushort)valBytes.Length,
                MaximumLength = (ushort)valBytes.Length,
                Buffer = valBuf
            };

            r = LsaStorePrivateData(policy, ref keyStr, ref valStr);
            Marshal.FreeHGlobal(keyBuf);
            Marshal.FreeHGlobal(valBuf);
        } finally {
            LsaClose(policy);
        }
        return r;
    }
}
'@

Add-Type -TypeDefinition $lsaCode -Language CSharp

$keyName = 'DefaultPassword'
$result = [LsaUtil]::StorePrivateData($keyName, $plainPw)
$plainPw = $null   # clear from memory promptly

if ($result -ne 0) {
    throw "LsaStorePrivateData failed with NTSTATUS 0x$($result.ToString('X8')). Ensure you are running as admin."
}
Write-Host '   OK: LSA secret DefaultPassword stored.' -ForegroundColor Green

# Set Winlogon keys for autologon (without plaintext DefaultPassword REG_SZ)
$wlKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty -Path $wlKey -Name 'AutoAdminLogon'  -Value '1'             -Type String -Force
Set-ItemProperty -Path $wlKey -Name 'DefaultUserName' -Value 'TA01'           -Type String -Force
Set-ItemProperty -Path $wlKey -Name 'DefaultDomainName' -Value (hostname)     -Type String -Force
Set-ItemProperty -Path $wlKey -Name 'ForceAutoLogon'  -Value '1'             -Type String -Force
Set-ItemProperty -Path $wlKey -Name 'DisableCad'      -Value '1'             -Type DWord  -Force

# Remove plaintext DefaultPassword REG_SZ if present (LSA secret supersedes it)
Remove-ItemProperty -Path $wlKey -Name 'DefaultPassword' -ErrorAction SilentlyContinue
Write-Host '   OK: DefaultPassword REG_SZ removed (LSA secret is authoritative).' -ForegroundColor Green

# Fix DevicePasswordLessBuildVersion — if set to 0x2 it resets AutoAdminLogon to 0 on every boot
$pwlessKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PasswordLess\Device'
if (Test-Path $pwlessKey) {
    Set-ItemProperty -Path $pwlessKey -Name 'DevicePasswordLessBuildVersion' -Value 0 -Type DWord -Force
    Write-Host '   OK: DevicePasswordLessBuildVersion = 0 (prevents autologon reset on boot).' -ForegroundColor Green
} else {
    Write-Host '   INFO: DevicePasswordLessBuildVersion key absent — no reset risk.' -ForegroundColor Cyan
}

Write-Host '   OK: Autologon configured (LSA secret). Reboot to apply.' -ForegroundColor Green

Write-Host ''
Write-Host "=== Setup complete on $env:COMPUTERNAME ===" -ForegroundColor Cyan
Write-Host ''
Write-Host 'Verify from the controller host:' -ForegroundColor White
Write-Host "  Test-NetConnection $env:COMPUTERNAME -Port 445   # TcpTestSucceeded: True" -ForegroundColor Gray
Write-Host "  Test-NetConnection $env:COMPUTERNAME -Port 135   # TcpTestSucceeded: True" -ForegroundColor Gray
Write-Host "  net use \\$env:COMPUTERNAME\Apps /user:$env:COMPUTERNAME\TA01 <password>" -ForegroundColor Gray
Write-Host "  schtasks /query /s $env:COMPUTERNAME /u $env:COMPUTERNAME\TA01 /p <password>" -ForegroundColor Gray
Write-Host ''
Write-Host 'IMPORTANT: This setup survives reboots but is lost on VM reimage/reassignment.' -ForegroundColor Yellow
Write-Host 'For permanent provisioning, bake steps 1-3 into the golden VM image.' -ForegroundColor Yellow
Write-Host 'Re-run step 4 on the CONTROLLER after a profile reset or cert expiry.' -ForegroundColor Yellow
