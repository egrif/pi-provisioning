#Requires -Version 5.1
<#
.SYNOPSIS
    Download, flash, and configure a Raspberry Pi SD card on Windows using cloud-init.
    Requires administrator privileges to write to the SD card.

.NOTES
    Requires WSL2 or Python 3.12 for SHA-512 password hashing.
    Requires 7-Zip, xz.exe, or WSL2 for image decompression.
    Install WSL2: run 'wsl --install' in an admin terminal, then reboot.
    Install 7-Zip: https://www.7-zip.org/

.EXAMPLE
    # Interactive (prompts for distro, disk, password)
    .\download-and-flash-cloud-init.ps1 -Hostname mypi

    # Fully specified
    .\download-and-flash-cloud-init.ps1 -Hostname mypi -Distro rpios-lite-64 -Disk 1 `
        -PiUser beartums -Timezone America/New_York `
        -NasHost 192.168.1.10 -NasUser eric `
        -WifiSsid HomeNet -WifiPassword secret

    # Skip download and flash — write cloud-init config to an already-flashed drive
    .\download-and-flash-cloud-init.ps1 -BootDrive E: -Hostname mypi

    # Proxmox VE (PiMox) — two-phase install, auto-reboots after first boot
    .\download-and-flash-cloud-init.ps1 -Hostname pimox -Pimox `
        -PiUser beartums -NasHost 192.168.1.10 -NasUser eric
#>

param(
    [string]$BootDrive      = "",    # skip download+flash; write cloud-init directly to this drive
    [string]$Distro         = "",    # distro key or number (skips interactive menu)
    [int]$Disk              = -1,    # disk number (skips interactive selection)

    [string]$Hostname       = "raspberrypi",
    [string]$PiUser         = "beartums",
    [string]$PiPassword     = "",    # prompted if omitted
    [string]$HashedPassword = "",    # pre-hashed $6$ SHA-512 (skips hashing step)
    [string]$Timezone       = "America/New_York",
    [string]$SshPubKey      = "",    # path to .pub file or literal key string
    [switch]$NoSsh,

    [string]$WifiSsid       = "",
    [string]$WifiPassword   = "",

    [string]$NasHost        = "",
    [string]$NasShare       = "grifData",
    [string]$NasUser        = "",
    [string]$NasPassword    = "",
    [string]$NasCreds       = "",    # path to existing creds file

    [string]$DockerUser     = "",
    [switch]$SkipNas,
    [switch]$SkipDocker,
    [switch]$SkipDisplay,
    [string]$CacheDir       = "",    # default: ~\.pi-images
    [switch]$NoCache,
    [switch]$Yes,            # auto-confirm non-destructive prompts (device confirm always requires "yes")

    [switch]$Pimox,                         # install Proxmox VE (two-phase; auto-reboots after first boot)
    [string]$RootPassword   = "",           # 'same' to reuse PiPassword; default: prompt with enter-to-reuse
    [string]$PimoxIp        = "",           # static IP for Proxmox bridge (default: auto-detect)
    [string]$PimoxGateway   = "",           # default gateway (default: auto-detect)
    [string]$PimoxNetmask   = "",           # CIDR prefix length, e.g. 24 (default: auto-detect)
    [string]$PimoxDns       = "",           # DNS server (default: auto-detect)
    [string]$PimoxIface     = ""            # network interface to bridge (default: auto-detect)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Info  ($m) { Write-Host "[INFO]  $m" -ForegroundColor Cyan   }
function Ok    ($m) { Write-Host "[ OK ]  $m" -ForegroundColor Green  }
function Warn  ($m) { Write-Host "[WARN]  $m" -ForegroundColor Yellow }
function Die   ($m) { Write-Host "[ERR]   $m" -ForegroundColor Red; exit 1 }
function Step  ($m) { Write-Host "`n---- $m ----" -ForegroundColor White }

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# ── Distro definitions ────────────────────────────────────────────────────────
$DISTROS = @(
    @{ Key="rpios-lite-64";    Label="Raspberry Pi OS Lite 64-bit";    Url="https://downloads.raspberrypi.com/raspios_lite_arm64_latest"; Size="~500 MB"  }
    @{ Key="rpios-desktop-64"; Label="Raspberry Pi OS Desktop 64-bit"; Url="https://downloads.raspberrypi.com/raspios_arm64_latest";      Size="~1.2 GB" }
    @{ Key="ubuntu-2404";      Label="Ubuntu Server 24.04 LTS 64-bit"; Url="https://cdimage.ubuntu.com/releases/24.04/release/ubuntu-24.04.2-preinstalled-server-arm64+raspi.img.xz"; Size="~1.1 GB" }
    @{ Key="ubuntu-2204";      Label="Ubuntu Server 22.04 LTS 64-bit"; Url="https://cdimage.ubuntu.com/releases/22.04/release/ubuntu-22.04.5-preinstalled-server-arm64+raspi.img.xz"; Size="~700 MB"  }
)

# ── Defaults ──────────────────────────────────────────────────────────────────
if ([string]::IsNullOrEmpty($DockerUser)) { $DockerUser = $PiUser }
if ([string]::IsNullOrEmpty($CacheDir))   { $CacheDir = Join-Path $env:USERPROFILE ".pi-images" }
$EnableSsh = -not $NoSsh

if ($Pimox) { $SkipDocker = $true; $SkipDisplay = $true }

if (-not [string]::IsNullOrEmpty($SshPubKey) -and (Test-Path $SshPubKey -ErrorAction SilentlyContinue)) {
    $SshPubKey = (Get-Content $SshPubKey -Raw).Trim()
}

# ── Admin check (required for disk write) ─────────────────────────────────────
if ([string]::IsNullOrEmpty($BootDrive)) {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Die "This script requires administrator privileges to flash an SD card.`n  Right-click PowerShell and choose 'Run as administrator', then re-run."
    }
}

# ── XZ decompressor detection ─────────────────────────────────────────────────
function Find-Decompressor {
    if (Get-Command xz -ErrorAction SilentlyContinue) { return "xz" }
    foreach ($p in @("$env:ProgramFiles\7-Zip\7z.exe","${env:ProgramFiles(x86)}\7-Zip\7z.exe")) {
        if (Test-Path $p) { return $p }
    }
    if (Get-Command 7z -ErrorAction SilentlyContinue) { return "7z" }
    try {
        $null = wsl which xz 2>$null
        if ($LASTEXITCODE -eq 0) { return "wsl-xz" }
    } catch {}
    return $null
}

function Expand-XZ([string]$Tool, [string]$SrcFile, [string]$DestFile) {
    Info "Decompressing image (this may take a few minutes)..."
    if ($Tool -eq "xz") {
        & xz --decompress --keep --stdout $SrcFile > $DestFile
        if ($LASTEXITCODE -ne 0) { Die "xz decompression failed" }
    } elseif ($Tool -match '7z(\.exe)?$') {
        $outDir = Split-Path $DestFile
        & $Tool e $SrcFile "-o$outDir" -y 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Die "7-Zip decompression failed" }
        $extracted = Join-Path $outDir ([System.IO.Path]::GetFileNameWithoutExtension($SrcFile))
        if ((Test-Path $extracted) -and $extracted -ne $DestFile) { Move-Item $extracted $DestFile -Force }
    } elseif ($Tool -eq "wsl-xz") {
        $wslSrc = (wsl wslpath ($SrcFile -replace '\\','/')).Trim()
        wsl xz --decompress --keep --stdout $wslSrc > $DestFile
        if ($LASTEXITCODE -ne 0) { Die "WSL xz decompression failed" }
    } else {
        Die "No decompressor available. Install one of:`n  - 7-Zip: https://www.7-zip.org/`n  - WSL2: 'wsl --install' (admin terminal, then reboot)`n  - xz.exe from https://tukaani.org/xz/"
    }
    Ok "Decompressed: $DestFile"
}

# ── Password hashing ──────────────────────────────────────────────────────────
function Get-SHA512Hash([string]$Password) {
    # Try WSL + openssl
    try {
        $hash = ($Password | wsl openssl passwd -6 -stdin 2>$null)
        if ($LASTEXITCODE -eq 0 -and $hash -match '^\$6\$') { return $hash.Trim() }
    } catch {}
    # Try Python3 (crypt module, Python 3.6–3.12)
    try {
        $pyCode = 'import crypt,sys; pw=sys.stdin.readline().rstrip(chr(13)); print(crypt.crypt(pw, crypt.mksalt(crypt.METHOD_SHA512)))'
        $hash = ($Password | python3 -c $pyCode 2>$null)
        if ($LASTEXITCODE -eq 0 -and $hash -match '^\$6\$') { return $hash.Trim() }
    } catch {}
    return $null
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 1 — Credentials (needed in both normal and boot-path modes)
# ─────────────────────────────────────────────────────────────────────────────
Step "Pi user credentials"

$HashedPass = ""
if (-not [string]::IsNullOrEmpty($HashedPassword)) {
    if ($HashedPassword -notmatch '^\$6\$') { Die "-HashedPassword must start with '`$6`$'" }
    $HashedPass = $HashedPassword
    Ok "Using provided SHA-512 hash"
} else {
    if ([string]::IsNullOrEmpty($PiPassword)) {
        $sec1 = Read-Host "Password for '$PiUser'" -AsSecureString
        $sec2 = Read-Host "Confirm password"       -AsSecureString
        $b1   = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec1)
        $b2   = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec2)
        $PiPassword  = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($b1)
        $PiPassword2 = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($b2)
        if ($PiPassword -ne $PiPassword2) { Die "Passwords do not match" }
    }
    $HashedPass = Get-SHA512Hash $PiPassword
    if (-not $HashedPass) {
        Die "Cannot hash password. Options:`n  1. Install WSL2: 'wsl --install' (admin terminal, reboot)`n  2. Install Python 3.12 or earlier from python.org`n  3. Pass a pre-hashed value as -HashedPassword '`$6`$...'"
    }
    Ok "Password hashed (SHA-512)"
}

# NAS credentials
$NasCredsContent = ""
if (-not $SkipNas -and [string]::IsNullOrEmpty($NasHost)) { $SkipNas = $true }

if (-not $SkipNas) {
    Step "NAS credentials"
    if (-not [string]::IsNullOrEmpty($NasCreds)) {
        if (-not (Test-Path $NasCreds)) { Die "Credentials file not found: $NasCreds" }
        $NasCredsContent = (Get-Content $NasCreds -Raw).Replace("`r`n","`n").Trim()
        Ok "Using credentials file: $NasCreds"
    } elseif (-not [string]::IsNullOrEmpty($NasUser)) {
        if ([string]::IsNullOrEmpty($NasPassword)) {
            $sec = Read-Host "NAS password for '$NasUser'" -AsSecureString
            $b   = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
            $NasPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($b)
        }
        $NasCredsContent = "username=$NasUser`npassword=$NasPassword"
    } else {
        $NasUser = Read-Host "NAS username"
        $sec = Read-Host "NAS password" -AsSecureString
        $b   = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        $NasPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($b)
        $NasCredsContent = "username=$NasUser`npassword=$NasPassword"
    }
    Ok "NAS credentials ready"
}

# Pimox root password
$HashedRootPass = ""
if ($Pimox) {
    Step "Proxmox root password"
    if ($RootPassword -eq "same") {
        $RootPassword = $PiPassword
        Ok "Root password: reusing pi-user password"
    } elseif ([string]::IsNullOrEmpty($RootPassword)) {
        $sec = Read-Host "Proxmox root password [Enter to reuse pi-user password]" -AsSecureString
        $b   = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        $tmp = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($b)
        if ([string]::IsNullOrEmpty($tmp)) {
            $RootPassword = $PiPassword
            Ok "Root password: reusing pi-user password"
        } else {
            $RootPassword = $tmp
            Ok "Root password: set (custom)"
        }
    } else {
        Ok "Root password: provided via -RootPassword"
    }
    $HashedRootPass = Get-SHA512Hash $RootPassword
    if (-not $HashedRootPass) {
        Die "Cannot hash root password. Install WSL2 or Python 3.12 for SHA-512 hashing."
    }
    Ok "Root password hashed (SHA-512)"
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 2 — Boot partition: either provided directly (-BootDrive) or
#            obtained by downloading + flashing an image
# ─────────────────────────────────────────────────────────────────────────────
$BootPath    = ""
$DistroLabel = ""

if (-not [string]::IsNullOrEmpty($BootDrive)) {

    # ── Boot-drive mode: skip download and flash ───────────────────────────────
    Step "Boot-drive mode (skipping download and flash)"
    $BootPath = $BootDrive.TrimEnd('\') + '\'
    if (-not (Test-Path $BootPath)) { Die "Drive not found: $BootPath" }
    if (-not (Test-Path "${BootPath}cmdline.txt")) {
        Die "cmdline.txt not found in $BootPath`n  Flash the SD card first, or check the drive letter."
    }
    $DistroLabel = "(boot-drive mode)"
    Ok "Using boot drive: $BootPath"

} else {

    # ── Normal mode: distro → download → flash → mount ─────────────────────────
    Step "Distribution"

    $selectedDistro = $null
    if (-not [string]::IsNullOrEmpty($Distro)) {
        if ($Distro -match '^\d+$') {
            $idx = [int]$Distro - 1
            if ($idx -ge 0 -and $idx -lt $DISTROS.Count) { $selectedDistro = $DISTROS[$idx] }
        } else {
            $selectedDistro = $DISTROS | Where-Object { $_.Key -eq $Distro } | Select-Object -First 1
        }
        if (-not $selectedDistro) { Die "Unknown distro: $Distro  (valid keys: $($DISTROS.Key -join ', '))" }
    } else {
        Write-Host ""
        Write-Host "  Available distributions:" -ForegroundColor White
        Write-Host ""
        for ($i = 0; $i -lt $DISTROS.Count; $i++) {
            $d = $DISTROS[$i]
            $default = if ($d.Key -eq "rpios-lite-64") { "  <- default" } else { "" }
            Write-Host ("  {0}) {1,-48} {2}{3}" -f ($i+1), $d.Label, $d.Size, $default)
        }
        Write-Host ""
        $choice = Read-Host "Choose a distro [1]"
        if ([string]::IsNullOrEmpty($choice)) { $choice = "1" }
        if ($choice -notmatch '^\d+$') { Die "Invalid selection" }
        $idx = [int]$choice - 1
        if ($idx -lt 0 -or $idx -ge $DISTROS.Count) { Die "Selection out of range" }
        $selectedDistro = $DISTROS[$idx]
    }
    $DistroLabel = $selectedDistro.Label
    Ok "Selected: $DistroLabel"

    # ── Image download ──────────────────────────────────────────────────────────
    Step "Image download"

    if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir | Out-Null }
    $cacheFile = Join-Path $CacheDir "$($selectedDistro.Key).img.xz"
    $imgFile   = Join-Path $CacheDir "$($selectedDistro.Key).img"

    $needDownload = $true
    if (-not $NoCache -and (Test-Path $cacheFile)) {
        $ageDays = ([DateTime]::Now - (Get-Item $cacheFile).LastWriteTime).TotalDays
        if ($ageDays -lt 7) {
            Ok "Using cached image ($([int]$ageDays)d old): $cacheFile"
            $needDownload = $false
        } else {
            Warn "Cached image is $([int]$ageDays) days old — re-downloading"
            Remove-Item $cacheFile, $imgFile -ErrorAction SilentlyContinue
        }
    }

    if ($needDownload) {
        Info "Downloading $DistroLabel..."
        $ProgressPreference = 'Continue'
        Invoke-WebRequest -Uri $selectedDistro.Url -OutFile $cacheFile -UseBasicParsing
        Ok "Download complete: $cacheFile"
    }

    $decompressor = Find-Decompressor
    if (-not (Test-Path $imgFile)) {
        Expand-XZ -Tool $decompressor -SrcFile $cacheFile -DestFile $imgFile
    } else {
        Info "Decompressed image already exists: $imgFile"
    }

    # ── Disk selection ──────────────────────────────────────────────────────────
    Step "SD card disk"

    $candidateDisks = Get-Disk | Where-Object { $_.BusType -in @('USB','SD') -and $_.Size -gt 0 } | Sort-Object Number
    if ($candidateDisks.Count -eq 0) {
        $candidateDisks = Get-Disk | Where-Object { $_.Number -gt 0 -and $_.Size -lt 256GB } | Sort-Object Number
        if ($candidateDisks.Count -gt 0) {
            Warn "No USB/SD disks detected — showing non-boot disks under 256 GB"
        }
    }

    if ($Disk -ge 0) {
        $selectedDisk = Get-Disk -Number $Disk -ErrorAction SilentlyContinue
        if (-not $selectedDisk) { Die "Disk $Disk not found" }
    } else {
        if ($candidateDisks.Count -eq 0) { Die "No candidate disks found. Insert the SD card and re-run." }
        Write-Host ""
        Write-Host "  Detected disks:" -ForegroundColor White
        Write-Host ""
        foreach ($d in $candidateDisks) {
            $sizeGB = [math]::Round($d.Size / 1GB, 1)
            Write-Host ("  Disk {0}  {1,6} GB  {2}  {3}" -f $d.Number, $sizeGB, $d.BusType, $d.FriendlyName)
        }
        Write-Host ""
        $diskInput = Read-Host "Enter disk number (e.g. 1)"
        if ($diskInput -notmatch '^\d+$') { Die "Invalid disk number" }
        $selectedDisk = Get-Disk -Number ([int]$diskInput) -ErrorAction SilentlyContinue
        if (-not $selectedDisk) { Die "Disk $diskInput not found" }
    }

    $diskSizeGB = [math]::Round($selectedDisk.Size / 1GB, 1)
    Write-Host ""
    Write-Host "[WARN]  About to flash Disk $($selectedDisk.Number): $($selectedDisk.FriendlyName) ($diskSizeGB GB) with $DistroLabel" -ForegroundColor Yellow
    Write-Host ""
    $confirm = Read-Host "Type 'yes' to confirm (THIS WILL ERASE ALL DATA ON THE DISK)"
    if ($confirm -ne "yes") { Die "Aborted" }

    # ── Flash ───────────────────────────────────────────────────────────────────
    Step "Flashing"

    # Remove drive letter access from all partitions so Windows releases the device
    try {
        Get-Partition -DiskNumber $selectedDisk.Number -ErrorAction SilentlyContinue | ForEach-Object {
            foreach ($ap in $_.AccessPaths) {
                if ($ap -match '^[A-Za-z]:\\$') {
                    Remove-PartitionAccessPath -DiskNumber $selectedDisk.Number -PartitionNumber $_.PartitionNumber -AccessPath $ap -ErrorAction SilentlyContinue
                }
            }
        }
        Start-Sleep -Seconds 1
    } catch { Warn "Could not pre-remove drive letters — proceeding anyway" }

    $diskDevice = "\\.\PhysicalDrive$($selectedDisk.Number)"
    $imgSize    = (Get-Item $imgFile).Length
    Info "Writing $([math]::Round($imgSize/1GB,2)) GB to $diskDevice ..."

    try {
        $srcStream = [System.IO.File]::OpenRead($imgFile)
        $dstStream = New-Object System.IO.FileStream(
            $diskDevice,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::ReadWrite,
            (4 * 1024 * 1024)
        )
        $buf       = New-Object byte[] (4 * 1024 * 1024)
        $written   = [long]0
        $startTime = [DateTime]::Now
        while (($read = $srcStream.Read($buf, 0, $buf.Length)) -gt 0) {
            $dstStream.Write($buf, 0, $read)
            $written += $read
            $elapsed  = ([DateTime]::Now - $startTime).TotalSeconds
            $speedMB  = if ($elapsed -gt 0) { [int]($written / $elapsed / 1MB) } else { 0 }
            $pct      = [int](100 * $written / $imgSize)
            Write-Progress -Activity "Flashing SD card" -Status "$pct%  |  $speedMB MB/s  |  $([math]::Round($written/1GB,2))/$([math]::Round($imgSize/1GB,2)) GB" -PercentComplete $pct
        }
        $dstStream.Flush()
        Write-Progress -Activity "Flashing SD card" -Completed
    } catch [System.UnauthorizedAccessException] {
        Die "Access denied writing to disk $($selectedDisk.Number).`n  Make sure no Explorer windows are open on the SD card, then re-run."
    } finally {
        if ($srcStream) { $srcStream.Close() }
        if ($dstStream) { $dstStream.Close() }
    }
    Ok "Flash complete"

    # ── Mount boot partition ────────────────────────────────────────────────────
    Step "Mounting boot partition"

    # Rescan so Windows picks up the new partition table
    "rescan" | diskpart | Out-Null
    Start-Sleep -Seconds 3

    $bootPart = Get-Partition -DiskNumber $selectedDisk.Number -ErrorAction SilentlyContinue |
        Where-Object { $_.Size -gt 0 -and $_.Size -lt 1GB } |
        Select-Object -First 1

    if (-not $bootPart) { Die "Could not detect boot partition on disk $($selectedDisk.Number) — try re-inserting the SD card" }

    if (-not $bootPart.DriveLetter) {
        Add-PartitionAccessPath -DiskNumber $selectedDisk.Number -PartitionNumber $bootPart.PartitionNumber -AssignDriveLetter
        Start-Sleep -Seconds 3
        $bootPart = Get-Partition -DiskNumber $selectedDisk.Number -PartitionNumber $bootPart.PartitionNumber
    }

    if (-not $bootPart.DriveLetter) { Die "Could not assign a drive letter to the boot partition" }
    $BootPath = "$($bootPart.DriveLetter):\"
    if (-not (Test-Path "${BootPath}cmdline.txt")) { Die "cmdline.txt not found in $BootPath — flash may have failed" }
    Ok "Boot partition mounted at: $BootPath"
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 3 — Generate cloud-init files
# ─────────────────────────────────────────────────────────────────────────────
Step "Generating cloud-init configuration"

$InstanceId  = "pi-provisioner-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
$GeneratedAt = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssK")
Info "Instance ID: $InstanceId"

$UserDataSb = [System.Text.StringBuilder]::new()
function ud([string]$line) { [void]$script:UserDataSb.AppendLine($line) }

ud "#cloud-config"
ud "# Generated by download-and-flash-cloud-init.ps1  |  $GeneratedAt"
ud "# Instance: $InstanceId"
ud ""
ud "manage_resolv_conf: false"
ud ""
ud "hostname: $Hostname"
ud "manage_etc_hosts: true"
ud ""
ud "apt:"
ud "  preserve_sources_list: true"
ud "  conf: |"
ud "    Acquire {"
ud '      Check-Date "false";'
ud "    };"
ud ""
ud "timezone: $Timezone"
ud ""
ud "keyboard:"
ud "  model: pc105"
ud '  layout: "us"'
ud ""
ud "users:"
ud "  - name: $PiUser"
ud "    groups: users,adm,dialout,audio,netdev,video,plugdev,cdrom,games,input,gpio,spi,i2c,render,sudo"
ud "    shell: /bin/bash"
ud "    sudo: ALL=(ALL) NOPASSWD:ALL"
ud "    lock_passwd: false"
ud "    passwd: `"$HashedPass`""
if (-not [string]::IsNullOrEmpty($SshPubKey)) {
    ud "    ssh_authorized_keys:"
    ud "      - $SshPubKey"
}
ud ""
ud "chpasswd:"
ud "  expire: false"
ud ""
ud "enable_ssh: $($EnableSsh.ToString().ToLower())"
ud "ssh_pwauth: $($EnableSsh.ToString().ToLower())"
ud ""
ud "rpi:"
ud "  interfaces:"
ud "    serial: true"
ud "    i2c: true"
ud ""
ud "packages:"
ud "  - avahi-daemon"
ud "  - i2c-tools"
if (-not $SkipNas) { ud "  - cifs-utils" }
ud ""
ud "package_update: true"
ud "package_upgrade: false"
ud ""
ud "write_files:"

if (-not $SkipNas) {
    ud "  - path: /etc/cifs-credentials"
    ud "    owner: root:root"
    ud "    permissions: '0600'"
    ud "    content: |"
    foreach ($line in ($NasCredsContent -split "`n")) { ud "      $line" }
}

if (-not $SkipDisplay) {
    $showDocker = if (-not $SkipDocker) { '1' } else { '0' }
    ud "  - path: /etc/ssd1306.conf"
    ud "    owner: root:root"
    ud "    permissions: '0644'"
    ud "    content: |"
    ud "      # ssd1306 display config -- pre-seeded by download-and-flash-cloud-init.ps1"
    ud "      show_temperature=1"
    ud "      show_memory=1"
    ud "      show_disk=1"
    ud "      show_ip=1"
    ud "      show_hostname=1"
    ud "      show_clock=1"
    ud "      show_uptime=1"
    ud "      show_docker=$showDocker"
    ud "      show_network=0"
    ud "      show_wifi=0"
    ud "      show_gpu_temp=0"
    ud "      show_cpu_freq=0"
    ud "      temp_unit=fahrenheit"
    ud "      load_display=percent"
    ud "      screen_time=3"
    ud "      top_line=hostname"
    ud "      network_interfaces=eth0,wlan0"
}

if ($Pimox) {
    ud "  - path: /usr/local/sbin/pimox-install.sh"
    ud "    permissions: '0755'"
    ud "    owner: root:root"
    ud "    content: |"
    ud '      #!/usr/bin/env bash'
    ud '      set -euo pipefail'
    ud '      exec >> /var/log/pimox-install.log 2>&1'
    ud '      echo "[$(date -Iseconds)] Starting Proxmox VE installation..."'
    ud '      export DEBIAN_FRONTEND=noninteractive'
    ud '      echo "postfix postfix/main_mailer_type select Local only"   | debconf-set-selections'
    ud '      echo "postfix postfix/mailname           string $(hostname)" | debconf-set-selections'
    ud '      apt-get install -y proxmox-ve postfix open-iscsi pve-edk2-firmware-aarch64'
    ud '      echo "[$(date -Iseconds)] Proxmox VE installation complete."'
    ud '      systemctl disable pimox-install.service'
    ud ""
    ud "  - path: /etc/systemd/system/pimox-install.service"
    ud "    owner: root:root"
    ud "    permissions: '0644'"
    ud "    content: |"
    ud "      [Unit]"
    ud "      Description=PiMox -- Install Proxmox VE after reboot"
    ud "      After=network-online.target"
    ud "      Wants=network-online.target"
    ud "      ConditionPathExists=/usr/local/sbin/pimox-install.sh"
    ud "      "
    ud "      [Service]"
    ud "      Type=oneshot"
    ud "      ExecStart=/usr/local/sbin/pimox-install.sh"
    ud "      RemainAfterExit=yes"
    ud "      StandardOutput=journal"
    ud "      StandardError=journal"
    ud "      "
    ud "      [Install]"
    ud "      WantedBy=multi-user.target"
    ud ""
    ud "  - path: /etc/cloud/cloud.cfg.d/99-pimox-hostname.cfg"
    ud "    owner: root:root"
    ud "    permissions: '0644'"
    ud "    content: |"
    ud "      preserve_hostname: true"
    ud "      manage_etc_hosts: false"
}

# pi-provision.sh — config vars use PowerShell expansion; bash body is a literal single-quoted here-string
$skipNasBash     = if ($SkipNas)     { 'true' } else { 'false' }
$skipDockerBash  = if ($SkipDocker)  { 'true' } else { 'false' }
$skipDisplayBash = if ($SkipDisplay) { 'true' } else { 'false' }
$pimoxBash       = if ($Pimox)       { 'true' } else { 'false' }

$piProvisionConfig = @"
#!/bin/bash
set -euo pipefail

# Configuration (embedded at flash time)
PI_USER="$PiUser"
TIMEZONE="$Timezone"
SKIP_NAS=$skipNasBash
NAS_HOST="$NasHost"
NAS_SHARE="$NasShare"
SKIP_DOCKER=$skipDockerBash
DOCKER_USER="$DockerUser"
SKIP_DISPLAY=$skipDisplayBash
PI_HOSTNAME="$Hostname"
PIMOX=$pimoxBash
"@

$piProvisionPimoxConfig = ""
if ($Pimox) {
    $piProvisionPimoxConfig = @"
PIMOX_IP="$PimoxIp"
PIMOX_GATEWAY="$PimoxGateway"
PIMOX_NETMASK="$PimoxNetmask"
PIMOX_DNS="$PimoxDns"
PIMOX_IFACE="$PimoxIface"
HASHED_ROOT_PASS="$HashedRootPass"
"@
}

$piProvisionBody = @'

# Logging setup
LOG=/var/log/pi-provisioning.log
exec >> "$LOG" 2>&1

ts()   { date -Iseconds 2>/dev/null || date; }
log()  { echo "[$(ts)] $*"; }
ok()   { echo "[$(ts)] [ OK ] $*"; }
fail() { echo "[$(ts)] [FAIL] $*"; }
step() { echo "[$(ts)] ──────────────────────────────────────────────────"; echo "[$(ts)] $*"; }

step "pi-provision.sh starting"
log "Hostname    : $(hostname)"
log "Kernel      : $(uname -r)"
log "Uptime      : $(uptime -p 2>/dev/null || uptime)"
log "Pi user     : $PI_USER"
log "Timezone    : $TIMEZONE"
log "Skip NAS    : $SKIP_NAS"
log "Skip Docker : $SKIP_DOCKER"
log "Skip Display: $SKIP_DISPLAY"
log "Free disk   : $(df -h / | awk 'NR==2{print $4}') available"
log "Memory      : $(free -h | awk '/^Mem/{print $2}') total"

# Wait for apt lock
step "Waiting for apt lock"
MAX_WAIT=36
for i in $(seq 1 $MAX_WAIT); do
  if flock -w 1 /var/lib/dpkg/lock-frontend true 2>/dev/null; then
    ok "apt lock acquired after $i attempt(s)"
    break
  fi
  log "Waiting for dpkg lock... ($i/$MAX_WAIT)"
  sleep 5
done

# WiFi unblock
step "WiFi unblock"
rfkill unblock wifi 2>/dev/null && log "rfkill unblock wifi: done" || log "rfkill not available (skipping)"
UNBLOCKED=0
for f in /var/lib/systemd/rfkill/*:wlan; do
  if [ -f "$f" ]; then
    echo 0 > "$f"
    log "Cleared rfkill state: $f"
    UNBLOCKED=$(( UNBLOCKED + 1 ))
  fi
done
[ "$UNBLOCKED" -gt 0 ] && ok "Cleared $UNBLOCKED rfkill state file(s)" || log "No rfkill state files found"

# NAS / CIFS mount
if [[ "$SKIP_NAS" == "false" ]]; then
  step "NAS CIFS mount"
  log "Target: //${NAS_HOST}/${NAS_SHARE} -> /mnt/${NAS_SHARE}"
  MOUNT_POINT="/mnt/${NAS_SHARE}"
  mkdir -p "$MOUNT_POINT"
  log "Mount point ready: $MOUNT_POINT"
  if [ -f /etc/cifs-credentials ]; then
    log "Credentials file: /etc/cifs-credentials ($(stat -c %a /etc/cifs-credentials) perms)"
  else
    fail "Credentials file not found: /etc/cifs-credentials"
  fi
  FSTAB_LINE="//${NAS_HOST}/${NAS_SHARE}  ${MOUNT_POINT}  cifs  credentials=/etc/cifs-credentials,iocharset=utf8,vers=3.0,_netdev,nofail  0  0"
  if grep -qF "$MOUNT_POINT" /etc/fstab; then
    log "fstab entry already present -- skipping"
  else
    printf '\n# pi-provision: %s\n%s\n' "$MOUNT_POINT" "$FSTAB_LINE" >> /etc/fstab
    ok "fstab entry added for $MOUNT_POINT"
    log "Entry: $FSTAB_LINE"
  fi
  log "Attempting mount..."
  if mount "$MOUNT_POINT" 2>/dev/null || mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
    ok "Mounted //${NAS_HOST}/${NAS_SHARE} -> $MOUNT_POINT"
    log "Contents (first 5): $(ls "$MOUNT_POINT" 2>/dev/null | head -5 | tr '\n' ' ' || echo "(empty or unreadable)")"
  else
    fail "Mount failed -- NAS may not be reachable yet"
    log "Hint: retry manually with: mount $MOUNT_POINT"
    log "Hint: check credentials with: smbclient -L //${NAS_HOST} -U <user>"
  fi
fi

# Docker installation
if [[ "$SKIP_DOCKER" == "false" ]]; then
  step "Docker"
  if command -v docker &>/dev/null; then
    ok "Docker already installed: $(docker --version)"
  else
    log "Downloading Docker install script from get.docker.com..."
    curl -fsSL https://get.docker.com | sh
    ok "Docker installed: $(docker --version)"
  fi
  if docker compose version &>/dev/null 2>&1; then
    ok "Docker Compose: $(docker compose version --short 2>/dev/null || docker compose version)"
  else
    log "Docker Compose plugin missing -- installing..."
    apt-get install -y -qq docker-compose-plugin || fail "docker-compose-plugin install failed (non-fatal)"
    ok "Docker Compose plugin install attempted"
  fi
  if id "$DOCKER_USER" &>/dev/null; then
    usermod -aG docker "$DOCKER_USER" || fail "usermod -aG docker $DOCKER_USER failed (non-fatal)"
    ok "$DOCKER_USER added to docker group"
  else
    fail "User $DOCKER_USER not found -- docker group assignment skipped"
  fi
fi

# ssd1306 OLED display (beartums/U6143_ssd1306)
if [[ "$SKIP_DISPLAY" == "false" ]]; then
  step "ssd1306 OLED display"
  log "Checking i2c bus..."
  i2cdetect -y 1 2>/dev/null && log "i2cdetect complete" || log "i2cdetect failed -- i2c may not be ready yet"
  log "Downloading install script from beartums/U6143_ssd1306..."
  curl -fsSL https://raw.githubusercontent.com/beartums/U6143_ssd1306/master/install.sh -o /tmp/ssd1306-install.sh
  log "Running installer (SUDO_USER=$PI_USER)..."
  SUDO_USER="$PI_USER" bash /tmp/ssd1306-install.sh
  rm -f /tmp/ssd1306-install.sh
  log "ssd1306 install script finished"
  if systemctl is-active --quiet ssd1306-display 2>/dev/null; then
    ok "ssd1306-display service is running"
  else
    log "ssd1306-display service not running yet -- may need a reboot"
    log "Check status: systemctl status ssd1306-display"
    log "Check logs:   journalctl -u ssd1306-display -n 50"
  fi
  log "i2c bus after install:"
  i2cdetect -y 1 2>/dev/null || log "i2cdetect not available"
fi

# ── Pimox Phase 1 ───────────────────────────────────────────────────────────
if [[ "$PIMOX" == "true" ]]; then
  step "Pimox Phase 1"

  # Network auto-detection
  PIFACE="$PIMOX_IFACE"
  [[ -z "$PIFACE" ]] && PIFACE=$(ip -4 route show default 2>/dev/null | awk '/^default/{print $5;exit}')
  [[ -n "$PIFACE" ]] || { fail "Could not detect network interface"; exit 1; }
  log "Interface: $PIFACE"

  SIP="$PIMOX_IP"
  [[ -z "$SIP" ]] && SIP=$(ip -4 addr show "$PIFACE" 2>/dev/null | awk '/inet /{split($2,a,"/");print a[1];exit}')
  [[ -n "$SIP" ]] || { fail "Could not detect IP on $PIFACE"; exit 1; }
  log "Static IP: $SIP"

  NM="$PIMOX_NETMASK"
  [[ -z "$NM" ]] && NM=$(ip -4 addr show "$PIFACE" 2>/dev/null | awk '/inet /{split($2,a,"/");print a[2];exit}')
  NM="${NM:-24}"
  log "Netmask: /$NM"

  GW="$PIMOX_GATEWAY"
  [[ -z "$GW" ]] && GW=$(ip -4 route show default 2>/dev/null | awk '/^default/{print $3;exit}')
  [[ -n "$GW" ]] || { fail "Could not detect gateway"; exit 1; }
  log "Gateway: $GW"

  PDNS="$PIMOX_DNS"
  [[ -z "$PDNS" ]] && PDNS=$(awk '/^nameserver/{print $2;exit}' /etc/resolv.conf 2>/dev/null || true)
  PDNS="${PDNS:-1.1.1.1}"
  log "DNS: $PDNS"

  CODENAME=$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-bookworm}" || echo "bookworm")
  log "OS codename: $CODENAME"

  # Update /etc/hosts with static IP → hostname mapping
  log "Updating /etc/hosts..."
  sed -i "/\b${PI_HOSTNAME}\b/d" /etc/hosts
  echo "${SIP}    ${PI_HOSTNAME}" >> /etc/hosts
  ok "Added ${SIP} -> ${PI_HOSTNAME} in /etc/hosts"

  # Set root password (chpasswd -e accepts pre-hashed password)
  echo "root:${HASHED_ROOT_PASS}" | chpasswd -e
  ok "Root password set"

  # Add PiMox GPG key
  log "Adding PiMox GPG key..."
  curl -L "https://mirrors.lierfang.com/pxcloud/lierfang.gpg" | tee /usr/share/keyrings/lierfang.gpg > /dev/null
  ok "PiMox GPG key added"

  # Add PiMox repository and refresh
  echo "deb [arch=arm64 signed-by=/usr/share/keyrings/lierfang.gpg] https://mirrors.lierfang.com/pxcloud/pxvirt ${CODENAME} main" \
    > /etc/apt/sources.list.d/pveport.list
  apt-get update -y -qq
  ok "PiMox apt repository added"

  # Disable NetworkManager (conflicts with Proxmox bridge networking)
  if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    systemctl disable --now NetworkManager && systemctl mask NetworkManager
    ok "NetworkManager disabled and masked"
  else
    log "NetworkManager not active -- skipping"
  fi

  # Install ifupdown2 (Debian-native networking, required by Proxmox)
  log "Installing ifupdown2..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ifupdown2
  ok "ifupdown2 installed"

  # Configure vmbr0 Linux bridge
  log "Configuring /etc/network/interfaces (vmbr0 bridge)..."
  [[ -f /etc/network/interfaces ]] && cp /etc/network/interfaces /etc/network/interfaces.pimox-backup
  cat > /etc/network/interfaces <<NETEOF
# Generated by pi-provision.sh (pimox mode)
auto lo
iface lo inet loopback

auto ${PIFACE}
iface ${PIFACE} inet manual

auto vmbr0
iface vmbr0 inet static
    address ${SIP}/${NM}
    gateway ${GW}
    dns-nameservers ${PDNS}
    bridge-ports ${PIFACE}
    bridge-stp off
    bridge-fd 0
NETEOF
  ok "vmbr0 bridge: ${PIFACE} -> vmbr0 @ ${SIP}/${NM}, gw ${GW}"

  step "Pimox Phase 1 complete"
  log "Proxmox VE will install on next boot via pimox-install.service"
  log "Phase 2 log: /var/log/pimox-install.log"
  log "Proxmox web UI: https://${SIP}:8006  (after Phase 2 completes)"
fi

step "pi-provision.sh complete"
log "Provisioning log : $LOG"
log "Cloud-init log   : /var/log/cloud-init-output.log"
log "Cloud-init status: /run/cloud-init/status.json"
'@

$piProvisionScript = $piProvisionConfig + $piProvisionPimoxConfig + $piProvisionBody
$indented = ($piProvisionScript.TrimEnd() -split "`n" | ForEach-Object { "      $_" }) -join "`n"

ud "  - path: /usr/local/sbin/pi-provision.sh"
ud "    permissions: '0755'"
ud "    owner: root:root"
ud "    content: |"
[void]$script:UserDataSb.AppendLine($indented)

ud ""
ud "runcmd:"
ud "  - [ bash, /usr/local/sbin/pi-provision.sh ]"
if ($Pimox) {
    ud "  - [ systemctl, daemon-reload ]"
    ud "  - [ systemctl, enable, pimox-install.service ]"
}

if ($Pimox) {
    ud ""
    ud "power_state:"
    ud "  mode: reboot"
    ud "  delay: '+1'"
    ud "  message: Rebooting to complete Pimox setup and install Proxmox VE"
}

$UserDataContent = $script:UserDataSb.ToString().Replace("`r`n", "`n")
$UserDataFile = "${BootPath}user-data"
[System.IO.File]::WriteAllText($UserDataFile, $UserDataContent, $Utf8NoBom)
Ok "user-data written: $UserDataFile"

# ── meta-data ─────────────────────────────────────────────────────────────────
$MetaDataFile = "${BootPath}meta-data"
[System.IO.File]::WriteAllText($MetaDataFile, "instance-id: $InstanceId`n", $Utf8NoBom)
Ok "meta-data written (instance-id: $InstanceId)"

# ── cmdline.txt ───────────────────────────────────────────────────────────────
$CmdlineFile = "${BootPath}cmdline.txt"
$cmdline = ((Get-Content $CmdlineFile -Raw) -replace "`r|`n", " ").Trim()
$cmdline = ($cmdline -replace '\s*ds=nocloud;i=\S*', '').Trim()
$cmdline = "$cmdline ds=nocloud;i=$InstanceId"
[System.IO.File]::WriteAllText($CmdlineFile, "$cmdline`n", $Utf8NoBom)
Ok "cmdline.txt updated (ds=nocloud;i=$InstanceId)"

# ── config.txt — enable i2c ───────────────────────────────────────────────────
$ConfigFile = "${BootPath}config.txt"
if (Test-Path $ConfigFile) {
    $configContent = Get-Content $ConfigFile -Raw
    if ($configContent -match '(?m)^#dtparam=i2c_arm=on') {
        $configContent = $configContent -replace '(?m)^#dtparam=i2c_arm=on', 'dtparam=i2c_arm=on'
        [System.IO.File]::WriteAllText($ConfigFile, $configContent.Replace("`r`n","`n"), $Utf8NoBom)
        Ok "i2c uncommented in config.txt"
    } elseif ($configContent -match '(?m)^dtparam=i2c_arm=on') {
        Info "i2c already enabled in config.txt"
    } else {
        $addition = "`n# Added by download-and-flash-cloud-init.ps1`ndtparam=i2c_arm=on`n"
        [System.IO.File]::WriteAllText($ConfigFile, ($configContent.Replace("`r`n","`n") + $addition), $Utf8NoBom)
        Ok "i2c appended to config.txt"
    }
} else {
    Warn "config.txt not found -- skipping i2c config"
}

# ── network-config ────────────────────────────────────────────────────────────
$NetConfigFile = "${BootPath}network-config"
if (-not [string]::IsNullOrEmpty($WifiSsid)) {
    $wifiPasswordLine = if (-not [string]::IsNullOrEmpty($WifiPassword)) { "`n          password: `"$WifiPassword`"" } else { "" }
    $netContent = @"
# network-config -- generated by download-and-flash-cloud-init.ps1
# netplan v2 format; applied by cloud-init on first boot only.

network:
  version: 2
  ethernets:
    eth0:
      dhcp4: true
      optional: true
  wifis:
    wlan0:
      dhcp4: true
      optional: true
      regulatory-domain: US
      access-points:
        "$WifiSsid":$wifiPasswordLine
"@
} else {
    $netContent = @'
# network-config -- generated by download-and-flash-cloud-init.ps1
# Uncomment and edit to configure WiFi:
#network:
#  version: 2
#  ethernets:
#    eth0:
#      dhcp4: true
#      optional: true
#  wifis:
#    wlan0:
#      dhcp4: true
#      optional: true
#      access-points:
#        "myssid":
#          password: "mypassword"
'@
}
[System.IO.File]::WriteAllText($NetConfigFile, $netContent.Replace("`r`n","`n"), $Utf8NoBom)
Ok "network-config written"

# ── Eject ─────────────────────────────────────────────────────────────────────
if ([string]::IsNullOrEmpty($BootDrive)) {
    Step "Ejecting"
    try {
        $vol = Get-Volume -DriveLetter $BootPath[0] -ErrorAction SilentlyContinue
        if ($vol) {
            $shell = New-Object -ComObject Shell.Application
            $shell.NameSpace(17).ParseName($BootPath).InvokeVerb("Eject")
            Ok "SD card ejected — safe to remove"
        }
    } catch {
        Warn "Auto-eject failed — please eject the SD card manually before removing"
    }
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║  SD card ready -- cloud-init provisioning            ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Info "Distro      : $DistroLabel"
Info "Hostname    : $Hostname"
Info "User        : $PiUser"
Info "Timezone    : $Timezone"
Info "SSH         : $(if ($EnableSsh) { 'enabled (password auth)' } else { 'disabled' })"
Info "i2c         : enabled (config.txt + rpi.interfaces)"
if (-not [string]::IsNullOrEmpty($WifiSsid)) { Info "WiFi        : $WifiSsid" }
if (-not $SkipNas)    { Info "NAS         : //$NasHost/$NasShare -> /mnt/$NasShare" }
if (-not $SkipDocker) { Info "Docker      : will install for '$DockerUser'" }
if (-not $SkipDisplay){ Info "Display     : ssd1306 OLED (beartums/U6143_ssd1306)" }
if ($Pimox) {
    Info "Pimox       : enabled"
    Info "  Phase 1   : runs on first boot (hostname, bridge, GPG key, repo)"
    Info "  Phase 2   : runs after auto-reboot (installs proxmox-ve)"
    $pimoxWebIp = if (-not [string]::IsNullOrEmpty($PimoxIp)) { $PimoxIp } else { "<auto-detected-ip>" }
    Info "  Web UI    : https://${pimoxWebIp}:8006  (after Phase 2)"
}
Info "Instance ID : $InstanceId"
Write-Host ""
Info "On first boot, cloud-init will run /usr/local/sbin/pi-provision.sh"
Info "Provisioning log : /var/log/pi-provisioning.log   (on the Pi)"
Info "Cloud-init log   : /var/log/cloud-init-output.log (on the Pi)"
Write-Host ""
if ([string]::IsNullOrEmpty($BootDrive)) {
    Warn "Remove the SD card and insert it into the Pi"
} else {
    Warn "Eject the SD card safely before inserting it into the Pi"
}
