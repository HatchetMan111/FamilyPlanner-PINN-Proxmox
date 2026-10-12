#!/usr/bin/env bash
# pinn. auf Proxmox VE als LXC installieren (Community-Scripts-Stil).
# Einzeiler auf dem PVE-Host als root:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/FamilyPlanner-PINN-Proxmox/main/install/pinn.sh)"
set -euo pipefail

APP="pinn"
APP_PORT="8090"
INSTALLER="HatchetMan111/FamilyPlanner-PINN-Proxmox"
BRANCH="main"
RAW_BASE="https://raw.githubusercontent.com/${INSTALLER}/${BRANCH}"
GUEST_SCRIPT_URL="${RAW_BASE}/install/pinn-install.sh"
CPU="${CPU:-2}"
RAM="${RAM:-2048}"
DISK="${DISK:-8}"
BRIDGE="${BRIDGE:-vmbr0}"
STORAGE_TMPL="local"

fail() {
  local code=$?
  echo "FEHLER in pinn.sh (Befehl: '${BASH_COMMAND}', Exit: ${code})" >&2
  if [ -n "${CTID:-}" ] && pct status "${CTID}" >/dev/null 2>&1; then
    echo "--- pct config ${CTID} ---" >&2
    pct config "${CTID}" >&2 || true
  fi
  echo "Tipp: Re-Run mit DEBUG=1, Log: ${LOG:-/tmp/pinn-install-host-*.log}" >&2
  echo "Tipp: Detail-Debug: DEBUG=1 bash -c \"\$(wget -qLO - ${RAW_BASE}/install/pinn.sh)\"" >&2
  exit "${code}"
}
trap fail ERR

if [ "${DEBUG:-0}" = "1" ]; then set -x; fi
LOG="/tmp/pinn-install-host-$(date +%F_%H%M%S).log"
exec > >(tee -a "${LOG}") 2>&1
echo "pinn-Installer, Log: ${LOG}"

if [ "$(id -u)" -ne 0 ]; then echo "FEHLER: als root auf dem Proxmox-Host ausfuehren" >&2; exit 1; fi
for bin in pct pvesh pvesm pveam wget; do
  command -v "${bin}" >/dev/null 2>&1 || { echo "FEHLER: '${bin}' fehlt — kein Proxmox-Host?" >&2; exit 1; }
done

echo "==> [1/7] Ziel-CT bestimmen"
existing=""
for id in $(pct list | tail -n +2 | awk '{print $1}'); do
  if pct config "${id}" 2>/dev/null | grep -q "^hostname: ${APP}$"; then existing="${id}"; break; fi
done
if [ -n "${CTID:-}" ]; then
  if pct status "${CTID}" >/dev/null 2>&1; then
    if pct config "${CTID}" | grep -q "^hostname: ${APP}$"; then
      echo "CT ${CTID} ist bereits '${APP}' -> nur Provision (kein Neu-Create, keine Daten werden geloescht)"
      existing="${CTID}"
    else
      echo "FEHLER: CTID ${CTID} ist belegt (anderer Container). Freie ID: $(pvesh get /cluster/nextid). Abbruch." >&2
      exit 1
    fi
  fi
elif [ -n "${existing}" ]; then
  CTID="${existing}"
  echo "Bestehender '${APP}'-CT ${CTID} gefunden -> nur Provision"
else
  CTID="$(pvesh get /cluster/nextid)"
  echo "Neue CT-ID: ${CTID}"
fi

if [ -z "${existing}" ]; then
  echo "==> [2/7] Storage + Template"
  if pvesm status | grep -q '^local-lvm'; then STORAGE="local-lvm"; else STORAGE="local"; fi
  echo "Storage: ${STORAGE}"
  TPL="$(pveam available --section system 2>/dev/null | grep -o 'debian-12-standard_[^ ]*amd64[^ ]*' | sort -V | tail -1 || true)"
  if [ -z "${TPL}" ]; then echo "FEHLER: kein debian-12-Template in 'pveam available' (Netz/Update pruefen)" >&2; exit 1; fi
  if ! pveam list "${STORAGE_TMPL}" 2>/dev/null | grep -q "${TPL}"; then
    echo "Lade Template ${TPL} ..."
    pveam download "${STORAGE_TMPL}" "${TPL}"
  fi

  echo "==> [3/7] CT erstellen + starten"
  pct create "${CTID}" "${STORAGE_TMPL}:vztmpl/${TPL}" \
    --hostname "${APP}" --cores "${CPU}" --memory "${RAM}" --rootfs "${STORAGE}:${DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" --unprivileged 1 \
    --features "nesting=1,keyctl=1" --onboot 1 --start 1
else
  echo "==> [2-3/7] Create/Start uebersprungen (Reuse ${CTID})"
  pct start "${CTID}" 2>/dev/null || true
fi

echo "==> [4/7] Auf Container-IP warten (max. 5 Min)"
ip=""
for _ in $(seq 1 60); do
  if pct status "${CTID}" 2>/dev/null | grep -q '^status: running'; then
    ip="$(pct exec "${CTID}" -- ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1 || true)"
    [ -n "${ip}" ] && break
  fi
  sleep 5
done
if [ -z "${ip}" ]; then echo "FEHLER: keine IP fuer CT ${CTID} (DHCP/Bridge ${BRIDGE} pruefen; pct config ${CTID})" >&2; exit 1; fi
echo "Container-IP: ${ip}"

echo "==> [5/7] Setup-Script in den CT legen"
rm -f /tmp/pinn-install.sh
if ! wget -qO /tmp/pinn-install.sh "${GUEST_SCRIPT_URL}"; then
  echo "FEHLER: Download fehlgeschlagen: ${GUEST_SCRIPT_URL} (HTTP-Fehler, Branch/Pfad pruefen)" >&2
  exit 1
fi
[ -s /tmp/pinn-install.sh ] || { echo "FEHLER: Download ist leer: ${GUEST_SCRIPT_URL}" >&2; exit 1; }
if pct push "${CTID}" /tmp/pinn-install.sh /tmp/pinn-install.sh 2>/dev/null; then
  echo "per pct push uebertragen"
else
  echo "pct push fehlgeschlagen -> Fallback: curl im Gast"
  pct exec "${CTID}" -- bash -c "curl -fsSL '${GUEST_SCRIPT_URL}' -o /tmp/pinn-install.sh" \
    || { echo "FEHLER: auch curl-Fallback schlug fehl: ${GUEST_SCRIPT_URL}" >&2; exit 1; }
fi

echo "==> [6/7] Setup im CT ausfuehren"
pct exec "${CTID}" -- bash /tmp/pinn-install.sh

echo "==> [7/7] Verifikation (onboot + Service + HTTP)"
pct config "${CTID}" | grep -q '^onboot: 1' || { echo "FEHLER: onboot nicht gesetzt (pct config ${CTID})" >&2; exit 1; }
pct exec "${CTID}" -- systemctl is-active pinn | grep -q '^active$' \
  || { echo "FEHLER: pinn.service nicht active" >&2; exit 1; }
curl -fsS "http://${ip}:${APP_PORT}/api/health" >/dev/null \
  || { echo "FEHLER: keine Antwort auf http://${ip}:${APP_PORT}/api/health" >&2; exit 1; }

echo
echo "================================================================"
echo "  pinn. laeuft:  http://${ip}:${APP_PORT}"
echo "  CTID ${CTID} (${APP}), ${CPU} vCPU / ${RAM} MB / ${DISK} GB, onboot: 1"
echo "  Ersteinrichtung: als Hauptadmin anmelden (Passwort: Admin)"
echo "  Update: Einzeiler erneut laufen lassen | Deinstall: pct stop ${CTID} && pct destroy ${CTID}"
echo "  Log: ${LOG}"
echo "================================================================"
