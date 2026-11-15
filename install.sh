#!/usr/bin/env bash
set -euo pipefail
umask 077
exec 3>&1 4>&2
exec >>/var/log/dementia-install.log 2>&1

stage() {
    printf 'dementia-stage:%s\n' "$1" >&4
}
stage requirements

if (( EUID != 0 )); then
    echo "Installer must run as root"
    exit 1
fi

. /etc/os-release
case "$ID" in
    ubuntu) codename=${UBUNTU_CODENAME:-${VERSION_CODENAME:-}} ;;
    debian) codename=${VERSION_CODENAME:-} ;;
    *) echo "Unsupported OS: $ID (expected Ubuntu or Debian)"; exit 1 ;;
esac
[[ $codename =~ ^[a-z][a-z0-9-]*$ ]]
test -d /run/systemd/system
test -c /dev/net/tun

IFS= read -r panel_url
IFS= read -r node_id
IFS= read -r token
IFS= read -r port
node_name=
IFS= read -r node_name || true
[[ $panel_url == https://* && $node_id =~ ^[0-9a-f-]{36}$ && $token =~ ^[A-Za-z0-9_-]{43}$ ]]
[[ $port =~ ^[0-9]{1,5}$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 ))

base=/opt/dementia
# Preserve keys from installations created before the Dementia rename.
for legacy_base in /opt/amnezia-panel /opt/relay; do
    if [[ -d "$legacy_base" && ! -e "$base" ]]; then
        echo "Legacy node installation detected. Migrate its state before installing dementia."
        exit 1
    fi
done
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec 8>/run/lock/dementia-node.lock
flock -n 8
install -d -m 0700 "$base" "$base/state"
exec 9>"$base/install.lock"
flock -n 9

if [[ -f "$base/node-id" && $(cat "$base/node-id") != "$node_id" ]]; then
    echo "This machine already belongs to another node"
    exit 1
fi
if [[ -f "$base/awgp0.conf" ]]; then
    echo "Existing systemd installation detected. Migrate its keys and state before installing the container."
    exit 1
fi

printf '%s\n' "$node_id" > "$base/node-id"
stage docker
if ! command -v docker >/dev/null ||
   ! docker compose version >/dev/null 2>&1 ||
   ! docker buildx version >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    packages=(docker-buildx-plugin docker-compose-plugin)
    if ! command -v docker >/dev/null; then
        packages+=(docker-ce docker-ce-cli containerd.io)
    fi
    needs_repo=false
    for package in "${packages[@]}"; do
        if ! apt-cache show "$package" >/dev/null 2>&1; then
            needs_repo=true
            break
        fi
    done
    if "$needs_repo"; then
        apt-get install -y ca-certificates curl
        install -d -m 0755 /etc/apt/keyrings
        curl --proto '=https' --fail --silent --show-error --location --connect-timeout 10 --max-time 60 \
            "https://download.docker.com/linux/$ID/gpg" -o /etc/apt/keyrings/dementia-docker.asc
        chmod 0644 /etc/apt/keyrings/dementia-docker.asc
        cat > /etc/apt/sources.list.d/dementia-docker.sources <<REPO
Types: deb
URIs: https://download.docker.com/linux/$ID
Suites: $codename
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/dementia-docker.asc
REPO
        apt-get update
    fi
    apt-get install -y "${packages[@]}"
fi

# Provision the local Engine even if the SSH account has a custom Docker context.
unset DOCKER_CONTEXT DOCKER_HOST VPN_PORT COMPOSE_PROJECT_NAME COMPOSE_FILE
systemctl enable --now docker
docker info >/dev/null

install -d -m 0700 "$base/bundle"
for file in compose.yaml Dockerfile entrypoint.sh sync.py; do
    install -m 0600 "$source_dir/$file" "$base/bundle/$file"
done
printf '%s\n' "$node_id" > "$base/node-id"
printf 'VPN_PORT=%s\n' "$port" > "$base/bundle/.env"

# Build before replacing the agent credential so a failed build leaves the active node intact.
cd "$base/bundle"
stage build
docker compose build
printf '%s\n%s\n%s\n' "$panel_url" "$node_id" "$token" > "$base/state/agent.conf.tmp"
mv "$base/state/agent.conf.tmp" "$base/state/agent.conf"
printf '%s\n' "$node_name" > "$base/state/node-name.tmp"
mv "$base/state/node-name.tmp" "$base/state/node-name"
stage start
if ! docker compose up -d --no-build --wait --wait-timeout 60; then
    docker compose ps -a
    docker compose logs --tail=60 node
    exit 1
fi
stage verify

docker compose exec -T node awg show awgp0 public-key >&3
awk '$1 == "HeaderProtectionKey" {print $3}' "$base/state/awgp0.conf" >&3
