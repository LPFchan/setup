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
# The .zshrc block label is what manage_block matches on, so renaming the
# module without removing the old block leaves two of them in .zshrc, both
# sourcing the plugin. And the clone carries local commits, so it must be
# moved rather than re-cloned.

removed_labels=()
manage_block() {
    # $2 is the label, $4 the mode.
    [[ "${4:-}" == remove ]] && removed_labels+=( "$2" )
    return 0
}
removed_states=()
remove_script_state() { removed_states+=( "$1" ); }

# An existing install under the old name: a real clone with a local commit.
rm -rf "$ZSH_PLUGINS_DIR"
mkdir -p "$ZSH_PLUGINS_DIR/zsh-autocomplete"
git -C "$ZSH_PLUGINS_DIR/zsh-autocomplete" init -q
git -C "$ZSH_PLUGINS_DIR/zsh-autocomplete" -c user.email=t@t -c user.name=t     commit -q --allow-empty -m "local work"
local_sha=$(git -C "$ZSH_PLUGINS_DIR/zsh-autocomplete" rev-parse HEAD)

_migrate_from_old_name

[[ -d "$ZSH_PLUGINS_DIR/zsh-omnibar/.git" ]] ||
    { echo "migration did not move the clone to the new name" >&2; exit 1 }
[[ ! -e "$ZSH_PLUGINS_DIR/zsh-autocomplete" ]] ||
    { echo "migration left the old directory behind" >&2; exit 1 }
[[ "$(git -C "$ZSH_PLUGINS_DIR/zsh-omnibar" rev-parse HEAD)" == "$local_sha" ]] ||
    { echo "migration lost local commits; it re-cloned instead of moving" >&2; exit 1 }
(( ${removed_labels[(Ie)zsh-autocomplete]} )) ||
    { echo "migration did not remove the old .zshrc block" >&2; exit 1 }
(( ${removed_states[(Ie)zsh-autocomplete]} )) ||
    { echo "migration did not drop the old state row" >&2; exit 1 }

# Running twice must not undo anything, since update() calls it every sync.
_migrate_from_old_name
[[ -d "$ZSH_PLUGINS_DIR/zsh-omnibar/.git" ]] ||
    { echo "second migration run damaged the install" >&2; exit 1 }

# A new machine, with nothing to migrate, must not be disturbed.
rm -rf "$ZSH_PLUGINS_DIR"
mkdir -p "$ZSH_PLUGINS_DIR/zsh-omnibar"
_migrate_from_old_name
[[ -d "$ZSH_PLUGINS_DIR/zsh-omnibar" ]] ||
    { echo "migration removed a fresh install" >&2; exit 1 }

echo "zsh-omnibar install tests passed"
