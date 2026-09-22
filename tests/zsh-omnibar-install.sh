#!/usr/bin/env zsh
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

export HOME="$TEST_TMP/home"
export ZSH_PLUGINS_DIR="$HOME/.zsh"
mkdir -p "$HOME"

clone_count=0
upsert_count=0
record_count=0
git_clone_if_missing() {
    clone_count=$((clone_count + 1))
    [[ "${FAIL_FIRST_CLONE:-0}" != "1" || "$clone_count" -ne 1 ]]
}
manage_block() { :; }
git_local_ref() { echo abcdef0; }
record_script_state() { record_count=$((record_count + 1)); }
remove_script_state() { :; }

# shellcheck disable=SC1091
source "$ROOT/files/zsh-omnibar.sh"
_upsert_block() { upsert_count=$((upsert_count + 1)); }

FAIL_FIRST_CLONE=1
if install; then
    echo "install unexpectedly succeeded after the first clone failed" >&2
    exit 1
fi
[[ "$clone_count" -eq 1 ]] || { echo "install continued cloning after failure" >&2; exit 1; }
[[ "$upsert_count" -eq 0 ]] || { echo "install wrote .zshrc after clone failure" >&2; exit 1; }
[[ "$record_count" -eq 0 ]] || { echo "install recorded state after clone failure" >&2; exit 1; }

FAIL_FIRST_CLONE=0
clone_count=0
install
[[ "$clone_count" -eq 2 ]] || { echo "install did not clone both repositories" >&2; exit 1; }
[[ "$upsert_count" -eq 1 ]] || { echo "install did not write .zshrc" >&2; exit 1; }
[[ "$record_count" -eq 1 ]] || { echo "install did not record state" >&2; exit 1; }

# --- migration from the previous name ------------------------------------
#
# These use a manage_block that actually edits a file. A stub that only records
# the label it was called with cannot see the outcomes that matter here --
# .zshrc ending up with two plugin blocks, or with none -- which is the whole
# reason the migration exists.

manage_block() {
    local file="$1" label="$2" content="$3" mode="$4"
    local begin="# >>> setup:$label >>>" end="# <<< setup:$label <<<"
    touch "$file"
    local tmp=$(mktemp)
    awk -v b="$begin" -v e="$end" '
        $0 == b { skip = 1 } !skip { print } $0 == e { skip = 0 }
    ' "$file" > "$tmp"
    if [[ "$mode" == upsert ]]; then
        printf '%s\n%s\n%s\n' "$begin" "$content" "$end" >> "$tmp"
    fi
    mv "$tmp" "$file"
}
blocks_in() {
    [[ -f "$1" ]] || { print 0; return }
    local -a m=( ${(f)"$(grep '^# >>> setup:' "$1" 2>/dev/null)"} )
    print ${#m}
}
removed_states=()
remove_script_state() { removed_states+=( "$1" ); }

setup_old_install() {
    rm -rf "$ZSH_PLUGINS_DIR" "$HOME/.zshrc"
    mkdir -p "$ZSH_PLUGINS_DIR/zsh-autocomplete"
    git -C "$ZSH_PLUGINS_DIR/zsh-autocomplete" init -q
    git -C "$ZSH_PLUGINS_DIR/zsh-autocomplete" -c user.email=t@t -c user.name=t \
        commit -q --allow-empty -m "local work"
    manage_block "$HOME/.zshrc" zsh-autocomplete "source old" upsert
}

# --- the happy path -------------------------------------------------------

setup_old_install
local_sha=$(git -C "$ZSH_PLUGINS_DIR/zsh-autocomplete" rev-parse HEAD)
removed_states=()

_migrate_from_old_name || { echo "migration failed on the happy path" >&2; exit 1 }

[[ -d "$ZSH_PLUGINS_DIR/zsh-omnibar/.git" ]] ||
    { echo "migration did not move the clone to the new name" >&2; exit 1 }
[[ ! -e "$ZSH_PLUGINS_DIR/zsh-autocomplete" ]] ||
    { echo "migration left the old directory behind" >&2; exit 1 }
[[ "$(git -C "$ZSH_PLUGINS_DIR/zsh-omnibar" rev-parse HEAD)" == "$local_sha" ]] ||
    { echo "migration lost local commits; it re-cloned instead of moving" >&2; exit 1 }
[[ "$(blocks_in "$HOME/.zshrc")" -eq 0 ]] ||
    { echo "migration left the old .zshrc block in place" >&2; exit 1 }
[[ "${removed_states[*]}" == *zsh-autocomplete* ]] ||
    { echo "migration did not drop the old state row" >&2; exit 1 }

# After the module writes its own block there must be exactly one.
# `manage_block` directly, not `_upsert_block`: the earlier half of this file
# replaces that with a counter stub that never writes.
manage_block "$HOME/.zshrc" zsh-omnibar "$BLOCK_CONTENT" upsert
[[ "$(blocks_in "$HOME/.zshrc")" -eq 1 ]] ||
    { echo ".zshrc has $(blocks_in "$HOME/.zshrc") plugin blocks, expected 1" >&2; exit 1 }

# Idempotent: update() runs this on every sync.
_migrate_from_old_name || { echo "second migration run reported failure" >&2; exit 1 }
[[ -d "$ZSH_PLUGINS_DIR/zsh-omnibar/.git" && "$(blocks_in "$HOME/.zshrc")" -eq 1 ]] ||
    { echo "second migration run damaged the install" >&2; exit 1 }

# --- the target already exists as a plain directory ----------------------
#
# `mv src existing_dir` moves the source *inside* it. The migration must
# refuse rather than nest the clone and report success -- and must leave the
# old block alone, because a stale block that still works beats none at all.

setup_old_install
mkdir -p "$ZSH_PLUGINS_DIR/zsh-omnibar"

if _migrate_from_old_name; then
    echo "migration reported success with the target already present" >&2; exit 1
fi
[[ -d "$ZSH_PLUGINS_DIR/zsh-autocomplete/.git" ]] ||
    { echo "migration moved the clone despite refusing" >&2; exit 1 }
[[ ! -e "$ZSH_PLUGINS_DIR/zsh-omnibar/zsh-autocomplete" ]] ||
    { echo "migration nested the clone inside the target" >&2; exit 1 }
[[ "$(blocks_in "$HOME/.zshrc")" -eq 1 ]] ||
    { echo "a refused migration must not touch .zshrc" >&2; exit 1 }

# install() must not proceed past a refused migration.
if install; then
    echo "install continued after the migration refused" >&2; exit 1
fi

# --- a machine that never had the old name -------------------------------

rm -rf "$ZSH_PLUGINS_DIR" "$HOME/.zshrc"
mkdir -p "$ZSH_PLUGINS_DIR/zsh-omnibar"
git -C "$ZSH_PLUGINS_DIR/zsh-omnibar" init -q
removed_states=()

_migrate_from_old_name || { echo "migration failed on a fresh machine" >&2; exit 1 }
[[ -d "$ZSH_PLUGINS_DIR/zsh-omnibar/.git" ]] ||
    { echo "migration damaged a fresh install" >&2; exit 1 }
[[ ! -e "$HOME/.zshrc" ]] ||
    { echo "migration created .zshrc on a machine with nothing to migrate" >&2; exit 1 }
[[ -z "${removed_states[*]}" ]] ||
    { echo "migration touched state on a machine with nothing to migrate" >&2; exit 1 }

echo "zsh-omnibar install tests passed"