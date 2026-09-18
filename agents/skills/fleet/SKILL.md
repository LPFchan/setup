---
name: fleet
description: "Fleet topology — machines, hosts, roles, SSH aliases, Tailscale hostnames, and services running on each. Load this whenever the user mentions a host by name (mangchi, eleven, bingus, grimoire, yeowoolmac, oci-ubuntu), asks about the fleet, wants to run something on a remote machine, or when SSH/remote operations are needed."
argument-hint: "Host name (e.g. bingus, grimoire) or fleet question"
tags: [fleet, ssh, remote, hosts, infrastructure]
audience: fleet
---

# FLEET

Run `hostname` to see which machine you're on. All machines reach each other
over SSH without a password (keys via `ssh-import-id gh:LPFchan`).

Topology: Cloudflare DNS → 10.0.0.0/24 → Tailscale subnet.

Run `sudo tailscale switch --list` to list and check what tailnet you're currently on. `lost.plus` is the default tailnet for the fleet. If you find yourself on a different tailnet and in need of connecting to any of the machines in the fleet, switch to `lost.plus` temporarily, finish the task and make sure to switch back to the initial tailnet you've started with. Every machine runs
LPFchan/setup (`setup`, `ai-menu`, `resume`, `backup`, …) with config synced.
All machines except `bingus` auto-launch tmux and ai-menu by default. Press Esc
to dismiss ai-menu.

When accessing a remote machine, use the `main` tmux session. Do not open a new
separate tmux session. This allows the operator to see and interact with the
terminal, such as entering an admin password manually.

When requested to deploy a new web service, use cloudflare credentials from the `passage` MCP (`infra/CF_MASTER_TOKEN`) to edit DNS records and Worker routes.

Most live services now run on Cloudflare Workers, not on a machine: the
Common Auth hub (`auth.lost.plus`), its cloud gateway, awa, okdam, coverse,
censor, and the tweet/joongna/bunjang/thinq MCPs. The per-service registry —
hostname, where it runs, which gateway fronts it — is the `lost-plus` skill's
`registry` reference; load that instead of guessing from this file. OCI and
Grimoire each still run a local Common Auth gateway (`auth-gateway.service`,
`127.0.0.1:8740`, config from `LPFchan/auth` `deploy/<machine>/`) for the
services that remain on that machine.

## NanoPi R3S LTS — OpenWrt router
- 10.0.0.1 · user root (SSH pubkey + LuCI creds in passage)
- OpenWrt 24.10.2, Rockchip SoC, ~1 GB RAM
- gateway for the 10.0.0.0/24 LAN (Cloudflare → this → Tailscale)
- persistent log at /etc/logpersist.log — procd svc /etc/init.d/logpersist, 1 MB rolling, survives reboots

## yeowoolair — daily-driver MacBook Air
- yeowool-air.tailaa113.ts.net (no static IP) · user yeowool
- active repos in ~/Documents/

## mangchi — NVIDIA Jetson AGX Thor (T5000)
- mangchi.lost.plus (10.0.0.53) · user yeowool
- Ubuntu 24.04 with JetPack 7.2.1 BSP; 128 GB unified memory
- preferred training and inference host

## bingus — Synology DS923+ NAS (DSM 7)
- bingus.lost.plus (10.0.0.50) · user yeowool
- renews the lost.plus Let's Encrypt cert monthly (neilpang-acme.sh)
- homebridge on homebridge.lost.plus
- Tailscale exit node + subnet advertise
- UniFi console (jacobalberty-unifi) on unifi.lost.plus
- Google Photos nightly backup (gphotos-backup)

## grimoire — headless Ubuntu dual-RTX 3090 inference server
- grimoire.lost.plus (10.0.0.51) · user yeowool
- OpenAI-compatible API at chat.lost.plus/v1
- inference gateway repo `~/inference`; load the `inference` skill for Grimoire and Mangchi serving
- usage/telemetry dashboard at dash.lost.plus (`dash` compose service, :9002, same repo)
- hosts ComfyUI image-gen server (:8188)
- hosts eastself (@eastself_bot on Telegram, eastself.lost.plus, repo ~/Eastself/)
- hosts hermes agent (@neoyeowoolbot on Telegram)
	hermes has access to the following:
	- google cloud CLI, oracle cloud CLI
	- discord, twitter, instagram DM using Beeper Desktop Linux
	- iCloud calendar and mail
	- all credentials in passage
- hosts heatmap at heatmap.lost.plus
- hosts Muum at muum.lost.plus (repo ~/muum), behind the local gateway
- fronts the ComfyUI MCP for comfy.lost.plus behind the local gateway (ingress is the OCI tunnel → Grimoire Tailscale Serve)
- second RTX 3090 currently vacant due to board-level repair work

## yeowoolmac — Mac mini (M4 Pro, 24 GB unified)
- mac.lost.plus (10.0.0.52) · user yeowool
- for sophisticated computer-use tasks: summon codex agent here
- two partitions: `audio work` and `the rest`. ssh and parsec through mac.lost.plus  should resolve for both partitions, regardless of the logged in status.
- switch partitions with `mac-boot status`, `mac-boot 'The Rest'`, or `mac-boot 'Audio Work'`. Switching is passwordless, requests a normal application-aware restart, and guarantees reboot after 60 seconds if anything blocks it.

## eleven — Fedora 44 laptop (Intel i5-5250U, 8 GB)
- eleven.tailaa113.ts.net (no static IP) · user yeowool

## oci-ubuntu — always-free Oracle Cloud VPS
- oci.lost.plus · user ubuntu
- runs the `obsidian-sync` Cloudflare tunnel (`/etc/cloudflared/config.yml`) and the local Common Auth gateway (`auth-gateway.service`)
- behind the local gateway: obsidian MCP at mcp.lost.plus (repo `~/mcp`), passage MCP at passage.lost.plus (`~/passage-mcp`), onedrive MCP at onedrive.lost.plus (`~/onedrive-mcp`), Marble at marble.lost.plus (`~/Marble`)
- direct (no gateway): lost.plus homepage (`~/lost.plus`), artmu-bench at artmu.lost.plus (`~/artmu-bench-site`), Photopeace at photopeace.lost.plus (`~/photopeace`), upstream tracker at upstream.lost.plus (`~/upstream`)
- checkouts of the Workers-hosted repos (`~/auth`, `~/agent-with-agent`, `~/okdam-songbook`, `~/coverse`, `~/censor`, `~/tweet-fetch-mcp`, `~/joongna-mcp`, `~/bunjang-mcp`, `~/thinqconnect-mcp`) live here as deploy sources; nothing from them runs on this box any more
