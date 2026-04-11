#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Generates a Tailscale HTTPS certificate and binds it to the Windows Remote Desktop listener.
.DESCRIPTION
    - Ensures Tailscale and OpenSSL are available
    - Gets the machine's Tailscale FQDN
    - Generates a TLS cert using `tailscale cert`
    - Converts to PFX via OpenSSL
    - Imports into the Local Machine certificate store
    - Configures the RDP listener to use the certificate
    - Optionally creates a scheduled task for automatic renewal
.NOTES
    Must be run as Administrator.
#>

param(
    [switch]$CreateScheduledTask,
    [int]$RenewalIntervalDays = 30
)

$ErrorActionPreference = "Stop"
$TempDir = Join-Path $env:TEMP "tailscale-rdp-cert"

# ─── Helper Functions ──────────────────────────────────────────────

function Write-Step {
    param([string]$Message)
    Write-Host "`n[$((Get-Date).ToString('HH:mm:ss'))] $Message" -ForegroundColor Cyan
}

function Get-OpenSslPath {
    $candidates = @(
        "openssl"
        "C:\Program Files\FireDaemon OpenSSL 3\bin\openssl.exe"
        "C:\Program Files\OpenSSL-Win64\bin\openssl.exe"
        "C:\Program Files\OpenSSL\bin\openssl.exe"
        "C:\Program Files (x86)\OpenSSL-Win32\bin\openssl.exe"
    )
    foreach ($c in $candidates) {
        if (Get-Command $c -ErrorAction SilentlyContinue) {
            return (Get-Command $c).Source
        }
        if (Test-Path $c) {
            return $c
        }
    }
    return $null
}

function Get-TailscaleFqdn {
    $statusJson = & tailscale status --json 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to get Tailscale status. Is Tailscale running and logged in?`n$statusJson"
    }

    $status = $statusJson | ConvertFrom-Json
    $self = $status.Self
    $fqdn = $self.DNSName.TrimEnd('.')

    if ([string]::IsNullOrWhiteSpace($fqdn)) {
        throw "Could not determine Tailscale FQDN. Ensure HTTPS certificates are enabled in your Tailscale admin console."
    }

    return $fqdn
}

function Remove-OldTailscaleCerts {
    param([string]$Fqdn)

    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store(
        "My", [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine
    )
    $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)

    $certsToRemove = $store.Certificates | Where-Object {
        $_.Subject -like "*$Fqdn*" -or $_.DnsNameList.Unicode -contains $Fqdn
    }

    foreach ($cert in $certsToRemove) {
        Write-Host "  Removing old certificate: $($cert.Thumbprint) (Expires: $($cert.NotAfter))" -ForegroundColor Yellow
        $store.Remove($cert)
    }

    $store.Close()
}

function Grant-PrivateKeyAccess {
    param(
        [string]$Thumbprint,
        [string]$AccountName = "NETWORK SERVICE"
    )

    try {
        $cert = Get-ChildItem -Path "Cert:\LocalMachine\My" | Where-Object { $_.Thumbprint -eq $Thumbprint }
        if (-not $cert) {
            Write-Host "  WARNING: Could not find certificate with thumbprint $Thumbprint" -ForegroundColor Yellow
            return
        }

        # Get the private key
        $privateKey = $cert.PrivateKey
        if (-not $privateKey) {
            Write-Host "  WARNING: Certificate has no private key" -ForegroundColor Yellow
            return
        }

        # Get the key file path
        $keyPath = $privateKey.CspKeyContainerInfo.UniqueKeyContainerName
        if (-not $keyPath) {
            Write-Host "  WARNING: Could not determine private key path" -ForegroundColor Yellow
            return
        }

        # Construct the full path to the key file
        $keyDir = "$env:ProgramData\Microsoft\Crypto\RSA\MachineKeys"
        $keyFile = Join-Path $keyDir $keyPath

        if (-not (Test-Path $keyFile)) {
            Write-Host "  WARNING: Private key file not found at $keyFile" -ForegroundColor Yellow
            return
        }

        # Grant NETWORK SERVICE read access to the private key
        $acl = Get-Acl -Path $keyFile
        $permission = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $AccountName,
            [System.Security.AccessControl.FileSystemRights]::Read,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        $acl.AddAccessRule($permission)
        Set-Acl -Path $keyFile -AclObject $acl

        Write-Host "  Granted $AccountName read access to private key." -ForegroundColor Green
    }
    catch {
        Write-Host "  WARNING: Could not grant private key access: $_" -ForegroundColor Yellow
    }
}

# ─── Main Script ───────────────────────────────────────────────────

Write-Host "=============================================" -ForegroundColor White
Write-Host " Tailscale RDP Certificate Setup" -ForegroundColor White
Write-Host "=============================================" -ForegroundColor White

# Step 1: Check dependencies
Write-Step "Step 1: Checking dependencies"

if (-not (Get-Command "tailscale" -ErrorAction SilentlyContinue)) {
    throw "Tailscale is not installed or not on PATH. Please install it from https://tailscale.com/download and try again."
}
Write-Host "  Tailscale: OK" -ForegroundColor Green

$openssl = Get-OpenSslPath
if (-not $openssl) {
    throw "OpenSSL is not installed or not on PATH. Please install it (e.g. 'winget install FireDaemon.OpenSSL' or from https://slproweb.com/products/Win32OpenSSL.html) and try again."
}
Write-Host "  OpenSSL:   OK ($openssl)" -ForegroundColor Green

# Step 2: Get Tailscale FQDN
Write-Step "Step 2: Getting Tailscale FQDN"
$fqdn = Get-TailscaleFqdn
Write-Host "  FQDN: $fqdn" -ForegroundColor Green

# Step 3: Generate certificates
Write-Step "Step 3: Generating Tailscale certificate"

if (-not (Test-Path $TempDir)) {
    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
}

$certFile = Join-Path $TempDir "$fqdn.crt"
$keyFile  = Join-Path $TempDir "$fqdn.key"
$pfxFile  = Join-Path $TempDir "$fqdn.pfx"

& tailscale cert --cert-file $certFile --key-file $keyFile $fqdn 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Failed to generate Tailscale certificate. Ensure HTTPS certificates are enabled in the Tailscale admin console (DNS settings)."
}
Write-Host "  Certificate generated." -ForegroundColor Green

# Step 4: Convert to PFX
Write-Step "Step 4: Converting to PFX"

$pfxPassword = [System.Guid]::NewGuid().ToString("N")

& $openssl pkcs12 -export `
    -out $pfxFile `
    -inkey $keyFile `
    -in $certFile `
    -passout "pass:$pfxPassword" 2>&1

if ($LASTEXITCODE -ne 0 -or -not (Test-Path $pfxFile)) {
    throw "Failed to convert certificate to PFX format."
}
Write-Host "  PFX created." -ForegroundColor Green

# Step 5: Remove old certs and import new one
Write-Step "Step 5: Importing certificate into Local Machine store"

Remove-OldTailscaleCerts -Fqdn $fqdn

$securePassword = ConvertTo-SecureString -String $pfxPassword -AsPlainText -Force
$importedCert = Import-PfxCertificate `
    -FilePath $pfxFile `
    -CertStoreLocation "Cert:\LocalMachine\My" `
    -Password $securePassword `
    -Exportable

$thumbprint = $importedCert.Thumbprint
Write-Host "  Imported certificate thumbprint: $thumbprint" -ForegroundColor Green
Write-Host "  Subject: $($importedCert.Subject)" -ForegroundColor Gray
Write-Host "  Expires: $($importedCert.NotAfter)" -ForegroundColor Gray

# Grant NETWORK SERVICE access to the private key
Grant-PrivateKeyAccess -Thumbprint $thumbprint -AccountName "NETWORK SERVICE"

# Step 6: Bind certificate to RDP listener
Write-Step "Step 6: Configuring RDP to use the certificate"

$tsPath = (Get-WmiObject -Class "Win32_TSGeneralSetting" -Namespace "root\cimv2\TerminalServices" -Filter "TerminalName='RDP-tcp'")
if ($null -eq $tsPath) {
    throw "Could not find the RDP-tcp listener. Is Remote Desktop enabled?"
}

Set-WmiInstance -Path $tsPath.__PATH -Argument @{ SSLCertificateSHA1Hash = $thumbprint } | Out-Null
Write-Host "  RDP listener bound to certificate $thumbprint" -ForegroundColor Green

$rdpRegPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp"
Set-ItemProperty -Path $rdpRegPath -Name "SSLCertificateSHA1Hash" -Value ([byte[]](@(
    for ($i = 0; $i -lt $thumbprint.Length; $i += 2) {
        [Convert]::ToByte($thumbprint.Substring($i, 2), 16)
    }
)))
Write-Host "  Registry updated." -ForegroundColor Green

# Restart RDP service to apply changes
Write-Step "Step 7: Restarting RDP service"
Restart-Service TermService -Force
Write-Host "  RDP service restarted." -ForegroundColor Green

# Step 8: Cleanup temp files
Write-Step "Step 8: Cleaning up temporary files"
Remove-Item -Path $certFile -Force -ErrorAction SilentlyContinue
Remove-Item -Path $keyFile  -Force -ErrorAction SilentlyContinue
Remove-Item -Path $pfxFile  -Force -ErrorAction SilentlyContinue
Remove-Item -Path $TempDir  -Force -ErrorAction SilentlyContinue -Recurse
Write-Host "  Temporary files removed." -ForegroundColor Green

# Step 9 (Optional): Create a Scheduled Task for renewal
if ($CreateScheduledTask) {
    Write-Step "Step 9: Creating scheduled task for automatic renewal"

    $scriptPath = $MyInvocation.MyCommand.Path
    if ([string]::IsNullOrWhiteSpace($scriptPath)) {
        Write-Host "  WARNING: Cannot determine script path. Save this script to a fixed location and re-run with -CreateScheduledTask." -ForegroundColor Yellow
    }
    else {
        $taskName = "Tailscale-RDP-Cert-Renewal"

        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

        $action  = New-ScheduledTaskAction -Execute "powershell.exe" `
            -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
        $trigger = New-ScheduledTaskTrigger -Daily -DaysInterval $RenewalIntervalDays -At "03:00AM"
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 15)

        Register-ScheduledTask -TaskName $taskName `
            -Action $action `
            -Trigger $trigger `
            -Principal $principal `
            -Settings $settings `
            -Description "Renews the Tailscale TLS certificate and rebinds it to the RDP listener." | Out-Null

        Write-Host "  Scheduled task '$taskName' created (runs every $RenewalIntervalDays days at 3 AM)." -ForegroundColor Green
    }
}

# ─── Summary ───────────────────────────────────────────────────────

Write-Host "`n=============================================" -ForegroundColor White
Write-Host " Done!" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor White
Write-Host " FQDN:        $fqdn"
Write-Host " Thumbprint:  $thumbprint"
Write-Host " Expires:     $($importedCert.NotAfter)"
Write-Host ""
Write-Host " You can now RDP to: $fqdn" -ForegroundColor Green
Write-Host " The connection will use a valid TLS certificate from Let's Encrypt (via Tailscale)." -ForegroundColor Gray
if (-not $CreateScheduledTask) {
    Write-Host ""
    Write-Host " TIP: Re-run with -CreateScheduledTask to set up automatic renewal." -ForegroundColor Yellow
}
Write-Host ""
