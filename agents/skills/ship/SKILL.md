---
name: ship
description: "Take an app or service public. Use when asked to ship, release, or make something ready for general availability."
argument-hint: "The app or service"
tags: [release, macos, sparkle, dmg, lost.plus]
audience: fleet
---

# Ship

Web service: use [lost-plus](../lost-plus/SKILL.md). macOS app:

Ask the operator only for the icon direction and the first version number.

- Icon drawn by hand in a script (no SF Symbols in app icons).
- UI in en + ar bg cs da de es et fi fr hi hr hu it ja ko nb nl pl pt-BR
  pt-PT ro ru sk sv tr uk vi zh-Hans, via string catalogs.
- Version = the `v*` tag; build number = commit count (Sparkle compares it).
- Sparkle key per app: `generate_keys --account <app>` (without `--account`
  it reuses the shared default key).
- Stable self-signed cert "<App> Self-Signed" (keeps TCC grants across
  updates): openssl with `extendedKeyUsage = codeSigning`, exported as a
  `-legacy` .p12 (OpenSSL 3's default won't import into Keychain).
- Sign inside out, Sparkle's XPC services first. No `--options runtime`:
  without a team ID it blocks Sparkle from loading.
- Back up to passage folder `sparkle` before deleting anything:
  `<app>_sparkle_private_key`, `<app>_signing_cert_p12_base64`,
  `<app>_signing_cert_password`. CI reads repo secrets `SPARKLE_PRIVATE_KEY`,
  `SIGNING_CERT_P12`, `SIGNING_CERT_PASSWORD`.
- DMG via [DMGMaker](https://github.com/saihgupr/DMGMaker) `v1.0.3` with
  [this patch](references/DMGMaker-v1.0.3.patch) for `--background`, and a
  background in the icon's colors.
- On a `v*` tag, CI builds, signs, packs the DMG, publishes a GitHub release,
  and adds it to `docs/appcast.xml`.
- Not notarized: release notes and homepage tell users to click Open Anyway
  in System Settings → Privacy & Security.
- `docs/` on GitHub Pages is the homepage + feed at `<app>.lost.plus`. Add the
  DNS CNAME `<app>` → `lpfchan.github.io` (DNS-only, `infra/CF_MASTER_TOKEN`)
  before enabling Pages; add the hostname to the lost-plus registry.
- Before tagging, build from a fresh worktree.
