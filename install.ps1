# Enroll a Windows machine in the fleet:
#   irm https://raw.githubusercontent.com/LPFchan/setup/main/install.ps1 | iex
# Installs Python if needed, auth and fleet into ~\.local\bin, turns on the
# OpenSSH server (one UAC prompt), signs in, syncs and schedules the nightly pass.
# Run it again to repair or update; every step checks before it changes anything.

& {
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# Resolve main once, as bin/setup does, so every file comes from one commit.
$Source = $env:SOURCE_URL
if (-not $Source) {
    $Source = 'https://raw.githubusercontent.com/LPFchan/setup/main'
    try {
        $sha = (Invoke-RestMethod -UseBasicParsing 'https://api.github.com/repos/LPFchan/setup/git/ref/heads/main').object.sha
        if ($sha -match '^[0-9a-f]{40}$') { $Source = "https://raw.githubusercontent.com/LPFchan/setup/$sha" }
    } catch {}
}
$Bin = Join-Path $HOME '.local\bin'
$Manifest = Join-Path $HOME '.config\fleet\manifest.json'

function Step($text) { Write-Host "setup: $text" }

function Find-Python {
    # Each candidate is asked for its own path; python.exe on PATH may be the
    # Store's stub, which only opens the Store. No double quotes in the -c code:
    # Windows PowerShell drops them on the way to a native program.
    # Windows PowerShell turns a native program's redirected stderr into an
    # error, which 'Stop' makes fatal; the stub writes to stderr.
    $ErrorActionPreference = 'Continue'
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
    $shell = (Get-ItemProperty HKLM:\SOFTWARE\OpenSSH -Name DefaultShell -ErrorAction SilentlyContinue).DefaultShell
    if (-not $shell -or -not (Test-Path $shell)) { return $false }
    $rule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
    if (-not $rule -or "$($rule.Enabled)" -ne 'True' -or "$($rule.Profile)" -ne 'Any' -or
        "$($rule.Direction)" -ne 'Inbound' -or "$($rule.Action)" -ne 'Allow') { return $false }
    $port = $rule | Get-NetFirewallPortFilter
    if ("$($port.Protocol)" -ne 'TCP' -or "$($port.LocalPort)" -ne '22') { return $false }
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
# A Match block runs to the next Match or the end of the file, indented or not.
$edited = foreach ($line in $original) {
    if ($line -match '^\s*Match\s') { $inBlock = $line -match '^\s*Match\s+Group\s+administrators\b' }
    if ($inBlock -and $line -match '^\s*[^#\s]') { "#$line"; continue }
    $line
}
if (($edited -join "`n") -ne ($original -join "`n")) {
    Copy-Item $config "$config.pre-fleet.bak" -Force
    [IO.File]::WriteAllText($config, ($edited -join "`n") + "`n", (New-Object Text.UTF8Encoding $false))
    & "$env:SystemRoot\System32\OpenSSH\sshd.exe" -t
    if ($LASTEXITCODE) { Copy-Item "$config.pre-fleet.bak" $config -Force; throw 'sshd_config failed its check; restored' }
}
Restart-Service sshd
# Recreated every time, so an edited rule (blocked, another port) cannot linger.
Remove-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Direction Inbound `
    -Protocol TCP -LocalPort 22 -Action Allow -Profile Any | Out-Null
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
    # python.org's own installer, per user: winget is missing on a fresh Windows 10.
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
    $installer = Join-Path $env:TEMP "python-3.14.8-$arch.exe"
    Invoke-WebRequest -UseBasicParsing -Uri "https://www.python.org/ftp/python/3.14.8/python-3.14.8-$arch.exe" -OutFile $installer
    try {
        $run = Start-Process $installer -Wait -PassThru -ArgumentList @(
            '/quiet', 'InstallAllUsers=0', 'PrependPath=0', 'Include_launcher=0', 'Include_test=0')
        if ($run.ExitCode) { throw "Python installer failed (exit $($run.ExitCode))" }
    } finally {
        Remove-Item $installer -ErrorAction SilentlyContinue
    }
    $Python = Find-Python
    if (-not $Python) { throw 'Python 3.9 or newer not found after install; install it from python.org and run this again' }
}
Step "Python: $Python"

# --- auth and fleet ---------------------------------------------------------
New-Item -ItemType Directory -Force -Path $Bin, (Split-Path $Manifest) | Out-Null
# All three download first; only then does any of them replace the installed copy.
$files = @(@('auth', (Join-Path $Bin 'auth')), @('fleet', (Join-Path $Bin 'fleet')),
           @('fleet-manifest.json', $Manifest))
foreach ($file in $files) {
    Invoke-WebRequest -UseBasicParsing -Uri "$Source/files/$($file[0])" -OutFile "$($file[1]).download"
}
foreach ($file in $files) { Move-Item -Force "$($file[1]).download" $file[1] }
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
# Windows fetches some root certificates only when its own TLS stack meets
# them; Python reads the store as it is. One request here brings Auth's root in.
$origin = if ($env:LOST_AUTH_ORIGIN) { $env:LOST_AUTH_ORIGIN } else { 'https://auth.lost.plus' }
try { Invoke-WebRequest -UseBasicParsing -Uri $origin | Out-Null } catch {}
& { $ErrorActionPreference = 'Continue'; & auth status *> $null }
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
