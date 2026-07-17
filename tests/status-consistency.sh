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
install() {
    touch "$TEST_TMP/outdated-install-invoked"
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
managed_picker() { printf '%s\n' fzf-multicolumn; }
printf '0\n' > "$TEST_TMP/status-picker-count"
fzf-multicolumn() {
    cat > "$TEST_TMP/interactive-rows"
    local n=$(( $(cat "$TEST_TMP/status-picker-count") + 1 )) delim=$'\x1f'
    printf '%s\n' "$n" > "$TEST_TMP/status-picker-count"
    case "$n" in
        1)
            _setup_picker_toggle checkbox live-block
            _setup_picker_render > "$TEST_TMP/interactive-selected-rows"
            _setup_picker_toggle checkbox live-block
            return 1
            ;;
        *) return 1 ;;
    esac
}
cmd_reconfigure
interactive_row=$(grep 'live-block' "$TEST_TMP/interactive-rows" | tail -1)
[[ "$interactive_row" == *"aaaaaaa"* && "$interactive_row" == *"bbbbbbb"* \
   && "$interactive_row" == *"installed"* && "$interactive_row" == *"update available"* ]] \
    || fail "interactive row did not use the normalized live result: $interactive_row"
grep -Eq 'module +local +service +remote +status' "$TEST_TMP/interactive-rows" \
    || fail "interactive detail columns lack an aligned heading"
assert_eq 2 "$(cat "$TEST_TMP/probe-count")" "selection-only redraws must reuse one cached script probe"

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
if cmd_update_output=$(cmd_update 2>&1); then
    cmd_update_rc=0
else
    cmd_update_rc=$?
fi
[[ "$cmd_update_rc" -ne 0 ]] || fail "setup update masked a failed script probe"
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

# Span UI: selecting a checkbox reloads the same picker into select-all + five
# contextual actions, tracks focus by identity, and dispatches a batch action.
cat > "$TEST_TMP/manifest.tsv" <<'EOF'
# module	target	mode	source
current-update	~/.local/current-update	script	current-update.sh
outdated-update	~/.local/outdated-update	script	outdated-update.sh
EOF
rm -f "$TEST_TMP/current-update-invoked" "$TEST_TMP/outdated-update-invoked"
printf '0\n' > "$TEST_TMP/fzf-count"
fzf-multicolumn() {
    local n input delim=$'\x1f'
    input=$(cat)
    n=$(( $(cat "$TEST_TMP/fzf-count") + 1 ))
    printf '%s\n' "$n" > "$TEST_TMP/fzf-count"
    case "$n" in
        1)
            grep -q '@@5@@all-menu' <<< "$input" || fail "initial row lacks span5 ALL menu cell"
            [[ "$(_setup_picker_transform all-menu all)" == accept ]] || fail "ALL menu cell is not interactive"
            [[ "$*" == *'enter:transform:_setup_picker_transform'* ]] || fail "checkboxes do not use in-process transform"
            [[ "$*" == *'--id-nth=1,2'* ]] || fail "reload lacks stable row identity"
            [[ "$*" == *'result:transform:_setup_picker_result_transform'* ]] || fail "reload does not restore its deterministic position"
            [[ "$*" == *'result:+transform-header:_setup_picker_header'* ]] || fail "reload does not refresh the selection header"
            transform=$(_setup_picker_transform checkbox outdated-update)
            [[ "$transform" == 'reload-sync(_setup_picker_render)' ]] || fail "checkbox transform does not reload in place: $transform"
            [[ "$(_setup_picker_result_transform)" == 'pos(7)' ]] || fail "checkbox reload does not restore its deterministic position"
            input=$(_setup_picker_render)
            [[ $(grep -c 'action' <<< "$input") -eq 3 ]] || fail "selected top row did not contain only its three applicable actions"
            ! grep -Eq 'action.* 0([^0-9]|$)' <<< "$input" || fail "selected top row surfaced a zero-count action"
            grep -q "select-all${delim}all${delim}\[ \]${delim}" <<< "$input" || fail "partial select-all marker was not unchecked"
            [[ "$(_setup_picker_header)" == '1/2 · '* ]] || fail "selection count was not updated in the header"
            grep -q '@@5@@module' <<< "$input" || fail "module detail lacks span5"
            grep "^action${delim}update${delim}" <<< "$input" | head -1
            ;;
        *) return 1 ;;
    esac
}
cmd_reconfigure >/dev/null
assert_eq 2 "$(cat "$TEST_TMP/fzf-count")" "checkbox toggle caused an extra picker restart before the action"
[[ ! -e "$TEST_TMP/current-update-invoked" ]] \
    || fail "interactive update invoked update() for an unselected current module"
[[ -e "$TEST_TMP/outdated-update-invoked" ]] \
    || fail "interactive selected update did not call script update()"

# A selected/current setup reinstall is deferred until last and must still see
# FORCE=1. install_one is stubbed because a real setup install execs itself.
cat > "$TEST_TMP/manifest.tsv" <<'EOF'
# module	target	mode	source
setup	~/.local/bin/setup	0755	bin/setup
EOF
mkdir -p "$HOME/.local/bin"
printf '# setup-module: setup\n' > "$HOME/.local/bin/setup"
printf '0\n' > "$TEST_TMP/fzf-count"
fzf-multicolumn() {
    local n input delim=$'\x1f'
    input=$(cat); n=$(( $(cat "$TEST_TMP/fzf-count") + 1 )); printf '%s\n' "$n" > "$TEST_TMP/fzf-count"
    case "$n" in
        1)
            _setup_picker_transform checkbox setup >/dev/null
            _setup_picker_render | grep "^action${delim}reinstall${delim}" | head -1
            ;;
        *) return 1 ;;
    esac
}
confirm_action() { return 0; }
install_one() { printf '%s:%s\n' "$1" "$FORCE" >> "$TEST_TMP/reinstall-log"; }
FORCE=0
cmd_reconfigure >/dev/null
assert_eq 2 "$(cat "$TEST_TMP/fzf-count")" "setup checkbox caused an extra picker restart before the action"
assert_eq 'setup:1' "$(cat "$TEST_TMP/reinstall-log")" "deferred setup reinstall lost FORCE=1"
assert_eq 0 "$FORCE" "reinstall did not restore FORCE after deferred setup"

# Selecting the detail cell opens the individual submenu without toggling its
# checkbox. Returning from the submenu restores focus to that same detail cell.
cat > "$TEST_TMP/manifest.tsv" <<'EOF'
# module	target	mode	source
current-update	~/.local/current-update	script	current-update.sh
outdated-update	~/.local/outdated-update	script	outdated-update.sh
EOF
rm -f "$TEST_TMP/outdated-update-invoked"
printf '0\n' > "$TEST_TMP/fzf-count"
fzf-multicolumn() {
    local n input delim=$'\x1f'
    input=$(cat); n=$(( $(cat "$TEST_TMP/fzf-count") + 1 )); printf '%s\n' "$n" > "$TEST_TMP/fzf-count"
    case "$n" in
        1) printf 'module%soutdated-update%sdetail\n' "$delim" "$delim" ;;
        2)
            grep -q "action${delim}update${delim}Update" <<< "$input" || fail "individual submenu omitted update"
            grep "^action${delim}update${delim}" <<< "$input" | head -1
            ;;
        3)
            [[ "$*" == *'0/2 · '* ]] || fail "individual action toggled the batch checkbox"
            [[ "$*" == *'load:pos(6)'* ]] || fail "detail focus was not restored after individual submenu"
            return 1
            ;;
    esac
}
cmd_reconfigure >/dev/null
[[ -e "$TEST_TMP/outdated-update-invoked" ]] \
    || fail "individual submenu update did not call script update()"

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
if [[ "${1:-}" == --help ]]; then echo '--grid-span-prefix=STR'; else echo '0.74.0-multicolumn.2'; fi
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

# ai-menu carries its payload in a separate clone. A diverged private clone must
# compare path-scoped content against remote HEAD, then update must reset that
# module-managed clone before installing the payload.
ai_remote="$TEST_TMP/ai-menu-remote.git"
ai_work="$TEST_TMP/ai-menu-work"
git init --bare --initial-branch=main "$ai_remote" >/dev/null
git init --initial-branch=main "$ai_work" >/dev/null
git -C "$ai_work" config user.name test
git -C "$ai_work" config user.email test@example.com
mkdir -p "$ai_work/files"
printf 'old payload\n' > "$ai_work/files/ai-menu"
git -C "$ai_work" add files/ai-menu
git -C "$ai_work" commit -m old >/dev/null
git -C "$ai_work" remote add origin "$ai_remote"
git -C "$ai_work" push -u origin main >/dev/null

STATE_DIR="$TEST_TMP/ai-menu-state"
AI_MENU_SRC_REPO="$ai_remote"
# shellcheck disable=SC1091
source "$ROOT/files/ai-menu.sh"
install >/dev/null

git -C "$SRC_CLONE" config user.name test
git -C "$SRC_CLONE" config user.email test@example.com
printf 'private diverged payload\n' > "$SRC_CLONE/files/ai-menu"
git -C "$SRC_CLONE" add files/ai-menu
git -C "$SRC_CLONE" commit -m private-diverge >/dev/null

printf 'new payload\n' > "$ai_work/files/ai-menu"
git -C "$ai_work" add files/ai-menu
git -C "$ai_work" commit -m new >/dev/null
git -C "$ai_work" push >/dev/null
if ai_status=$(status); then
    ai_status_rc=0
else
    ai_status_rc=$?
fi
assert_eq 1 "$ai_status_rc" "ai-menu status must detect a stale payload clone"
[[ "$ai_status" == *"outdated"* ]] \
    || fail "ai-menu stale clone was not reported outdated: $ai_status"
update >/dev/null
assert_eq "new payload" "$(cat "$PAYLOAD_TARGET")" "ai-menu update must install the remote payload"

agents_remote="$TEST_TMP/agents-remote.git"
agents_work="$TEST_TMP/agents-work"
git init --bare --initial-branch=main "$agents_remote" >/dev/null
git init --initial-branch=main "$agents_work" >/dev/null
git -C "$agents_work" config user.name test
git -C "$agents_work" config user.email test@example.com
mkdir -p "$agents_work/agents/skills/demo" "$agents_work/files"
printf 'agents v1\n' > "$agents_work/agents/AGENTS.md"
printf -- '---\nname: demo\n---\n# Demo\n' > "$agents_work/agents/skills/demo/SKILL.md"
printf '# agents installer v1\n' > "$agents_work/files/agents.sh"
git -C "$agents_work" add agents files/agents.sh
git -C "$agents_work" commit -m agents-v1 >/dev/null
git -C "$agents_work" remote add origin "$agents_remote"
git -C "$agents_work" push -u origin main >/dev/null

STATE_DIR="$TEST_TMP/agents-state"
AGENTS_SRC_REPO="$agents_remote"
# shellcheck disable=SC1091
source "$ROOT/files/agents.sh"
install >/dev/null

mkdir -p "$agents_work/docs"
printf 'unrelated\n' > "$agents_work/docs/note.md"
git -C "$agents_work" add docs/note.md
git -C "$agents_work" commit -m unrelated >/dev/null
git -C "$agents_work" push >/dev/null
if agents_status=$(status); then
    agents_status_rc=0
else
    agents_status_rc=$?
fi
assert_eq 0 "$agents_status_rc" "agents status must ignore remote changes outside agents/ and files/agents.sh"
[[ "$agents_status" == *"current"* ]] \
    || fail "agents unrelated remote change was not current: $agents_status"

printf 'agents v2\n' > "$agents_work/agents/AGENTS.md"
git -C "$agents_work" add agents/AGENTS.md
git -C "$agents_work" commit -m agents-v2 >/dev/null
git -C "$agents_work" push >/dev/null
mkdir -p "$SRC_CLONE/agents/skills/stale"
printf '# stale\n' > "$SRC_CLONE/agents/skills/stale/SKILL.md"
if agents_status=$(status); then
    agents_status_rc=0
else
    agents_status_rc=$?
fi
assert_eq 1 "$agents_status_rc" "agents status must detect remote changes under agents/"
[[ "$agents_status" == *"outdated"* ]] \
    || fail "agents scoped remote change was not outdated: $agents_status"
update >/dev/null
[[ ! -e "$AGENTS_DIR/skills/stale/SKILL.md" ]] \
    || fail "agents update copied an untracked stale skill from the private clone"

echo "status consistency tests passed"
