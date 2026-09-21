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

echo "module-dependencies: ok"
