# Onboarding a fleet machine

Use this for a new macOS or Linux host. Keep the operator's existing connection
open until a second SSH login succeeds through the tailnet. Work in the local
`main` tmux session; use its existing SSH window when available. Passwords go
directly into that terminal, never into chat or command arguments.

## Configure passwordless sudo first

Configure passwordless sudo for the operator account on both macOS and Linux.
Create a per-user `NOPASSWD: ALL` rule in `/etc/sudoers.d/`, validate the candidate
with `visudo -cf`, install it root-owned with mode `0440`, validate the full
configuration with `visudo -c`, and verify `sudo -k; sudo -n true`. Confirm the
main sudoers configuration includes `/etc/sudoers.d/` before relying on it. Do
not replace the main sudoers file or grant this to every user.

Enter the current admin password directly in the terminal when prompted. After
confirming the include, run as the operator account:

```sh
onboarding_user=$(id -un)
onboarding_rule=$(mktemp)
printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$onboarding_user" > "$onboarding_rule"
sudo visudo -cf "$onboarding_rule" && \
    sudo mkdir -p /etc/sudoers.d && \
    sudo install -o root -g "$(id -gn root)" -m 0440 \
        "$onboarding_rule" "/etc/sudoers.d/$onboarding_user" && \
    sudo visudo -c
rm -f "$onboarding_rule"
sudo -k
sudo -n true
```

If validation fails, stop and correct or remove the new rule before continuing.

## Identify the machine and prepare tools

Record the login user, hostname, OS/version, CPU architecture, RAM, and intended
role. Confirm the chosen fleet name with the operator if it is unspecified.
Use `hostname`, `uname -m`, and either `sw_vers`/`sysctl` on macOS or
`/etc/os-release`/`lscpu`/`free -h` on Linux.

On Linux, also ask the operator whether the machine should run headless (no
desktop session). If yes, follow [Run headless](#run-headless-linux) once
Tailscale SSH access is verified. Check the current state with
`systemctl get-default`.

Set the machine's hostname to the fleet name. On macOS, set all three names;
an unset `HostName` makes macOS take one from the network (for example a
router's `Macmini.lan`), and that name is what `auth` reports to Common Auth:

```sh
sudo scutil --set ComputerName <fleet-name>
sudo scutil --set LocalHostName <fleet-name>
sudo scutil --set HostName <fleet-name>
```

On systemd Linux, use `sudo hostnamectl set-hostname <fleet-name>`. Verify
with `hostname` on either OS.

On macOS, install Homebrew if absent:

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

This may prompt for sudo, confirmation, and an Apple Command Line Tools download.
Wait for it to finish. Load `brew shellenv` using the installed path:
`/opt/homebrew/bin/brew` on Apple silicon, `/usr/local/bin/brew` on Intel.

On Linux, install `curl`, `git`, `zsh`, `python3`, and OpenSSH client/server with
the distribution's package manager. Enable the SSH server (`ssh` on Ubuntu,
`sshd` on Fedora). Retain the existing SSH/firewall settings unless the task
requires a change. Install `gh` following the
[official distro instructions](https://github.com/cli/cli/blob/trunk/docs/install_linux.md).
On Ubuntu with Ubuntu Pro ESM enabled (DGX OS ships it), ESM's older `gh`
outranks GitHub's repository. Pin `gh` to GitHub's origin, reinstall, and check
`apt-cache policy gh`:

```sh
printf 'Package: gh\nPin: origin cli.github.com\nPin-Priority: 600\n' |
    sudo tee /etc/apt/preferences.d/github-cli
```

If Docker is installed on Linux, add the operator account to the `docker`
group so containers run without sudo. Skip this on machines without Docker.
The new membership applies from the next login:

```sh
getent group docker && sudo usermod -aG docker "$(id -un)"
```

Verify from a fresh SSH login with `id -nG` and `docker ps`.

## Set the default login shell

Installing zsh does not change the account's login shell. Use the system zsh
(`/bin/zsh` on macOS; the package-provided path on Linux), confirm it is listed
in `/etc/shells`, then set it for the operator account:

```sh
onboarding_zsh=$(command -v zsh)
grep -Fx "$onboarding_zsh" /etc/shells
sudo chsh -s "$onboarding_zsh" "$(id -un)"
```

If it is not listed, resolve that before running `chsh`. Open a fresh SSH login
and verify the account's shell and command search path. A temporary `zsh`
subshell is not enough to verify the login default. Check the account record
with `dscl . -read "/Users/$(id -un)" UserShell` on macOS or
`getent passwd "$(id -un)"` on Linux.

## Configure Git identity

GitHub authentication does not configure commit authorship. Inspect
`git config --global user.name` and `git config --global user.email`. Preserve
an existing identity; if missing, confirm the intended name and email with the
operator before setting them:

```sh
git config --global user.name '<operator-approved name>'
git config --global user.email '<operator-approved email>'
```

The fleet has used both `LPFchan` / `me@lost.plus` and `yeowool` /
`hi@yeowool.ing`; do not choose an identity solely from the GitHub login. Check
`git var GIT_AUTHOR_IDENT` in the intended repository, since repository-specific
configuration can override the global values.

## Enroll in Tailscale

The fleet tailnet is `lost.plus`. Return the generated authorization URL to the
operator and wait for browser approval; do not reuse another machine's identity
or copy its Tailscale state.

For a persistent CLI-only macOS service:

```sh
brew install --formula tailscale
sudo "$(command -v brew)" services start tailscale
sudo tailscale up --hostname=<fleet-name>
```

Use the formula, not the GUI cask. Root's Homebrew service is a system
LaunchDaemon that starts at boot. Do not also install a second daemon using
`tailscaled install-system-daemon`. Verify the service with `sudo brew services
list` and inspect its LaunchDaemon. The CLI variant does not configure macOS
DNS automatically; only configure MagicDNS if required, preserving the previous
DNS settings. See [Tailscale's macOS CLI guide](https://github.com/tailscale/tailscale/wiki/Tailscaled-on-macOS).

For systemd Linux hosts:

```sh
curl -fsSL https://tailscale.com/install.sh | sh
sudo systemctl enable --now tailscaled
sudo tailscale up --hostname=<fleet-name>
systemctl is-enabled tailscaled
systemctl is-active tailscaled
```

Use the distro's service manager for non-systemd hosts. The installer supports
multiple distributions; check [Tailscale's installer](https://tailscale.com/install.sh)
for the target rather than assuming apt.

After approval, inspect `sudo tailscale status --json`: verify `BackendState`
is `Running`, `CurrentTailnet`, `Self.DNSName`, and `Self.TailscaleIPs`. Use the
reported DNS name in the fleet record; do not derive it from another machine.
Test a second OpenSSH connection through that address. Tailscale SSH is a
separate feature and is not necessary for ordinary fleet SSH.

## Create the machine's GitHub SSH identity

Inspect `~/.ssh` first; never overwrite an existing private key. For a fresh
machine needing unattended fleet operations:

```sh
mkdir -p ~/.ssh
chmod 700 ~/.ssh
ssh-keygen -t ed25519 -N '' -C '<user>@<fleet-name>' -f ~/.ssh/id_ed25519
cat ~/.ssh/id_ed25519.pub
```

Show only the public key to the operator. Wait for them to add it as an
authentication key at [GitHub SSH settings](https://github.com/settings/ssh/new).
Confirm its key type and base64 body appear in `https://github.com/LPFchan.keys`
before installing fleet modules: setup uses that list to decide whether the
machine belongs to the fleet. If publication lags, retry instead of bypassing
the audience check.

Verify `ssh -T git@github.com`; check GitHub's published host-key fingerprint
before accepting a new host key. Successful GitHub authentication exits with
status 1 and prints the account name because GitHub does not offer shell access.

## Log in to GitHub CLI

On macOS, `brew install gh`. Use the Linux package installed above on Linux.

```sh
gh auth login --hostname github.com --git-protocol ssh --web --skip-ssh-key
```

Pass the device code and browser URL to the operator and wait for authorization.
`--skip-ssh-key` avoids uploading another key after manual enrollment. Verify
`gh auth status` and `gh api user --jq .login` report `LPFchan`; do not print
tokens or copy a login from another machine.

## Install setup and the requested modules

Run as the normal user, not root. For a noninteractive bootstrap, passing `list`
avoids entering the module picker:

```sh
curl -fsSL https://setup.lost.plus/install.sh | zsh -s -- list
export PATH="$HOME/.local/bin:$PATH"
```

Install modules individually, checking each result. Every fleet machine gets
the default set; add `schedule` on Linux, where `setup schedule` and the
module timers render through it (macOS uses launchd instead):

```sh
fleet_modules=(zsh-basics zsh-omnibar zsh-syntax-highlighting starship tmux \
    ssh-aliases agents auth)
[[ $(uname) == Linux ]] && fleet_modules+=(schedule)
for module in $fleet_modules; do
    setup install "$module" || break
done
```

Then run `auth login` and pass its browser URL to the operator; wait for
approval and verify with `auth status`. This is the machine's Common Auth
identity: it is what later grants lost.plus MCPs and the passage vault.

Machines that run interactive AI workloads also get the AI group, only when
the operator asks for it:

```sh
for module in harnesses providers opencodex ai-menu resume; do
    setup install "$module" || break
done
```

Installing `harnesses` enables its daily refresh timer; verify the launchd job
on macOS or the systemd timer on Linux. `ai-menu` auto-launches its menu in new
shells. Other modules (`backup`, `system-updates`, `kernel-simmer`,
`gpu-fancontrol`, `monitoring`, `mac-boot`) are role-specific; install them only
when requested. Dependencies may pull in additional modules.

`ssh-aliases` installs inbound owner keys from GitHub and outbound fleet shortcuts
while preserving unmanaged entries. Test passwordless SSH to the new host from
an existing fleet machine after installation. Newly generated machine keys reach
other hosts when their `ssh-aliases` module next updates; do not force a fleet-wide
`setup update` to accelerate this without an instruction.

## Enable and verify automatic updates

```sh
setup schedule
setup schedule status
setup status
```

The update runs at 06:00 in the machine's local timezone; verify that timezone
matches the operator's intent. On macOS, this is a user LaunchAgent
(`com.lost.plus.setup-update`) in the `gui/<uid>` domain. SSH into a Mac with no
GUI login may create the plist without loading it; check status and resolve that
before claiming success. This differs from Tailscale's system LaunchDaemon.

On systemd Linux, verify `systemctl --user status setup-update.timer`. A headless
machine that must update while logged out needs user lingering; inspect
`loginctl show-user "$USER" -p Linger` and enable it with `sudo loginctl
enable-linger "$USER"` when that behavior is wanted.

Start a fresh interactive shell to check the prompt, syntax highlighting, and
tmux integration. Dismiss the AI menu with Esc if installed. Confirm both the
Tailscale daemon and setup scheduler's persisted configuration; do not reboot
an occupied machine solely to test onboarding.

## Run headless (Linux)

Only when the operator asked for it. Headless means the machine boots to a
text console with no desktop; SSH, Docker, and systemd services are
unaffected. Confirm a second SSH login over Tailscale works first.

Stopping the display manager ends any logged-in desktop session and its apps.
Check `loginctl list-sessions` for a seat session and see what runs inside it
(`loginctl session-status <id>`) before stopping it. No reboot is needed;
later boots come up headless too:

```sh
sudo systemctl set-default multi-user.target
sudo systemctl stop display-manager
systemctl get-default
systemctl is-active display-manager
```

Revert with `sudo systemctl set-default graphical.target` and
`sudo systemctl start display-manager`.

If the machine reaches the LAN over Wi-Fi, turn off Wi-Fi power saving so it
stays reachable while idle. Find the connection and interface with
`nmcli -t -f NAME,TYPE,DEVICE con show --active`, then:

```sh
sudo nmcli con modify <wifi-connection> 802-11-wireless.powersave 2
sudo iw dev <wifi-interface> set power_save off
iw dev <wifi-interface> get power_save
```

The `nmcli` setting persists from the next activation; `iw` applies it now.

On a DGX Spark, some units keep their fans off after booting with no monitor
attached ([NVIDIA forum](https://forums.developer.nvidia.com/t/dgx-spark-gb10-fans-do-not-spin-in-headless-boot-mode-temperature-rises-to-70-c/361960),
unresolved as of 2026-10). After the first headless boot, let it idle and
check `nvidia-smi --query-gpu=temperature.gpu,power.draw --format=csv`; report
to the operator if the idle GPU climbs toward 70 °C.

## Record the host

Update `setup/agents/skills/fleet/SKILL.md` with the verified hardware, user,
tailnet DNS name, and role. Keep its SSH shortcut in sync with
`setup/files/ssh-aliases.sh`. Use an isolated worktree for repository edits.
Do not edit the installed skill copy. Honor any requested preview gate before
committing docs, and let the fleet's scheduled updates distribute the change.
