#!/usr/bin/env zsh
set -euo pipefail

ROOT=${0:A:h:h}
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

export HOME="$TEST_TMP/home"
export XDG_STATE_HOME="$TEST_TMP/state"
export SETUP_SOURCE_ONLY=1
mkdir -p "$HOME/.local/bin" "$XDG_STATE_HOME"

# shellcheck disable=SC1091
source "$ROOT/bin/setup"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

for module in active-service inactive-service unchanged-service; do
    printf 'old\n' > "$HOME/.local/bin/$module"
done

configure_shell() { :; }
normalize_block_order() { :; }
fetch_manifest() {
    cat > "$MANIFEST_FILE" <<'EOF'
# module	target	mode	source
active-service	~/.local/bin/active-service	0755	active
inactive-service	~/.local/bin/inactive-service	0755	inactive
unchanged-service	~/.local/bin/unchanged-service	0755	unchanged
EOF
}
installed_hash_for() { printf 'installed\n'; }
install_one() {
    local module="$1" target
    target=$(expand_path "$2")
    [[ "$module" == unchanged-service ]] || printf 'new\n' > "$target"
}
is_service_module() { return 0; }
module_service_unit() { printf '%s.timer\n' "$1"; }
module_is_active() { [[ "$1" == active-service || "$1" == unchanged-service ]]; }
module_service_transition() { printf '%s\t%s\n' "$1" "$2" >> "$TEST_TMP/transitions"; }

cmd_update active-service inactive-service unchanged-service >/dev/null

[[ -f "$TEST_TMP/transitions" ]] || fail "active updated service was not re-enabled"
grep -qx $'enable\tactive-service' "$TEST_TMP/transitions" \
    || fail "active updated service did not preserve its state"
if grep -q 'inactive-service' "$TEST_TMP/transitions"; then
    fail "inactive service was enabled by update"
fi
if grep -q 'unchanged-service' "$TEST_TMP/transitions"; then
    fail "unchanged service was unnecessarily re-enabled"
fi

echo "ok"
