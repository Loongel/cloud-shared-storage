#!/bin/sh
set -eu

ENV_FILE=${1:-/etc/cs-storage/server.env}

read_env_value() {
  file=$1
  key=$2
  test -f "$file" || return 1
  awk -F= -v k="$key" '$1 == k {sub(/^[^=]*=/, ""); print; found=1; exit} END {exit found ? 0 : 1}' "$file"
}

addr_port() {
  addr=$1
  case "$addr" in
    *:*) printf '%s\n' "${addr##*:}" ;;
    *) printf '%s\n' "$addr" ;;
  esac
}

addr_host() {
  addr=$1
  case "$addr" in
    :*) return 1 ;;
    \[*\]:*) return 1 ;;
    *:*) printf '%s\n' "${addr%:*}" ;;
    *) return 1 ;;
  esac
}

iface_for_ip() {
  ipaddr=$1
  command -v ip >/dev/null 2>&1 || return 1
  ip -o -4 addr show 2>/dev/null | awk -v ipaddr="$ipaddr" '
    {
      split($4, a, "/")
      if (a[1] == ipaddr) {
        print $2
        found=1
        exit
      }
    }
    END {exit found ? 0 : 1}
  '
}

ufw_active() {
  command -v ufw >/dev/null 2>&1 || return 1
  ufw status 2>/dev/null | awk 'NR == 1 && $2 == "active" {found=1} END {exit found ? 0 : 1}'
}

firewalld_active() {
  command -v firewall-cmd >/dev/null 2>&1 || return 1
  firewall-cmd --state >/dev/null 2>&1
}

ensure_ufw() {
  port=$1
  iface=${2:-}
  if test -n "$iface"; then
    ufw allow in on "$iface" to any port "$port" proto tcp comment "cs-storage-server" >/dev/null
  else
    ufw allow "$port/tcp" comment "cs-storage-server" >/dev/null
  fi
}

ensure_firewalld() {
  port=$1
  iface=${2:-}
  if test -n "$iface"; then
    rule="-i $iface -p tcp --dport $port -j ACCEPT"
    firewall-cmd --direct --query-rule ipv4 filter INPUT 0 $rule >/dev/null 2>&1 ||
      firewall-cmd --direct --add-rule ipv4 filter INPUT 0 $rule >/dev/null
    firewall-cmd --permanent --direct --query-rule ipv4 filter INPUT 0 $rule >/dev/null 2>&1 ||
      firewall-cmd --permanent --direct --add-rule ipv4 filter INPUT 0 $rule >/dev/null
  else
    firewall-cmd --query-port="$port/tcp" >/dev/null 2>&1 ||
      firewall-cmd --add-port="$port/tcp" >/dev/null
    firewall-cmd --permanent --query-port="$port/tcp" >/dev/null 2>&1 ||
      firewall-cmd --permanent --add-port="$port/tcp" >/dev/null
  fi
}

ensure_iptables() {
  port=$1
  iface=${2:-}
  if test -n "$iface"; then
    iptables -C INPUT -i "$iface" -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 ||
      iptables -I INPUT 1 -i "$iface" -p tcp --dport "$port" -j ACCEPT
  else
    iptables -C INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 ||
      iptables -I INPUT 1 -p tcp --dport "$port" -j ACCEPT
  fi
}

server_addr=$(read_env_value "$ENV_FILE" CS_SERVER_ADDR 2>/dev/null || true)
test -n "$server_addr" || server_addr=:18080
port=$(addr_port "$server_addr")
case "$port" in
  ''|*[!0-9]*) echo "CSS_FIREWALL_SKIP invalid_port addr=$server_addr" >&2; exit 0 ;;
esac

bind_ip=$(addr_host "$server_addr" 2>/dev/null || true)
iface=
if test -n "$bind_ip" && test "$bind_ip" != "0.0.0.0"; then
  iface=$(iface_for_ip "$bind_ip" 2>/dev/null || true)
fi

if ufw_active; then
  ensure_ufw "$port" "$iface"
  echo "CSS_FIREWALL_OK backend=ufw port=$port iface=${iface:-any}"
  exit 0
fi
if firewalld_active; then
  ensure_firewalld "$port" "$iface"
  echo "CSS_FIREWALL_OK backend=firewalld port=$port iface=${iface:-any}"
  exit 0
fi
if command -v iptables >/dev/null 2>&1; then
  ensure_iptables "$port" "$iface"
  echo "CSS_FIREWALL_OK backend=iptables port=$port iface=${iface:-any}"
  exit 0
fi

echo "CSS_FIREWALL_SKIP no_supported_firewall_tool port=$port iface=${iface:-any}"
