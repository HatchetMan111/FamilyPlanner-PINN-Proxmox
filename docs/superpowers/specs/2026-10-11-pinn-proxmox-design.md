# Pinn auf Proxmox (LXC + Docker) — Design Spec

Datum: 2026-10-11
Status: freigegeben (OK am 2026-10-11)
Bezug: Pinn Upstream https://github.com/pinn-shost/pinn (Self-hosted Family Organizer, PocketBase + Docker, Web-UI :8090, HTTPS :8443 via Caddy)

## 1. Verstaendnis / Brief

Gesagt:
- Server-Install-Script fuer Proxmox im Community-Script-Stil (community-scripts.github.io/ProxmoxVE), Einzeiler `bash -c "$(wget -qLO - .../install/pinn.sh)"`
- Lokale App, vollstaendig lokal ohne Cloud-Zwang, naechste freie ID, passender Name (pinn)
- Idempotent, `set -euo pipefail`, volle Fehlerkette, `bash -x`-Log
- Web UI unter `http://[IP]:[PORT]`, bind `0.0.0.0`, systemd `enable` + `Restart=always` + `After=network-online.target`, `onboot: 1`
- Verifikation: `systemctl is-active` + HTTP-Check + finale URL-Ausgabe
- Deliverables: `[app].sh`, App-Code inkl. Web UI, systemd-Unit, README, Reboot-Test mit Log

Annahmen (bestaetigt 2026-10-11):
- Ziel = LXC (keine VM): Pinn ist leichtgewichtig (PocketBase + Alpine + Caddy + optionale Container duckdns/tailscale/traccar/ha-netz/wartung), passt in Community-Script-Defaults
- Defaults: 2 vCPU / 2048 MB RAM / 8 GB Disk, Debian 12 Template, unprivilegiert mit `nesting=1,keyctl=1` fuer Docker, `vmbr0` DHCP, `onboot: 1`, Hostname `pinn`
- Web-UI-Port = 8090 (aus `docker-compose.yaml`: `pocketbase` `8090:80`; HTTPS 8443 via Caddy bleibt optional, MVP prueft 8090)
- Dateien leben im Installer-Repo `HatchetMan111/FamilyPlanner-PINN-Proxmox` unter `install/pinn.sh` (Host-Teil) + `install/pinn-install.sh` (Container-Teil), damit der Einzeiler `bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/FamilyPlanner-PINN-Proxmox/main/install/pinn.sh)"` funktioniert (geaendert 2026-10-11 per User-Vorgabe, war vorher pinn-shost/pinn)
- Tech-Stack im Gast: Debian 12 + Docker Engine + Compose-Plugin + git/curl/ca-certificates, `/opt/pinn` als Clone-Ziel, offizielles `pinn-setup.sh` wird wiederverwendet (kein Fork der Compose-Logik)

Nicht-Ziele MVP: VM-Variante, Traccar-Autoaktivierung (`COMPOSE_PROFILES=tracker` bleibt aus), DuckDNS/Tailscale-Pflicht, HTTPS-:8443-Verifikation, Multi-Family-Seeding, Migration bestehender NAS-Daten.

## 2. Ansatz-Entscheid

Gewahlt: A — LXC + Docker + offizielles Setup wiederverwenden, 2-Datei-Split (Host + Container).

- Warum LXC statt VM: Ressourcenprofil klein (PocketBase-Single-Binary, Alpine-Images), kein eigener Kernel noetig, Community-Scripts-Standard (`pct create/start/push/exec`), schnellster Reboot-Test.
- Warum Docker statt nativ: Upstream-Layout ist Docker-first (`docker-compose.yaml` mit 6 Services, `pinn-setup.sh` sortiert `pb_hooks/pb_public/caddy`, laedt pdf.js/Tesseract, baut PocketBase-Image mit Pruefsumme); nativ muesste Caddy/Traccar/Wartung/Backups nachgebaut werden = Drift.
- Warum 2 Dateien: Host-Script bleibt schlank (CT-Lifecycle + IP-Poll + Verifikation), Container-Script enthaelt apt/Docker/Clone/Setup/Unit (lintbar, `pct push`-faehig, auch manuell im CT lauffaehig).

Verworfen:
- B Single-File mit Heredoc: >400 Zeilen in einer Datei, ShellCheck/`bash -n` schwerer, Wartung schlechter, kein Vorteil ausser einer Datei weniger.
- C Nativ ohne Docker (PocketBase-Binary + systemd direkt): spart Docker-Overhead, bricht aber Update-Pfad (`Updates per Knopf` via Container `wartung` + `pinn-setup.sh`), Caddy/DuckDNS/ha-netz/tailscale muessten manuell repliziert werden.

## 3. Architektur

- 1x LXC `pinn` (Debian 12, unprivilegiert): Default 2 vCPU / 2048 MB / 8 GB, `local-lvm` (Fallback `local`), `vmbr0` DHCP, `features: nesting=1,keyctl=1`, `onboot: 1`. CTID = naechste freie (`pvesh get /cluster/nextid`, override via `CTID=`-Env/Flag).
- Im Gast: `/opt/pinn` (git clone `https://github.com/pinn-shost/pinn`, danach `git pull --ff-only` bei Re-Run), Systemdeps `curl git ca-certificates`, Docker-Install via offiziellem `get.docker.com` (idempotent, `docker --version`-Check), Compose-Plugin.
- Setup-Ausfuehrung: `sh pinn-setup.sh` im `/opt/pinn` (legt Ordner `pb_data/konfig/backups/wartung/traccar/...`, `.env` aus `env.txt`, laedt Vendor-Libs, `docker compose up -d --build`, wartet auf `/api/health`). Keine Compose-Fork: Datei bleibt Upstream.
- systemd-Unit `pinn.service`: `After=network-online.target`, `Wants=network-online.target`, `Restart=always`, `WorkingDirectory=/opt/pinn`, `ExecStart=/usr/bin/docker compose up --build`, `ExecStop=/usr/bin/docker compose down`, `enable --now`. Docker selbst via `systemctl enable docker`.
- Host-Script `install/pinn.sh`: Variablen oben (APP=pinn, APP_PORT=8090, UPSTREAM_REPO=pinn-shost/pinn, INSTALLER_PATH=install/pinn-install.sh, Defaults CPU/RAM/DISK/BRIDGE/STORAGE/TEMPLATE), Template-Auto (`pveam update + download` falls fehlend), `pct create/start`, Guest-IP-Poll (`pct exec ip -4 route` + `pct config`, Timeout 5 Min), `pct push` + `pct exec` Container-Setup, Verifikation, finale Ausgabe.
- Update: Re-Run Host-Script erkennt existierenden CT per Hostname/`pct config` -> nur Gast-Provision (`git pull + sh pinn-setup.sh + systemctl restart pinn`). Deinstall: `pct stop <ID> + pct destroy <ID>` (Doku-Hinweis, kein Auto-Destroy).

## 4. Datenfluss

1. User auf PVE-Host: `CTID= CPU=2 RAM=2048 DISK=8 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/FamilyPlanner-PINN-Proxmox/main/install/pinn.sh)"` (ohne Env = Defaults + naechste freie ID).
2. Host: naechste freie CTID bestimmen, Storage-Auto (local-lvm bevorzugt), Template-Check/Download (debian-12-standard), `pct create` (Hostname pinn, unprivilegiert, nesting/keyctl, onboot=1, vmbr0 DHCP), `pct start`, IP-Poll bis DHCP-Adresse da.
3. Gast-Provision: `pct push install/pinn-install.sh /tmp/pinn-install.sh` (Fallback: `curl` raw-URL im Gast), `pct exec -- sh /tmp/pinn-install.sh` (apt-Update, Docker-Check/Install, clone/pull nach /opt/pinn, `sh pinn-setup.sh`, Unit schreiben/enable/now).
4. Verifikation (Host via `pct exec` + Gast-intern): `systemctl is-active pinn` = active + `curl -fsS http://127.0.0.1:8090/api/health` 200 Poll bis 3 Min + `pct config <ID> | grep -q onboot` + Port-Check 8090.
5. Ausgabe: finale URL `http://<LXC-IP>:8090`, CTID/Name/Ressourcen, Ersteinrichtungs-Hinweis (`Als Hauptadmin anmelden`, Passwort `Admin` beim ersten Mal, danach Setup-Assistent), Update-/Deinstall-/Reboot-Zeilen, Logpfad `/tmp/pinn-install-*.log`.

## 5. Robustheit / Security / Testing

- Fehler: `set -euo pipefail` in beiden Scripts, Trap mit Befehl+Zeile+Exit+caller-Stack, dazu `pct config/status`, `journalctl -u pinn -n 100`, `docker logs pocketbase --tail 80`, `docker compose ps`, Voll-Log per `tee /tmp/pinn-install-*.log`, `--debug` = `set -x`/`bash -x`-Hinweis. Niemals nur letzte Zeile.
- Idempotenz: CT existiert -> kein Neu-Create (Abbruch mit Hinweis oder Provision-only); `/opt/pinn/.git` existiert -> `pull` statt `clone`; Docker vorhanden -> Skip Install; Unit existiert -> ueberschreiben + `daemon-reload`.
- Health: PocketBase-Healthcheck (`/api/health`) + systemd Restart=always + CT onboot=1. Bind 0.0.0.0 kommt aus Compose (`8090:80`), kein Extra-iptables im MVP ausser Doku-Hinweis falls PVE-Firewall aktiv.
- Security: keine Secrets in Logs (`.env`/`konfig/pinn.env` nie catten), nur LAN-Bind dokumentiert, unprivilegierter CT, kein Root-Passwort im Script (pct ohne Password = Key/Root-Login des Hosts).
- Tests: `bash -n` + ShellCheck (beide Scripts), Install -> is-active + HTTP-200, `pct reboot <ID>` -> 120 s -> is-active + HTTP-200 + onboot-Check, Reboot-Log als Beleg. Kein Live-Proxmox hier: Trockenlint + Vorlage genuegt, E2E auf PVE des Users.

## 6. Erfolgs- / Abnahmekriterien MVP

1. Einzeiler erstellt LXC mit naechster freier ID + Hostname pinn (Defaults 2/2048/8G).
2. Service active + Web UI auf `http://<LXC-IP>:8090` erreichbar (`/api/health` 200).
3. Reboot-Test bestanden (nach `pct reboot` wieder active + HTTP 200, Log vorhanden).
4. README-Patch mit Einzeiler + Update-/Deinstall-Hinweis + erwarteter Ausgabe.
5. Dateien: `install/pinn.sh`, `install/pinn-install.sh`, `install/pinn.service` (Unit-Vorlage), README-Abschnitt.

## 7. Offene Punkte fuer Plan-Phase

- Exakter Template-String (debian-12-standard Version pinnen oder `pveam available`-dynamisch?) und Storage-Auto-Reihenfolge (local-lvm vs. local vs. USER_STORAGE).
- `pct push` vs. `curl`-Fallback im Gast (aeltere PVE ohne push?) — beide einbauen oder nur push?
- HTTPS-:8443 im MVP verifizieren oder nur dokumentieren (DuckDNS erst via Setup-Assistent)?
- Vendor-Lib-Download (pdf.js/Tesseract via jsDelivr) im LXC-Erstlauf als Pflicht oder best-effort mit Warnung (wie Upstream)?
- README-Platzierung: Upstream-README Sektion vs. `install/README.md` — Upstream-Pflege mit 4 Sprachen (en/de/fr/es) beachten?

Spec Self-Review: keine TBD/TODO ausser bewusst offengelassenen Plan-Punkten oben; konsistent mit Freigabe (LXC, Standard 2/2048/8G, :8090, Dateien im Installer-Repo FamilyPlanner-PINN-Proxmox unter install/); Scope = 1 MVP; ID/Hostname/Ports/Verifikation eindeutig.
