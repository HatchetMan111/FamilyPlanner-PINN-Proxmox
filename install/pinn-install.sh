#!/usr/bin/env bash
# pinn. im LXC einrichten (laeuft als root IM Container via: pct exec <CTID> -- bash /tmp/pinn-install.sh)
set -euo pipefail

SERVICE_NAME="pinn"
APP_DIR="/opt/pinn"
APP_PORT="8090"
UPSTREAM="https://github.com/pinn-shost/pinn"
RAW_BASE="https://raw.githubusercontent.com/HatchetMan111/FamilyPlanner-PINN-Proxmox/main"
UNIT_URL="${RAW_BASE}/install/pinn.service"
UNIT_DST="/etc/systemd/system/${SERVICE_NAME}.service"

fail() {
  local code=$?
  echo "FEHLER in pinn-install.sh (Befehl: '${BASH_COMMAND}', Exit: ${code})" >&2
  echo '--- systemctl status pinn ---' >&2
  systemctl status "${SERVICE_NAME}" --no-pager >&2 || true
  echo '--- journalctl -u pinn (letzte 100 Zeilen) ---' >&2
  journalctl -u "${SERVICE_NAME}" -n 100 --no-pager >&2 || true
  echo '--- docker ---' >&2
  (cd "${APP_DIR}" && docker compose ps >&2 || docker ps >&2 || true)
  echo '--- docker logs pocketbase (letzte 80 Zeilen) ---' >&2
  (docker logs pocketbase --tail 80 >&2 || true)
  echo "Tipp: Re-Run mit DEBUG=1, Details: pct enter <CTID>, dann journalctl -u pinn" >&2
  exit "${code}"
}
trap fail ERR

if [ "${DEBUG:-0}" = "1" ]; then set -x; fi

echo "==> [1/7] Systempakete"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl git ca-certificates iproute2

echo "==> [2/7] Docker"
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sh /tmp/get-docker.sh
  rm -f /tmp/get-docker.sh
else
  echo "Docker vorhanden: $(docker --version)"
fi
docker compose version
systemctl enable --now docker

echo "==> [3/7] Upstream nach ${APP_DIR}"
if [ -d "${APP_DIR}/.git" ]; then
  git -C "${APP_DIR}" pull --ff-only
else
  git clone "${UPSTREAM}" "${APP_DIR}"
fi

echo "==> [4/7] systemd-Unit"
if ! curl -fsSL "${UNIT_URL}" -o "${UNIT_DST}"; then
  echo "FEHLER: Unit konnte nicht geladen werden: ${UNIT_URL} (HTTP-Fehler, pruefe Branch/Dateipfad)" >&2
  exit 1
fi
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"

echo "==> [5/7] pinn-setup.sh (Upstream, baut Container, laedt Vendor-Libs)"
cd "${APP_DIR}"
sh pinn-setup.sh

echo "==> [6/7] Service starten"
systemctl restart "${SERVICE_NAME}"

echo "==> [7/7] Verifikation (Service + http://127.0.0.1:${APP_PORT}/api/health, max. 3 Min)"
ok=0
for _ in $(seq 1 90); do
  if [ "$(systemctl is-active "${SERVICE_NAME}")" = "active" ] \
    && curl -fsS "http://127.0.0.1:${APP_PORT}/api/health" >/dev/null 2>&1; then
    ok=1
    break
  fi
  sleep 2
done
if [ "${ok}" != "1" ]; then
  echo "FEHLER: ${SERVICE_NAME} antwortet nicht (systemctl: $(systemctl is-active "${SERVICE_NAME}"))" >&2
  exit 1
fi

ip="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)"
[ -z "${ip}" ] && ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo "OK: pinn. laeuft — http://${ip:-<LXC-IP>}:${APP_PORT} (Ersteinrichtung: als Hauptadmin anmelden, Passwort: Admin)"
