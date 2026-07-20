#!/usr/bin/env zsh
# setup-module: agents
# setup-type: script
#
# Installs the canonical agent payload (AGENTS.md + global skills)
# into ~/.agents/ and symlinks it into each harness. Source of truth lives in
# this repo under agents/; edit there and `setup update` to sync every machine.

(( ${+functions[git_clone_if_missing]} )) || source "${${(%):-%x}:A:h}/../lib/script-helpers.sh"

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

_skill_audience() {
    awk -F ': *' '/^audience:/{print $2; exit}' "$1/SKILL.md" 2>/dev/null
}

_skill_is_visible() {
    [[ "$(_skill_audience "$1")" != fleet || "${MACHINE_IS_FLEET:-0}" == 1 ]]
}

_refresh_machine_audience() {
    local trust_rc=0
    MACHINE_IS_FLEET=0
    setup_machine_is_trusted || trust_rc=$?
    (( trust_rc == 0 )) && MACHINE_IS_FLEET=1
    if (( trust_rc == 2 )); then
        echo "agents: warning: could not read the owner key list; fleet-only skills are hidden" >&2
    fi
}

_prune_skill_links() {
    local d skill name
    for d in "${SKILLS_LINK_DIRS[@]}"; do
        [[ -d "$d" ]] || continue
        for skill in "$d"/*(N); do
            [[ -L "$skill" && "$(readlink "$skill")" == "$AGENTS_DIR"/skills/* ]] || continue
            name=$(basename "$skill")
            [[ -d "$AGENTS_DIR/skills/$name" ]] && continue
            rm -f "$skill"
            [[ -e "$skill.pre-agents.bak" ]] && mv "$skill.pre-agents.bak" "$skill"
        done
    done
}

_installed_payload_matches() {
    cmp -s "$SRC_CLONE/agents/AGENTS.md" "$AGENTS_DIR/AGENTS.md" || return 1
    local skill name target
    for skill in "$SRC_CLONE"/agents/skills/*(N/); do
        name=$(basename "$skill")
        target="$AGENTS_DIR/skills/$name"
        if _skill_is_visible "$skill"; then
            [[ -d "$target" ]] && diff -qr "$skill" "$target" >/dev/null || return 1
        else
            [[ ! -e "$target" ]] || return 1
        fi
    done
    for target in "$AGENTS_DIR"/skills/*(N/); do
        name=$(basename "$target")
        [[ -d "$SRC_CLONE/agents/skills/$name" ]] || return 1
        _skill_is_visible "$SRC_CLONE/agents/skills/$name" || return 1
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
    _refresh_machine_audience
    mkdir -p "$AGENTS_DIR"
    cp "$SRC_CLONE/agents/AGENTS.md" "$AGENTS_DIR/AGENTS.md"
    rm -rf "$AGENTS_DIR/skills"                       # mirror, don't accrete stale skills
    mkdir -p "$AGENTS_DIR/skills"
    local skill
    for skill in "$SRC_CLONE"/agents/skills/*(N/); do
        _skill_is_visible "$skill" && cp -R "$skill" "$AGENTS_DIR/skills/"
    done

    local t d
    for t in "${AGENTS_LINKS[@]}"; do _link "$AGENTS_DIR/AGENTS.md" "$t"; done
    _prune_skill_links
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
    _refresh_machine_audience
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
    if ! _installed_payload_matches; then
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
    _prune_skill_links
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
