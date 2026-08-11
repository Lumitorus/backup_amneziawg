#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
CONTAINER_NAME="amnezia-awg2"
IMAGE_NAME="amnezia-awg2-backup"
AWG_PORT="434"
DOCKER_SUITE=""
FORCE=0
SKIP_CHECKSUM=0
BACKUP_DIR=""

log() { printf '[AWG restore] %s\n' "$*"; }
die() { printf '[AWG restore] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS] [BACKUP_DIR]

Restore Amnezia AWG from a backup directory containing:
  awg_config.tar.gz
  amnezia_image.tar
  SHA256SUMS            (optional, but strongly recommended)

Options:
  --force                 Replace an existing container/configuration.
  --skip-checksum         Do not verify SHA256SUMS if it is present.
  --port PORT             UDP port to publish (default: 434).
  --container NAME        Container name (default: amnezia-awg2).
  --image NAME            Image name/tag after docker load
                          (default: amnezia-awg2-backup).
  --docker-suite SUITE    Docker Debian/Ubuntu repository suite override
                          (for example: bookworm, trixie, noble).
  -h, --help              Show this help.

If BACKUP_DIR is omitted, the directory containing this script is used.

Examples:
  sudo ./$SCRIPT_NAME
  sudo ./$SCRIPT_NAME /root/awg-server-2026-07-09_02-00-00
  sudo ./$SCRIPT_NAME --force --port 434 /home/admin/awg-backup
EOF
}

while (($#)); do
  case "$1" in
    --force) FORCE=1; shift ;;
    --skip-checksum) SKIP_CHECKSUM=1; shift ;;
    --port) [[ $# -ge 2 ]] || die "--port requires a value"; AWG_PORT="$2"; shift 2 ;;
    --container) [[ $# -ge 2 ]] || die "--container requires a value"; CONTAINER_NAME="$2"; shift 2 ;;
    --image) [[ $# -ge 2 ]] || die "--image requires a value"; IMAGE_NAME="$2"; shift 2 ;;
    --docker-suite) [[ $# -ge 2 ]] || die "--docker-suite requires a value"; DOCKER_SUITE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; [[ $# -le 1 ]] || die "Too many arguments"; BACKUP_DIR="${1:-}"; break ;;
    -*) die "Unknown option: $1" ;;
    *) [[ -z "$BACKUP_DIR" ]] || die "Only one backup directory may be specified"; BACKUP_DIR="$1"; shift ;;
  esac
done

[[ "$AWG_PORT" =~ ^[0-9]+$ ]] && ((AWG_PORT >= 1 && AWG_PORT <= 65535)) \
  || die "Invalid UDP port: $AWG_PORT"
[[ "$CONTAINER_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || die "Invalid container name"
[[ "$IMAGE_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_./:@-]*$ ]] || die "Invalid image name"

if ((EUID != 0)); then
  command -v sudo >/dev/null 2>&1 || die "Run this script as root (sudo is not installed)"
  log "Requesting root privileges via sudo..."
  sudo_args=(--port "$AWG_PORT" --container "$CONTAINER_NAME" --image "$IMAGE_NAME")
  ((FORCE)) && sudo_args+=(--force)
  ((SKIP_CHECKSUM)) && sudo_args+=(--skip-checksum)
  [[ -z "$DOCKER_SUITE" ]] || sudo_args+=(--docker-suite "$DOCKER_SUITE")
  [[ -z "$BACKUP_DIR" ]] || sudo_args+=("$BACKUP_DIR")
  exec sudo -- "$0" "${sudo_args[@]}"
fi

if [[ -z "$BACKUP_DIR" ]]; then
  BACKUP_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
else
  BACKUP_DIR="$(cd -- "$BACKUP_DIR" 2>/dev/null && pwd -P)" \
    || die "Backup directory does not exist: $BACKUP_DIR"
fi

CONFIG_ARCHIVE="$BACKUP_DIR/awg_config.tar.gz"
IMAGE_ARCHIVE="$BACKUP_DIR/amnezia_image.tar"
CHECKSUM_FILE="$BACKUP_DIR/SHA256SUMS"

[[ -r "$CONFIG_ARCHIVE" ]] || die "Missing or unreadable: $CONFIG_ARCHIVE"
[[ -r "$IMAGE_ARCHIVE" ]] || die "Missing or unreadable: $IMAGE_ARCHIVE"

cleanup() {
  if [[ -n "${STAGING_DIR:-}" && -d "$STAGING_DIR" ]]; then
    rm -rf -- "$STAGING_DIR"
  fi
}
on_error() {
  local rc=$?
  trap - ERR
  printf '[AWG restore] ERROR: command failed on line %s (exit %s)\n' "$1" "$rc" >&2
  exit "$rc"
}
trap cleanup EXIT
trap 'on_error "$LINENO"' ERR

verify_backup() {
  if [[ -f "$CHECKSUM_FILE" && "$SKIP_CHECKSUM" -eq 0 ]]; then
    log "Verifying backup checksums..."
    (cd -- "$BACKUP_DIR" && sha256sum --check --strict SHA256SUMS) \
      || die "Checksum verification failed; restore was stopped"
  elif [[ -f "$CHECKSUM_FILE" ]]; then
    log "WARNING: checksum verification was explicitly skipped"
  else
    log "WARNING: SHA256SUMS is absent; archive integrity cannot be verified"
  fi
}

validate_config_archive() {
  local entry
  log "Checking configuration archive paths..."
  while IFS= read -r entry; do
    entry="${entry#./}"
    [[ -z "$entry" ]] && continue
    [[ "$entry" != /* ]] || die "Archive contains an absolute path: $entry"
    [[ "/$entry/" != *"/../"* ]] || die "Archive contains an unsafe path: $entry"
    [[ "$entry" == "awg" || "$entry" == awg/* ]] \
      || die "Unexpected archive layout: '$entry' (expected top-level awg/)"
  done < <(tar -tzf "$CONFIG_ARCHIVE")
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker CLI is already installed"
    systemctl enable --now docker >/dev/null 2>&1 || true
    docker info >/dev/null 2>&1 || die "Docker is installed, but the daemon is unavailable"
    return
  fi

  [[ -r /etc/os-release ]] || die "Cannot identify the operating system"
  # shellcheck disable=SC1091
  . /etc/os-release

  local repo_os suite arch base_url
  case "${ID:-}:${ID_LIKE:-}" in
    ubuntu:*|*:ubuntu*)
      repo_os="ubuntu"
      suite="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
      ;;
    debian:*|kali:*|*:debian*)
      repo_os="debian"
      suite="${VERSION_CODENAME:-}"
      if [[ "${ID:-}" == "kali" || "$suite" == kali-* || -z "$suite" ]]; then
        suite="$(sed -E 's@/.*@@; s/[^a-z].*$//' /etc/debian_version 2>/dev/null || true)"
      fi
      ;;
    *) die "Supported systems: Debian, Ubuntu, Kali, and their apt-based derivatives" ;;
  esac
  [[ -z "$DOCKER_SUITE" ]] || suite="$DOCKER_SUITE"
  [[ -n "$suite" ]] || die "Cannot determine Docker repository suite; use --docker-suite"

  arch="$(dpkg --print-architecture)"
  base_url="https://download.docker.com/linux/$repo_os"
  log "Installing Docker Engine from $repo_os/$suite repository..."

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "$base_url/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  curl -fsSL "$base_url/dists/$suite/Release" -o /dev/null \
    || die "Docker repository has no suite '$suite'; rerun with --docker-suite SUITE"

  cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: $base_url
Suites: $suite
Components: stable
Architectures: $arch
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  # Conflicting distribution packages must be removed before Docker CE.
  local conflicts=() pkg
  for pkg in docker.io docker-compose docker-doc docker-buildx podman-docker containerd runc; do
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed' \
      && conflicts+=("$pkg") || true
  done
  ((${#conflicts[@]} == 0)) || apt-get remove -y "${conflicts[@]}"

  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  docker info >/dev/null
}

restore_config() {
  STAGING_DIR="$(mktemp -d /opt/amnezia/.awg-restore.XXXXXX)"
  tar -xzf "$CONFIG_ARCHIVE" -C "$STAGING_DIR" --no-same-owner
  [[ -d "$STAGING_DIR/awg" ]] || die "Archive did not produce the expected awg directory"

  if [[ -e /opt/amnezia/awg ]]; then
    ((FORCE)) || die "/opt/amnezia/awg already exists; use --force to preserve and replace it"
    local old_path="/opt/amnezia/awg.pre-restore.$(date +%Y%m%d-%H%M%S)"
    log "Preserving existing configuration as $old_path"
    mv -- /opt/amnezia/awg "$old_path"
  fi
  mv -- "$STAGING_DIR/awg" /opt/amnezia/awg
  chmod 700 /opt/amnezia/awg || true
  log "Configuration restored to /opt/amnezia/awg"
}

load_image() {
  log "Loading Docker image (this may take a while)..."
  docker load --input "$IMAGE_ARCHIVE"
  docker image inspect "$IMAGE_NAME" >/dev/null 2>&1 \
    || die "Loaded archive does not contain image '$IMAGE_NAME'; inspect with: docker images"
}

check_container_conflict() {
  if docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    ((FORCE)) || die "Container '$CONTAINER_NAME' already exists; use --force to replace it"
  fi
}

start_container() {
  if docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    log "Removing existing container $CONTAINER_NAME..."
    docker rm --force "$CONTAINER_NAME" >/dev/null
  fi

  log "Starting $CONTAINER_NAME on UDP port $AWG_PORT..."
  docker run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    --privileged \
    --cap-add NET_ADMIN \
    --publish "$AWG_PORT:$AWG_PORT/udp" \
    --volume /opt/amnezia/awg:/opt/amnezia/awg \
    "$IMAGE_NAME" >/dev/null

  sleep 3
  [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME")" == "true" ]] \
    || { docker logs --tail 100 "$CONTAINER_NAME" >&2 || true; die "Container failed to stay running"; }
}

log "Using backup directory: $BACKUP_DIR"
verify_backup
validate_config_archive
mkdir -p /opt/amnezia
install_docker
load_image
check_container_conflict
restore_config
start_container

log "Restore completed successfully"
docker ps --filter "name=^/${CONTAINER_NAME}$"
log "View logs with: docker logs --tail 100 $CONTAINER_NAME"
