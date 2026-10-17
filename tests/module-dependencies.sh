#!/usr/bin/env zsh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" SETUP_SOURCE_ONLY=1
mkdir -p "$HOME/.local/bin" "$XDG_STATE_HOME/setup"
# shellcheck disable=SC1091
source "$ROOT/bin/setup"

fail() { echo "FAIL: $*" >&2; exit 1; }
normalize_block_order() { :; }
configure_shell() { :; }
fetch_manifest() { :; }
is_service_module() { return 1; }

write_manifest() { printf '%b' "$1" > "$MANIFEST_FILE"; }
write_requires() { printf '%b' "$1" > "$REQUIRES_FILE"; }

# --- ordering --------------------------------------------------------
# c needs b, b needs a; asking for c must install a, then b, then c.
write_manifest '# module\ttarget\tmode\tsource\na\t~/a\t0755\tx\nb\t~/b\t0755\tx\nc\t~/c\t0755\tx\n'
write_requires 'b\ta\nc\tb\n'
order=$(resolve_install_order c | tr '\n' ' ')
[[ "$order" == "a b c " ]] || fail "install order was '$order', expected 'a b c '"

# A dependency named twice resolves once.
order=$(resolve_install_order c b | tr '\n' ' ')
[[ "$order" == "a b c " ]] || fail "duplicate request reordered to '$order'"

# --- cycles ----------------------------------------------------------
write_requires 'a\tb\nb\ta\n'
if resolve_install_order a >/dev/null 2>&1; then
    fail "a dependency cycle was accepted"
fi

# --- dependency missing from this machine's catalog ------------------
write_requires 'a\tnosuch\n'
if resolve_install_order a >/dev/null 2>&1; then
    fail "a dependency outside the catalog was accepted"
fi

# --- auto-install marks only what the operator did not ask for -------
write_requires 'b\ta\n'
installed=()
install_one() { installed+=("$1"); printf '' > "$(expand_path "$2")"; return 0; }
rm -f "$DEP_FILE"
cmd_install b >/dev/null 2>&1 || fail "install of b failed"
[[ "${installed[*]}" == "a b" ]] || fail "install sequence was '${installed[*]}', expected 'a b'"
dep_is_marked a || fail "pulled-in dependency a was not marked"
dep_is_marked b && fail "explicitly requested b was marked as a dependency"

# An explicit request for something already pulled in clears the mark.
cmd_install a >/dev/null 2>&1 || fail "install of a failed"
dep_is_marked a && fail "explicitly requested a stayed marked as a dependency"

# --- uninstall refuses while a dependent is installed ----------------
write_requires 'b\ta\n'
: > "$HOME/a"; : > "$HOME/b"
uninstall_one() { rm -f "$(expand_path "$2")"; return 0; }
BATCH=1
if cmd_uninstall a >/dev/null 2>&1; then
    fail "uninstalling a dependency of an installed module was allowed"
fi
[[ -e "$HOME/a" ]] || fail "refused uninstall still removed the target"

# Removing the dependent first, then the dependency, is allowed.
cmd_uninstall b >/dev/null 2>&1 || fail "uninstall of b failed"
cmd_uninstall a >/dev/null 2>&1 || fail "uninstall of a failed once nothing needed it"
[[ ! -e "$HOME/a" ]] || fail "a survived its uninstall"

# --- hidden dependency prunes the dependent --------------------------
# Six-column filtered shape: module, target, mode, source, status, requires.
filtered="$TMP/filtered.tsv"
printf '%b' 'keep\t~/keep\t0755\tx\t\t\nneedy\t~/needy\t0755\tx\t\tgone\nchained\t~/chained\t0755\tx\t\tneedy\n' \
    > "$filtered"
prune_hidden_dependents "$filtered" || fail "prune returned non-zero"
grep -q '^keep' "$filtered" || fail "prune dropped an independent module"
grep -q '^needy' "$filtered" && fail "prune kept a module whose dependency is hidden"
grep -q '^chained' "$filtered" && fail "prune kept a module depending on a dropped dependent"

# --- the cached manifest stays four columns --------------------------
# An older setup on a machine that has not self-updated reads this file with a
# four-field read; a fifth column would be folded into source.
manifest_cols=$(awk -F '\t' 'NF { print NF }' "$MANIFEST_FILE" | sort -u | tr '\n' ' ')
[[ "$manifest_cols" == "4 " ]] || fail "cached manifest has columns '$manifest_cols', expected '4 '"

# --- fleet needs schedule on Linux only ------------------------------
# Its timer is a systemd unit on Linux and a launchd agent on macOS, which
# the requires column cannot say, so module_requires adds it.
write_requires 'fleet\tauth\n'
uname() { echo Linux; }
[[ "$(module_requires fleet)" == "auth schedule" ]] || fail "fleet on Linux requires '$(module_requires fleet)'"
uname() { echo Darwin; }
[[ "$(module_requires fleet)" == "auth" ]] || fail "fleet on macOS requires '$(module_requires fleet)'"
unfunction uname

# The same rule keeps schedule from being uninstalled under fleet.
saved_manifest="$TMP/manifest.saved"
cp "$MANIFEST_FILE" "$saved_manifest"
printf '%b' 'schedule\t~/schedule\tscript\tx\nfleet\t~/fleet\tscript\tx\n' > "$MANIFEST_FILE"
functions[saved_is_installed]=${functions[module_is_installed]}
module_is_installed() { return 0; }
uname() { echo Linux; }
[[ "$(installed_dependents_of schedule)" == fleet ]] || fail "schedule dependents on Linux: '$(installed_dependents_of schedule)'"
[[ "$(installed_dependents_of auth)" == fleet ]] || fail "auth dependents: '$(installed_dependents_of auth)'"
uname() { echo Darwin; }
[[ -z "$(installed_dependents_of schedule)" ]] || fail "schedule dependents on macOS: '$(installed_dependents_of schedule)'"
unfunction uname
functions[module_is_installed]=${functions[saved_is_installed]}
cp "$saved_manifest" "$MANIFEST_FILE"

# --- update installs a dependency gained since install, first ---------
# u (a plain file) now needs s (a script module). s comes in before u is
# updated, so a u that re-enables itself finds s; s is not "new available".
printf '%b' 'u\t~/u\t0755\tx\ns\t~/s\tscript\tx\nother\t~/other\tscript\tx\n' > "$MANIFEST_FILE"
write_requires 'u\ts\n'
rm -f "$HOME/s" "$HOME/u" "$SCRIPT_STATE_FILE" "$DEP_FILE"
: > "$HOME/u"
printf '%s\tH\n' "$HOME/u" > "$HASH_FILE"
swap_retired_modules() { return 0; }
script_status_fields() {
    module_is_installed "$1" "$2" script && printf '%s\tcurrent\n' "$2" || printf '%s\tuninstalled\n' "$2"
}
: > "$TMP/installed"
install_one() {
    printf '%s ' "$1" >> "$TMP/installed"
    [[ "$3" == script ]] && printf '%s\tx\n' "$1" >> "$SCRIPT_STATE_FILE"
    return 0
}
out=$(cmd_update 2>&1) || fail "update failed: $out"
[[ "$(<"$TMP/installed")" == "s u " ]] || fail "update sequence was '$(<"$TMP/installed")', expected 's u '"
dep_is_marked s || fail "the dependency update installed was not marked"
[[ "$out" == *"1 new module(s) available: other"* ]] || fail "update reported: $out"
rm -f "$HASH_FILE" "$SCRIPT_STATE_FILE" "$DEP_FILE" "$HOME/u"
cp "$saved_manifest" "$MANIFEST_FILE"

# --- a failed dependency holds back the module that needs it -----------
# u needs s; s fails to install, so u is not updated without it.
printf '%b' 'u\t~/u\t0755\tx\ns\t~/s\tscript\tx\n' > "$MANIFEST_FILE"
write_requires 'u\ts\n'
rm -f "$HOME/s" "$SCRIPT_STATE_FILE" "$DEP_FILE"
: > "$HOME/u"
printf '%s\tH\n' "$HOME/u" > "$HASH_FILE"
: > "$TMP/installed"
install_one() {
    printf '%s ' "$1" >> "$TMP/installed"
    [[ "$1" == s ]] && return 1
    return 0
}
out=$(cmd_update 2>&1) && fail "update with a failed dependency succeeded: $out"
[[ "$(<"$TMP/installed")" == "s " ]] || fail "update sequence was '$(<"$TMP/installed")', expected 's '"
[[ "$out" == *"u waits for it"* ]] || fail "update reported: $out"
rm -f "$HASH_FILE" "$SCRIPT_STATE_FILE" "$DEP_FILE" "$HOME/u"

# --- a filter on a dependency brings that dependency's prerequisites ----
# u needs s, s needs p; neither is installed. `update s` installs p before s.
printf '%b' 'u\t~/u\t0755\tx\ns\t~/s\tscript\tx\np\t~/p\tscript\tx\n' > "$MANIFEST_FILE"
write_requires 'u\ts\ns\tp\n'
rm -f "$HOME/s" "$HOME/p" "$SCRIPT_STATE_FILE" "$DEP_FILE"
: > "$HOME/u"
printf '%s\tH\n' "$HOME/u" > "$HASH_FILE"
: > "$TMP/installed"
install_one() {
    printf '%s ' "$1" >> "$TMP/installed"
    [[ "$3" == script ]] && printf '%s\tx\n' "$1" >> "$SCRIPT_STATE_FILE"
    return 0
}
out=$(cmd_update s 2>&1) || fail "filtered update failed: $out"
[[ "$(<"$TMP/installed")" == "p s " ]] || fail "filtered update sequence was '$(<"$TMP/installed")', expected 'p s '"

# A service dependency the update installs is enabled: the loop below skips
# it, and a filter can skip its dependent.
rm -f "$HOME/s" "$HOME/p" "$SCRIPT_STATE_FILE" "$DEP_FILE"
: > "$TMP/installed"
: > "$TMP/enabled"
functions[saved_is_service]=${functions[is_service_module]}
is_service_module() { [[ "$1" == s ]]; }
module_service_unit() { echo timer; }
module_service_transition() { printf '%s %s ' "$1" "$2" >> "$TMP/enabled"; }
out=$(cmd_update s 2>&1) || fail "filtered update of a service dependency failed: $out"
[[ "$(<"$TMP/installed")" == "p s " ]] || fail "update sequence was '$(<"$TMP/installed")', expected 'p s '"
[[ "$(<"$TMP/enabled")" == "enable s " ]] || fail "enabled '$(<"$TMP/enabled")', expected 'enable s '"
# One that cannot be enabled holds its dependent back, as a failed install does.
rm -f "$HOME/s" "$HOME/p" "$SCRIPT_STATE_FILE" "$DEP_FILE"
: > "$TMP/installed"
is_service_module() { [[ "$1" == p ]]; }
module_service_transition() { return 1; }
rc=0; out=$(cmd_update s 2>&1) || rc=$?
(( rc != 0 )) || fail "update passed a service dependency that could not be enabled"
[[ "$(<"$TMP/installed")" == "p " ]] || fail "updated past a service that could not be enabled: '$(<"$TMP/installed")'"
functions[is_service_module]=${functions[saved_is_service]}
rm -f "$HASH_FILE" "$SCRIPT_STATE_FILE" "$DEP_FILE" "$HOME/u"
cp "$saved_manifest" "$MANIFEST_FILE"

# --- an installed dependency updates before the module that needs it ---
# u needs d but comes first in the manifest; both are installed.
printf '%b' 'u\t~/u\t0755\tx\nd\t~/d\t0755\tx\n' > "$MANIFEST_FILE"
write_requires 'u\td\n'
: > "$HOME/u"; : > "$HOME/d"
printf '%s\tH\n%s\tH\n' "$HOME/u" "$HOME/d" > "$HASH_FILE"
: > "$TMP/installed"
install_one() { printf '%s ' "$1" >> "$TMP/installed"; return 0; }
out=$(cmd_update 2>&1) || fail "update with an installed dependency failed: $out"
[[ "$(<"$TMP/installed")" == "d u " ]] || fail "update sequence was '$(<"$TMP/installed")', expected 'd u '"
# A filter on u updates d with it, first.
printf '%s\tH\n%s\tH\n' "$HOME/u" "$HOME/d" > "$HASH_FILE"
: > "$TMP/installed"
out=$(cmd_update u 2>&1) || fail "filtered update with an installed dependency failed: $out"
[[ "$(<"$TMP/installed")" == "d u " ]] || fail "filtered update sequence was '$(<"$TMP/installed")', expected 'd u '"
# One whose update fails holds u back.
printf '%s\tH\n%s\tH\n' "$HOME/u" "$HOME/d" > "$HASH_FILE"
: > "$TMP/installed"
install_one() { printf '%s ' "$1" >> "$TMP/installed"; [[ "$1" != d ]]; }
out=$(cmd_update 2>&1) && fail "update past a failed dependency update succeeded: $out"
[[ "$(<"$TMP/installed")" == "d " ]] || fail "updated past a failed dependency: '$(<"$TMP/installed")'"
[[ "$out" == *"u waits for d"* ]] || fail "update reported: $out"
# A loop in the manifest updates nothing.
write_requires 'u\td\nd\tu\n'
printf '%s\tH\n%s\tH\n' "$HOME/u" "$HOME/d" > "$HASH_FILE"
: > "$TMP/installed"
install_one() { printf '%s ' "$1" >> "$TMP/installed"; return 0; }
out=$(cmd_update 2>&1) && fail "update through a dependency loop succeeded: $out"
[[ -z "$(<"$TMP/installed")" ]] || fail "updated through a dependency loop: '$(<"$TMP/installed")'"
[[ "$out" == *"loop through"* ]] || fail "update reported: $out"
rm -f "$HASH_FILE" "$HOME/u" "$HOME/d"
cp "$saved_manifest" "$MANIFEST_FILE"

echo "module-dependencies: ok"
