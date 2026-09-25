---
name: ship
description: "Take one of the operator's apps or services public: a macOS app gets an icon, 28-language UI, Sparkle self-updates, a stable self-signed certificate, a tag-driven DMG release on GitHub, and a <app>.lost.plus homepage + update feed; a web service gets its lost.plus hostname and registry entry. Use when asked to ship, release, deploy, make something ready for general availability / the public, or cut a first version."
argument-hint: "The app or service, and what's missing (icon, i18n, updates, release, site)"
tags: [release, deploy, macos, sparkle, dmg, i18n, github-pages, lost.plus]
audience: fleet
---

# Ship

Copy a working sibling instead of designing from scratch. The reference
implementations, all on the same pipeline:

| Repo | Build system | Notes |
| --- | --- | --- |
| `LPFchan/Threek` | XcodeGen + `xcodebuild` | menu bar app, bundled helper framework |
| `LPFchan/parakeet` | SwiftPM, hand-assembled bundle | menu bar app, onboarding window |
| `LPFchan/Markfops` | XcodeGen, `xcodebuild archive` | document app, older ad-hoc-signed variant |

Their `scripts/`, `Packaging/`, `docs/` and `.github/workflows/release.yml`
are the templates: copy, rename the app, keep the comments.

A web service instead? Ship it with the [lost-plus](../lost-plus/SKILL.md)
skill (gateway, Common Auth, registry). Only the "Domain" and "Registry" steps
below apply.

## Decisions for the operator

Ask these once; everything else is mechanical.

- Icon direction. Render 2-3 variants side by side and let them pick.
- First version number (the last app picked `1.0.0` for the first public
  release).
- Anything that changes what the user sees on first launch.

Signing is settled: a stable **self-signed** certificate, not Developer ID.
Users click Open Anyway once; the stable certificate keeps TCC grants
(Accessibility, audio capture) across Sparkle updates. Distribution is
settled too: a DMG made with DMGMaker, on GitHub Releases, updated by Sparkle.

## macOS app

1. **Icon.** `scripts/make-icon.swift` draws it in code on the macOS grid
   (824-pt squircle on a 1024-pt canvas, drop shadow) and writes every size.
   Draw glyphs by hand: Apple's license forbids SF Symbols in app icons. Merge
   overlapping shapes with `CGPath.union` so fills don't leave seams.
2. **Localization.** String catalogs (`Localizable.xcstrings`,
   `InfoPlist.xcstrings` for permission prompts) in the same 28 languages as
   Parakeet: ar bg cs da de es et fi fr hi hr hu it ja ko nb nl pl pt-BR
   pt-PT ro ru sk sv tr uk vi zh-Hans. Reuse existing translations for shared
   strings ("Open at Login", "Check for Updates…", "Quit X") from a sibling's
   catalog. AppKit menu titles need `String(localized:)`. English has no
   `.lproj`, so list `CFBundleLocalizations` (XcodeGen) or create an empty
   `en.lproj` (hand-built bundle), or macOS won't count English as supported.
3. **Sparkle.** SPM package, `SPUStandardUpdaterController`, a "Check for
   Updates…" item, a check on every launch, and the user-driver delegate that
   brings found updates to the front (menu bar apps are never active; mark the
   conformance `@preconcurrency`). `SUFeedURL` is
   `https://<app>.lost.plus/appcast.xml`. Generate the key with
   `generate_keys --account <app>` and put `SUPublicEDKey` in the plist.
4. **Certificate.** `openssl` a 10-year code-signing cert named
   "<App> Self-Signed" (`extendedKeyUsage = codeSigning`), export a `-legacy`
   .p12, import it into the login keychain with `-T /usr/bin/codesign`.
5. **Secrets.** Before deleting any temp file, store all three in passage,
   folder `sparkle`: `<app>_sparkle_private_key`,
   `<app>_signing_cert_p12_base64`, `<app>_signing_cert_password`. Then set
   the repo secrets `SPARKLE_PRIVATE_KEY`, `SIGNING_CERT_P12`,
   `SIGNING_CERT_PASSWORD` with `gh secret set` (pipe from files; never put
   values on a command line). GitHub can't show secrets again, so passage is
   the only backup.
6. **Build script.** `scripts/build-app.sh`: version = latest `v*` tag,
   build number = commit count, license notices into
   `Contents/Resources/Licenses`, sign inside out (nested frameworks and
   Sparkle's XPC services first, the app last), `codesign --verify --strict`.
   Assert that bundled helpers made it into the app.
7. **DMG.** `scripts/make-dmg.sh` clones DMGMaker `v1.0.3` and applies
   `Packaging/DMGMaker-v1.0.3.patch` (adds `--background`). The background is
   `Packaging/dmg-background.html` in the icon's colors, rendered 600×600 @2x
   by `scripts/make-dmg-background.sh`; keep decoration out of the middle band.
8. **Release workflow.** On a `v*` tag: import the cert into a temp keychain,
   build, pack, `sign_update` the DMG, `gh release create` with Open Anyway
   install notes, then `scripts/appcast.py` prepends the item to
   `docs/appcast.xml` and a bot commit pushes it to main.
9. **Homepage.** `docs/`: `index.html` (hero, download button, features,
   first-launch steps; background = icon color, check WCAG AA), `icon.png`,
   `favicon.png`, `llms.txt`, `robots.txt`, `sitemap.xml`, `CNAME`, empty
   `appcast.xml`.
10. **Docs.** README gets Download link, Install, build/release commands, and
    the secrets paragraph (what each secret does, backups in passage). Update
    the repo's truth docs (SPEC/STATUS) if it has them.

## Domain

1. **DNS first.** `CNAME <app> → lpfchan.github.io`, DNS-only (not proxied),
   via the Cloudflare API with `CF_MASTER_TOKEN` from passage folder `infra`.
   The `CLOUDFLARE_API_KEY` in the shell can't see the `lost.plus` zone.
2. **Then Pages.** `gh api -X POST repos/<o>/<r>/pages` with source
   `main` `/docs`, then `PUT … -f cname=<app>.lost.plus`. Enabling Pages
   before DNS exists leaves the HTTPS certificate stuck at none.
3. Wait for `https_certificate.state == approved`, then
   `PUT … -F https_enforced=true`. Verify `https://<app>.lost.plus/appcast.xml`
   returns 200. If the certificate never starts, clearing and re-setting the
   cname kicks it, but each toggle makes GitHub commit to `docs/CNAME` on
   main.

## Registry

Add the hostname to [lost-plus's registry](../lost-plus/references/registry.md)
in this repo, in the same change set as the launch.

## Before tagging

- Run `build-app.sh` and `make-dmg.sh` from a **fresh worktree** (no ignored
  build output), not your working checkout. The first Threek release failed
  in CI because a generated directory only existed locally. XcodeGen lists a
  directory's files at generation time, so build generated resources before
  `xcodegen generate`.
- Mount the DMG and check it holds the app and the Applications link.
- In repos that enforce `LOG-*` commits (repo-template), the workflow's bot
  commit must pass `scripts/check-commit-standards.sh`: the `agent:` value
  must equal the id suffix, at most 6 characters (Threek uses `ghbot`). Check
  it locally with a simulated message.
- If the release run fails before publishing, fix it, move the tag
  (`git tag -f`, `git push -f origin <tag>`), and let it rerun. Once a release
  is published, never move its tag; ship the next patch version instead.

## After the release

Download the DMG from the release, install it, and confirm it launches,
asks for its permissions, and Check for Updates reports it is up to date.
