#!/usr/bin/env bash
# automation/scripts/collect-baseline.sh
# Snapshot live node configs into state/baseline/ (mirrors real fs paths)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BASELINE="$REPO_ROOT/state/baseline"

declare -A NODES=(
  [pve1]=10.10.10.2
  [pve2]=10.10.10.3
  [pve3]=10.10.10.4
)

echo "=== Collecting per-node configs ==="

for name in "${!NODES[@]}"; do
  ip="${NODES[$name]}"
  dir="$BASELINE/$name"

  echo "--- $name ($ip) ---"

  ssh root@"$ip" 'cat /etc/network/interfaces' \
    > "$dir/etc/network/interfaces"

  ssh root@"$ip" 'cat /etc/resolv.conf' \
    > "$dir/etc/resolv.conf"

  ssh root@"$ip" 'cat /etc/dhcp/dhclient.conf' \
    > "$dir/etc/dhcp/dhclient.conf"

  # interfaces.d — копируем каждый файл отдельно, сохраняя имена
  ssh root@"$ip" 'ls /etc/network/interfaces.d/ 2>/dev/null || true' | while read -r fname; do
    [ -z "$fname" ] && continue
    ssh root@"$ip" "cat /etc/network/interfaces.d/$fname" \
      > "$dir/etc/network/interfaces.d/$fname"
  done

  echo "    done"
done

echo "=== Collecting pve1-specific configs ==="

cp /etc/dnsmasq.d/homelab.conf      "$BASELINE/pve1/etc/dnsmasq.d/homelab.conf"
cp /etc/iptables/rules.v4           "$BASELINE/pve1/etc/iptables/rules.v4"
cp /etc/sysctl.d/99-forwarding.conf "$BASELINE/pve1/etc/sysctl.d/99-forwarding.conf"

echo "=== Collecting cluster SDN config ==="

SDN_DST="$BASELINE/cluster/etc/pve/sdn"
cat /etc/pve/sdn/zones.cfg   > "$SDN_DST/zones.cfg"
cat /etc/pve/sdn/vnets.cfg   > "$SDN_DST/vnets.cfg"
cat /etc/pve/sdn/subnets.cfg > "$SDN_DST/subnets.cfg" 2>/dev/null || true

echo "=== Done. Final tree ==="
tree "$BASELINE"
