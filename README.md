```markdown
# Tailscale RDP Certificate Manager

Automatically generate and bind a valid TLS certificate to the Windows Remote Desktop (RDP) listener using [Tailscale](https://tailscale.com/) and Let's Encrypt.

## Why?

By default, Windows RDP uses a self-signed certificate. This means every time you connect, you see an ugly trust warning — and you have no way to verify you're connecting to the right machine.

Tailscale can provision [free Let's Encrypt certificates](https://tailscale.com/kb/1153/enabling-https/) for any machine on your tailnet. This script takes that certificate and binds it to your RDP listener, giving you **trusted, warning-free Remote Desktop connections** over Tailscale.

## How It Works

```
tailscale cert ──► PEM cert + key ──► OpenSSL ──► PFX ──► Windows Cert Store ──► RDP Listener
```

1. Queries `tailscale status` to determine your machine's Tailscale FQDN (e.g. `mypc.tail1234.ts.net`)
2. Runs `tailscale cert` to obtain a Let's Encrypt TLS certificate
3. Converts the PEM certificate + key into a PFX using OpenSSL
4. Removes any previously imported Tailscale certs from the Local Machine store
5. Imports the new PFX into `Cert:\LocalMachine\My`
6. Binds the certificate to the RDP-tcp listener via WMI and the registry
7. Cleans up all temporary key material from disk
8. *(Optional)* Creates a scheduled task for automatic renewal

Based on the approach described in [tailscale/tailscale#2928](https://github.com/tailscale/tailscale/issues/2928).

## Prerequisites

| Requirement | Details |
|---|---|
| **Windows** | Windows 10/11 or Windows Server 2016+ |
| **Remote Desktop** | Must be enabled on the machine |
| **Tailscale** | Installed, running, and logged in. Download from [tailscale.com/download](https://tailscale.com/download) |
| **OpenSSL** | Installed and accessible. See [Installation](#installing-openssl) below |
| **HTTPS Certificates** | Enabled in your [Tailscale admin console](https://login.tailscale.com/admin/dns) under **DNS → HTTPS Certificates** |
| **Administrator** | The script must be run as Administrator |

### Installing OpenSSL

The script does **not** install OpenSSL automatically. If it's not already on your system, install it via one of:

```powershell
# Option 1: winget
winget install FireDaemon.OpenSSL

# Option 2: winget (Shining Light)
winget install ShiningLight.OpenSSL.Light
```

Or download manually from [slproweb.com](https://slproweb.com/products/Win32OpenSSL.html).

The script checks the following paths automatically:

- `openssl` (on PATH)
- `C:\Program Files\FireDaemon OpenSSL 3\bin\openssl.exe`
- `C:\Program Files\OpenSSL-Win64\bin\openssl.exe`
- `C:\Program Files\OpenSSL\bin\openssl.exe`
- `C:\Program Files (x86)\OpenSSL-Win32\bin\openssl.exe`

## Usage

### One-Time Setup

```powershell
.\Set-TailscaleRdpCert.ps1
```

### With Automatic Renewal

```powershell
.\Set-TailscaleRdpCert.ps1 -CreateScheduledTask
```

This creates a scheduled task (`Tailscale-RDP-Cert-Renewal`) that runs as SYSTEM every 30 days at 3:00 AM.

### Custom Renewal Interval

```powershell
.\Set-TailscaleRdpCert.ps1 -CreateScheduledTask -RenewalIntervalDays 14
```

## Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-CreateScheduledTask` | Switch | `$false` | Creates a Windows scheduled task for automatic renewal |
| `-RenewalIntervalDays` | Int | `30` | How often (in days) the scheduled task runs |

## Example Output

```
=============================================
 Tailscale RDP Certificate Setup
=============================================

[11:45:23] Step 1: Checking dependencies
  Tailscale: OK
  OpenSSL:   OK (C:\Program Files\FireDaemon OpenSSL 3\bin\openssl.exe)

[11:45:23] Step 2: Getting Tailscale FQDN
  FQDN: mypc.tail1234.ts.net

[11:45:24] Step 3: Generating Tailscale certificate
  Certificate generated.

[11:45:24] Step 4: Converting to PFX
  PFX created.

[11:45:24] Step 5: Importing certificate into Local Machine store
  Imported certificate thumbprint: A1B2C3D4E5F6...
  Subject: CN=mypc.tail1234.ts.net
  Expires: 06/23/2026 00:00:00

[11:45:25] Step 6: Configuring RDP to use the certificate
  RDP listener bound to certificate A1B2C3D4E5F6...
  Registry updated.

[11:45:25] Step 7: Cleaning up temporary files
  Temporary files removed.

=============================================
 Done!
=============================================
 FQDN:        mypc.tail1234.ts.net
 Thumbprint:  A1B2C3D4E5F6...
 Expires:     06/23/2026 00:00:00

 You can now RDP to: mypc.tail1234.ts.net

 TIP: Re-run with -CreateScheduledTask to set up automatic renewal.
```

## Connecting

After running the script, connect to your machine using its Tailscale FQDN:

```
mstsc /v:mypc.tail1234.ts.net
```

You should see a **valid, trusted certificate** with no security warnings.

## Security Notes

- **Temporary key material** (PEM key, PFX) is written to `%TEMP%\tailscale-rdp-cert\` and deleted immediately after import
- The PFX is encrypted with a **random one-time password** that exists only in memory during execution
- Old Tailscale certificates are **automatically removed** from the certificate store before importing the new one
- The scheduled task runs as **SYSTEM** — no user credentials are stored

## Troubleshooting

| Issue | Solution |
|---|---|
| `Failed to get Tailscale status` | Ensure Tailscale is running and you're logged in (`tailscale login`) |
| `Could not determine Tailscale FQDN` | Enable HTTPS certificates in the [Tailscale admin console](https://login.tailscale.com/admin/dns) |
| `Failed to generate Tailscale certificate` | Same as above — HTTPS certs must be enabled under DNS settings |
| `Could not find the RDP-tcp listener` | Enable Remote Desktop in Windows Settings → System → Remote Desktop |
| `OpenSSL is not installed` | See [Installing OpenSSL](#installing-openssl) |
| Certificate warning still appears | Ensure you're connecting via the **Tailscale FQDN**, not an IP address |

## License

MIT

## Acknowledgements

- [Tailscale](https://tailscale.com/) for making networking not terrible
- [tailscale/tailscale#2928](https://github.com/tailscale/tailscale/issues/2928) for the original approach
```