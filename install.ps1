# Enroll a Windows machine in the fleet:
#   irm https://auth.lost.plus/fleet.ps1 | iex
# Installs Python if needed and turns on the OpenSSH server (one UAC prompt),
# then fetches fleet and runs `fleet self-install`: auth and fleet in
# ~\.local\bin, sign-in, sync and the nightly pass.
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

# --- OpenSSH server (elevated) ----------------------------------------------
# Password logins stay on and the firewall rule is not limited to Tailscale.
# The administrators block in sshd_config is commented out so an admin's own
# ~\.ssh\authorized_keys, which fleet writes, is the one sshd reads; the keys
# administrators_authorized_keys let in are copied there first.
$Elevated = @'
param($UserKeys, $Stamp)
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
$adminKeys = "$env:ProgramData\ssh\administrators_authorized_keys"
if (Test-Path $adminKeys) {
    $have = if (Test-Path $UserKeys) { [IO.File]::ReadAllText($UserKeys) } else { '' }
    $missing = @(Get-Content $adminKeys | Where-Object { $_ -match '^\s*[^#\s]' -and ($have -split "`r?`n") -notcontains $_ })
    if ($missing) {
        New-Item -ItemType Directory -Force -Path (Split-Path $UserKeys) | Out-Null
        $lead = if ($have -and -not $have.EndsWith("`n")) { "`n" } else { '' }
        [IO.File]::AppendAllText($UserKeys, $lead + ($missing -join "`n") + "`n")
    }
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
New-ItemProperty -Path HKLM:\SOFTWARE\OpenSSH -Name FleetSetup -Value $Stamp -PropertyType String -Force | Out-Null
'@

# A standard user cannot read the firewall rules or sshd_config, so the check
# trusts the stamp the elevated pass leaves: its own hash, so a changed $Elevated
# runs once more.
$Stamp = (Get-FileHash -Algorithm SHA256 -InputStream (
    New-Object IO.MemoryStream (, [Text.Encoding]::UTF8.GetBytes($Elevated)))).Hash
function Test-SshReady {
    $service = Get-Service sshd -ErrorAction SilentlyContinue
    if (-not $service -or $service.StartType -ne 'Automatic' -or $service.Status -ne 'Running') { return $false }
    $key = Get-ItemProperty HKLM:\SOFTWARE\OpenSSH -ErrorAction SilentlyContinue
    return [bool]($key -and $key.FleetSetup -eq $Stamp -and $key.DefaultShell -and (Test-Path $key.DefaultShell))
}

if (Test-SshReady) {
    Step 'OpenSSH server already set up'
} else {
    Step 'setting up the OpenSSH server (asks for administrator approval)'
    $script = Join-Path $env:TEMP "fleet-sshd-$PID.ps1"
    Set-Content -Path $script -Value $Elevated -Encoding utf8
    try {
        $run = Start-Process powershell -Verb RunAs -Wait -PassThru -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$script`"",
            "`"$(Join-Path $HOME '.ssh\authorized_keys')`"", $Stamp)
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
    # The OS's architecture, not this PowerShell's: 32-bit PowerShell on 64-bit
    # Windows reports x86 and keeps the real one in PROCESSOR_ARCHITEW6432.
    $os = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    $file = switch ($os) { 'ARM64' { 'python-3.14.8-arm64.exe' } 'x86' { 'python-3.14.8.exe' } default { 'python-3.14.8-amd64.exe' } }
    $installer = Join-Path $env:TEMP $file
    Invoke-WebRequest -UseBasicParsing -Uri "https://www.python.org/ftp/python/3.14.8/$file" -OutFile $installer
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

# --- fleet ------------------------------------------------------------------
# Windows fetches some root certificates only when its own TLS stack meets
# them; Python reads the store as it is. One request here brings Auth's root in.
$origin = if ($env:LOST_AUTH_ORIGIN) { $env:LOST_AUTH_ORIGIN } else { 'https://auth.lost.plus' }
try { Invoke-WebRequest -UseBasicParsing -Uri $origin | Out-Null } catch {}
# fleet installs itself from the same commit: auth, its cmd shims, PATH, sign-in,
# sync and the nightly task. A directory of its own, since Python imports from it.
$temp = Join-Path $env:TEMP "fleet-$PID"
New-Item -ItemType Directory -Force -Path $temp | Out-Null
$previous = $env:SOURCE_URL
try {
    Invoke-WebRequest -UseBasicParsing -Uri "$Source/files/fleet" -OutFile (Join-Path $temp 'fleet')
    $env:SOURCE_URL = $Source
    & $Python -X utf8 (Join-Path $temp 'fleet') self-install
    if ($LASTEXITCODE) { throw "fleet self-install failed (exit $LASTEXITCODE)" }
} finally {
    $env:SOURCE_URL = $previous
    Remove-Item -Recurse -Force $temp -ErrorAction SilentlyContinue
}
# This shell, too, not only the next one.
$Bin = Join-Path $HOME '.local\bin'
if (($env:Path -split ';') -notcontains $Bin) { $env:Path = "$Bin;$env:Path" }
}
