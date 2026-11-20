#!/usr/bin/env bash
# nice-finance installer for Proxmox VE 8.x / 9.x. Run as root in the host shell:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/NikoFoX/nice-finance-installer/main/install.sh)"
#
# A new install creates an unprivileged Debian container (tag
# nice-finance-installer, hostname nice-finance), installs Docker, avahi and
# skopeo in it, logs in to ghcr.io, copies the release files out of the newest
# vX.Y.Z image to /opt/nice-finance and runs nf-install.sh from there. The
# install and update logic ships in the image; this file only prepares the
# container.
#
# Run again:
#   - the tagged container has /usr/local/bin/update -> runs `update` in it;
#   - the tagged container has no `update` (an install stopped halfway) ->
#     finishes the missing steps and reruns nf-install.sh (it keeps .env);
#   - several tagged containers, or an untagged one named nice-finance -> stops
#     without changes.
#
# The GHCR token is read with `read -s` and goes only on stdin to
# `docker login --password-stdin` in the container. Commands in the container
# get an explicit environment (HOME=/root), none of the host's.
# Everything runs from main, called on the last line: a partly downloaded
# file does nothing.
set -euo pipefail
shopt -s inherit_errexit

readonly CT_TAG=nice-finance-installer
# Fixed: nice-finance.local (avahi) is the name in the Caddyfile and in the
# Enable Banking callback.
readonly CT_HOSTNAME=nice-finance
readonly IMAGE=ghcr.io/nikofox/nice-finance
readonly REGISTRY=ghcr.io
readonly REGISTRY_USER=nikofox
readonly APP_DIR=/opt/nice-finance
readonly PROJECT=nice-finance-release
readonly UPDATE_CMD=/usr/local/bin/update
readonly HOST_LOCK=/run/lock/nice-finance-installer.lock
readonly CT_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
readonly VERSION_RE='^v[0-9]+\.[0-9]+\.[0-9]+$'
# stderr of skopeo that means a rejected token (the same as in nf-lib.sh).
readonly AUTH_ERROR_RE='unauthorized|authentication required|denied|invalid username/password'
readonly NETWORK_TRIES=30

# Runs in the container as root. Idempotent: a resumed install repeats it.
# avahi-daemon's rlimit-nproc=3 stops it in an unprivileged container.
# shellcheck disable=SC2016  # expanded by bash in the container
readonly PROVISION_SCRIPT='
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
if type -P docker skopeo jq curl avahi-daemon >/dev/null && docker compose version >/dev/null 2>&1; then
  echo "Docker, avahi, skopeo and jq are already installed." >&2
else
  apt-get update -q
  apt-get install -y -q ca-certificates curl gnupg avahi-daemon skopeo jq
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $VERSION_CODENAME stable" \
    >/etc/apt/sources.list.d/docker.list
  apt-get update -q
  apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
if grep -q "^rlimit-nproc=" /etc/avahi/avahi-daemon.conf; then
  sed -i "s/^rlimit-nproc=/#rlimit-nproc=/" /etc/avahi/avahi-daemon.conf
  systemctl restart avahi-daemon || true
fi
systemctl enable --now docker
systemctl enable --now avahi-daemon || true
systemctl is-active -q avahi-daemon \
  || echo "avahi-daemon is not running: nice-finance.local will not resolve; the IP address still works." >&2
docker info >/dev/null \
  || { echo "Docker does not start in the container (see: journalctl -u docker)." >&2; exit 1; }
'

# Runs in the container: copies deploy/release/* and scripts/lib.sh out of the
# image into $2. nf-install.sh moves in last: its presence means a full copy.
# shellcheck disable=SC2016  # expanded by bash in the container
readonly EXTRACT_SCRIPT='
set -euo pipefail
image=$1 dir=$2
mkdir -p "$dir"
tmp=$(mktemp -d "$dir/.extract.XXXXXX")
cid=$(docker create "$image")
cleanup() { docker rm "$cid" >/dev/null; rm -rf -- "$tmp"; }
trap cleanup EXIT
docker cp "$cid:/app/deploy/release/." "$tmp/"
docker cp "$cid:/app/scripts/lib.sh" "$tmp/lib.sh"
for f in "$tmp"/*; do
  [[ ${f##*/} == nf-install.sh ]] || mv -f -- "$f" "$dir/"
done
mv -f -- "$tmp/nf-install.sh" "$dir/"
'

ctid=""

die() {
  echo "$*" >&2
  exit 1
}

# ct_run <command…>: non-interactive command in the container, stdin passed on.
ct_run() {
  pct exec "$ctid" -- env -i HOME=/root PATH="$CT_PATH" LANG=C.UTF-8 "$@"
}

ct_exec() {
  ct_run "$@" </dev/null
}

# ct_attach <command…>: interactive command in the container (prompts, terminal).
ct_attach() {
  lxc-attach -n "$ctid" --clear-env --set-var HOME=/root --set-var "TERM=${TERM:-xterm}" \
    --set-var "PATH=$CT_PATH" --set-var LANG=C.UTF-8 -- "$@"
}

check_host() {
  local version
  (($(id -u) == 0)) || die "Run this as root in the Proxmox VE host shell."
  command -v pct >/dev/null || die "No pct here: run this in the Proxmox VE host shell, not in a container."
  version=$(pveversion)
  [[ $version =~ ^pve-manager/(8|9)\. ]] || die "Proxmox VE 8.x or 9.x needed; this host has: $version"
}

take_lock() {
  exec 8>"$HOST_LOCK"
  flock -n 8 || die "Another nice-finance installer is running on this host (lock $HOST_LOCK). Try again when it ends."
}

# Sets ctid to the tagged container, or leaves it empty when there is none.
# Stops when the choice is not clear.
find_installer_ct() {
  local id conf tagged=() named=()
  while read -r id _; do
    [[ $id =~ ^[0-9]+$ ]] || continue
    conf=$(pct config "$id")
    if grep -Eq "^tags: (.*;)?$CT_TAG(;|$)" <<<"$conf"; then
      tagged+=("$id")
    elif grep -qx "hostname: $CT_HOSTNAME" <<<"$conf"; then
      named+=("$id")
    fi
  done < <(pct list)
  if ((${#tagged[@]} > 1)); then
    die "Several containers have the tag $CT_TAG (${tagged[*]}); remove the tag from all but one and run again. Nothing changed."
  fi
  if ((${#tagged[@]} == 1)); then
    ctid=${tagged[0]}
    return 0
  fi
  if ((${#named[@]})); then
    die "Container ${named[*]} is named $CT_HOSTNAME but was not made by this installer (no tag $CT_TAG). Nothing changed; see SETUP_GUIDE.md for a manual install."
  fi
}

start_ct() {
  if [[ $(pct status "$ctid") != "status: running" ]]; then
    echo "Starting container $ctid ..." >&2
    pct start "$ctid"
  fi
  local try
  for ((try = 1; try <= NETWORK_TRIES; try++)); do
    if ct_exec getent hosts deb.debian.org >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  die "Container $ctid has no network (no DHCP lease or DNS on vmbr0?). Check it with: pct enter $ctid"
}

# ask_number <prompt> <default>: prints a positive integer.
ask_number() {
  local answer
  while true; do
    read -rp "$1 [$2]: " answer || true
    answer=${answer:-$2}
    if [[ $answer =~ ^[1-9][0-9]*$ ]]; then
      printf '%s' "$answer"
      return 0
    fi
    echo "Enter a whole number." >&2
  done
}

ask_vmid() {
  local next answer
  next=$(pvesh get /cluster/nextid)
  while true; do
    read -rp "Container ID [$next]: " answer || true
    answer=${answer:-$next}
    # nextid with --vmid fails when the ID is taken.
    if [[ $answer =~ ^[1-9][0-9]*$ ]] && pvesh get /cluster/nextid --vmid "$answer" >/dev/null 2>&1; then
      printf '%s' "$answer"
      return 0
    fi
    echo "ID $answer is not valid or already used." >&2
  done
}

# choose_storage <content> <preferred> <what>: prints an active storage for
# the content type. One -> no question; several -> a list and a prompt.
choose_storage() {
  local content=$1 preferred=$2 what=$3 name status avail answer i
  local names=() free=()
  while read -r name _ status _ _ avail _; do
    [[ $status == active ]] || continue
    names+=("$name")
    free+=("$avail")
  done < <(pvesm status -content "$content" | tail -n +2)
  ((${#names[@]})) || die "No active storage for $what (content $content) on this host. Nothing created."
  if ((${#names[@]} == 1)); then
    echo "Storage for $what: ${names[0]}" >&2
    printf '%s' "${names[0]}"
    return 0
  fi
  local default=${names[0]}
  for name in "${names[@]}"; do
    [[ $name == "$preferred" ]] && default=$name
  done
  echo "Storages for $what:" >&2
  for i in "${!names[@]}"; do
    printf '  %-20s %s GB free\n' "${names[i]}" "$((free[i] / 1024 / 1024))" >&2
  done
  while true; do
    read -rp "Storage for $what [$default]: " answer || true
    answer=${answer:-$default}
    for name in "${names[@]}"; do
      if [[ $name == "$answer" ]]; then
        printf '%s' "$answer"
        return 0
      fi
    done
    echo "No storage $answer in the list." >&2
  done
}

# Prints the newest debian-N-standard template name.
newest_template() {
  local name newest
  pveam update >&2 || die "pveam update failed (no internet on the host?)."
  newest=$(pveam available --section system | while read -r _ name; do
    if [[ $name =~ ^debian-[0-9]+-standard_ ]]; then
      printf '%s\n' "$name"
    fi
  done | sort -V | tail -n 1)
  [[ -n $newest ]] || die "No debian-*-standard template in pveam available."
  printf '%s' "$newest"
}

create_ct() {
  local vmid cores memory disk rootfs_st tmpl_st template answer
  vmid=$(ask_vmid)
  cores=$(ask_number "CPU cores" 2)
  memory=$(ask_number "RAM in MB" 2048)
  disk=$(ask_number "Disk in GB" 12)
  rootfs_st=$(choose_storage rootdir local-lvm "the container disk")
  tmpl_st=$(choose_storage vztmpl local "the Debian template")
  template=$(newest_template)
  cat >&2 <<EOF

New container:
  ID $vmid, hostname $CT_HOSTNAME, tag $CT_TAG
  $cores cores, $memory MB RAM, $disk GB disk on $rootfs_st
  template $template (from $tmpl_st), unprivileged, nesting and keyctl, start at boot
  network: DHCP on vmbr0
EOF
  read -rp "Create it? [Y/n]: " answer || true
  [[ ! $answer =~ ^[Nn] ]] || die "Nothing created."
  if ! pveam list "$tmpl_st" | grep -qF -- "$tmpl_st:vztmpl/$template"; then
    pveam download "$tmpl_st" "$template" >&2
  fi
  pct create "$vmid" "$tmpl_st:vztmpl/$template" \
    --hostname "$CT_HOSTNAME" --tags "$CT_TAG" \
    --cores "$cores" --memory "$memory" --rootfs "$rootfs_st:$disk" \
    --unprivileged 1 --features nesting=1,keyctl=1 --onboot 1 \
    --net0 name=eth0,bridge=vmbr0,ip=dhcp >&2
  ctid=$vmid
}

prompt_login() {
  local token attempt
  echo "GitHub token for $REGISTRY: classic, only the read:packages scope, with an expiry date (never repo)." >&2
  for attempt in 1 2 3; do
    IFS= read -rsp "Token (input hidden): " token || true
    echo >&2
    if [[ -n $token ]] \
      && printf '%s\n' "$token" | ct_run docker login "$REGISTRY" -u "$REGISTRY_USER" --password-stdin >&2; then
      unset token
      return 0
    fi
    echo "Login to $REGISTRY failed (attempt $attempt of 3)." >&2
  done
  die "No working token. Run the same command again to continue."
}

ensure_login() {
  if ! ct_exec grep -qs "\"$REGISTRY\"" /root/.docker/config.json; then
    prompt_login
  fi
}

# Prints the highest vX.Y.Z tag. A rejected token -> a new prompt.
latest_tag() {
  local err json attempt latest tag
  err=$(mktemp)
  for attempt in 1 2 3; do
    if json=$(ct_exec skopeo list-tags "docker://$IMAGE" 2>"$err"); then
      break
    fi
    cat -- "$err" >&2
    if ! grep -qiE -- "$AUTH_ERROR_RE" "$err"; then
      rm -f -- "$err"
      die "Could not list the tags of $IMAGE (error above)."
    fi
    if ((attempt == 3)); then
      rm -f -- "$err"
      die "$REGISTRY still rejects the token. Run the same command again to continue."
    fi
    echo "$REGISTRY rejected the token (expired, revoked or without read:packages)." >&2
    prompt_login
  done
  rm -f -- "$err"
  # jq runs in the container (installed by PROVISION_SCRIPT), as in nf-lib.sh.
  # shellcheck disable=SC2016  # $re is a jq variable
  latest=$(ct_run jq -r --arg re "$VERSION_RE" '.Tags[] | select(test($re))' <<<"$json" | sort -V | tail -n 1)
  [[ -n $latest ]] || die "No vX.Y.Z tag in $IMAGE."
  printf '%s' "$latest"
}

copy_release_files() {
  local tag
  tag=$(latest_tag)
  echo "Pulling $IMAGE:$tag ..." >&2
  ct_exec docker pull -q "$IMAGE:$tag" >&2
  ct_exec bash -c "$EXTRACT_SCRIPT" bash "$IMAGE:$tag" "$APP_DIR"
}

install_in_ct() {
  echo "Installing Docker, avahi, skopeo and jq in container $ctid ..." >&2
  ct_exec bash -c "$PROVISION_SCRIPT" \
    || die "Preparing container $ctid failed (see above). Run the same command again to continue, or: pct enter $ctid"
  ensure_login
  if ! ct_exec test -f "$APP_DIR/nf-install.sh"; then
    copy_release_files
  fi
  ct_attach bash "$APP_DIR/nf-install.sh" "$APP_DIR" "$PROJECT" \
    || die "nf-install stopped (see above). Run the same command again to continue, or open a shell with: pct enter $ctid"
}

final_message() {
  local addr ip="" mac
  for addr in $(ct_exec hostname -I); do
    if [[ $addr =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      ip=$addr
      break
    fi
  done
  mac=$(pct config "$ctid" | sed -n 's/^net0:.*hwaddr=\([0-9A-Fa-f:]*\).*/\1/p')
  cat >&2 <<EOF

nice-finance is running in container $ctid. Open:
  https://nice-finance.local   (devices with mDNS: most phones and laptops)
  https://${ip:-<IP of the container>}$([[ -n $ip ]] || printf '   (see: pct exec %s -- hostname -I)' "$ctid")

- The IP comes from DHCP and can change: reserve it in your router${mac:+ for MAC $mac}.
- Connect the bank (Enable Banking) only under https://nice-finance.local: the
  callback goes to that name and the login cookie is per address.
- The browser warns about the certificate (Caddy's own CA, not handed out);
  accept the warning once per device.
- Backups: Datacenter -> Backup -> Add, container $ctid, mode snapshot. With
  Proxmox Backup Server turn on encryption: the backup holds .env, the Enable
  Banking key and the GitHub token.
- Update later: run this command again on the host, or in the container
  (pct enter $ctid): update   (or: update vX.Y.Z)
EOF
}

main() {
  check_host
  take_lock
  find_installer_ct
  if [[ -n $ctid ]]; then
    start_ct
    if ct_exec test -x "$UPDATE_CMD"; then
      echo "nice-finance is installed in container $ctid; running update." >&2
      ct_attach "$UPDATE_CMD" \
        || die "update failed (see above). Shell in the container: pct enter $ctid"
      return 0
    fi
    echo "Container $ctid has no $UPDATE_CMD: continuing the stopped install." >&2
  else
    create_ct
    start_ct
  fi
  install_in_ct
  final_message
}

main "$@"
