#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${MONITOR_ENV_FILE:-${HOME}/scripts/.monitor.env}"
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:?DISCORD_WEBHOOK_URL no definido}"
HOST="${MONITOR_HOSTNAME:-$(hostname)}"
DISK_WARN="${DISK_WARN:-85}"
RAM_WARN="${RAM_WARN:-90}"
TEMP_WARN="${TEMP_WARN:-75}"
LOAD_WARN_FACTOR="${LOAD_WARN_FACTOR:-2}"
DISKS="${DISKS:-/}"
EXTRA_DISKS="${EXTRA_DISKS:-}"
STATE_DIR="${STATE_DIR:-/tmp/monitor-recursos}"

mkdir -p "$STATE_DIR"

for mp in $EXTRA_DISKS; do
  if mountpoint -q "$mp" 2>/dev/null; then
    DISKS="$DISKS $mp"
  fi
done

send_discord() {
  local title="$1" desc="$2" color="$3"
  curl -s -H "Content-Type: application/json" -X POST "$DISCORD_WEBHOOK_URL" -d @- > /dev/null << JSON
{
  "username": "${DISCORD_USERNAME:-Homelab Monitor}",
  "embeds": [{
    "title": "$title",
    "description": "$desc",
    "color": $color,
    "footer": { "text": "$HOST · $(date '+%Y-%m-%d %H:%M')" }
  }]
}
JSON
}

check_state() {
  local key="$1" alert="$2" title="$3" desc="$4"
  local f="$STATE_DIR/$key"
  local prev="ok"
  [ -f "$f" ] && prev="$(cat "$f")"

  if [ "$alert" = "1" ] && [ "$prev" = "ok" ]; then
    send_discord "ALERTA: $title" "$desc" 15158332
    echo "alert" > "$f"
  elif [ "$alert" = "0" ] && [ "$prev" = "alert" ]; then
    send_discord "RECUPERADO: $title" "$desc" 3066993
    echo "ok" > "$f"
  fi
}

for mp in $DISKS; do
  use=$(df --output=pcent "$mp" 2>/dev/null | tail -1 | tr -dc '0-9')
  [ -z "$use" ] && continue
  read -r total used avail <<< "$(df -h --output=size,used,avail "$mp" 2>/dev/null | tail -1)"
  key="disk_$(echo "$mp" | tr '/' '_')"
  info="Uso: **${use}%** · Ocupado: **${used}** · Libre: **${avail}** · Total: ${total}"
  if [ "$use" -ge "$DISK_WARN" ]; then
    check_state "$key" 1 "Disco lleno: $mp" "$info (umbral ${DISK_WARN}%)"
  else
    check_state "$key" 0 "Disco: $mp" "$info"
  fi
done

ram=$(free | awk '/Mem:/ {printf "%d", $3/$2*100}')
read -r rtotal rused rfree <<< "$(free -h --si | awk '/Mem:/ {print $2, $3, $7}')"
raminfo="Uso: **${ram}%** · Ocupada: **${rused}** · Libre: **${rfree}** · Total: ${rtotal}"
if [ "$ram" -ge "$RAM_WARN" ]; then
  check_state "ram" 1 "RAM alta" "$raminfo (umbral ${RAM_WARN}%)"
else
  check_state "ram" 0 "RAM" "$raminfo"
fi

cores=$(nproc)
load1=$(awk '{print $1}' /proc/loadavg)
load_int=$(printf "%.0f" "$load1")
limit=$((cores * LOAD_WARN_FACTOR))
if [ "$load_int" -ge "$limit" ]; then
  check_state "load" 1 "CPU saturada" "Load1: **${load1}** en ${cores} nucleos (umbral ${limit})"
else
  check_state "load" 0 "CPU" "Load1: **${load1}** en ${cores} nucleos"
fi

temp=""
if command -v vcgencmd >/dev/null 2>&1; then
  temp=$(vcgencmd measure_temp | grep -o '[0-9]*\.[0-9]*' | cut -d. -f1)
elif [ -f /sys/class/thermal/thermal_zone0/temp ]; then
  temp=$(( $(cat /sys/class/thermal/thermal_zone0/temp) / 1000 ))
fi

if [ -n "$temp" ]; then
  if [ "$temp" -ge "$TEMP_WARN" ]; then
    check_state "temp" 1 "Temperatura alta" "**${temp} C** (umbral ${TEMP_WARN} C)"
  else
    check_state "temp" 0 "Temperatura" "**${temp} C**"
  fi
fi
