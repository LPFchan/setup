#!/usr/bin/env python3
"""Build sandbox/ — a throwaway $HOME the recordings run against.

Nothing here mocks the tools. The real bin/setup, files/resume and
files/ai-menu from this repo run inside this HOME; the seeder just gives them
something to find: an ssh config with the fleet in it, populated session stores
for each harness, and per-machine tmux configs generated from files/tmux.sh.

Machine colours come from the same computation zsh-basics does —
cksum(short hostname) % 360 at full saturation — so the hues on screen are the
fleet's real ones, not chosen.
"""
import json, os, re, shutil, sqlite3, stat, subprocess, sys, time
from datetime import datetime, timezone, timedelta

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '..', '..'))
SB   = os.path.join(HERE, 'sandbox')
HOME = os.path.join(SB, 'home')
CONF = os.path.join(SB, 'conf')

FLEET = ['yeowoolair', 'grimoire', 'bingus', 'yeowoolmac', 'oci-ubuntu']
SELF  = 'yeowoolair'

SSH_HOSTS = [                       # mirrors files/ssh-aliases.sh
    ('yeowoolmac', 'mac.lost.plus',   'yeowool', None),
    ('grimoire',   'grimoire.lost.plus', 'yeowool', None),
    ('oci-ubuntu', 'oci.lost.plus',   'ubuntu',  None),
    ('bingus',     'bingus.lost.plus', 'yeowool', 'xterm-256color'),
]

HARNESSES = ['claude', 'codex', 'claudex', 'opencode', 'hermes', 'grok']

PROJECTS = ['Documents/setup', 'Documents/fzf-multicolumn', 'Documents/repo-template',
            'Documents/nxgallery', 'Documents/Marble', 'Documents/Photopeace',
            'Documents/Superhuman', 'grimoire', 'Eastself']

# (minutes ago, harness, cwd, first prompt) — the resume picker's rows
SESSIONS = [
    (  8, 'claude',   'Documents/setup',           'make ai-menu rank folders by recency'),
    ( 15, 'claude',   'grimoire',                  'why is the draft model falling out of cache'),
    ( 27, 'codex',    'Documents/fzf-multicolumn', 'span-aware grid: keep the focused cell on redraw'),
    ( 52, 'opencode', 'Documents/setup',           'make ai-menu rank folders by recency'),
    ( 77, 'hermes',   'Eastself',                  'wire the telegram bridge to the new inference host'),
    (100, 'claude',   'Documents/repo-template',   'scaffold the skills directory'),
    (144, 'grok',     'Documents/nxgallery',       'lazy-load the masonry grid below the fold'),
    (166, 'claude',   'Documents/setup',           'fold zsh-init into the zsh-basics module'),
    (205, 'codex',    'Documents/Marble',          'obsidian vault sync keeps dropping attachments'),
    (244, 'opencode', 'grimoire',                  'gpu fan curve is oscillating above 70C'),
    (315, 'claude',   'grimoire',                  'summarise yesterday calendar into the daily note'),
    (388, 'hermes',   'Eastself',                  'schedule the nightly photo backup report'),
    (455, 'codex',    'Documents/Photopeace',      'colour-manage the export pipeline'),
    (520, 'grok',     'Documents/Superhuman',      'draft the release notes from the changelog'),
]


def sh(*args, **kw):
    return subprocess.run(args, capture_output=True, text=True, **kw).stdout


def machine_colour(host):
    """Exactly what zsh-basics computes: POSIX cksum of the lowercased short
    hostname, mod 360, converted from HSV with S and V pinned at 100%."""
    out = subprocess.run(['cksum'], input=host.lower(), capture_output=True,
                         text=True).stdout
    h = int(out.split()[0]) % 360
    sector, off = h // 60, h % 60
    r, g, b = [(255, 255 * off // 60, 0), (255 * (60 - off) // 60, 255, 0),
               (0, 255, 255 * off // 60), (0, 255 * (60 - off) // 60, 255),
               (255 * off // 60, 0, 255), (255, 0, 255 * (60 - off) // 60)][sector]
    hexc = f"#{r:02X}{g:02X}{b:02X}"
    text = "#000000" if (299 * r + 587 * g + 114 * b) >= 128000 else "#FFFFFF"
    return h, hexc, text


def write(path, body, mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        f.write(body)
    os.chmod(path, mode)


def tmux_block():
    """Pull the module's managed tmux settings out of files/tmux.sh so the
    recordings use the same configuration a real machine gets."""
    src = open(os.path.join(REPO, 'files', 'tmux.sh')).read()
    m = re.search(r"^BLOCK_CONTENT='(.*?)'\n\nAUTOSTART", src, re.S | re.M)
    if not m:
        sys.exit("could not extract BLOCK_CONTENT from files/tmux.sh")
    return m.group(1).replace("'\"'\"'", "'")


def build_tmux_confs():
    block = tmux_block()
    for host in FLEET:
        _, hexc, text = machine_colour(host)
        body = block
        # resolve the two formats that would otherwise need the shell's env
        body = body.replace('set -g status-left " #{p12:host_short} "',
                            f'set -g status-left " {host:<12} "')
        body = re.sub(r'set -gF window-status-current-style .*',
                      f'set -g window-status-current-style "bg={hexc},fg={text},bold,nodim"', body)
        body = re.sub(r'set -gF status-style .*',
                      f'set -g status-style "bg={hexc},fg={text}"', body)
        write(os.path.join(CONF, f'{host}.conf'), body + '\n')


def build_bin():
    binp = os.path.join(HOME, '.local', 'bin')
    os.makedirs(binp, exist_ok=True)
    # Harness stubs: hold the window open so the tab keeps its name. They must
    # answer version flags — module probes shell out to them, and a stub that
    # slept through `--version` would hang the whole status snapshot.
    for name in HARNESSES:
        write(os.path.join(binp, name), f'''#!/bin/sh
case "$1" in
  --version|-V|-v|version) echo "{name} 1.0.0"; exit 0 ;;
  --help|-h) echo "usage: {name}"; exit 0 ;;
esac
printf '%s\\n' "$@" >/dev/null
exec sleep 900
''', 0o755)
    # the real tools from this repo
    for src, dst in (('bin/setup', 'setup'), ('files/resume', 'resume'),
                     ('files/refresh-models', 'refresh-models')):
        shutil.copy2(os.path.join(REPO, src), os.path.join(binp, dst))
        os.chmod(os.path.join(binp, dst), 0o755)
    # the status helper, straight out of the module
    src = open(os.path.join(REPO, 'files', 'tmux.sh')).read()
    helper = re.search(r"cat <<'CPUMEM'\n(.*?)\nCPUMEM", src, re.S).group(1)
    write(os.path.join(binp, 'tmux-cpu-mem'), helper + '\n', 0o755)
    # emulated ssh: each fleet host is a nested tmux on its own socket + config
    # TMUX is cleared so the inner server attaches as a genuinely nested
    # client — that is what stacks a second status bar under the first.
    write(os.path.join(binp, 'ssh'), f'''#!/bin/sh
host="$1"
conf="{CONF}/$host.conf"
[ -f "$conf" ] || {{ echo "no emulated host: $host" >&2; exit 1; }}
TMUX= exec tmux -L "vid-$host" -f "$conf" new-session -A -s main
''', 0o755)
    # Module status probes are live by design — several reach GitHub. Offline
    # that hangs the whole snapshot, so these shims let anything addressed at
    # the local source URL through and fail everything else immediately. The
    # probes still run for real; they just get their answer straight away.
    write(os.path.join(binp, 'curl'), '''#!/bin/sh
case "$*" in *127.0.0.1*|*localhost*) exec /usr/bin/curl "$@" ;; esac
exit 7
''', 0o755)
    write(os.path.join(binp, 'git'), '''#!/bin/sh
case "$1" in ls-remote|fetch|clone|pull|push) exit 128 ;; esac
exec /usr/bin/git "$@"
''', 0o755)

    for tool in ('fzf', 'fzf-multicolumn', 'starship'):
        real = os.path.expanduser(f'~/.local/bin/{tool}')
        if not os.path.exists(real):
            real = shutil.which(tool)
        if real:
            link = os.path.join(binp, tool)
            if os.path.lexists(link):
                os.remove(link)
            os.symlink(real, link)


def build_shell():
    _, hexc, text = machine_colour(SELF)
    hue, _, _ = machine_colour(SELF)
    path = f"{HOME}/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    write(os.path.join(HOME, '.zshenv'), f'''export PATH="{path}"
export SYSTEM_COLOR_HUE={hue}
export SYSTEM_COLOR_HEX="{hexc}"
export SYSTEM_COLOR_TEXT_HEX="{text}"
export XDG_STATE_HOME="$HOME/.local/state"
export HISTFILE="$HOME/.zsh_history"
export HISTSIZE=2000
export SAVEHIST=2000
''')

    # the tmux title hooks, verbatim from the module
    src = open(os.path.join(REPO, 'files', 'tmux.sh')).read()
    title = re.search(r"^TITLE_BLOCK_CONTENT='(.*?)'\n", src, re.S | re.M).group(1)
    title = title.replace("'\"'\"'", "'")

    write(os.path.join(HOME, '.zshrc'), f'''export PATH="{path}"
setopt NO_NOMATCH
bindkey -e
autoload -Uz add-zsh-hook

{title}

if command -v starship >/dev/null; then
  eval "$(starship init zsh)"
fi

source "$HOME/.bashrc.d/ai-menu"
''')

    # starship: the two-segment prompt the fleet runs
    write(os.path.join(HOME, '.config', 'starship.toml'), '''add_newline = false
format = "$hostname$directory$character"

[hostname]
ssh_only = false
format = "[$hostname ]($style)"
style = "bold cyan"

[directory]
truncation_length = 3
truncate_to_repo = false
format = "[$path ]($style)"
style = "bold white"

[character]
success_symbol = "[\\u279c](bold green)"
error_symbol = "[\\u279c](bold red)"
''')

    # ai-menu payload, straight from the repo
    os.makedirs(os.path.join(HOME, '.bashrc.d'), exist_ok=True)
    shutil.copy2(os.path.join(REPO, 'files', 'ai-menu'),
                 os.path.join(HOME, '.bashrc.d', 'ai-menu'))

    # ssh config — the outbound aliases ai-menu reads its host column from
    lines = []
    for alias, hn, user, term in SSH_HOSTS:
        lines += [f'Host {alias}', f'    HostName {hn}', f'    User {user}',
                  '    IdentityFile ~/.ssh/id_ed25519']
        if term:
            lines.append(f'    SetEnv TERM={term}')
    write(os.path.join(HOME, '.ssh', 'config'), '\n'.join(lines) + '\n', 0o600)
    os.chmod(os.path.join(HOME, '.ssh'), 0o700)

    # claudex profile, so the claudex-cc entry appears in the menu
    write(os.path.join(HOME, '.config', 'claudex', 'config.toml'), '''[[profiles]]
name = "codex"
[[profiles]]
name = "commandcode"
''')

    # history + recency store: what fills ai-menu's folder column
    hist = ['cd ~/' + p for p in PROJECTS]
    write(os.path.join(HOME, '.zsh_history'), '\n'.join(hist) + '\n')
    now = time.time()
    recents = [f"{now - 60 * i:.6f}\t{os.path.join(HOME, p)}"
               for i, p in enumerate(PROJECTS)]
    write(os.path.join(HOME, '.local', 'state', 'setup', 'ai-menu-dirs'),
          '\n'.join(recents) + '\n')

    for p in PROJECTS:
        os.makedirs(os.path.join(HOME, p), exist_ok=True)
    os.makedirs(os.path.join(HOME, '.bashrc.d'), exist_ok=True)


def when(mins):
    return datetime.now(timezone.utc) - timedelta(minutes=mins)


def build_sessions():
    """Populate every store `resume` scans, so its picker is real output."""
    # --- Claude Code: one JSONL per session under a cwd-encoded project dir
    for i, (mins, tool, cwd, msg) in enumerate(SESSIONS):
        if tool != 'claude':
            continue
        full = os.path.join(HOME, cwd)
        proj = full.replace('/', '-')
        sid = f"c0ffee{i:02d}-1006-4006-8006-a11ce000{i:04d}"
        p = os.path.join(HOME, '.claude', 'projects', proj, f'{sid}.jsonl')
        rows = [
            {"type": "user", "cwd": full, "message": {"role": "user", "content": msg}},
            {"type": "assistant", "message": {"role": "assistant",
                                              "model": "claude-opus-4",
                                              "content": [{"type": "text", "text": "ok"}]}},
        ]
        write(p, '\n'.join(json.dumps(r) for r in rows) + '\n')
        ts = when(mins).timestamp()
        os.utime(p, (ts, ts))

    # --- Codex: rollout-<stamp>-<id>.jsonl
    for i, (mins, tool, cwd, msg) in enumerate(SESSIONS):
        if tool != 'codex':
            continue
        full = os.path.join(HOME, cwd)
        stamp = when(mins).strftime('%Y-%m-%dT%H-%M-%S')
        sid = f"01c0ffee-{i:04d}-7000-8000-a11ce0000{i:03d}"
        p = os.path.join(HOME, '.codex', 'sessions', f'rollout-{stamp}-{sid}.jsonl')
        rows = [
            {"type": "session_meta", "payload": {"cwd": full, "id": sid}},
            {"type": "response_item", "payload": {"role": "user", "content": [
                {"type": "input_text", "text": msg}]}},
        ]
        write(p, '\n'.join(json.dumps(r) for r in rows) + '\n')
        ts = when(mins).timestamp()
        os.utime(p, (ts, ts))

    # --- OpenCode: sqlite
    db = os.path.join(HOME, '.local', 'share', 'opencode', 'opencode.db')
    os.makedirs(os.path.dirname(db), exist_ok=True)
    if os.path.exists(db):
        os.remove(db)
    c = sqlite3.connect(db)
    c.execute("CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT, title TEXT,"
              " directory TEXT, time_updated INTEGER)")
    for i, (mins, tool, cwd, msg) in enumerate(SESSIONS):
        if tool != 'opencode':
            continue
        c.execute("INSERT INTO session VALUES (?,?,?,?,?)",
                  (f"ses_c0ffee{i:04d}", None, msg, os.path.join(HOME, cwd),
                   int(when(mins).timestamp() * 1000)))
    c.commit(); c.close()

    # --- ForgeCode: sqlite
    db = os.path.join(HOME, '.forge', '.forge.db')
    os.makedirs(os.path.dirname(db), exist_ok=True)
    if os.path.exists(db):
        os.remove(db)
    c = sqlite3.connect(db)
    c.execute("CREATE TABLE conversations (conversation_id TEXT PRIMARY KEY, title TEXT,"
              " updated_at TEXT, context TEXT)")
    c.commit(); c.close()

    # --- Hermes: sqlite
    db = os.path.join(HOME, '.hermes', 'state.db')
    os.makedirs(os.path.dirname(db), exist_ok=True)
    if os.path.exists(db):
        os.remove(db)
    c = sqlite3.connect(db)
    c.execute("CREATE TABLE sessions (id TEXT PRIMARY KEY, cwd TEXT, title TEXT,"
              " source TEXT, parent_session_id TEXT, archived INTEGER,"
              " started_at INTEGER, ended_at INTEGER)")
    c.execute("CREATE TABLE messages (session_id TEXT, role TEXT, content TEXT,"
              " timestamp INTEGER, id INTEGER PRIMARY KEY AUTOINCREMENT)")
    for i, (mins, tool, cwd, msg) in enumerate(SESSIONS):
        if tool != 'hermes':
            continue
        sid, ts = f"hm_c0ffee{i:04d}", int(when(mins).timestamp())
        c.execute("INSERT INTO sessions VALUES (?,?,?,?,?,?,?,?)",
                  (sid, os.path.join(HOME, cwd), msg, 'cli', None, 0, ts, ts))
        c.execute("INSERT INTO messages (session_id, role, content, timestamp)"
                  " VALUES (?,?,?,?)", (sid, 'user', msg, ts))
    c.commit(); c.close()

    # --- Grok Build: one summary.json per session dir
    for i, (mins, tool, cwd, msg) in enumerate(SESSIONS):
        if tool != 'grok':
            continue
        full = os.path.join(HOME, cwd)
        sid = f"gk-c0ffee-{i:04d}"
        p = os.path.join(HOME, '.grok', 'sessions', full.replace('/', '-'), sid,
                         'summary.json')
        write(p, json.dumps({
            "info": {"id": sid, "cwd": full},
            "num_chat_messages": 6,
            "generated_title": msg,
            "last_active_at": when(mins).isoformat(),
        }, indent=1))


def build_setup_state():
    """Give `setup` a state dir so status/picker report a settled machine with
    one module out of date — which is what makes the table worth looking at."""
    state = os.path.join(HOME, '.local', 'state', 'setup')
    os.makedirs(state, exist_ok=True)
    shutil.copy2(os.path.join(REPO, 'manifest.tsv'), os.path.join(state, 'manifest.tsv'))
    os.makedirs(os.path.join(state, 'lib'), exist_ok=True)
    shutil.copy2(os.path.join(REPO, 'lib', 'script-helpers.sh'),
                 os.path.join(state, 'lib', 'script-helpers.sh'))

    # Record the hashes of the file modules we installed, so status() reports
    # them tracked and current rather than untracked.
    rows = []
    for line in open(os.path.join(REPO, 'manifest.tsv')):
        if line.startswith('#') or not line.strip():
            continue
        f = line.rstrip('\n').split('\t')
        module, target, mode, source = f[0], f[1], f[2], f[3]
        if mode == 'script':
            continue
        full = target.replace('~', HOME, 1)
        if not os.path.exists(full):
            continue
        h = subprocess.run(['shasum', '-a', '256', full],
                           capture_output=True, text=True).stdout.split()[0]
        rows.append(f"{full}\t{h}\t")
    if rows:
        write(os.path.join(state, 'installed.tsv'), '\n'.join(rows) + '\n')


def main():
    if os.path.exists(SB):
        shutil.rmtree(SB)
    os.makedirs(HOME, exist_ok=True)
    build_tmux_confs()
    build_bin()
    build_shell()
    build_sessions()
    build_setup_state()
    print(f"sandbox -> {SB}")
    for host in FLEET:
        hue, hexc, text = machine_colour(host)
        print(f"  {host:<11} hue {hue:<4} {hexc}  text {text}")


main()
