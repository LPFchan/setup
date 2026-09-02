---
name: fleet
description: "Fleet topology — machines, hosts, roles, SSH aliases, Tailscale hostnames, and services running on each. Load this whenever the user mentions a host by name (eleven, bingus, grimoire, yeowoolmac, oci-ubuntu), asks about the fleet, wants to run something on a remote machine, or when SSH/remote operations are needed."
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

When requested to deploy a new web service, use cloudflare credentials from vaultwarden MCP to edit DNS records.

## NanoPi R3S LTS — OpenWrt router
- 10.0.0.1 · user root (SSH pubkey + LuCI creds in vaultwarden)
- OpenWrt 24.10.2, Rockchip SoC, ~1 GB RAM
- gateway for the 10.0.0.0/24 LAN (Cloudflare → this → Tailscale)
- persistent log at /etc/logpersist.log — procd svc /etc/init.d/logpersist, 1 MB rolling, survives reboots

## yeowoolair — daily-driver MacBook Air
- yeowool-air.tailaa113.ts.net (no static IP) · user yeowool
- active repos in ~/Documents/

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
- custom llama.cpp fork (repo ~/grimoire); load the `grimoire` skill for inference setup
- usage/telemetry dashboard at dash.lost.plus (`dash` compose service, :9002, same repo)
- hosts ComfyUI image-gen server (:8188)
- hosts eastself (@eastself_bot on Telegram, eastself.lost.plus, repo ~/Eastself/)
- hosts hermes agent (@neoyeowoolbot on Telegram)
	hermes has access to the following:
	- google cloud CLI, oracle cloud CLI
	- discord, twitter, instagram DM using Beeper Desktop Linux
	- iCloud calendar and mail
	- all credentials at vaultwarden
- hosts heatmap at heatmap.lost.plus
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
- hosts MCP servers: obsidian/marble, joongna-price-search, tweet-fetch, thinqconnect, vaultwarden, comfyui-mcp
- hosts lost.plus homepage (repo `~/lost.plus`)
- hosts Songbook at okdam.lost.plus (repo `~/okdam-songbook`)
- hosts gswtools at gsw.lost.plus (repo `~/gswtools`)
- hosts artmu-bench at artmu.lost.plus (repo `~/artmu-bench`)
- hosts censor at censor.lost.plus (repo `~/censor`)
- hosts Photopeace at photopeace.lost.plus (repo `~/photopeace`)
