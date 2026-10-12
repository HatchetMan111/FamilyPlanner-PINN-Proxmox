# FamilyPlanner PINN für Proxmox (LXC, Community-Scripts-Stil)

Installiert **[pinn.](https://github.com/pinn-shost/pinn)** – den Self-hosted Family Organizer
(geteilter Kalender, Essensplanung, Einkaufslisten, Aufgaben, Finanzen u. v. m., PocketBase + Docker,
keine Cloud, keine Abos) – als **LXC-Container auf Proxmox VE**, mit einem **Einzeiler** im Stil der
[Proxmox VE Community Scripts](https://community-scripts.github.io/ProxmoxVE).

Upstream-App: https://github.com/pinn-shost/pinn · Design-Spec: `docs/superpowers/specs/2026-10-11-pinn-proxmox-design.md`

## Einzeiler (auf dem Proxmox-Host ausführen)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/FamilyPlanner-PINN-Proxmox/main/install/pinn.sh)"
```

> Stand: `install/pinn.sh` und `install/pinn-install.sh` sind in Arbeit (Plan-Phase).
> Der Einzeiler funktioniert erst, sobald diese Dateien hier auf `main` liegen.

## Was das Script tut

1. Nimmt die **nächste freie CT-ID** (`pvesh get /cluster/nextid`, per `CTID=` übersteuerbar) und legt
   einen LXC mit **Namen `pinn`** an (Debian 12, unprivilegiert, `nesting=1,keyctl=1` für Docker, `onboot: 1`).
2. Installiert im Container Docker + Compose-Plugin, klont den Upstream nach `/opt/pinn` und führt das
   offizielle `pinn-setup.sh` aus (kein Fork der Compose-Logik).
3. Richtet den systemd-Service **`pinn.service`** ein (`systemctl enable`, `Restart=always`,
   `After=network-online.target`) und verifiziert: `systemctl is-active` + HTTP-Check auf `localhost:8090`.
4. Gibt am Ende die finale URL **`http://[LXC-IP]:8090`** plus Container-IP aus.

## Defaults

| Variable | Default | Bedeutung |
|---|---|---|
| `APP` / Hostname | `pinn` | LXC-Name |
| `CTID` | nächste freie | per `CTID=123` übersteuerbar |
| `CPU` | `2` | vCPUs |
| `RAM` | `2048` | MB RAM |
| `DISK` | `8` | GB Disk |
| `TEMPLATE` | Debian 12 | wird per `pveam` geladen falls fehlend |
| `BRIDGE` | `vmbr0` | DHCP |
| `APP_PORT` | `8090` | Web-UI-Port |

Beispiel mit eigenen Werten:

```bash
CTID=150 CPU=2 RAM=2048 DISK=10 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/FamilyPlanner-PINN-Proxmox/main/install/pinn.sh)"
```

## Voraussetzungen

- Proxmox VE 8/9 mit Storage `local-lvm` (Fallback `local`), Bridge `vmbr0`, Internetzugang
  (github.com, Docker Hub, jsDelivr für Vendor-Libs).
- Script läuft als `root` auf dem PVE-Host.

## Nach der Installation

1. Im Browser `http://[LXC-IP]:8090` öffnen → **„Als Hauptadmin anmelden“**, Passwort beim ersten Mal: `Admin`.
2. Eigenes Passwort festlegen → der **Einrichtungs-Assistent** führt durch HTTPS (DuckDNS), Fernzugriff
   (WireGuard/Tailscale), Google, KI, Ortung und Home Assistant.
3. Auf jedem Handy die HTTPS-Adresse öffnen und zum Home-Screen hinzufügen (PWA).

Hinweis: `pinn.` lädt keine Daten in eine Cloud. Push-Mitteilungen enthalten keinen Inhalt
(nur Wecksignal, Gerät holt die Nachricht vom eigenen Server).

## Update

Script einfach erneut laufen lassen (idempotent: kein Neu-Create, nur `git pull` + `pinn-setup.sh` + Restart):

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/FamilyPlanner-PINN-Proxmox/main/install/pinn.sh)"
```

Alternativ im Container:

```bash
pct exec <CTID> -- bash -c 'cd /opt/pinn && git pull --ff-only && sh pinn-setup.sh && systemctl restart pinn'
```

Updates gehen danach auch per Knopf in pinn. (Einstellungen → System → Sicherungen & Updates).

## Deinstallieren

```bash
pct stop <CTID> && pct destroy <CTID>
```

(Daten im Container werden dabei gelöscht; Upstream-Backups liegen in `/opt/pinn/backups` im Container –
ggf. vorher sichern.)

## Reboot-Test (Beleg für Reboot-Sicherheit)

```bash
pct reboot <CTID>
sleep 120
pct exec <CTID> -- systemctl is-active pinn
curl -fsS http://[LXC-IP]:8090/api/health
pct config <CTID> | grep -q 'onboot: 1' && echo 'onboot OK'
```

Erwartet: `active`, HTTP-Antwort vom Health-Endpoint, `onboot OK`.

## Debugging

- Bei Fehlern gibt das Script die **komplette Fehlerkette** aus (Befehl, Zeile, Exit-Code, Logs) –
  niemals nur die letzte Zeile.
- Detail-Log: `bash -x` (Script mit `--debug` bzw. erneut mit `bash -x` starten).
- Relevante Logs im Container:

```bash
pct enter <CTID>
journalctl -u pinn -n 100 --no-pager
docker logs pocketbase --tail 80
docker compose -C /opt/pinn ps
```

## Dateien in diesem Repo

- `install/pinn.sh` – Host-Script (CT-Lifecycle, IP-Poll, Verifikation) *(in Arbeit)*
- `install/pinn-install.sh` – Container-Setup (Docker, Clone, Setup, systemd-Unit) *(in Arbeit)*
- `install/pinn.service` – systemd-Unit-Vorlage *(in Arbeit)*
- `docs/superpowers/specs/2026-10-11-pinn-proxmox-design.md` – freigegebene Design-Spec

## Lizenz

Installer-Scripts: MIT (wie Upstream pinn., https://github.com/pinn-shost/pinn/blob/main/LICENSE).
