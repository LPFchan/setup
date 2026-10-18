# Enroll a Windows machine in the fleet:
#   irm https://raw.githubusercontent.com/LPFchan/setup/main/install.ps1 | iex
# Installs Python if needed, auth and fleet into ~\.local\bin, turns on the
# OpenSSH server (one UAC prompt), signs in, syncs and schedules the nightly pass.
# Run it again to repair or update; every step checks before it changes anything.

& {
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Source = if ($env:SOURCE_URL) { $env:SOURCE_URL } else { 'https://raw.githubusercontent.com/LPFchan/setup/main' }
$Bin = Join-Path $HOME '.local\bin'
$Manifest = Join-Path $HOME '.config\fleet\manifest.json'

function Step($text) { Write-Host "setup: $text" }

function Find-Python {
    # Each candidate is asked for its own path; python.exe on PATH may be the
    # Store's stub, which only opens the Store. No double quotes in the -c code:
    # Windows PowerShell drops them on the way to a native program.
    $probe = 'import sys; sys.version_info >= (3, 9) and print(sys.executable)'
    $candidates = @('py', 'python') + @(Get-ChildItem "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe" `
        -ErrorAction SilentlyContinue | ForEach-Object FullName)
    foreach ($candidate in $candidates) {
        if (-not (Get-Command $candidate -ErrorAction SilentlyContinue)) { continue }
        $exe = & $candidate -c $probe 2>$null
        if ($LASTEXITCODE -eq 0 -and $exe) { return "$exe".Trim() }
    }
    return $null
}

function Test-SshReady {
    $service = Get-Service sshd -ErrorAction SilentlyContinue
    if (-not $service -or $service.StartType -ne 'Automatic' -or $service.Status -ne 'Running') { return $false }
    if (-not (Get-ItemProperty HKLM:\SOFTWARE\OpenSSH -Name DefaultShell -ErrorAction SilentlyContinue)) { return $false }
    $rule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
    if (-not $rule -or "$($rule.Enabled)" -ne 'True' -or "$($rule.Profile)" -ne 'Any') { return $false }
    try { $config = Get-Content "$env:ProgramData\ssh\sshd_config" -ErrorAction Stop } catch { return $false }
    return -not ($config -match '^\s*Match\s+Group\s+administrators')
}

# --- OpenSSH server (elevated) ----------------------------------------------
# Password logins stay on and the firewall rule is not limited to Tailscale.
# The administrators block in sshd_config is commented out so an admin's own
# ~\.ssh\authorized_keys, which fleet writes, is the one sshd reads.
$Elevated = @'
$ErrorActionPreference = 'Stop'
foreach ($name in 'OpenSSH.Client', 'OpenSSH.Server') {
    $cap = Get-WindowsCapability -Online | Where-Object Name -like "$name~*" | Select-Object -First 1
    if ($cap -and $cap.State -ne 'Installed') { Add-WindowsCapability -Online -Name $cap.Name | Out-Null }
}
Set-Service sshd -StartupType Automatic
Start-Service sshd  # the first start writes host keys and sshd_config
$shell = "$env:ProgramFiles\PowerShell\7\pwsh.exe"
if (-not (Test-Path $shell)) { $shell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }
New-Item -Path HKLM:\SOFTWARE\OpenSSH -Force | Out-Null
New-ItemProperty -Path HKLM:\SOFTWARE\OpenSSH -Name DefaultShell -Value $shell -PropertyType String -Force | Out-Null
$config = "$env:ProgramData\ssh\sshd_config"
$original = Get-Content $config
$inBlock = $false
$edited = foreach ($line in $original) {
    if ($line -match '^\s*Match\s+Group\s+administrators\b') { $inBlock = $true; "#$line"; continue }
    if ($inBlock -and $line -match '^\s+\S') { "#$line"; continue }
    $inBlock = $false
    $line
}
if (($edited -join "`n") -ne ($original -join "`n")) {
    Copy-Item $config "$config.pre-fleet.bak" -Force
    [IO.File]::WriteAllText($config, ($edited -join "`n") + "`n", (New-Object Text.UTF8Encoding $false))
    & "$env:SystemRoot\System32\OpenSSH\sshd.exe" -t
    if ($LASTEXITCODE) { Copy-Item "$config.pre-fleet.bak" $config -Force; throw 'sshd_config failed its check; restored' }
}
Restart-Service sshd
$rule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
if (-not $rule) {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Direction Inbound `
        -Protocol TCP -LocalPort 22 -Action Allow -Profile Any | Out-Null
} else {
    Set-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -Enabled True -Profile Any
}
'@

if (Test-SshReady) {
    Step 'OpenSSH server already set up'
} else {
    Step 'setting up the OpenSSH server (asks for administrator approval)'
    $script = Join-Path $env:TEMP "fleet-sshd-$PID.ps1"
    Set-Content -Path $script -Value $Elevated -Encoding utf8
    try {
        $run = Start-Process powershell -Verb RunAs -Wait -PassThru -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$script`"")
        if ($run.ExitCode) { throw "OpenSSH setup failed (exit $($run.ExitCode))" }
    } finally {
        Remove-Item $script -ErrorAction SilentlyContinue
    }
}

# --- Python -----------------------------------------------------------------
$Python = Find-Python
if (-not $Python) {
    Step 'installing Python'
    winget install --id Python.Python.3.13 -e --scope user --silent --accept-package-agreements --accept-source-agreements
    $Python = Find-Python
    if (-not $Python) { throw 'Python 3.9 or newer not found after install; install it from python.org and run this again' }
}
Step "Python: $Python"

# --- auth and fleet ---------------------------------------------------------
New-Item -ItemType Directory -Force -Path $Bin, (Split-Path $Manifest) | Out-Null
foreach ($file in @(@('auth', (Join-Path $Bin 'auth')), @('fleet', (Join-Path $Bin 'fleet')),
                    @('fleet-manifest.json', $Manifest))) {
    $staged = "$($file[1]).download"
    Invoke-WebRequest -UseBasicParsing -Uri "$Source/files/$($file[0])" -OutFile $staged
    Move-Item -Force $staged $file[1]
}
foreach ($name in 'auth', 'fleet') {
    # cmd shims so both run from any shell; the Python path is baked in.
    Set-Content -Path (Join-Path $Bin "$name.cmd") -Encoding ascii -Value "@`"$Python`" -X utf8 `"%~dp0$name`" %*"
}
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (($userPath -split ';') -notcontains $Bin) {
    [Environment]::SetEnvironmentVariable('Path', (@($Bin) + ($userPath -split ';' | Where-Object { $_ })) -join ';', 'User')
}
if (($env:Path -split ';') -notcontains $Bin) { $env:Path = "$Bin;$env:Path" }
Step "auth and fleet installed in $Bin"

# --- sign in, sync, schedule ------------------------------------------------
& auth status *> $null
if ($LASTEXITCODE) {
    & auth login
    if ($LASTEXITCODE) { throw 'auth login failed' }
}
& fleet sync
$synced = $LASTEXITCODE
& fleet schedule enable
if ($LASTEXITCODE) { throw 'fleet schedule enable failed' }
# 1: a conflict, local copies backed up; 3: Auth gave no answer. The nightly pass retries.
if ($synced) { throw "fleet sync did not finish (exit $synced); run fleet sync again" }
Step 'done. Install harnesses with: fleet install claude codex'
}
