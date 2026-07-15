#!/usr/bin/env bash
# setup-module: agents
# setup-type: script
#
# Installs the canonical agent payload (AGENTS.md + global skills)
# into ~/.agents/ and symlinks it into each harness. Source of truth lives in
# this repo under agents/; edit there and `setup update` to sync every machine.

[[ "$(type -t git_clone_if_missing)" == "function" ]] || source "$(dirname "${BASH_SOURCE[0]}")/../lib/script-helpers.sh"

MODULE="agents"
AGENTS_DIR="$HOME/.agents"
SRC_REPO="${AGENTS_SRC_REPO:-https://github.com/LPFchan/setup.git}"
SETUP_STATE_DIR="${STATE_DIR:-$HOME/.local/state/setup}"
SRC_CLONE="$SETUP_STATE_DIR/agents-src"
SOURCE_PATHS=(agents files/agents.sh)

# AGENTS.md symlink targets (canonical: $AGENTS_DIR/AGENTS.md)
AGENTS_LINKS=(
    "$HOME/.claude/CLAUDE.md"
    "$HOME/.codex/AGENTS.md"
    "$HOME/AGENTS.md"
    "$HOME/.config/opencode/AGENTS.md"
)
# Harness skills dirs — global skills are symlinked in per-skill (non-destructive)
SKILLS_LINK_DIRS=(
    "$HOME/.claude/skills"
    "$HOME/.codex/skills"
)

_sync_src() {
    case "$SRC_CLONE" in
        "$SETUP_STATE_DIR"/*) ;;
        *) echo "agents: refusing to reset source clone outside $SETUP_STATE_DIR: $SRC_CLONE" >&2; return 1 ;;
    esac
    git_sync_private_clone_to_origin_head "$SRC_REPO" "$SRC_CLONE" || {
        echo "agents: failed to sync source clone from $SRC_REPO" >&2
        return 1
    }
}

# Symlink $target -> $src, backing up an existing real file/dir once.
_link() {
    local src="$1" target="$2"
    mkdir -p "$(dirname "$target")"
    if [[ -L "$target" ]]; then
        [[ "$(readlink "$target")" == "$src" ]] || ln -sfn "$src" "$target"
        return 0
    fi
    if [[ -e "$target" ]]; then
        local bak="$target.pre-agents.bak"
        [[ -e "$bak" ]] || mv "$target" "$bak"
        rm -rf "$target"
    fi
    ln -s "$src" "$target"
}

_link_skills() {
    local linkdir="$1" skill name
    mkdir -p "$linkdir"
    for skill in "$AGENTS_DIR"/skills/*/; do
        [[ -d "$skill" ]] || continue
        name=$(basename "$skill")
        _link "${skill%/}" "$linkdir/$name"
    done
}

_post_install() {
    # Clean up legacy FLEET.md symlinks — fleet topology now lives in the
    # fleet skill (agents/skills/fleet/SKILL.md).
    local _old_fleet=(
        "$AGENTS_DIR/FLEET.md"
        "$HOME/.claude/FLEET.md"
        "$HOME/.codex/FLEET.md"
        "$HOME/FLEET.md"
        "$HOME/.config/opencode/FLEET.md"
    )
    local t
    for t in "${_old_fleet[@]}"; do
        if [[ -L "$t" || -f "$t" ]]; then rm -f "$t"; fi
    done
}

install() {
    _sync_src || return 1
    if [[ ! -d "$SRC_CLONE/agents" ]]; then
        echo "agents: payload missing at $SRC_CLONE/agents — push the agents/ dir to $SRC_REPO first" >&2
        return 1
    fi
    mkdir -p "$AGENTS_DIR"
    cp "$SRC_CLONE/agents/AGENTS.md" "$AGENTS_DIR/AGENTS.md"
    rm -rf "$AGENTS_DIR/skills"                       # mirror, don't accrete stale skills
    cp -R "$SRC_CLONE/agents/skills" "$AGENTS_DIR/skills"

    local t d
    for t in "${AGENTS_LINKS[@]}"; do _link "$AGENTS_DIR/AGENTS.md" "$t"; done
    for d in "${SKILLS_LINK_DIRS[@]}"; do _link_skills "$d"; done

    _post_install
    _record_state
    echo "agents: installed -> $AGENTS_DIR (linked into ${#AGENTS_LINKS[@]} targets)"
}

update() {
    install
    _post_install
}

status() {
    if [[ ! -f "$AGENTS_DIR/AGENTS.md" ]] || [[ ! -d "$SRC_CLONE/.git" ]]; then
        printf '%-25s %-12s\n' "$MODULE" "uninstalled"
        return 2
    fi
    local local_hash remote_hash local_ref remote_ref
    IFS=$'\t' read -r local_hash remote_hash local_ref remote_ref \
        < <(git_scoped_content_refs "$SRC_CLONE" "${SOURCE_PATHS[@]}" || true)
    if [[ -n "$remote_hash" && "$local_hash" != "$remote_hash" ]]; then
        printf '%-25s %-12s local=%s remote=%s target=%s\n' "$MODULE" "outdated" "${local_hash:0:7}" "${remote_hash:0:7}" "$AGENTS_DIR"
        record_script_state "$MODULE" "path" "${local_hash:0:7}" "${remote_hash:0:7}"
        return 1
    fi
    # Legacy artifacts that need cleanup trigger an update even when git refs match.
    if [[ -e "$AGENTS_DIR/FLEET.md" || -L "$AGENTS_DIR/FLEET.md" ]]; then
        printf '%-25s %-12s local=%s remote=%s target=%s\n' "$MODULE" "outdated" "${local_hash:0:7}" "${remote_hash:0:7}" "$AGENTS_DIR"
        return 1
    fi
    printf '%-25s %-12s local=%s remote=%s target=%s\n' "$MODULE" "current" "${local_hash:0:7}" "${remote_hash:0:7}" "$AGENTS_DIR"
    _record_state
    return 0
}

uninstall() {
    local t d name skill
    for t in "${AGENTS_LINKS[@]}"; do
        if [[ -L "$t" && "$(readlink "$t")" == "$AGENTS_DIR"/* ]]; then rm -f "$t"; fi
        [[ -e "$t.pre-agents.bak" && ! -e "$t" ]] && mv "$t.pre-agents.bak" "$t"
    done
    for d in "${SKILLS_LINK_DIRS[@]}"; do
        [[ -d "$d" ]] || continue
        for skill in "$AGENTS_DIR"/skills/*/; do
            [[ -d "$skill" ]] || continue
            name=$(basename "$skill")
            if [[ -L "$d/$name" && "$(readlink "$d/$name")" == "$AGENTS_DIR"/* ]]; then rm -f "$d/$name"; fi
            [[ -e "$d/$name.pre-agents.bak" && ! -e "$d/$name" ]] && mv "$d/$name.pre-agents.bak" "$d/$name"
        done
    done
    rm -rf "$AGENTS_DIR/AGENTS.md" "$AGENTS_DIR/skills"
    rmdir "$AGENTS_DIR" 2>/dev/null || true
    rm -rf "$SRC_CLONE"
    remove_script_state "$MODULE"
    echo "agents: uninstalled (backups restored where present)"
}

_record_state() {
    local h
    h=$(git_path_content_hash "$SRC_CLONE" HEAD "${SOURCE_PATHS[@]}" 2>/dev/null || git_local_ref "$SRC_CLONE")
    record_script_state "$MODULE" "path" "${h:0:7}" "${h:0:7}"
}
