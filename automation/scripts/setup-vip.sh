#!/bin/bash
# =============================================================================
# setup-vip.sh — HA VIP для Proxmox UI (keepalived unicast + HAProxy)
#
# Запускать с pve1 как root.
# Требует: automation/scripts/vip.env (скопируй из vip.env.example и заполни)
# Результат: https://<VIP>:8006 — единая точка входа в Proxmox UI
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/vip.env"

[[ -f "$ENV_FILE" ]] || {
  echo "[ERROR] Файл $ENV_FILE не найден."
  echo "        Скопируй vip.env.example → vip.env и заполни значениями."
  exit 1
}
# shellcheck source=vip.env.example
source "$ENV_FILE"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
ok()  { echo "[$(date '+%H:%M:%S')] ✓ $*"; }
die() { echo "[ERROR] $*" >&2; exit 1; }

# =============================================================================
# Preflight
# =============================================================================
log "=== Preflight checks ==="

ip addr show vmbr0 2>/dev/null | grep -q "${MGMT_NODES[0]}" \
  || die "Запусти скрипт на pve1 (${MGMT_NODES[0]})"

for node in "${MGMT_NODES[@]}"; do
  ssh -o ConnectTimeout=5 -o BatchMode=yes root@$node 'true' \
    || die "Нет SSH доступа к $node"
done
ok "SSH до всех нод"

ping -c 1 -W 1 "$VIP" &>/dev/null && die "VIP $VIP уже занят!" || true
ok "VIP $VIP свободен"

pvecm status 2>/dev/null | grep -q "Quorate: Yes" \
  || die "Кластер не quorate — проверь pvecm status"
ok "Кластер quorate"

[[ ${#AUTH_PASS} -le 8 ]] \
  || die "AUTH_PASS длиннее 8 символов — keepalived молча обрежет. Сократи в vip.env"

# =============================================================================
# Step 1: Пакеты
# =============================================================================
log "=== Step 1: Установка пакетов ==="
for node in "${MGMT_NODES[@]}"; do
  ssh root@$node 'apt-get install -yq keepalived haproxy sudo 2>/dev/null' \
    && ok "  $node: OK"
done

# =============================================================================
# Step 2: Системный юзер keepalived_script
# =============================================================================
log "=== Step 2: keepalived_script user ==="
for node in "${MGMT_NODES[@]}"; do
  ssh root@$node \
    'id keepalived_script &>/dev/null \
      || useradd -r -s /sbin/nologin -M keepalived_script' \
    && ok "  $node: OK"
done

# =============================================================================
# Step 3: Health check script
# =============================================================================
log "=== Step 3: Health check script ==="

CHKSCRIPT='#!/bin/sh
pidof haproxy  > /dev/null 2>&1 || exit 1
pidof pveproxy > /dev/null 2>&1 || exit 1
exit 0'

for node in "${MGMT_NODES[@]}"; do
  echo "$CHKSCRIPT" | ssh root@$node \
    'cat > /usr/local/sbin/chk_pve_vip.sh && chmod +x /usr/local/sbin/chk_pve_vip.sh'
  ssh root@$node \
    'su -s /bin/sh keepalived_script -c "/usr/local/sbin/chk_pve_vip.sh"' \
    && ok "  $node: CHECK OK" \
    || die "  $node: CHECK FAILED — haproxy или pveproxy не запущен?"
done

# =============================================================================
# Step 4: HAProxy
# =============================================================================
log "=== Step 4: HAProxy ==="

HAPROXY_CFG="global
  log /dev/log local0
  maxconn 4096
  daemon

defaults
  log global
  mode tcp
  option tcplog
  timeout connect 5s
  timeout client  60s
  timeout server  60s

frontend pve_ui
  bind *:8006
  default_backend pve_nodes

backend pve_nodes
  balance source
  option ssl-hello-chk
  server pve1 ${WIFI_IPS[0]}:8006 check inter 2s fall 3 rise 2 ssl verify none
  server pve2 ${WIFI_IPS[1]}:8006 check inter 2s fall 3 rise 2 ssl verify none
  server pve3 ${WIFI_IPS[2]}:8006 check inter 2s fall 3 rise 2 ssl verify none"

for node in "${MGMT_NODES[@]}"; do
  echo "$HAPROXY_CFG" | ssh root@$node 'cat > /etc/haproxy/haproxy.cfg'
  ssh root@$node 'haproxy -c -f /etc/haproxy/haproxy.cfg &>/dev/null' \
    || die "HAProxy конфиг невалидный на $node"
  ssh root@$node 'systemctl enable --now haproxy'
  ssh root@$node 'ss -tlnp | grep -q ":8006"' \
    && ok "  $node: слушает :8006"
done

# =============================================================================
# Step 5: keepalived (unicast, разный priority на каждой ноде)
# =============================================================================
log "=== Step 5: keepalived ==="

for i in "${!MGMT_NODES[@]}"; do
  node="${MGMT_NODES[$i]}"
  src_ip="${WIFI_IPS[$i]}"
  priority="${PRIORITIES[$i]}"

  peers=""
  for j in "${!WIFI_IPS[@]}"; do
    [[ $j -ne $i ]] && peers+="    ${WIFI_IPS[$j]}"$'\n'
  done

  KEEPCONF="global_defs {
  enable_script_security
  script_user keepalived_script
}

vrrp_script chk_pve_vip {
  script \"/usr/local/sbin/chk_pve_vip.sh\"
  interval 2
  fall 2
  rise 2
}

vrrp_instance VI_PVE {
  state BACKUP
  interface ${INTERFACE}
  virtual_router_id ${VRID}
  priority ${priority}
  advert_int 1
  nopreempt

  unicast_src_ip ${src_ip}
  unicast_peer {
${peers}  }

  authentication {
    auth_type PASS
    auth_pass ${AUTH_PASS}
  }

  virtual_ipaddress {
    ${VIP}/${VIP_PREFIX} dev ${INTERFACE}
  }

  track_script {
    chk_pve_vip
  }
}"

  echo "$KEEPCONF" | ssh root@$node 'cat > /etc/keepalived/keepalived.conf'
  ssh root@$node 'keepalived -t -f /etc/keepalived/keepalived.conf 2>&1' \
    | grep -v "^$" | tail -1
  ok "  $node: конфиг записан (priority $priority, src $src_ip)"
done

# =============================================================================
# Step 6: Запуск
# =============================================================================
log "=== Step 6: Запуск keepalived ==="

systemctl enable --now keepalived
ok "  pve1: keepalived started"
sleep 4

for node in "${MGMT_NODES[@]:1}"; do
  ssh root@$node 'systemctl enable --now keepalived'
  ok "  $node: keepalived started"
  sleep 1
done

sleep 4

# =============================================================================
# Verification
# =============================================================================
log "=== Verification ==="

VIP_HOLDER=""
for i in "${!MGMT_NODES[@]}"; do
  node="${MGMT_NODES[$i]}"
  has_vip=$(ssh root@$node "ip a show ${INTERFACE} | grep -c 'inet ${VIP}/' || true")
  if [[ "$has_vip" -gt 0 ]]; then
    VIP_HOLDER="$node (${WIFI_IPS[$i]})"
    ok "  VIP ${VIP} — на $node"
  else
    log "  $node: no vip"
  fi
done

[[ -z "$VIP_HOLDER" ]] && die "VIP не появился! Смотри: journalctl -u keepalived -n 30"

HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "https://${VIP}:8006" || echo "000")
if [[ "$HTTP_CODE" =~ ^(200|301|302)$ ]]; then
  ok "Proxmox UI: https://${VIP}:8006 (HTTP $HTTP_CODE)"
else
  log "WARNING: https://${VIP}:8006 → HTTP $HTTP_CODE — проверь с ноутбука вручную"
fi

echo ""
echo "================================================"
echo "  Готово! Proxmox UI: https://${VIP}:8006"
echo "  VIP держит: $VIP_HOLDER"
echo "================================================"
