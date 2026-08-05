#!/usr/bin/env zsh
# setup-module: ssh-aliases
# setup-type: script
#
# Manages a marker-delimited block of outbound Host aliases in ~/.ssh/config,
# built from the fleet table below and omitting the current machine. Keep the
# table in sync with agents/FLEET.md.

(( ${+functions[setup_sha256_string]} )) || source "${${(%):-%x}:A:h}/../lib/script-helpers.sh"

MODULE="ssh-aliases"
SSH_CONFIG="$HOME/.ssh/config"

# alias | hostname | user | optional TERM fallback
FLEET=(
    "yeowoolmac|mac.lost.plus|yeowool"
    "grimoire|grimoire.lost.plus|yeowool"
    "oci-ubuntu|oci.lost.plus|ubuntu"
    "bingus|bingus.lost.plus|yeowool|xterm-256color"
    "yeowoolair|yeowool-air.tailaa113.ts.net|yeowool"
)

_self() { echo "${SSH_ALIASES_SELF:-$(hostname -s 2>/dev/null || hostname)}"; }

# Interactive-shell wrapper that survives a suspend/resume cycle. Every fleet
# machine autostarts the shared "main" tmux session, so a dropped login can be
# reattached in place instead of costing the operator a terminal window.
RECONNECT_BLOCK='if [[ -o interactive && -t 0 ]] && [[ -n ${TERM_PROGRAM-} || -n ${SSH_TTY-} || -n ${TMUX-} ]]; then
  zmodload zsh/datetime 2>/dev/null

  # A dead link leaves the local terminal in whatever modes the remote tmux
  # set. Mouse reporting is the painful one: until it is disabled, every mouse
  # movement types an SGR escape sequence at the local prompt.
  _ssh_restore_terminal() {
      printf "\033[?1000l\033[?1002l\033[?1003l\033[?1006l\033[?1015l\033[?2004l\033[?1049l\033[?25h\033[0m"
      [[ -n ${_ssh_tty_state-} ]] && stty "$_ssh_tty_state" 2>/dev/null
      return 0
  }

  # Echo the destination only for a plain interactive login: exactly one
  # non-option operand and no remote command, so "ssh host cmd", forwarding-only
  # sessions, and anything piped keep stock behavior.
  _ssh_login_target() {
      local arg needs_value=0
      local -a operands
      for arg in "$@"; do
          if (( needs_value )); then needs_value=0; continue; fi
          case $arg in
              -[bcDEeFIiJLlmOopQRSWw]) needs_value=1 ;;
              -*) ;;
              *) operands+=("$arg") ;;
          esac
      done
      (( ${#operands} == 1 )) && printf "%s" "${operands[1]}"
      return 0
  }

  # System sleep freezes every process, so a jump in wall-clock time across a
  # two-second tick is a reliable wake signal that costs nothing while asleep.
  # Hanging up the stale client the moment the lid opens is what makes the
  # resume immediate: left alone, the session sits frozen until ServerAlive
  # finally gives up on a connection that sleep already killed.
  _ssh_wake_watcher() {
      local shell_pid=$1 last=$EPOCHSECONDS now
      while sleep 2; do
          kill -0 $shell_pid 2>/dev/null || return 0
          now=$EPOCHSECONDS
          (( now - last > 20 )) && pkill -HUP -P $shell_pid -x ssh 2>/dev/null
          last=$now
      done
  }

  ssh() {
      local target
      target=$(_ssh_login_target "$@")
      # Re-check the terminal at call time: the restore sequences and the
      # progress notes must never land in a redirected stdout.
      if [[ -z $target || ! -t 0 || ! -t 1 ]]; then
          command ssh "$@"
          return
      fi
      setopt local_options no_notify no_monitor
      local _ssh_tty_state rc start watcher tries=0 established=0
      _ssh_tty_state=$(stty -g 2>/dev/null)
      _ssh_wake_watcher $$ &!
      watcher=$!
      while true; do
          start=$EPOCHSECONDS
          command ssh "$@"
          rc=$?
          _ssh_restore_terminal
          # 255 is ssh reporting its own transport failure (broken pipe,
          # timeout, no route); 129 is the wake watcher hanging up a client
          # still blocked on a connection that sleep killed. Anything else is
          # the remote side exiting on purpose.
          (( rc != 255 && rc != 129 )) && break
          if (( EPOCHSECONDS - start >= 10 )); then
              established=1; tries=0
          fi
          # Never retry a session that never came up, so an unreachable host
          # still fails immediately instead of looping.
          (( established )) || break
          (( tries += 1 ))
          # Retry at a flat one-second cadence rather than backing off: the
          # network is either back the instant the lid opens or it is not, and
          # a growing delay only adds dead time to the common case.
          if (( tries > 120 )); then
              print -u2 -- "ssh: $target still unreachable, giving up"
              break
          fi
          print -u2 -- "ssh: reconnecting to $target (^C to stop)"
          sleep 1 || break
      done
      kill $watcher 2>/dev/null
      return $rc
  }
fi'

_build_block() {
    local self entry alias hn user term
    self=$(_self)
    for entry in "${FLEET[@]}"; do
        IFS='|' read -r alias hn user term <<< "$entry"
        [[ "$alias" == "$self" ]] && continue
        printf 'Host %s\n' "$alias"
        printf '    HostName %s\n' "$hn"
        printf '    User %s\n' "$user"
        printf '    IdentityFile ~/.ssh/id_ed25519\n'
        # Suspending a laptop strands the TCP session; without keepalives the
        # client waits out the full TCP timeout before reporting a broken pipe,
        # which is what makes a lid-close look like a hung terminal.
        printf '    ServerAliveInterval 15\n'
        printf '    ServerAliveCountMax 3\n'
        # Bounded connect so a reconnect attempt made before Wi-Fi has
        # reassociated fails fast and is retried, rather than stalling.
        printf '    ConnectTimeout 5\n'
        [[ -n "$term" ]] && printf '    SetEnv TERM=%s\n' "$term"
    done
    return 0
}

_state_hash() {
    local aliases reconnect
    aliases=$([[ -f "$SSH_CONFIG" ]] && awk '/^# >>> setup:ssh-aliases >>>/{f=1;next}/^# <<< setup:ssh-aliases <<</{f=0}f' "$SSH_CONFIG")
    reconnect=$([[ -f "$HOME/.zshrc" ]] && awk '/^# >>> setup:ssh-reconnect >>>/{f=1;next}/^# <<< setup:ssh-reconnect <<</{f=0}f' "$HOME/.zshrc")
    printf '%s\n%s' "$aliases" "$reconnect" | setup_sha256_string
}

_desired_hash() {
    local aliases reconnect
    aliases=$(setup_managed_block_body "$(_build_block)")
    reconnect=$(setup_managed_block_body "$RECONNECT_BLOCK")
    printf '%s\n%s' "$aliases" "$reconnect" | setup_sha256_string
}

_ensure_perms() {
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh" 2>/dev/null || true
    [[ -f "$SSH_CONFIG" ]] && chmod 600 "$SSH_CONFIG" 2>/dev/null || true
}

install() {
    _ensure_perms
    manage_block "$SSH_CONFIG" "ssh-aliases" "$(_build_block)" "upsert" "append"
    manage_block "$HOME/.zshrc" "ssh-reconnect" "$RECONNECT_BLOCK" "upsert" "append"
    _ensure_perms
    _record_state
}

update() { install; }

status() {
    if ! has_managed_block "$SSH_CONFIG" "ssh-aliases" \
       && ! has_managed_block "$HOME/.zshrc" "ssh-reconnect"; then
        printf '%-25s %-12s\n' "$MODULE" "uninstalled"
        return 2
    fi
    # expected = hash of the block bodies built from module source (the fleet
    # table and the reconnect wrapper), so source drift is detected too.
    local expected actual
    actual=$(_state_hash)
    expected=$(_desired_hash)
    if [[ "$expected" == "$actual" ]]; then
        printf '%-25s %-12s local=%s remote=%s target=%s\n' "$MODULE" "current" "${actual:0:7}" "${actual:0:7}" "$SSH_CONFIG"
        _record_state
        return 0
    fi
    printf '%-25s %-12s local=%s remote=%s target=%s\n' "$MODULE" "outdated" "${actual:0:7}" "${expected:0:7}" "$SSH_CONFIG"
    return 1
}

uninstall() {
    manage_block "$SSH_CONFIG" "ssh-aliases" "" "remove"
    manage_block "$HOME/.zshrc" "ssh-reconnect" "" "remove"
    _ensure_perms
    remove_script_state "$MODULE"
}

_record_state() {
    local h
    h=$(_state_hash)
    record_script_state "$MODULE" "block" "$h" "$h"
}
