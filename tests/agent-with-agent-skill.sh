#!/usr/bin/env zsh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SKILL="$ROOT/agents/skills/agent-with-agent/SKILL.md"

[[ -f "$SKILL" ]]
grep -q '^name: agent-with-agent$' "$SKILL"
grep -q 'Only mint a room when the operator explicitly asks' "$SKILL"
grep -q 'auth token awa-v1' "$SKILL"
grep -q 'https://awa.lost.plus/skill.md' "$SKILL"
grep -q "resume that participant's token; do not create a new participant" "$SKILL"
! grep -q 'Choose your own name' "$SKILL"

echo "agent-with-agent skill tests passed"
