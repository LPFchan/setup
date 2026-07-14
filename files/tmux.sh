#!/usr/bin/env bash
# setup-module: tmux
# setup-type: script
#
# Ensures tmux is available, manages settings in ~/.tmux.conf, installs the
# tmux-cpu-mem status helper, and owns the ~/.zshrc block that auto-launches
# every interactive shell into the shared `main` session. Uninstalling removes
# the three setup-owned surfaces but leaves the system tmux package installed.

[[ "$(type -t setup_sha256_string)" == "function" ]] || source "$(dirname "${BASH_SOURCE[0]}")/../lib/script-helpers.sh"

MODULE="tmux"
TMUX_CONF="$HOME/.tmux.conf"
HELPER="$HOME/.local/bin/tmux-cpu-mem"
ZSHRC="$HOME/.zshrc"

BLOCK_CONTENT='set -g default-terminal "tmux-256color"
set -as terminal-features ",xterm*:RGB"
set -g mouse on
bind -n MouseDown1Status set-option -t = -F @setup-drag-window "#{window_id}" \; switch-client -t =
bind -n MouseDrag1Status run-shell -C -t = "swap-window -d -s \"#{@setup-drag-window}\" -t \"#{window_id}\""
unbind -n MouseUp3Status
unbind -n MouseDown3StatusDefault
bind -n MouseDown3Status display-menu -O -T "#[align=centre]#{window_name}" -t = -x W -y W "#{?#{>:#{session_windows},1},,-}Swap Left" l { swap-window -t :-1 } "#{?#{>:#{session_windows},1},,-}Swap Right" r { swap-window -t :+1 } "#{?pane_marked_set,,-}Swap Marked" s { swap-window } "" Kill X { kill-window } Respawn R { respawn-window -k } "#{?pane_marked,Unmark,Mark}" m { select-pane -m } Rename n { command-prompt -F -I "#W" { rename-window -t "#{window_id}" "%%" } } "" "New After" w { new-window -a } "New At End" W { new-window }
bind -n MouseDown3StatusLeft display-menu -O -T "#[align=centre]#{session_name}" -t = -x M -y W Next n { switch-client -n } Previous p { switch-client -p } "" Renumber N { move-window -r } Rename r { command-prompt -I "#S" { rename-session "%%" } } Detach d { detach-client } "" "New Session" s { new-session } "New Window" w { new-window }
bind -n DoubleClick1Status kill-window -t =
bind -n DoubleClick1StatusDefault new-window -a -t ":{end}" -c "#{pane_current_path}"
bind -T copy-mode WheelUpPane select-pane \; send-keys -X -N 1 scroll-up
bind -T copy-mode WheelDownPane select-pane \; send-keys -X -N 1 scroll-down
bind -T copy-mode-vi WheelUpPane select-pane \; send-keys -X -N 1 scroll-up
bind -T copy-mode-vi WheelDownPane select-pane \; send-keys -X -N 1 scroll-down
set -g status-interval 5
set -g status-position top
set -g status-left-length 64
set -g status-left " #{p12:host_short} "
set -g status-right "#(tmux-cpu-mem) "
set -g window-status-format "#[range=window|#{window_index}] #W #[norange]"
set -g window-status-current-format "#[range=window|#{window_index}] #W #[norange]"
set -g window-status-style "dim"
set -gF window-status-current-style "bg=#{?SYSTEM_COLOR_TEXT_HEX,#{SYSTEM_COLOR_TEXT_HEX},black},fg=#{?SYSTEM_COLOR_HEX,#{SYSTEM_COLOR_HEX},colour39},bold,nodim"
set -gF status-style "bg=#{?SYSTEM_COLOR_HEX,#{SYSTEM_COLOR_HEX},colour39},fg=#{?SYSTEM_COLOR_TEXT_HEX,#{SYSTEM_COLOR_TEXT_HEX},black}"'

AUTOSTART_BLOCK_CONTENT='if [[ -o interactive && -z $TMUX ]] && command -v tmux >/dev/null; then
  exec tmux new-session -A -s main
fi'

# Name a tmux window from the command as entered at the interactive zsh prompt,
# before launchers can exec architecture-, version-, or interpreter-named
# binaries. The command table is deliberately generic; only SSH needs protocol
# awareness because its useful title is the destination rather than `ssh`.
TITLE_BLOCK_CONTENT='if [[ -o interactive && -n ${TMUX-} ]] && command -v tmux >/dev/null; then
  autoload -Uz add-zsh-hook

  _setup_tmux_set_title() {
    emulate -L zsh
    local title=${1-}
    [[ -n $title ]] && tmux rename-window -- "$title"
  }

  _setup_tmux_preexec_title() {
    emulate -L zsh
    setopt extendedglob

    local -a words
    words=("${(z)2}")
    words=("${(@Q)words}")

    # Skip leading assignments and shell/process launchers so the title names
    # the program the user asked to run (for example, `env FOO=1 codex`).
    while (( $#words )); do
      if [[ ${words[1]} == [[:alpha:]_][[:alnum:]_]#=* ]]; then
        words=("${words[@]:1}")
      elif [[ ${words[1]} == (command|exec|noglob|nocorrect|time) ]]; then
        words=("${words[@]:1}")
      elif [[ ${words[1]} == env ]]; then
        words=("${words[@]:1}")
        while (( $#words )) && [[ ${words[1]} == -* || ${words[1]} == [[:alpha:]_][[:alnum:]_]#=* ]]; do
          words=("${words[@]:1}")
        done
      else
        break
      fi
    done

    (( $#words )) || return
    local command_name=${words[1]:t}
    local title=$command_name

    if [[ $command_name == ssh ]]; then
      local candidate
      integer i=2
      while (( i <= $#words )); do
        candidate=${words[i]}
        if [[ $candidate == -- ]]; then
          (( i++ ))
          break
        elif [[ $candidate != -* || $candidate == - ]]; then
          break
        elif [[ $candidate == -[BbcDEeFIiJLlmOoPpQRSWw] ]]; then
          (( i += 2 ))
        else
          (( i++ ))
        fi
      done
      if (( i <= $#words )); then
        title=${words[i]##*@}
      fi
    fi

    _setup_tmux_set_title "$title"
  }

  _setup_tmux_precmd_title() {
    tmux set-window-option automatic-rename on
  }

  add-zsh-hook -d preexec _setup_tmux_preexec_title 2>/dev/null
  add-zsh-hook -d precmd _setup_tmux_precmd_title 2>/dev/null
  add-zsh-hook preexec _setup_tmux_preexec_title
  add-zsh-hook precmd _setup_tmux_precmd_title
fi'

# Instantaneous CPU and RAM utilization for Linux and macOS. Linux uses a
# /proc/stat delta cached across calls (no sleep); macOS uses top and
# memory_pressure. Prints `CPU N% - RAM N%`.
# Desired helper content (source of truth). `_write_helper` installs it and
# `status()` hashes it to detect drift against the installed copy.
_helper_content() {
    cat <<'CPUMEM'
#!/bin/sh
case "$(uname -s)" in
  Linux)
    PREV="/tmp/tmux-cpu.$(id -u)"
    set -- $(awk '/^cpu /{print $2,$3,$4,$5,$6,$7,$8,$9}' /proc/stat)
    idle=$(( $4 + $5 ))
    total=$(( $1+$2+$3+$4+$5+$6+$7+$8 ))
    if [ -r "$PREV" ]; then read pt pi < "$PREV"; else pt=0; pi=0; fi
    echo "$total $idle" > "$PREV"
    dt=$(( total - pt )); di=$(( idle - pi ))
    cpu=0; [ "$dt" -gt 0 ] && cpu=$(( (100*(dt-di))/dt ))
    ram=$(free | awk '/^Mem:/{printf "%.0f",($2-$7)/$2*100}')
    ;;
  Darwin)
    cpu=$(top -l 1 -n 0 2>/dev/null | awk '/CPU usage/ {gsub("%", "", $7); printf "%.0f", 100-$7; exit}')
    ram=$(memory_pressure -Q 2>/dev/null | awk '/System-wide memory free percentage:/ {gsub("%", "", $5); printf "%.0f", 100-$5; exit}')
    ;;
  *)
    cpu=0
    ram=0
    ;;
esac
case "$cpu" in ''|*[!0-9]*) cpu=0 ;; esac
case "$ram" in ''|*[!0-9]*) ram=0 ;; esac
printf 'CPU %d%% - RAM %d%%' "$cpu" "$ram"
CPUMEM
}

_as_root() {
    if [[ "$EUID" -eq 0 ]]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        echo "tmux: installing with $(basename "$1") requires root; install tmux manually" >&2
        return 1
    fi
}

_ensure_tmux() {
    command -v tmux >/dev/null 2>&1 && return 0

    echo "tmux is not installed; installing it now..."
    case "$(uname -s)" in
        Darwin)
            if command -v brew >/dev/null 2>&1; then
                brew install tmux
            elif command -v port >/dev/null 2>&1; then
                _as_root port install tmux
            else
                echo "tmux: install Homebrew (or MacPorts), then rerun setup" >&2
                return 1
            fi
            ;;
        Linux)
            if command -v apt-get >/dev/null 2>&1; then
                _as_root apt-get install -y tmux
            elif command -v dnf >/dev/null 2>&1; then
                _as_root dnf install -y tmux
            elif command -v yum >/dev/null 2>&1; then
                _as_root yum install -y tmux
            elif command -v pacman >/dev/null 2>&1; then
                _as_root pacman -S --needed --noconfirm tmux
            elif command -v zypper >/dev/null 2>&1; then
                _as_root zypper --non-interactive install tmux
            elif command -v brew >/dev/null 2>&1; then
                brew install tmux
            else
                echo "tmux: no supported package manager found; install tmux manually" >&2
                return 1
            fi
            ;;
        *)
            echo "tmux: unsupported platform $(uname -s); install tmux manually" >&2
            return 1
            ;;
    esac

    if ! command -v tmux >/dev/null 2>&1; then
        echo "tmux: package installation completed but tmux is still not on PATH" >&2
        return 1
    fi
}

_write_helper() {
    mkdir -p "$(dirname "$HELPER")"
    _helper_content > "$HELPER"
    chmod 0755 "$HELPER"
}

_upsert_blocks() {
    manage_block "$TMUX_CONF" "tmux" "$BLOCK_CONTENT" "upsert" "append"
    manage_block "$ZSHRC" "tmux-autostart" "$AUTOSTART_BLOCK_CONTENT" "upsert" "prepend"
    manage_block "$ZSHRC" "tmux-title" "$TITLE_BLOCK_CONTENT" "upsert" "prepend"
}

# If a tmux server is already running, reload the config so the new block takes
# effect without a manual source-file. Note: terminal-features/RGB (truecolor)
# is only re-read when a client (re)attaches, so an already-attached session
# needs a detach+reattach to pick up the color change (mouse/status apply live).
_reload() {
    command -v tmux >/dev/null 2>&1 || return 0
    tmux info >/dev/null 2>&1 || return 0   # no server running → nothing to reload
    [[ -n "${SYSTEM_COLOR_HEX:-}" ]] && tmux set-environment -g SYSTEM_COLOR_HEX "$SYSTEM_COLOR_HEX"
    [[ -n "${SYSTEM_COLOR_TEXT_HEX:-}" ]] && tmux set-environment -g SYSTEM_COLOR_TEXT_HEX "$SYSTEM_COLOR_TEXT_HEX"
    [[ -n "${SYSTEM_COLOR_HUE:-}" ]] && tmux set-environment -g SYSTEM_COLOR_HUE "$SYSTEM_COLOR_HUE"
    tmux source-file "$TMUX_CONF" >/dev/null 2>&1 || true
}

# Combined hash over the .tmux.conf block, zsh integration blocks, and installed
# helper, so drift in any owned surface is detected.
_state_hash() {
    local block autostart title helper
    block=""
    autostart=""
    title=""
    [[ -f "$TMUX_CONF" ]] && block=$(awk '/^# >>> setup:tmux >>>/{f=1;next}/^# <<< setup:tmux <<</{f=0}f' "$TMUX_CONF")
    [[ -f "$ZSHRC" ]] && autostart=$(awk '/^# >>> setup:tmux-autostart >>>/{f=1;next}/^# <<< setup:tmux-autostart <<</{f=0}f' "$ZSHRC")
    [[ -f "$ZSHRC" ]] && title=$(awk '/^# >>> setup:tmux-title >>>/{f=1;next}/^# <<< setup:tmux-title <<</{f=0}f' "$ZSHRC")
    helper=$([[ -f "$HELPER" ]] && cat "$HELPER")
    printf '%s\n%s\n%s\n%s' "$block" "$autostart" "$title" "$helper" | setup_sha256_string
}

# Combined hash over all desired module-owned content, so status() detects drift
# between source and any installed surface.
_desired_hash() {
    local block autostart title helper
    block=$(setup_managed_block_body "$BLOCK_CONTENT")
    autostart=$(setup_managed_block_body "$AUTOSTART_BLOCK_CONTENT")
    title=$(setup_managed_block_body "$TITLE_BLOCK_CONTENT")
    helper=$(_helper_content)
    printf '%s\n%s\n%s\n%s' "$block" "$autostart" "$title" "$helper" | setup_sha256_string
}

_record_state() {
    local h
    h=$(_state_hash)
    record_script_state "$MODULE" "block" "$h" "$h"
}

install() {
    _ensure_tmux || return 1
    _write_helper
    _upsert_blocks
    _record_state
    _reload
}

update() { install; }

status() {
    if ! has_managed_block "$TMUX_CONF" "tmux" \
       && ! has_managed_block "$ZSHRC" "tmux-autostart" \
       && ! has_managed_block "$ZSHRC" "tmux-title" \
       && [[ ! -f "$HELPER" ]]; then
        printf '%-25s %-12s\n' "$MODULE" "uninstalled"
        return 2
    fi
    if ! command -v tmux >/dev/null 2>&1; then
        printf '%-25s %-12s local=%s remote=%s target=%s\n' "$MODULE" "outdated" "missing" "required" "tmux"
        return 1
    fi
    local expected actual
    expected=$(_desired_hash)
    actual=$(_state_hash)
    if [[ "$expected" == "$actual" ]]; then
        printf '%-25s %-12s local=%s remote=%s target=%s\n' "$MODULE" "current" "${actual:0:7}" "${expected:0:7}" "$TMUX_CONF"
        _record_state
        return 0
    fi
    printf '%-25s %-12s local=%s remote=%s target=%s\n' "$MODULE" "outdated" "${actual:0:7}" "${expected:0:7}" "$TMUX_CONF"
    return 1
}

uninstall() {
    manage_block "$TMUX_CONF" "tmux" "" "remove"
    manage_block "$ZSHRC" "tmux-autostart" "" "remove"
    manage_block "$ZSHRC" "tmux-title" "" "remove"
    rm -f "$HELPER"
    remove_script_state "$MODULE"
}
