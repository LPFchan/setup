#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

export HOME="$TEST_TMP/home"
export XDG_STATE_HOME="$TEST_TMP/state"
export LINUX_SETUP_SOURCE_URL="file://$ROOT"
export SETUP_SOURCE_ONLY=1
mkdir -p "$HOME" "$XDG_STATE_HOME"

# shellcheck disable=SC1091
source "$ROOT/bin/setup"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_eq() {
    local expected="$1" actual="$2" message="$3"
    [[ "$actual" == "$expected" ]] || fail "$message (expected '$expected', got '$actual')"
}

fixtures="$TEST_TMP/fixtures"
mkdir -p "$fixtures"

cat > "$fixtures/live-outdated.sh" <<'EOF'
# setup-module: live-block
status() {
    local count_file="$TEST_TMP/probe-count"
    printf '%s\n' "$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))" > "$count_file"
    printf '%-25s %-12s local=%s remote=%s target=%s\n' \
        "live-block" "outdated" "aaaaaaa" "bbbbbbb" "$HOME/.zshrc"
    return 1
}
EOF

cat > "$fixtures/uninstalled.sh" <<'EOF'
# setup-module: absent
status() {
    printf '%-25s %-12s\n' "absent" "uninstalled"
    return 2
}
update() {
    touch "$TEST_TMP/uninstalled-update-invoked"
}
EOF

cat > "$fixtures/current-update.sh" <<'EOF'
# setup-module: current-update
status() {
    printf '%-25s %-12s local=%s remote=%s target=%s\n' \
        "current-update" "current" "same" "same" "$HOME/.local/current-update"
    return 0
}
update() {
    touch "$TEST_TMP/current-update-invoked"
}
EOF

cat > "$fixtures/outdated-update.sh" <<'EOF'
# setup-module: outdated-update
status() {
    printf '%-25s %-12s local=%s remote=%s target=%s\n' \
        "outdated-update" "outdated" "old" "new" "$HOME/.local/outdated-update"
    return 1
}
update() {
    touch "$TEST_TMP/outdated-update-invoked"
}
EOF

cat > "$fixtures/probe-error.sh" <<'EOF'
# setup-module: probe-error
status() {
    echo "probe-error failed"
    return 3
}
update() {
    touch "$TEST_TMP/probe-error-update-invoked"
}
EOF

fetch_payload() {
    cp "$fixtures/$1" "$2"
}

export TEST_TMP
record_script_state live-block hash aaaaaaa aaaaaaa

fields=$(script_status_fields live-block '~/.zshrc' live-outdated.sh)
IFS=$'\t' read -r target state display local_ref remote_ref installed extra <<< "$fields"
assert_eq outdated "$state" "live probe must override equal cached refs"
assert_eq "update available" "$display" "interactive normalization must show live outdated state"
assert_eq aaaaaaa "$local_ref" "local ref normalization"
assert_eq bbbbbbb "$remote_ref" "remote ref normalization"
assert_eq 1 "$installed" "outdated live module is installed"
assert_eq 1 "$(cat "$TEST_TMP/probe-count")" "one adapter evaluation must invoke status once"

cat > "$TEST_TMP/manifest.tsv" <<'EOF'
# module	target	mode	source
live-block	~/.zshrc	script	live-outdated.sh
monitoring	~/.local/bin/monitoring	0755	files/monitoring
EOF
fetch_manifest() {
    cp "$TEST_TMP/manifest.tsv" "$MANIFEST_FILE"
}
fetch_checksums() { :; }
fzf() {
    cat > "$TEST_TMP/interactive-rows"
    return 1
}
cmd_reconfigure
interactive_row=$(awk '$1 == "live-block" { print; exit }' "$TEST_TMP/interactive-rows")
[[ "$interactive_row" == *"aaaaaaa"* && "$interactive_row" == *"bbbbbbb"* \
   && "$interactive_row" == *"installed"* && "$interactive_row" == *"update available"* ]] \
    || fail "interactive row did not use the normalized live result: $interactive_row"
assert_eq 2 "$(cat "$TEST_TMP/probe-count")" "one interactive row evaluation must invoke status once"

cli=$(status_one live-block '~/.zshrc' script live-outdated.sh)
[[ "$cli" == *"outdated"* && "$cli" == *"local=aaaaaaa remote=bbbbbbb"* ]] \
    || fail "CLI normalization must reflect the same live result: $cli"
assert_eq 3 "$(cat "$TEST_TMP/probe-count")" "one CLI row evaluation must invoke status once"

cat > "$TEST_TMP/manifest.tsv" <<'EOF'
# module	target	mode	source
current-update	~/.local/current-update	script	current-update.sh
outdated-update	~/.local/outdated-update	script	outdated-update.sh
absent	~/.local/absent	script	uninstalled.sh
probe-error	~/.local/probe-error	script	probe-error.sh
EOF
cmd_update_output=$(cmd_update 2>&1)
[[ ! -e "$TEST_TMP/current-update-invoked" ]] \
    || fail "setup update invoked update() for a current script module"
[[ -e "$TEST_TMP/outdated-update-invoked" ]] \
    || fail "setup update did not invoke update() for an outdated script module"
[[ ! -e "$TEST_TMP/uninstalled-update-invoked" ]] \
    || fail "setup update invoked update() for an uninstalled script module"
[[ "$cmd_update_output" == *"1 new module(s) available: absent"* ]] \
    || fail "setup update did not report the live-uninstalled module as new: $cmd_update_output"
[[ ! -e "$TEST_TMP/probe-error-update-invoked" ]] \
    || fail "setup update invoked update() after a failed status probe"
[[ "$cmd_update_output" == *"could not probe probe-error; skipping update"* ]] \
    || fail "setup update did not warn about the failed status probe: $cmd_update_output"

fields=$(script_status_fields absent '~/.local/bin/absent' uninstalled.sh)
IFS=$'\t' read -r target state display local_ref remote_ref installed extra <<< "$fields"
assert_eq uninstalled "$state" "uninstalled live state"
assert_eq "not installed" "$display" "uninstalled table label"
assert_eq 0 "$installed" "uninstalled membership"

# A managed binary must win over a different executable earlier on PATH.
mkdir -p "$HOME/.local/bin" "$TEST_TMP/shadow-bin"
cat > "$HOME/.local/bin/starship" <<'EOF'
#!/usr/bin/env bash
echo 'starship 1.26.0'
EOF
cat > "$TEST_TMP/shadow-bin/starship" <<'EOF'
#!/usr/bin/env bash
echo 'starship 1.25.1'
EOF
chmod +x "$HOME/.local/bin/starship" "$TEST_TMP/shadow-bin/starship"
PATH="$TEST_TMP/shadow-bin:$PATH"

# shellcheck disable=SC1091
source "$ROOT/files/starship.sh"
curl() {
    echo '{"tag_name":"v1.26.0"}'
}
if starship_output=$(status); then
    starship_rc=0
else
    starship_rc=$?
fi
assert_eq 0 "$starship_rc" "managed Starship should be current"
[[ "$starship_output" == *"current"* && "$starship_output" == *"local=1.26.0 remote=1.26.0"* ]] \
    || fail "Starship status inspected the PATH shadow instead of the managed target: $starship_output"

# The second managed binary module follows the same lifecycle identity rule.
cat > "$HOME/.local/bin/fzf-multicolumn" <<'EOF'
#!/usr/bin/env bash
echo '0.74.0-multicolumn.2'
EOF
cat > "$TEST_TMP/shadow-bin/fzf-multicolumn" <<'EOF'
#!/usr/bin/env bash
echo '0.73.0'
EOF
chmod +x "$HOME/.local/bin/fzf-multicolumn" "$TEST_TMP/shadow-bin/fzf-multicolumn"
# shellcheck disable=SC1091
source "$ROOT/files/fzf-multicolumn.sh"
_latest_tag() { echo 'v0.74.0-multicolumn.2'; }
if fzf_output=$(status); then
    fzf_rc=0
else
    fzf_rc=$?
fi
assert_eq 0 "$fzf_rc" "managed fzf-multicolumn should be current"
[[ "$fzf_output" == *"current"* && "$fzf_output" == *"local=0.74.0-multicolumn.2"* ]] \
    || fail "fzf-multicolumn status inspected the PATH shadow: $fzf_output"

echo "status consistency tests passed"
