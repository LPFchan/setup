---
name: oci-cli
description: "Operate Oracle Cloud with oci CLI using passage-held credentials."
tags: [oci, oracle, cloud, credentials, passage]
audience: fleet
---

# OCI-CLI

Operate the yeowool Oracle Cloud tenancy (home region `ap-chuncheon-1`, the
`oci-ubuntu` always-free VPS) through the `oci` CLI. All credentials live in
the **passage** MCP (the renamed vaultwarden-secrets MCP) — never in a repo,
a chat message, or a committed file.

## When to Use

- Asked to touch OCI: compute instances, Object Storage, DNS, IAM, the
  oci-ubuntu host itself.
- `oci` fails with a config/signing error and `~/.oci` is missing or stale.
- Don't use for: hosts listed in the `fleet` skill (SSH there instead);
  billing/quota questions (console-only).

## Prerequisites

- `oci --version` works. If missing, install with
  `pipx install oci-cli` (fleet python-install rules: pipx for global tools,
  never system pip).
- passage MCP reachable (source `mcp-passage`). If it is locked or absent,
  stop and ask the operator — do not fabricate a config.

## Credentials (passage, folder `infra`)

| item_name | feeds |
| --- | --- |
| `oci_user_ocid` | config `user` |
| `oci_tenancy_ocid` | config `tenancy` |
| `oci_region` | config `region` (currently `ap-chuncheon-1`) |
| `oci_api_fingerprint` | config `fingerprint` |
| `oci_api_key_pem` | `~/.oci/oci_api_key.pem` |

Related items in the same folder: `oci_console_ssh_key` (SSH to instances via
the console).

## Procedure

1. If `~/.oci/config` already exists, use it; only bootstrap when it is
   missing or `oci` fails with a signing/auth error.
2. Fetch the five items with `mcp__passage__get_secret`
   (`folder: infra`). Write the PEM to `~/.oci/oci_api_key.pem`,
   `chmod 600`. Write `~/.oci/config`:
   ```ini
   [DEFAULT]
   user=<oci_user_ocid>
   fingerprint=<oci_api_fingerprint>
   tenancy=<oci_tenancy_ocid>
   region=<oci_region>
   key_file=~/.oci/oci_api_key.pem
   ```
3. Verify: `SUPPRESS_LABEL_WARNING=True oci iam region list` — region rows
   are the pass criterion. `oci os ns get` returns the namespace.
4. Rotate only on operator request: generate the new key pair, update
   `oci_api_key_pem` and `oci_api_fingerprint` in passage with
   `mcp__passage__add_secret` (same folder, same names), then re-bootstrap.

## Pitfalls

- The CLI prints an `OCI_API_KEY` label warning on every call — harmless.
  Suppress with `SUPPRESS_LABEL_WARNING=True`; never "fix" it by editing the
  key file.
- Never echo secret values (PEM, fingerprint) into replies, logs, or commits.
  OCIDs and region are identifiers and fine to show.
- Several fleet hosts already have a working `~/.oci` — bootstrap only what
  is broken, and diff against passage if auth fails (a rotated key in
  passage beats a stale local PEM).
- The S3 compatibility API (customer secret keys) is separate from the `oci`
  CLI session — don't conflate the two. The `auth-litestream` bucket and its
  keys were deleted on 2026-09-18; the account holds no customer secret keys.
