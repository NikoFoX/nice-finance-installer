# nice-finance installer for Proxmox VE

One command in the Proxmox host shell sets up nice-finance in its own LXC
container. The application and its image stay private; this repository holds
only the starter script.

## Install

In the Proxmox web UI open the node's **Shell** (as root) and paste:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/NikoFoX/nice-finance-installer/main/install.sh)"
```

To run a reviewed version instead of whatever is on `main`, pin a commit SHA:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/NikoFoX/nice-finance-installer/<commit-sha>/install.sh)"
```

## Requirements

- Proxmox VE 8.x or 9.x, internet access, a DHCP server on `vmbr0`.
- A GitHub personal access token (classic) with **only** the `read:packages`
  scope and an expiry date. Never give it the `repo` scope. The script asks for
  it with hidden input and passes it only on stdin to `docker login`.

## What it does

- Asks for the container ID, CPU cores (2), RAM (2048 MB) and disk (12 GB), and
  for the storage when the host has more than one; confirms before creating.
- Creates an unprivileged Debian container (newest `debian-*-standard`
  template): hostname `nice-finance`, tag `nice-finance-installer`, nesting and
  keyctl on, start at boot, DHCP on `vmbr0`.
- Installs Docker Engine with the compose plugin (Docker's apt repository),
  avahi, skopeo and jq in it.
- Logs in to `ghcr.io`, copies the release files out of the newest `vX.Y.Z`
  image to `/opt/nice-finance` and runs the installer shipped in the image. It
  asks for the optional keys (OpenRouter, Enable Banking) and the admin account.
- Ends with both addresses: `https://nice-finance.local` and
  `https://<container IP>`.

Running the command again is safe: an installed container gets `update`, a
stopped install continues (the existing `.env` is kept), and anything unclear
(an untagged container named `nice-finance`, several tagged ones) stops without
changes.

## Update

In the container (`pct enter <ID>`), or by running the install command again:

```bash
update            # newest version
update v1.2.3     # a given version
```

`update` backs up the database first and returns to the previous version when
the new one does not start.

## Backup

Add a job in **Datacenter → Backup** for the container, mode **snapshot**. The
backup holds `.env`, the Enable Banking key and the GitHub token: with Proxmox
Backup Server, turn on encryption.
