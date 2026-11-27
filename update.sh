#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

base=/opt/dementia
bundle=$base/bundle
state=$base/state
[[ $EUID -eq 0 && -s $state/agent.conf && -d $bundle ]] || exit 1
if [[ ${1:-} != --snapshot && ${1:-} != --register-only ]]; then
    snapshot=$(mktemp "$base/updater.XXXXXXXX")
    trap 'rm -f "$snapshot"' EXIT
    cp "$0" "$snapshot"
    /bin/bash "$snapshot" --snapshot
    exit
fi
register_timer() {
    cat >/etc/systemd/system/dementia-node-update.service <<'SERVICE'
[Unit]
Description=Update dementia node
Wants=network-online.target docker.service
After=network-online.target docker.service

[Service]
Type=oneshot
ExecStart=/bin/bash /opt/dementia/bundle/update.sh
TimeoutStartSec=20min
SERVICE
    cat >/etc/systemd/system/dementia-node-update.timer <<'TIMER'
[Unit]
Description=Check for dementia node updates

[Timer]
OnBootSec=10min
OnUnitActiveSec=12h
RandomizedDelaySec=1h
Persistent=true
Unit=dementia-node-update.service

[Install]
WantedBy=timers.target
TIMER
    systemctl daemon-reload
    systemctl enable --now dementia-node-update.timer
}

if [[ ${1:-} == --register-only ]]; then
    register_timer
    exit 0
fi

exec 8>/run/lock/dementia-node.lock
flock -n 8 || exit 75
exec 9>"$base/install.lock"
flock -n 9 || exit 75

release_json=$(curl --proto '=https' --fail --silent --show-error --location \
    --connect-timeout 10 --max-time 30 \
    https://api.github.com/repos/dementia-panel/node/releases/latest)
tag=$(printf '%s' "$release_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')
[[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
if [[ -f $bundle/release-tag && $(cat "$bundle/release-tag") == "$tag" ]]; then
    if [[ ! -f /etc/systemd/system/dementia-node-update.timer ]]; then
        register_timer
    fi
    exit 0
fi

stage=$(mktemp -d "$base/update.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/new" "$stage/old"
url="https://raw.githubusercontent.com/dementia-panel/node/$tag"
for file in compose.yaml Dockerfile entrypoint.sh sync.py update.sh; do
    curl --proto '=https' --fail --silent --show-error --location \
        --connect-timeout 10 --max-time 60 --retry 2 \
        "$url/$file" -o "$stage/new/$file"
    test -s "$stage/new/$file"
done
cp -a "$bundle/." "$stage/old/"
printf '%s\n' "$tag" >"$stage/new/release-tag"

rollback() {
    for file in compose.yaml Dockerfile entrypoint.sh sync.py update.sh release-tag; do
        rm -f "$bundle/$file"
    done
    cp -a "$stage/old/." "$bundle/"
    cd "$bundle"
    docker compose build && docker compose up -d --no-build --wait --wait-timeout 90 || true
}
trap 'rollback; exit 1' ERR
cp -a "$stage/new/." "$bundle/"
cd "$bundle"
docker compose build
docker compose up -d --no-build --wait --wait-timeout 90
register_timer
printf '%s\n' "$tag" >"$state/release-tag"
trap - ERR
