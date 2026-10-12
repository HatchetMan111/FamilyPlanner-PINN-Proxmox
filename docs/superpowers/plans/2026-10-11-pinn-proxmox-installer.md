# Pinn Proxmox Installer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `install/pinn.sh` + `install/pinn-install.sh` + `install/pinn.service` in `HatchetMan111/FamilyPlanner-PINN-Proxmox` erstellen, sodass der Einzeiler auf einem Proxmox-Host einen `pinn`-LXC baut und `http://[LXC-IP]:8090` antwortet (heute: 404, leere Ausgabe).

**Architecture:** 2-Datei-Split wie Community Scripts: Host-Script (CT-Lifecycle via `pct`, holt Container-Script per `wget`+`pct push` mit `curl`-Fallback, verifiziert) und Container-Script (Docker, `git clone pinn-shost/pinn` nach `/opt/pinn`, offizielles `pinn-setup.sh`, systemd-Unit). Keine Compose-Fork.

**Tech Stack:** Bash (`set -euo pipefail`), `pct`/`pvesh`/`pvesm`/`pveam` (PVE-Host), Docker Engine + Compose-Plugin (Debian-12-LXC), systemd.

**Spec:** `docs/superpowers/specs/2026-10-11-pinn-proxmox-design.md`

## Global Constraints

- `set -euo pipefail` in beiden Scripts, kein stilles Versagen (Lektion vom 404-Leerlauf: jeder Download wird laut geprüft).
- CT-Name `pinn`, nächste freie CT-ID per `pvesh get /cluster/nextid`, Override via `CTID=`-Env.
- Defaults: 2 vCPU / 2048 MB RAM / 8 GB Disk, Debian-12-Template, unprivilegiert, `nesting=1,keyctl=1`, `vmbr0` DHCP, `onboot: 1`.
- Web-UI-Port `8090`, Health-Endpoint `/api/health`, Upstream-Clone-Ziel `/opt/pinn`, Upstream-Repo `pinn-shost/pinn`.
- Unit `pinn.service`: `After=network-online.target`, `Restart=always`, `systemctl enable`.
- Idempotent: Re-Run zerstört keine Daten (kein Auto-Recreate), `git pull --ff-only` statt Re-Clone.
- Keine Secrets in Logs/Scripts (kein Token, kein `.env`-Inhalt).
- HTTPS `:8443` nur Doku, keine Verifikation (Spec-Nicht-Ziel; DuckDNS kommt erst via Setup-Assistent).
- Vendor-Libs (pdf.js/Tesseract) handhabt das Upstream-`pinn-setup.sh` (best-effort mit Warnung); nicht nachbauen.
- Verifikation pro Task: `bash -n` + `shellcheck -S warning` müssen fehlerfrei sein.

## Review Focus

1. CTID belegt oder Hostname `pinn` existiert bereits → erwartet: lauter Abbruch mit Hinweis statt kryptischem `pct`-Fehler; Test in Task 3 (String-Assertions auf Abort-Pfad + Reuse-Pfad).
2. Nur `local` (kein `local-lvm`) vorhanden → erwartet: Storage-Auto-Fallback funktioniert; Test in Task 3 (Assertion auf Fallback-Zeile).
3. Template-Download schlägt fehl (offline) → erwartet: volle Fehlerkette + kein halb fertiger CT ohne Hinweis; Test in Task 3 (Assertion auf Trap + Cleanup-Hinweis).
4. Container-Script/Unit-URL liefert 404 (exakt der heutige Bug) → erwartet: lauter Abbruch mit URL + HTTP-Status, niemals leere Ausgabe; Test in Task 2 und 3 (Assertion auf `curl -fsSL`-Fail-Guard).
5. Zweiter Lauf nach erfolgreichem Install → erwartet: keine Datenzerstörung, nur `pull` + `restart`; Test in Task 2 (Assertion auf `pull --ff-only`-Pfad).

## File Structure

Arbeitskopie: `/tmp/opencode/familyplanner` (Clone von `HatchetMan111/FamilyPlanner-PINN-Proxmox`, Branch `main`).

- Create: `install/pinn.service` — systemd-Unit, läuft `docker compose up` in `/opt/pinn` (Task 1).
- Create: `install/pinn-install.sh` — läuft als root IM Container via `pct exec ... -- bash` (Task 2). Holt die Unit per `curl` von `RAW_BASE`, installiert Docker, klont/pullt Upstream, führt `pinn-setup.sh` aus, aktiviert die Unit, verifiziert Service + HTTP.
- Create: `install/pinn.sh` — läuft als root AUF dem PVE-Host via Einzeiler (Task 3). Erstellt/startet den CT, holt `pinn-install.sh` per `wget` + `pct push` (`curl`-Fallback im Gast), führt es aus, verifiziert `onboot` + Service + HTTP, druckt finale URL.
- Modify: `README.md` — Status-Hinweis „in Arbeit" entfernen, erwartete Ausgabe ergänzen (Task 4).
- Gemeinsamer Vertrag (alle Tasks): `RAW_BASE=https://raw.githubusercontent.com/HatchetMan111/FamilyPlanner-PINN-Proxmox/main`, Env-Vars `CTID/CPU/RAM/DISK/STORAGE/BRIDGE/DEBUG`, Gastpfade `/tmp/pinn-install.sh`, `/opt/pinn`, `/etc/systemd/system/pinn.service`.

---

### Task 1: systemd-Unit `install/pinn.service`

**Files:**
- Create: `install/pinn.service`
- Test: `bash -n` n/a (kein Script); Prüfung via `systemd-analyze verify` (falls vorhanden) + String-Assertions.

**Interfaces:**
- Consumes: nichts (eigenständig).
- Produces: Unit-Datei, die Task 2 per `curl $RAW_BASE/install/pinn.service` nach `/etc/systemd/system/pinn.service` lädt; Service-Name `pinn` (von Task 2/3 in `systemctl is-active pinn` verwendet).

- [ ] **Step 1: Unit-Datei schreiben**

Exakter Inhalt für `install/pinn.service`:

```ini
[Unit]
Description=pinn. family organizer (Docker Compose)
Documentation=https://github.com/pinn-shost/pinn
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
WorkingDirectory=/opt/pinn
ExecStart=/usr/bin/docker compose up
ExecStop=/usr/bin/docker compose down -t 30
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

Begründung (nicht ändern ohne Spec-Update): `Type=simple` + foreground-`up`, damit `Restart=always` greift und `systemctl is-active` den echten Zustand zeigt; kein `--build` im Start (Build passiert bei Install/Update, sonst dauert jeder Reboot Minuten).

- [ ] **Step 2: Verifizieren**

Run:
```bash
grep -q '^Restart=always$' install/pinn.service && grep -q '^After=network-online.target' install/pinn.service && grep -q '^WorkingDirectory=/opt/pinn$' install/pinn.service && echo UNIT-OK
command -v systemd-analyze >/dev/null && systemd-analyze verify install/pinn.service || echo 'systemd-analyze nicht verfügbar, String-Check genügt'
```
Expected: `UNIT-OK` (und ggf. verify ohne Fehler).

- [ ] **Step 3: Commit**

```bash
git add install/pinn.service
git commit -m 'feat: systemd-Unit pinn.service (compose foreground, Restart=always)'
```

---

### Task 2: Container-Setup `install/pinn-install.sh`

**Files:**
- Create: `install/pinn-install.sh`
- Test: `bash -n install/pinn-install.sh`, `shellcheck -S warning install/pinn-install.sh`, String-Assertions (Review-Focus 4 + 5).

**Interfaces:**
- Consumes: `install/pinn.service` aus Task 1 (via `$RAW_BASE`, Variable `UNIT_URL`); Upstream `https://github.com/pinn-shost/pinn` + dessen `pinn-setup.sh`.
- Produces: ausführbares Setup, das Task 3 via `pct exec "$CTID" -- bash /tmp/pinn-install.sh` aufruft; schreibt `/etc/systemd/system/pinn.service`, aktiviert Service `pinn`, verifiziert `http://127.0.0.1:8090/api/health`.

- [ ] **Step 1: Script schreiben**

Exakter Inhalt für `install/pinn-install.sh`:

```bash
#!/usr/bin/env bash
# pinn. im LXC einrichten (laeuft als root IM Container via: pct exec <CTID> -- bash /tmp/pinn-install.sh)
set -euo pipefail

APP="pinn"
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
```

Hinweise für den Implementierer (verbindlich): Aufruf erfolgt IMMER mit `bash` (wegen `BASH_COMMAND`, `[[`-freiem aber bash-spezifischem Trap-Verhalten und `$(...)`); `sh pinn-setup.sh` bleibt `sh`, weil Upstream POSIX ist. Kein `tee`-Redirect hier — der Host (Task 3) loggt zentral.

- [ ] **Step 2: Syntax + Lint prüfen**

Run:
```bash
bash -n install/pinn-install.sh && echo SYNTAX-OK
shellcheck -S warning install/pinn-install.sh && echo LINT-OK
```
Expected: `SYNTAX-OK` und `LINT-OK` (shellcheck ggf. erst installieren; Warnungen fixen, nicht ignorieren).

- [ ] **Step 3: Review-Focus-Assertions (Fail-Guards)**

Run:
```bash
grep -q 'curl -fsSL "${UNIT_URL}"' install/pinn-install.sh && echo GUARD-404-OK
grep -q 'git -C "${APP_DIR}" pull --ff-only' install/pinn-install.sh && echo IDEMPOTENT-OK
grep -q 'trap fail ERR' install/pinn-install.sh && grep -q 'journalctl -u' install/pinn-install.sh && echo ERRCHAIN-OK
grep -q 'systemctl is-active' install/pinn-install.sh && grep -q 'api/health' install/pinn-install.sh && echo VERIFY-OK
```
Expected: alle vier `*-OK`. (Deckt Review-Focus 4: 404-Guard, und 5: kein Re-Clone.)

- [ ] **Step 4: Commit**

```bash
git add install/pinn-install.sh
git commit -m 'feat: Container-Setup pinn-install.sh (Docker, Upstream, Unit, Verifikation)'
```

---

### Task 3: Host-Script `install/pinn.sh`

**Files:**
- Create: `install/pinn.sh`
- Test: `bash -n install/pinn.sh`, `shellcheck -S warning install/pinn.sh`, String-Assertions (Review-Focus 1–4).

**Interfaces:**
- Consumes: `install/pinn-install.sh` aus Task 2 (per `wget` vom `$RAW_BASE` geholt, per `pct push` in den CT gelegt, `curl`-Fallback im Gast); nutzt Gastpfad `/tmp/pinn-install.sh` und Aufruf `pct exec "$CTID" -- bash /tmp/pinn-install.sh`.
- Produces: den Einzeiler-Einstieg; druckt finale URL `http://[LXC-IP]:8090`.

- [ ] **Step 1: Script schreiben**

Exakter Inhalt für `install/pinn.sh`:

```bash
#!/usr/bin/env bash
# pinn. auf Proxmox VE als LXC installieren (Community-Scripts-Stil).
# Einzeiler auf dem PVE-Host als root:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/FamilyPlanner-PINN-Proxmox/main/install/pinn.sh)"
set -euo pipefail

APP="pinn"
APP_PORT="8090"
UPSTREAM="pinn-shost/pinn"
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
  echo "Tipp: Re-Run mit DEBUG=1 bash -c \"\$(wget -qLO - ${RAW_BASE}/install/pinn.sh)\", Log: ${LOG:-/tmp/pinn-install-host-*.log}" >&2
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
```

Hinweise für den Implementierer (verbindlich): `pct list`-Parsing NUR für die ID-Spalte (`awk '{print $1}'`), Hostname-Vergleich IMMER via `pct config … | grep '^hostname:'` (Spalten-Shift bei leerem Lock-Feld). `exec > >(tee …)` nur hier (PVE hat Bash), niemals leere Downloads akzeptieren (`-s`-Check = Lektion aus dem 404-Bug).

- [ ] **Step 2: Syntax + Lint prüfen**

Run:
```bash
bash -n install/pinn.sh && echo SYNTAX-OK
shellcheck -S warning install/pinn.sh && echo LINT-OK
```
Expected: `SYNTAX-OK` und `LINT-OK`.

- [ ] **Step 3: Review-Focus-Assertions**

Run:
```bash
grep -q 'pvesh get /cluster/nextid' install/pinn.sh && echo NEXTID-OK
grep -q 'belegt (anderer Container)' install/pinn.sh && echo COLLISION-OK
grep -q 'STORAGE="local-lvm"; else STORAGE="local"' install/pinn.sh && echo STORAGEFALLBACK-OK
grep -q 'Download ist leer' install/pinn.sh && grep -q 'auch curl-Fallback schlug fehl' install/pinn.sh && echo N404-GUARD-OK
grep -q -- '--onboot 1' install/pinn.sh && echo ONBOOT-OK
grep -q 'trap fail ERR' install/pinn.sh && echo ERRCHAIN-OK
```
Expected: alle `*-OK`. (Deckt Review-Focus 1–4.)

- [ ] **Step 4: Commit**

```bash
git add install/pinn.sh
git commit -m 'feat: Host-Script pinn.sh (CT-Lifecycle, Push, Verifikation, Einzeiler)'
```

---

### Task 4: README finalisieren + pushen + Abnahme auf ProxSmartHome

**Files:**
- Modify: `README.md` (Status-Block „in Arbeit" entfernen, Abschnitt „Erwartete Ausgabe" mit realem Beispiel ergänzen).
- Test: Einzeiler auf `ProxSmartHome` (führt der User aus, kein Live-PVE hier).

**Interfaces:**
- Consumes: Tasks 1–3 (alle Dateien auf `main` gepusht).
- Produces: grüner Einzeiler + Reboot-Beleg.

- [ ] **Step 1: README-Status aktualisieren**

Ersetze exakt diesen Block:
```markdown
> Stand: `install/pinn.sh` und `install/pinn-install.sh` sind in Arbeit (Plan-Phase).
> Der Einzeiler funktioniert erst, sobald diese Dateien hier auf `main` liegen.
```
durch:
```markdown
> Stand: Installer vollständig auf `main` (`install/pinn.sh`, `install/pinn-install.sh`, `install/pinn.service`).
```

Hänge ans Ende von `README.md` an:

```markdown
## Erwartete Ausgabe (Erfolg)

```
==> [1/7] Ziel-CT bestimmen
Neue CT-ID: 100
==> [2/7] Storage + Template
Storage: local-lvm
==> [3/7] CT erstellen + starten
==> [4/7] Auf Container-IP warten (max. 5 Min)
Container-IP: 192.168.178.50
==> [5/7] Setup-Script in den CT legen
per pct push uebertragen
==> [6/7] Setup im CT ausfuehren
OK: pinn. laeuft — http://192.168.178.50:8090 (Ersteinrichtung: als Hauptadmin anmelden, Passwort: Admin)
==> [7/7] Verifikation (onboot + Service + HTTP)
================================================================
  pinn. laeuft:  http://192.168.178.50:8090
  CTID 100 (pinn), 2 vCPU / 2048 MB / 8 GB, onboot: 1
  Ersteinrichtung: als Hauptadmin anmelden (Passwort: Admin)
  Update: Einzeiler erneut laufen lassen | Deinstall: pct stop 100 && pct destroy 100
  Log: /tmp/pinn-install-host-2026-10-11_120000.log
================================================================
```
(IPs/IDs sind Beispiele, echte Werte kommen vom eigenen Host.)
```

- [ ] **Step 2: Alles pushen**

Run:
```bash
bash -n install/pinn.sh && bash -n install/pinn-install.sh && shellcheck -S warning install/pinn.sh install/pinn-install.sh && echo ALL-CHECKS-OK
git add -A && git commit -m 'docs: README final (Erwartete Ausgabe, Status)' || echo 'nichts zu committen'
git push origin main
```
Expected: `ALL-CHECKS-OK`, Push ohne Fehler. Token-/Auth-Hinweis: Push via flüchtigem Credential-Helper (Env), niemals Token in `.git/config` oder Dateien schreiben.

- [ ] **Step 3: Abnahme auf ProxSmartHome (User führt aus)**

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/FamilyPlanner-PINN-Proxmox/main/install/pinn.sh)"
```

Erwartet: Schlussblock mit `pinn. laeuft: http://[LXC-IP]:8090` (statt der heutigen leeren Ausgabe).
Danach Reboot-Beleg aus README-Abschnitt „Reboot-Test" ausführen und Logauszug hierher posten.

- [ ] **Step 4: Lokale Spec-Kopie synchronisieren**

Run:
```bash
cp /tmp/opencode/familyplanner/docs/superpowers/specs/2026-10-11-pinn-proxmox-design.md /home/opencode/.opencode/docs/superpowers/specs/2026-10-11-pinn-proxmox-design.md
```
Expected: kein Diff (`diff -q` still).
