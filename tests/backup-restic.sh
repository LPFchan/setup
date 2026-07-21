#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

export BACKUP_SOURCE_ONLY=1
export BACKUP_TEST_MODE=1
export BACKUP_CONF_DIR="$TEST_TMP/etc/backup"
export BACKUP_STATE_DIR="$TEST_TMP/var/lib/backup"
export BACKUP_CACHE_DIR="$TEST_TMP/var/cache/backup"
export BACKUP_SYSTEMD_DIR="$TEST_TMP/systemd"
export BACKUP_LOCK_FILE="$TEST_TMP/backup.lock"
export BACKUP_RECOVERY_DIR="$TEST_TMP/recovery"

# shellcheck disable=SC1091
source "$ROOT/bin/backup"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

mkdir -p "$TEST_TMP/home/.ssh" "$TEST_TMP/data" "$TEST_TMP/bin"
: > "$TEST_TMP/home/.ssh/id_ed25519"
: > "$TEST_TMP/home/.ssh/known_hosts"

write_default_policy grimoire yeowool "$TEST_TMP/home"
grep -qx 'RESTIC_REPOSITORY=sftp:yeowool@bingus.lost.plus:/bak/grimoire-restic' \
    "$BACKUP_CONF_DIR/config" || fail "default repository does not use DSM's SFTP share path"
grep -qx 'MAX_FILE_SIZE=20M' "$BACKUP_CONF_DIR/config" || fail "default threshold is not 20M"
grep -qx 'BACKUP_USER=yeowool' "$BACKUP_CONF_DIR/config" || fail "backup operator is not configured"
grep -Fqx '**/node_modules/**' "$BACKUP_CONF_DIR/excludes" || fail "node_modules is not excluded"
grep -q 'override both' "$BACKUP_CONF_DIR/large-whitelist" || fail "whitelist semantics are unclear"
grep -Fqx "$TEST_TMP/home/Eastself" "$BACKUP_CONF_DIR/large-whitelist" \
    || fail "Eastself is not whitelisted"

sed -i 's|:/bak/grimoire-restic$|:/volume1/bak/grimoire-restic|' "$BACKUP_CONF_DIR/config"
write_default_policy grimoire yeowool "$TEST_TMP/home"
grep -qx 'RESTIC_REPOSITORY=sftp:yeowool@bingus.lost.plus:/bak/grimoire-restic' \
    "$BACKUP_CONF_DIR/config" || fail "legacy repository path was not migrated"

cat > "$BACKUP_CONF_DIR/config" <<EOF
RESTIC_REPOSITORY=sftp:yeowool@bingus.lost.plus:/bak/grimoire-restic
BACKUP_USER=$(id -un)
SFTP_IDENTITY=$TEST_TMP/home/.ssh/id_ed25519
SFTP_KNOWN_HOSTS=$TEST_TMP/home/.ssh/known_hosts
MAX_FILE_SIZE=20M
UPLOAD_LIMIT_KIB=30720
KEEP_DAILY=7
KEEP_WEEKLY=5
KEEP_MONTHLY=12
KEEP_YEARLY=3
EOF
load_config
if (verify_bingus_host_key) >/dev/null 2>&1; then
    fail "unconfirmed Bingus host key was accepted"
fi
ssh-keygen -q -t ed25519 -N '' -f "$TEST_TMP/host-key"
awk '{print "bingus.lost.plus " $1 " " $2}' "$TEST_TMP/host-key.pub" \
    > "$TEST_TMP/home/.ssh/known_hosts"
verify_bingus_host_key

# Ubuntu's Restic package omits self-update and predates empty-password mode.
# Enabling must replace it with a checksum-verified official binary.
(
    export TEST_TMP
    mkdir -p "$TEST_TMP/restic-install" "$TEST_TMP/restic-old-bin"
    cat > "$TEST_TMP/restic-old-bin/restic" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --help ]]; then
    echo 'old restic help'
elif [[ "${1:-}" == self-update ]]; then
    touch "$TEST_TMP/self-update-called"
    exit 1
fi
EOF
    cat > "$TEST_TMP/restic-old-bin/curl" <<'EOF'
#!/usr/bin/env bash
while (($#)); do
    case "$1" in
        --output) output="$2"; shift 2 ;;
        http*) printf '%s\n' "$1" > "$TEST_TMP/restic-download-url"; shift ;;
        *) shift ;;
    esac
done
cat > "$output" <<'BINARY'
#!/usr/bin/env bash
[[ "${1:-}" == --help ]] && echo --insecure-no-password
BINARY
EOF
    cat > "$TEST_TMP/restic-old-bin/bzip2" <<'EOF'
#!/usr/bin/env bash
cat "${@: -1}"
EOF
    cat > "$TEST_TMP/restic-old-bin/sha256sum" <<'EOF'
#!/usr/bin/env bash
cat > "$TEST_TMP/restic-checksum-input"
EOF
    chmod +x "$TEST_TMP/restic-old-bin/"*
    export RESTIC_INSTALL_PATH="$TEST_TMP/restic-install/restic"
    PATH="$TEST_TMP/restic-install:$TEST_TMP/restic-old-bin:/usr/bin:/bin"
    export PATH
    install_restic
    [[ -x "$RESTIC_INSTALL_PATH" ]] || fail "official Restic binary was not installed"
    "$RESTIC_INSTALL_PATH" --help | grep -q -- '--insecure-no-password' \
        || fail "installed Restic lacks empty-password support"
    grep -Eq '/v0\.19\.1/restic_0\.19\.1_linux_(amd64|arm64)\.bz2$' \
        "$TEST_TMP/restic-download-url" || fail "unexpected Restic release asset"
    grep -Eq '^[0-9a-f]{64}  ' "$TEST_TMP/restic-checksum-input" \
        || fail "Restic release checksum was not verified"
    [[ ! -e "$TEST_TMP/self-update-called" ]] \
        || fail "unsupported distro self-update path was used"
)

printf '%s\n' "$TEST_TMP/data" > "$BACKUP_CONF_DIR/sources"
printf '%s\n' '**/node_modules/**' > "$BACKUP_CONF_DIR/excludes"
truncate -s 21M "$TEST_TMP/data/large-model.bin"
printf '%s\n' "$TEST_TMP/data/large-model.bin" > "$BACKUP_CONF_DIR/large-whitelist"

mkdir -p "$TEST_TMP/data/python-app/.venv/bin"
cat > "$TEST_TMP/data/python-app/.venv/bin/python" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then
    echo "Python 3.12.1"
else
    echo "example-python-package==1.2.3"
fi
EOF
chmod +x "$TEST_TMP/data/python-app/.venv/bin/python"

mkdir -p "$TEST_TMP/data/node-app/node_modules"
printf '{}\n' > "$TEST_TMP/data/node-app/package.json"
printf '{"lockfileVersion":3}\n' > "$TEST_TMP/data/node-app/package-lock.json"

mkdir -p "$TEST_TMP/data/rust-app"
printf '[package]\nname="example"\nversion="0.1.0"\n' > "$TEST_TMP/data/rust-app/Cargo.toml"
printf 'version = 4\n' > "$TEST_TMP/data/rust-app/Cargo.lock"

mkdir -p "$TEST_TMP/data/.cache/huggingface/hub/models--example--model/refs"
printf '0123456789abcdef\n' \
    > "$TEST_TMP/data/.cache/huggingface/hub/models--example--model/refs/main"

cat > "$TEST_TMP/bin/restic" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_LOG"
if [[ "${RESTIC_BLOCK_AUTOMATIC:-0}" == 1 && "$*" == *"--tag automatic"* ]]; then
    touch "$RESTIC_AUTOMATIC_STARTED"
    trap 'exit 130' INT
    trap 'exit 143' TERM
    while :; do sleep 1; done
fi
if [[ "${RESTIC_AUTOMATIC_RC:-0}" != 0 && "$*" == *"--tag automatic"* ]]; then
    exit "$RESTIC_AUTOMATIC_RC"
fi
EOF
chmod +x "$TEST_TMP/bin/restic"
export TEST_LOG="$TEST_TMP/restic.log"
PATH="$TEST_TMP/bin:$PATH"

run_backup

[[ $(wc -l < "$TEST_LOG") -eq 4 ]] \
    || fail "expected snapshots followed by retention and integrity maintenance"
[[ $(sed -n '1s/.* \(backup\) .*/\1/p' "$TEST_LOG") == backup ]] \
    || fail "automatic snapshot did not run first"
[[ $(sed -n '2s/.* \(backup\) .*/\1/p' "$TEST_LOG") == backup ]] \
    || fail "whitelist snapshot did not run second"
[[ $(sed -n '3s/.* \(forget\) .*/\1/p' "$TEST_LOG") == forget ]] \
    || fail "retention did not follow snapshots"
[[ $(sed -n '4s/.* \(check\)$/\1/p' "$TEST_LOG") == check ]] \
    || fail "integrity check did not run last"
grep -q -- '--exclude-larger-than 20M' "$TEST_LOG" || fail "automatic backup lacks size threshold"
grep -q -- '--insecure-no-password' "$TEST_LOG" || fail "empty-password mode is not enabled"
[[ $(grep -Fc -- "--cache-dir $BACKUP_CACHE_DIR" "$TEST_LOG") -eq 4 ]] \
    || fail "not every Restic operation uses the explicit cache directory"
[[ -d "$BACKUP_CACHE_DIR" && $(stat -c %a "$BACKUP_CACHE_DIR") == 700 ]] \
    || fail "dedicated Restic cache directory was not created securely"
grep -q -- 'sftp.args=-i .*IdentitiesOnly=yes' "$TEST_LOG" \
    || fail "SFTP SSH options do not preserve Restic's default SSH command"
if grep -q -- 'sftp.command=' "$TEST_LOG"; then
    fail "SFTP options replace Restic's default SSH command"
fi
grep -q -- '--exclude-file' "$TEST_LOG" || fail "automatic backup lacks blacklist"
grep -q -- '--one-file-system' "$TEST_LOG" || fail "backup can cross source filesystems"
grep -q -- '--tag large-whitelist' "$TEST_LOG" || fail "large whitelist was not backed up"
grep -q "$TEST_TMP/data/large-model.bin" "$BACKUP_STATE_DIR/provenance/large-files.tsv" \
    || fail "large-file provenance was not recorded"
grep -q 'example-python-package==1.2.3' \
    "$BACKUP_STATE_DIR/provenance/environments/python/"*-pip-freeze.txt \
    || fail "Python package inventory was not recorded"
grep -Fq "$TEST_TMP/data/node-app" "$BACKUP_STATE_DIR/provenance/node-environments.tsv" \
    || fail "Node environment was not recorded"
grep -Fq "$TEST_TMP/data/rust-app" "$BACKUP_STATE_DIR/provenance/rust-projects.tsv" \
    || fail "Rust project was not recorded"
grep -q $'models\texample/model\tmain\t0123456789abcdef' \
    "$BACKUP_STATE_DIR/provenance/huggingface-cache.tsv" \
    || fail "Hugging Face revision was not recorded"
[[ $(grep -c $'\texact\t' "$BACKUP_STATE_DIR/provenance/reconstruction-health.tsv") -ge 4 ]] \
    || fail "reconstruction health does not grade exact environments"
grep -q $'python\texact\t1' "$BACKUP_STATE_DIR/provenance/reconstruction-summary.tsv" \
    || fail "reconstruction summary does not count Python environments"

: > "$TEST_LOG"
export RESTIC_AUTOMATIC_RC=3
run_backup 2> "$TEST_TMP/exit-three.stderr"
unset RESTIC_AUTOMATIC_RC
[[ $(wc -l < "$TEST_LOG") -eq 4 ]] || fail "exit 3 prevented backup maintenance"
grep -q -- '--tag large-whitelist' "$TEST_LOG" || fail "whitelist did not run after exit 3"
grep -q 'completed with unreadable source files' "$TEST_TMP/exit-three.stderr" \
    || fail "exit 3 did not produce a warning"

grep -q -- 'forget.*--keep-daily 7.*--keep-weekly 5.*--keep-monthly 12.*--keep-yearly 3.*--prune' \
    "$TEST_LOG" || fail "retention arguments are incomplete"
grep -q -- 'check$' "$TEST_LOG" || fail "integrity check did not run"

: > "$TEST_LOG"
export RESTIC_BLOCK_AUTOMATIC=1
export RESTIC_AUTOMATIC_STARTED="$TEST_TMP/restic-automatic-started"
rm -f "$RESTIC_AUTOMATIC_STARTED"
setsid env -u BACKUP_SOURCE_ONLY "$ROOT/bin/backup" run \
    > "$TEST_TMP/interrupted.stdout" 2> "$TEST_TMP/interrupted.stderr" &
signal_pid=$!
for _ in {1..100}; do
    [[ -e "$RESTIC_AUTOMATIC_STARTED" ]] && break
    sleep 0.05
done
if [[ ! -e "$RESTIC_AUTOMATIC_STARTED" ]]; then
    kill -TERM -- "-$signal_pid" 2>/dev/null || true
    wait "$signal_pid" 2>/dev/null || true
    fail "automatic snapshot did not start for signal test"
fi
kill -TERM -- "-$signal_pid"
signal_rc=0
wait "$signal_pid" || signal_rc=$?
unset RESTIC_BLOCK_AUTOMATIC RESTIC_AUTOMATIC_STARTED
[[ $signal_rc -eq 143 ]] || fail "signal cancellation returned $signal_rc instead of 143"
[[ $(wc -l < "$TEST_LOG") -eq 1 ]] \
    || fail "signal cancellation advanced past the in-flight Restic command"
grep -q -- '--tag automatic' "$TEST_LOG" \
    || fail "signal test did not run the automatic snapshot"
if grep -Eq -- '--tag large-whitelist| forget | check$' "$TEST_LOG"; then
    fail "signal cancellation launched a later Restic phase"
fi

: > "$TEST_LOG"
cmd_restore latest
grep -Fq "restore latest --target $BACKUP_RECOVERY_DIR/" "$TEST_LOG" \
    || fail "restore does not use the disk-backed recovery directory"
grep -Fq -- "--cache-dir $BACKUP_CACHE_DIR" "$TEST_LOG" \
    || fail "restore does not use the explicit cache directory"

: > "$TEST_LOG"
cmd_snapshots
grep -Fq -- "--cache-dir $BACKUP_CACHE_DIR" "$TEST_LOG" \
    || fail "snapshot listing does not use the explicit cache directory"
grep -q -- 'snapshots$' "$TEST_LOG" || fail "snapshot listing did not run"

: > "$TEST_LOG"
cmd_trigger check
grep -Fq -- "--cache-dir $BACKUP_CACHE_DIR" "$TEST_LOG" \
    || fail "standalone integrity check does not use the explicit cache directory"
grep -q -- 'check$' "$TEST_LOG" || fail "standalone integrity check did not run"

mkdir -p "$BACKUP_SYSTEMD_DIR"
touch "$BACKUP_SYSTEMD_DIR/backup-daily.service" "$BACKUP_SYSTEMD_DIR/backup-daily.timer" \
    "$BACKUP_SYSTEMD_DIR/backup-weekly.service" "$BACKUP_SYSTEMD_DIR/backup-weekly.timer"
write_systemd_units /home/yeowool/.local/bin/backup grimoire
[[ $(find "$BACKUP_SYSTEMD_DIR" -maxdepth 1 -type f -printf '%f\n' | sort) == $'backup.service\nbackup.timer' ]] \
    || fail "systemd generation did not leave exactly backup.service and backup.timer"
grep -q '^ExecStart=/home/yeowool/.local/bin/backup run$' "$BACKUP_SYSTEMD_DIR/backup.service" \
    || fail "single service does not invoke the combined backup job"
grep -q '^IOSchedulingClass=idle$' "$BACKUP_SYSTEMD_DIR/backup.service" \
    || fail "backup is not I/O deprioritized"
grep -q '^CPUWeight=10$' "$BACKUP_SYSTEMD_DIR/backup.service" \
    || fail "backup CPU weight is not constrained"
grep -q '^MemoryMax=8G$' "$BACKUP_SYSTEMD_DIR/backup.service" \
    || fail "backup memory is not bounded"
grep -q '^OnCalendar=\*-\*-\* 09:00:00$' "$BACKUP_SYSTEMD_DIR/backup.timer" \
    || fail "daily schedule is not 09:00"
grep -q '^Persistent=false$' "$BACKUP_SYSTEMD_DIR/backup.timer" \
    || fail "daily timer unexpectedly catches up missed runs"

SYSTEMCTL_LOG="$TEST_TMP/systemctl.log"
mkdir -p "$BACKUP_SYSTEMD_DIR/timers.target.wants"
ln -s ../backup-daily.timer "$BACKUP_SYSTEMD_DIR/timers.target.wants/backup-daily.timer"
ln -s ../backup-weekly.timer "$BACKUP_SYSTEMD_DIR/timers.target.wants/backup-weekly.timer"
systemctl() {
    printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
    [[ "$*" != 'disable backup-daily.timer' ]]
}
prepare_backup_units
for timer in backup.timer backup-daily.timer backup-weekly.timer; do
    grep -qx "disable $timer" "$SYSTEMCTL_LOG" \
        || fail "enable preparation did not independently disable $timer"
done
for unit in backup.timer backup-daily.timer backup-daily.service \
    backup-weekly.timer backup-weekly.service; do
    grep -qx "stop --no-block $unit" "$SYSTEMCTL_LOG" \
        || fail "enable preparation did not independently stop $unit"
done
[[ ! -e "$BACKUP_SYSTEMD_DIR/timers.target.wants/backup-daily.timer" \
    && ! -L "$BACKUP_SYSTEMD_DIR/timers.target.wants/backup-daily.timer" ]] \
    || fail "dangling daily timer enablement link survived preparation"
[[ ! -e "$BACKUP_SYSTEMD_DIR/timers.target.wants/backup-weekly.timer" \
    && ! -L "$BACKUP_SYSTEMD_DIR/timers.target.wants/backup-weekly.timer" ]] \
    || fail "dangling weekly timer enablement link survived preparation"
if grep -qE '(^| )backup\.service($| )' "$SYSTEMCTL_LOG"; then
    fail "enable preparation stops the active backup service"
fi
: > "$SYSTEMCTL_LOG"
stop_backup_units
for timer in backup.timer backup-daily.timer backup-weekly.timer; do
    grep -qx "disable $timer" "$SYSTEMCTL_LOG" \
        || fail "full disable did not independently disable $timer"
done
grep -q '^stop --no-block backup.service$' "$SYSTEMCTL_LOG" \
    || fail "full disable does not stop the active backup service"

: > "$SYSTEMCTL_LOG"
reload_and_reset_legacy_units
[[ $(sed -n '1p' "$SYSTEMCTL_LOG") == daemon-reload ]] \
    || fail "legacy failed state was reset before daemon-reload"
[[ $(grep -c '^reset-failed ' "$SYSTEMCTL_LOG") -eq 4 ]] \
    || fail "legacy failed-state cleanup did not target exactly four units"
for unit in backup-daily.service backup-daily.timer backup-weekly.service backup-weekly.timer; do
    grep -qx "reset-failed $unit" "$SYSTEMCTL_LOG" \
        || fail "legacy failed-state cleanup omitted $unit"
done
if grep -qx 'reset-failed' "$SYSTEMCTL_LOG" \
    || grep -qE '^reset-failed (backup\.service|[^ ]*unrelated[^ ]*)$' "$SYSTEMCTL_LOG"; then
    fail "legacy failed-state cleanup resets non-legacy failures"
fi
unset -f systemctl
enable_body=$(sed -n '/^cmd_enable()/,/^}/p' "$ROOT/bin/backup")
grep -q 'prepare_backup_units' <<< "$enable_body" \
    || fail "enable path does not use non-interrupting unit preparation"
if grep -q 'stop_backup_units' <<< "$enable_body"; then
    fail "enable path uses the full service stop"
fi
disable_body=$(sed -n '/^cmd_disable()/,/^}/p' "$ROOT/bin/backup")
grep -q 'remove_legacy_systemd_artifacts' <<< "$disable_body" \
    || fail "disable path does not remove legacy unit files and links"
grep -q 'reload_and_reset_legacy_units' <<< "$enable_body" \
    || fail "enable path does not clear stale legacy failures after reload"
grep -q 'reload_and_reset_legacy_units' <<< "$disable_body" \
    || fail "disable path does not clear stale legacy failures after reload"

if rg -qi 'btrfs|nfs' "$BACKUP_SYSTEMD_DIR" "$TEST_LOG"; then
    fail "generated backup path still references Btrfs or NFS"
fi

echo "ok"
