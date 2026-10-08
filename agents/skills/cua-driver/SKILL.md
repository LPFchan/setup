---
name: cua-driver
description: "Drive a native macOS app on dumpling with Cua Driver: operate, automate or test a GUI, take screenshots, record a video of it. Load for any computer-use task on dumpling."
audience: fleet
---

# cua-driver

Cua Driver runs on dumpling only (see `fleet`); from another machine, run every `cua-driver` command over `ssh dumpling`. Fetch the canonical skill for the installed version and follow it before taking any action. Its references (MACOS.md, WORKFLOW.md, RECORDING.md, …) sit at the same URL.

```sh
v=$(cua-driver --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
curl --fail --silent --show-error "https://raw.githubusercontent.com/trycua/cua/cua-driver-rs-v$v/libs/cua-driver/rust/Skills/cua-driver/SKILL.md"
```
