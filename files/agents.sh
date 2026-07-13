#!/usr/bin/env bash
# setup-module: agents
# setup-type: script
#
# Installs the canonical agent payload (AGENTS.md + FLEET.md + global skills)
# into ~/.agents/ and symlinks it into each harness. Source of truth lives in
# this repo under agents/; edit there and `setup update` to sync every machine.

[[ "$(type -t git_clone_if_missing)" == "function" ]] || source "$(dirname "${BASH_SOURCE[0]}")/../lib/script-helpers.sh"

MODULE="agents"
AGENTS_DIR="$HOME/.agents"
SRC_REPO="${AGENTS_SRC_REPO:-https://github.com/LPFchan/setup.git}"
SRC_CLONE="${STATE_DIR:-$HOME/.local/state/setup}/agents-src"

# AGENTS.md symlink targets (canonical: $AGENTS_DIR/AGENTS.md)
AGENTS_LINKS=(
    "$HOME/.claude/CLAUDE.md"
    "$HOME/.codex/AGENTS.md"
    "$HOME/AGENTS.md"
    "$HOME/.config/opencode/AGENTS.md"
)
# FLEET.md sibling symlink targets (so "see FLEET.md" resolves per harness)
FLEET_LINKS=(
    "$HOME/.claude/FLEET.md"
    "$HOME/.codex/FLEET.md"
    "$HOME/FLEET.md"
    "$HOME/.config/opencode/FLEET.md"
)
# Harness skills dirs — global skills are symlinked in per-skill (non-destructive)
SKILLS_LINK_DIRS=(
    "$HOME/.claude/skills"
    "$HOME/.codex/skills"
)

_sync_src() {
    if [[ -d "$SRC_CLONE/.git" ]]; then
        git_pull_ff "$SRC_CLONE" >/dev/null 2>&1 || true
    else
        git_clone_if_missing "$SRC_REPO" "$SRC_CLONE"
    fi
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

install() {
    _sync_src
    if [[ ! -d "$SRC_CLONE/agents" ]]; then
        echo "agents: payload missing at $SRC_CLONE/agents — push the agents/ dir to $SRC_REPO first" >&2
        return 1
    fi
    mkdir -p "$AGENTS_DIR"
    cp "$SRC_CLONE/agents/AGENTS.md" "$AGENTS_DIR/AGENTS.md"
    cp "$SRC_CLONE/agents/FLEET.md"  "$AGENTS_DIR/FLEET.md"
    rm -rf "$AGENTS_DIR/skills"                       # mirror, don't accrete stale skills
    cp -R "$SRC_CLONE/agents/skills" "$AGENTS_DIR/skills"

    local t d
    for t in "${AGENTS_LINKS[@]}"; do _link "$AGENTS_DIR/AGENTS.md" "$t"; done
    for t in "${FLEET_LINKS[@]}";  do _link "$AGENTS_DIR/FLEET.md"  "$t"; done
    for d in "${SKILLS_LINK_DIRS[@]}"; do _link_skills "$d"; done

    _record_state
    echo "agents: installed -> $AGENTS_DIR (linked into ${#AGENTS_LINKS[@]} targets)"
}

update() { install; }

status() {
    if [[ ! -f "$AGENTS_DIR/AGENTS.md" ]] || [[ ! -d "$SRC_CLONE/.git" ]]; then
        printf '%-25s %-12s\n' "$MODULE" "uninstalled"
        return 2
    fi
    local lr rr
    lr=$(git_local_ref "$SRC_CLONE")
    rr=$(git_remote_ref "$SRC_CLONE")
    if [[ -n "$rr" && "$lr" != "$rr" ]]; then
        printf '%-25s %-12s local=%s remote=%s target=%s\n' "$MODULE" "outdated" "${lr:0:7}" "${rr:0:7}" "$AGENTS_DIR"
        record_script_state "$MODULE" "git" "${lr:0:7}" "${rr:0:7}"
        return 1
    fi
    printf '%-25s %-12s local=%s remote=%s target=%s\n' "$MODULE" "current" "${lr:0:7}" "${rr:0:7}" "$AGENTS_DIR"
    _record_state
    return 0
}

uninstall() {
    local t d name skill
    for t in "${AGENTS_LINKS[@]}" "${FLEET_LINKS[@]}"; do
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
    rm -rf "$AGENTS_DIR/AGENTS.md" "$AGENTS_DIR/FLEET.md" "$AGENTS_DIR/skills"
    rmdir "$AGENTS_DIR" 2>/dev/null || true
    rm -rf "$SRC_CLONE"
    remove_script_state "$MODULE"
    echo "agents: uninstalled (backups restored where present)"
}

_record_state() {
    local lr
    lr=$(git_local_ref "$SRC_CLONE")
    record_script_state "$MODULE" "git" "${lr:0:7}" "${lr:0:7}"
}
