---
name: fleet
description: "Fleet topology — machines, hosts, roles, SSH aliases, Tailscale hostnames, and services running on each. Load this whenever the user mentions a host by name (bingus, grimoire, yeowoolmac, oci-ubuntu), asks about the fleet, wants to run something on a remote machine, or when SSH/remote operations are needed."
argument-hint: "Host name (e.g. bingus, grimoire) or fleet question"
tags: [fleet, ssh, remote, hosts, infrastructure]
audience: fleet
---

# FLEET

Run `hostname` to see which machine you're on. All machines reach each other
over SSH without a password (keys via `ssh-import-id gh:LPFchan`). Topology:
Cloudflare DNS → 10.0.0.0/24 → Tailscale subnet. Every machine runs
LPFchan/setup (`setup`, `ai-menu`, `resume`, `backup`, …) with config synced.
All machines except `bingus` auto-launch tmux and ai-menu by default. Press Esc
to dismiss ai-menu.

When accessing a remote machine, use the `main` tmux session. Do not open a new
separate tmux session. This allows the operator to see and interact with the
terminal, such as entering an admin password manually.

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
- OpenAI-compatible API at https://chat.lost.plus/v1
- custom llama.cpp fork (repo ~/grimoire); more in Obsidian `inference/`
- ComfyUI image-gen server (:8188)
- hosts hermes agent (@neoyeowoolbot on Telegram)
- hosts eastself (@eastself_bot on Telegram, repo ~/Eastself/)

## yeowoolmac — Mac mini (M4 Pro, 24 GB unified)
- mac.lost.plus (10.0.0.52) · user yeowool
- for sophisticated computer-use tasks: summon codex agent here

## oci-ubuntu — always-free Oracle Cloud VPS
- oci.lost.plus · user ubuntu
- MCP servers run here: obsidian/marble, joongna-price-search, tweet-fetch,
  thinqconnect, vaultwarden, comfyui-mcp
