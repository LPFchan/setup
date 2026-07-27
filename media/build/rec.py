#!/usr/bin/env python3
"""Record the casts the background video is built from.

Each cast is a real tmux session driven through a pty, with every byte the
terminal emits captured and timestamped. Nothing is simulated: the pickers are
the repo's own bin/setup, files/resume and files/ai-menu running against
sandbox/, and mouse interaction is performed by injecting SGR mouse sequences
into the client — the exact bytes a terminal sends when you click and drag.

    casts/<name>.json = {cols, rows, meta, events: [[t, base64], ...]}

meta.cursor, when present, is [[t, col, row, down], ...]: where the pointer was
and whether the button was held. A terminal never draws the pointer, so the
stage reconstructs it from that track.
"""
import base64, fcntl, http.server, json, os, pty, select, signal, socketserver
import struct, subprocess, sys, termios, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '..', '..'))
SB   = os.path.join(HERE, 'sandbox')
HOME = os.path.join(SB, 'home')
CONF = os.path.join(SB, 'conf')
CASTS = os.path.join(HERE, 'casts')

STATUS_LEFT = 14      # ' hostname    ' — status-left is 1 + p12 + 1 cells
STATUS_ROW  = 1       # status-position top, 1-based for mouse reporting


# --------------------------------------------------------------------------
def serve_repo():
    """Serve the repo so `setup` can resolve checksums.tsv without the network,
    which also keeps the recordings deterministic."""
    class H(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *a, **kw):
            super().__init__(*a, directory=REPO, **kw)
        def log_message(self, *a):
            pass
    httpd = socketserver.TCPServer(('127.0.0.1', 0), H)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd, httpd.server_address[1]


class Rec:
    """One tmux session on its own socket, recorded through a pty."""

    def __init__(self, host, cols, rows, port, sock=None):
        self.cols, self.rows = cols, rows
        self.sock = sock or f'vid-{host}'
        self.events, self.cursor = [], []
        env = dict(os.environ)
        env.update(
            HOME=HOME, TERM='xterm-256color', SHELL='/bin/zsh',
            PATH=f"{HOME}/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            XDG_STATE_HOME=f"{HOME}/.local/state",
            XDG_CONFIG_HOME=f"{HOME}/.config",
            STARSHIP_CONFIG=f"{HOME}/.config/starship.toml",
            LINUX_SETUP_SOURCE_URL=f"http://127.0.0.1:{port}",
            COLUMNS=str(cols), LINES=str(rows),
        )
        for k in ('TMUX', 'TMUX_PANE'):
            env.pop(k, None)
        self.env = env
        subprocess.run(['tmux', '-L', self.sock, 'kill-server'],
                       stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
        self.proc = subprocess.Popen(
            ['tmux', '-L', self.sock, '-f', os.path.join(CONF, f'{host}.conf'),
             'new-session', '-s', 'main'],
            stdin=slave, stdout=slave, stderr=slave, cwd=HOME, env=env,
            preexec_fn=os.setsid, close_fds=True)
        os.close(slave)
        self.t0 = time.time()

    def t(self):
        return round(time.time() - self.t0, 4)

    def wait(self, seconds):
        end = time.time() + seconds
        while True:
            left = end - time.time()
            if left <= 0:
                return
            r, _, _ = select.select([self.master], [], [], left)
            if not r:
                continue
            try:
                data = os.read(self.master, 65536)
            except OSError:
                return
            if data:
                self.events.append([self.t(), base64.b64encode(data).decode()])

    def tmux(self, *args):
        subprocess.run(['tmux', '-L', self.sock, *args], env=self.env,
                       stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)

    def keys(self, *args, pause=0.45):
        self.tmux('send-keys', *args)
        self.wait(pause)

    def run(self, line, pause=0.9):
        """Type a command and press enter, the way a person would."""
        self.keys(line, pause=0.28)
        self.keys('Enter', pause=pause)

    def type(self, text, per=0.12):
        """Type into whatever TUI has the pane, one key at a time."""
        for ch in text:
            self.keys(ch, pause=per)

    def mouse(self, x, y, kind):
        """SGR: press Cb=0, motion-with-button-1 Cb=32, release ends in 'm'."""
        cb = 32 if kind == 'drag' else 0
        end = 'm' if kind == 'up' else 'M'
        os.write(self.master, f"\033[<{cb};{x};{y}{end}".encode())

    def point(self, x, y, down):
        self.cursor.append([self.t(), x - 1, y - 1, 1 if down else 0])

    def save(self, name):
        self.tmux('kill-server')
        try:
            os.killpg(os.getpgid(self.proc.pid), signal.SIGTERM)
        except Exception:
            pass
        os.close(self.master)
        meta = {'cursor': self.cursor} if self.cursor else {}
        os.makedirs(CASTS, exist_ok=True)
        path = os.path.join(CASTS, f'{name}.json')
        json.dump({'cols': self.cols, 'rows': self.rows, 'meta': meta,
                   'events': self.events}, open(path, 'w'))
        dur = self.events[-1][0] if self.events else 0
        print(f"  {name:<16} {self.cols}x{self.rows}  {len(self.events):>4} events  {dur:5.2f}s"
              + (f"  {len(self.cursor)} pointer" if self.cursor else ""))


def tab_layout(names):
    """Slot and text span of each ' name ' tab. The bar renders status-left,
    then ' name ' per window joined by window-status-separator (one space), so
    a tab's text starts one cell into its slot and the next slot begins
    len+3 later."""
    out, start = [], STATUS_LEFT
    for n in names:
        out.append({'name': n, 'start': start, 'first': start + 1,
                    'last': start + len(n)})
        start += len(n) + 3
    return out


# --------------------------------------------------------------------------
def rec_bartabs(port):
    """The status bar: tabs opening one at a time, then dragged into a new
    order. One continuous take — both halves are the same subject."""
    WINDOWS = ['claude', 'codex', 'opencode', 'agy', 'hermes', 'grok']
    r = Rec('yeowoolair', 108, 12, port)
    r.wait(0.5)
    r.tmux('set-option', '-g', 'automatic-rename', 'off')
    r.tmux('rename-window', '-t', '0', WINDOWS[0])
    r.wait(0.45)
    for name in WINDOWS[1:]:
        r.tmux('new-window', '-n', name, 'exec sleep 900')
        r.wait(0.42)
    r.wait(0.55)

    tabs = tab_layout(WINDOWS)
    y = STATUS_ROW
    grab = (tabs[-1]['first'] + tabs[-1]['last']) // 2 + 1
    # Swap targets, right to left. A swap never moves the tabs left of it, so
    # each slot's centre stays where the original layout put it.
    targets = [(t['first'] + t['last']) // 2 + 1 for t in tabs[:-1]][::-1]
    drop = targets[-1]

    for x in range(grab + 16, grab - 1, -2):
        r.point(x, y, False)
        r.wait(0.04)
    r.point(grab, y, False)
    r.wait(0.34)

    r.mouse(grab, y, 'down')
    r.point(grab, y, True)
    r.wait(0.40)

    # tmux spends the first motion after a press establishing the drag; that
    # event never reaches MouseDrag1Status. Without this primer the first real
    # target is swallowed and the tab skips a position on the next one. Keep
    # the primer inside the grabbed tab so the binding it fires is a no-op
    # self-swap.
    r.mouse(grab - 1, y, 'drag')
    r.point(grab - 1, y, True)
    r.wait(0.12)

    # Pointer moves smoothly; tmux hears one event per tab centre. Sending on
    # every cell instead would land on tab boundaries, where swapping two tabs
    # of different widths moves the boundary out from under the cursor and the
    # next motion swaps them straight back.
    ti, x = 0, grab - 1
    while x > drop:
        x -= 1
        if ti < len(targets) and x <= targets[ti]:
            r.mouse(targets[ti], y, 'drag')
            ti += 1
            r.point(x, y, True)
            r.wait(0.20)          # let the reorder land and read
            continue
        r.point(x, y, True)
        r.wait(0.055)
    r.wait(0.45)

    r.mouse(drop, y, 'up')
    r.point(drop, y, False)
    r.wait(0.85)
    for x in range(drop, drop - 11, -2):
        r.point(x, y, False)
        r.wait(0.05)
    r.wait(0.6)

    order = subprocess.run(['tmux', '-L', r.sock, 'list-windows', '-F', '#{window_name}'],
                           env=r.env, capture_output=True, text=True).stdout.split()
    r.save('bartabs')
    print(f"      grab x={grab} targets={targets} -> {' '.join(order)}")
    return order


def rec_aimenu(port):
    """ai-menu: the three-track picker — tools, ssh hosts, recent folders."""
    r = Rec('yeowoolair', 112, 24, port)
    r.wait(1.2)
    # Hold the unfiltered menu long enough for both shots that live on it —
    # the fall down the tool column and the track across all three tracks.
    r.run('ai', pause=5.0)
    r.type('gri', per=0.32)          # narrow to the grimoire host + folder
    r.wait(1.2)
    for _ in range(3):
        r.keys('BSpace', pause=0.26)
    r.wait(1.6)
    r.save('aimenu')


def rec_picker(port):
    """setup's six-track reconfigure picker: checkbox gutter + module table."""
    r = Rec('yeowoolair', 104, 26, port)
    r.wait(1.0)
    r.run('setup', pause=6.0)        # probing every module takes a moment
    r.wait(6.0)
    r.save('picker')


def rec_resume(port):
    """resume: one row per session across every harness store."""
    r = Rec('yeowoolair', 118, 22, port)
    r.wait(1.2)
    r.run('resume', pause=2.6)
    r.type('grim', per=0.3)
    r.wait(1.3)
    for _ in range(4):
        r.keys('BSpace', pause=0.22)
    r.wait(1.5)
    r.save('resume')


def rec_nested(port):
    """ssh into grimoire, then bingus: real nested tmux, one machine-colour
    band per hop, stacking on top of each other."""
    r = Rec('yeowoolair', 120, 26, port)
    r.wait(1.2)
    r.run('ssh grimoire', pause=2.4)
    r.run('setup list', pause=1.6)
    r.run('hermes', pause=1.6)
    r.tmux('send-keys', 'C-b', 'c')  # new window on the inner server
    r.wait(0.9)
    r.run('ssh bingus', pause=2.4)
    r.run('ls -la ~/.local/bin', pause=2.6)
    r.wait(1.6)
    r.save('nested')


def rec_tile(port, host, script, name):
    """A 64x18 tile of one fleet machine, for the cascade."""
    r = Rec(host, 64, 18, port)
    r.wait(1.0)
    for line, pause in script:
        r.run(line, pause=pause)
    r.wait(1.2)
    r.save(name)


def main():
    if not os.path.isdir(SB):
        sys.exit("sandbox/ missing — run seed_sandbox.py first")
    httpd, port = serve_repo()
    only = set(sys.argv[1:])
    print(f"recording casts (source url http://127.0.0.1:{port})")

    jobs = {
        'bartabs':       lambda: rec_bartabs(port),
        'aimenu':        lambda: rec_aimenu(port),
        'picker':        lambda: rec_picker(port),
        'resume':        lambda: rec_resume(port),
        'nested':        lambda: rec_nested(port),
        'tile_grimoire': lambda: rec_tile(port, 'grimoire', [('setup list', 2.2)], 'tile_grimoire'),
        'tile_mac':      lambda: rec_tile(port, 'yeowoolmac', [('resume', 2.6)], 'tile_mac'),
        'tile_bingus':   lambda: rec_tile(port, 'bingus', [('ls -la ~/.local/bin', 2.4)], 'tile_bingus'),
        'tile_oci':      lambda: rec_tile(port, 'oci-ubuntu', [('cat ~/.ssh/config', 2.4)], 'tile_oci'),
    }
    for name, fn in jobs.items():
        if only and name not in only:
            continue
        fn()
    httpd.shutdown()


main()
