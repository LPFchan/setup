#!/usr/bin/env zsh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

export HOME="$TEST_TMP/home"
export STATE_DIR="$TEST_TMP/state/setup"
export AGENTS_SRC_REPO="$TEST_TMP/agents-remote.git"
export SETUP_OWNER_KEYS_URL="file://$TEST_TMP/owner.keys"
mkdir -p "$HOME/.ssh"

owner_key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOwnerSkillKey owner'
other_key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOtherSkillKey other'
printf '%s\n' "$owner_key" > "$TEST_TMP/owner.keys"
printf '%s\n' "$owner_key" > "$HOME/.ssh/id_ed25519.pub"

work="$TEST_TMP/agents-work"
git init --bare --initial-branch=main "$AGENTS_SRC_REPO" >/dev/null
git init --initial-branch=main "$work" >/dev/null
git -C "$work" config user.name test
git -C "$work" config user.email test@example.com
mkdir -p "$work/agents/skills/public" "$work/agents/skills/fleet" "$work/files"
printf 'agent rules\n' > "$work/agents/AGENTS.md"
printf -- '---\nname: public\n---\n# Public\n' > "$work/agents/skills/public/SKILL.md"
printf -- '---\nname: fleet\naudience: fleet\n---\n# Fleet\n' > "$work/agents/skills/fleet/SKILL.md"
printf '# agents installer\n' > "$work/files/agents.sh"
git -C "$work" add agents files/agents.sh
git -C "$work" commit -m initial >/dev/null
git -C "$work" remote add origin "$AGENTS_SRC_REPO"
git -C "$work" push -u origin main >/dev/null

# shellcheck disable=SC1091
source "$ROOT/lib/script-helpers.sh"
# shellcheck disable=SC1091
source "$ROOT/files/agents.sh"

install >/dev/null
[[ -f "$AGENTS_DIR/skills/public/SKILL.md" && -f "$AGENTS_DIR/skills/fleet/SKILL.md" ]] || {
    echo "trusted agents install omitted a skill" >&2
    exit 1
}
[[ -L "$HOME/.codex/skills/fleet" ]] || {
    echo "trusted agents install did not link the fleet skill" >&2
    exit 1
}

printf '%s\n' "$other_key" > "$HOME/.ssh/id_ed25519.pub"
install >/dev/null
[[ -f "$AGENTS_DIR/skills/public/SKILL.md" && ! -e "$AGENTS_DIR/skills/fleet" ]] || {
    echo "public agents install did not filter the fleet skill" >&2
    exit 1
}
[[ ! -e "$HOME/.codex/skills/fleet" && ! -L "$HOME/.codex/skills/fleet" ]] || {
    echo "public agents install left the fleet skill linked" >&2
    exit 1
}

echo "agents audience tests passed"
