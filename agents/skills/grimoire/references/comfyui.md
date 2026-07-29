# ComfyUI Co-tenancy

## Live Contract

| Item | Current owner |
| --- | --- |
| UI | `comfyui.service`; `/home/yeowool/comfyui`; port `8188` |
| MCP companion | `comfyui-mcp.service`; local port `9100`; Quick Tunnel |
| Models | `/home/yeowool/comfyui/models/<type>/` |
| Workflows | `/home/yeowool/comfyui/workflows/` |
| UI logs | `/var/log/comfyui/comfyui.{log,err}` |
| MCP logs | `/var/log/comfyui-mcp/comfyui-mcp.{log,err}` |

The host-local units in `/etc/systemd/system/` are authoritative. ComfyUI
binds unauthenticated `0.0.0.0:8188`; use `http://10.0.0.51:8188` on LAN and
do not expose it publicly without access control.

## Inspect First

```bash
systemctl status comfyui.service comfyui-mcp.service --no-pager
systemctl cat comfyui.service
systemctl show comfyui-mcp.service -p ActiveState -p SubState -p MainPID
ss -ltnp '( sport = :8188 or sport = :9100 )'
curl -fsS http://127.0.0.1:8188/system_stats | jq
nvidia-smi
tail -n 200 /var/log/comfyui/comfyui.err
```

Do not dump `comfyui-mcp.service` or its startup log: both contain its token.
Use `vaultwarden_secrets.get_secret({"folder":"mcp","item_name":"comfyui-mcp-token"})`.
Migrate the unit to credential loading and rotate the plaintext token.

The MCP service runs `npx -y comfyui-mcp@latest --tunnel`: its code, public
Quick Tunnel URL, and auto-managed `custom_nodes/comfyui-mcp-panel` can change
on restart. Find only the URL with:

```bash
rg 'Public MCP URL' /var/log/comfyui-mcp/comfyui-mcp.err | tail -n 1
```

Pin the package before requiring reproducibility. Never copy the token from
unit or log output.

## GPU Contract

ComfyUI's `--cuda-device 1` means physical GPU 1. Its API reports that remapped
device as `cuda:0`.

Before queueing a workflow:

1. Read the active Grimoire preset, `/status`, and `nvidia-smi`.
2. Activate a preset whose GPU mask excludes GPU 1; `single-gpu` currently
   does, but query its definition first.
3. Inspect activation `failed`/`warnings`; activation may stop running models.
4. Recheck GPU 1 before queueing.

`free` does not reserve GPU 1. Stop `comfyui.service` before giving GPU 1
back to Grimoire; a completed workflow may leave models resident.

## Models, Workflows, and Nodes

ComfyUI does not use Grimoire's `/home/yeowool/models/gguf/`. Put each model in
the matching ComfyUI type directory.

```bash
find /home/yeowool/comfyui/models -mindepth 2 -maxdepth 2 -type f -printf '%P\n' | sort
find /home/yeowool/comfyui/workflows -maxdepth 1 -type f -printf '%f\n' | sort
find /home/yeowool/comfyui/custom_nodes -mindepth 1 -maxdepth 1 -printf '%f\n' | sort
```

Treat workflows as operator data; preserve dirty/untracked content during
updates. Manager is enabled by the installed unit. Treat custom nodes as code:
review origin/revision and dependency changes, install Python packages through
`/home/yeowool/comfyui/.venv/bin/pip`, then restart and inspect the error log.
Never use system Python or `sudo pip`.

## Update or Repair

1. Capture unit state, GPU state, repository status, workflow files, and custom
   nodes.
2. Preserve dirty/untracked files.
3. Update the requested owner only: ComfyUI repo, one custom node, model files,
   workflow JSON, or host-local unit.
4. Use the existing `.venv`; after dependency changes, reinstall the relevant
   requirements.
5. For unit edits, run `systemctl daemon-reload`; start ComfyUI before its MCP
   companion.
6. Verify `/system_stats`, logs, physical GPU placement, node availability, and
   one representative workflow.

| Symptom | Check |
| --- | --- |
| UI unreachable | Unit, `ss`, `comfyui.err`, `/system_stats` |
| Wrong GPU or OOM | Unit flags, Grimoire preset/status, `nvidia-smi` |
| MCP connector dead after restart | New Quick Tunnel URL and MCP service status |
| MCP behavior changed after restart | Floating `comfyui-mcp@latest` |
| Workflow has missing nodes/models | `custom_nodes/`, model subdirectory, error log |
