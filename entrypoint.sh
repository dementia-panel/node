#!/usr/bin/env bash
set -euo pipefail
umask 077

state=/var/lib/dementia
conf=$state/awgp0.conf
interface=awgp0
rm -f /run/awg-ready
test -s "$state/agent.conf"

if [[ ! -s "$conf" ]]; then
    private=$(awg genkey)
    header=$(awg genkey)
    cat > "$conf.tmp" <<CONFIG
[Interface]
PrivateKey = $private
ListenPort = 51820
HeaderProtectionKey = $header
S1 = 32
S2 = 48
S3 = 16
S4 = 24
H1 = 14581001
H2 = 14581002
H3 = 14581003
H4 = 14581004
CONFIG
    mv "$conf.tmp" "$conf"
fi

amneziawg-go --foreground "$interface" &
vpn_pid=$!
sync_pid=
cleanup() {
    rm -f /run/awg-ready
    if [[ -n $sync_pid ]]; then
        kill "$sync_pid" 2>/dev/null || true
    fi
    kill "$vpn_pid" 2>/dev/null || true
    wait || true
}
trap cleanup EXIT
trap 'exit 0' TERM INT

for ((attempt=0; attempt<50; attempt++)); do
    if awg show "$interface" listen-port >/dev/null 2>&1; then
        break
    fi
    kill -0 "$vpn_pid"
    sleep 0.1
done
awg setconf "$interface" "$conf"
ip address replace 10.70.0.1/16 dev "$interface"
ip link set mtu 1360 up dev "$interface"

iptables -t nat -A POSTROUTING -s 10.70.0.0/16 ! -o "$interface" -j MASQUERADE
iptables -I INPUT -i "$interface" -j DROP
iptables -I FORWARD -i "$interface" -o "$interface" -j DROP
iptables -A FORWARD -i "$interface" ! -o "$interface" -j ACCEPT
iptables -A FORWARD -o "$interface" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

python3 /opt/dementia/sync.py &
sync_pid=$!
touch /run/awg-ready
wait -n "$vpn_pid" "$sync_pid"
exit 1
