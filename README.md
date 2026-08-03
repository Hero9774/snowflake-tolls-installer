# snowflake-tolls-installer
Bash-Skripte für den Betrieb eines Tor Snowflake Standalone-Proxys unter Debian/Ubuntu: Build aus dem Quellcode, gehärteter systemd-Dienst, wöchentliches Auto-Update per Timer sowie ein Kontroll-Skript für Status, Verbindungsstatistik und Versionsvergleich.
##########################

## Lizenz

Diese Skripte: BSD-3-Clause — siehe [LICENSE](LICENSE).
Snowflake selbst: BSD-3-Clause, © The Tor Project.

# snowflake-tools

Zwei Bash-Skripte für den unkomplizierten Betrieb eines
[Tor Snowflake](https://snowflake.torproject.org/) Standalone-Proxys auf
Debian-/Ubuntu-basierten Systemen.

Ein Snowflake-Proxy hilft Menschen in zensierten Netzen, das Tor-Netzwerk zu
erreichen. Er leitet **keinen** Exit-Traffic weiter — es gibt also keine
Abuse-Meldungen und kein rechtliches Risiko wie beim Betrieb einer Exit-Node.

| Skript | Zweck |
| --- | --- |
| `snowflake-setup.sh` | Installation, Updates, systemd-Dienst, Auto-Update-Timer |
| `snowflake-control.sh` | Statusübersicht, Verbindungsstatistik, Versionsvergleich |

## Warum aus dem Quellcode bauen?

Die Paketversionen in den Distributions-Repos hinken dem Upstream oft mehrere
Minor-Versionen hinterher. Bei Snowflake ist das nicht nur Kosmetik: Die
Gegenmaßnahmen zur Zensurerkennung (uTLS-Fingerprints, Broker-Rendezvous,
DTLS-Verschleierung) ändern sich laufend. Eine veraltete Version läuft zwar,
vermittelt aber unter Umständen deutlich weniger Clients.

`snowflake-setup.sh` baut deshalb direkt aus dem
[offiziellen Tor-GitLab](https://gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/snowflake).

## Voraussetzungen

- Debian-/Ubuntu-basiertes System mit systemd (getestet auf AnduinOS 2.0.1)
- Root-Rechte für die Installation
- Internetverbindung; **keine** Portweiterleitung nötig
- Optimal: NAT mit *Endpoint-Independent Mapping* (übliche Heimrouter wie die
  FritzBox erfüllen das)

Alles Weitere — Go, Git, Dienstbenutzer, Firewall-Regel — richtet das Skript
selbst ein.

## Installation

```bash
git clone https://github.com/DEIN-NAME/snowflake-tools.git
cd snowflake-tools
chmod +x *.sh
sudo ./snowflake-setup.sh
```

Wichtig: mit `sudo ./skript.sh` starten, **nicht** mit `sh skript.sh` — letzteres
startet das Skript unter `dash`, das einige verwendete Bash-Features nicht kennt.

Nach der Installation läuft der Proxy als systemd-Dienst und startet bei jedem
Boot automatisch. Bis die erste Verbindung vermittelt wird, kann es bis zu einer
Stunde dauern — das ist normal.

## snowflake-setup.sh

```bash
sudo ./snowflake-setup.sh              # Installation (bzw. Update bei erneutem Aufruf)
sudo ./snowflake-setup.sh update       # Quellcode aktualisieren, neu bauen, Neustart
sudo ./snowflake-setup.sh autoupdate   # wöchentliches Auto-Update einrichten
sudo ./snowflake-setup.sh status       # Kurzstatus
```

Was die Installation macht:

1. Installiert `golang-go` und `git`
2. Klont den Snowflake-Quellcode nach `/opt/snowflake-src` und baut den Proxy
3. Legt einen Systembenutzer `snowflake` ohne Login-Shell an
4. Schreibt eine gehärtete systemd-Unit (`ProtectSystem=strict`,
   `NoNewPrivileges`, leeres `CapabilityBoundingSet`, `MemoryMax=512M`)
5. Gibt den UDP-Portbereich in `ufw` frei, sofern ufw aktiv ist
6. Deaktiviert Suspend/Hibernate für den Dauerbetrieb (abschaltbar)

Das Skript ist idempotent und kann gefahrlos mehrfach ausgeführt werden.

### Auto-Update

```bash
sudo ./snowflake-setup.sh autoupdate
```

Kopiert das Skript nach `/usr/local/sbin/` und legt `snowflake-update.timer` an:
wöchentlich montags 04:30 Uhr, mit 30 Minuten Zufallsversatz und
`Persistent=true` — war der Rechner zu dem Zeitpunkt aus, wird das Update beim
nächsten Start nachgeholt.

Der kurze Dienst-Neustart nach dem Update ist unkritisch: Snowflake-Verbindungen
sind ohnehin kurzlebig, betroffene Clients holen sich einfach den nächsten Proxy.

### Konfiguration

Im Kopf des Skripts anpassbar:

| Variable | Standard | Bedeutung |
| --- | --- | --- |
| `SRC_DIR` | `/opt/snowflake-src` | Ablage des Quellcodes |
| `BIN_PATH` | `/usr/local/bin/snowflake-proxy` | Zielpfad des Binaries |
| `SERVICE_USER` | `snowflake` | Dienstbenutzer |
| `PORT_RANGE` | `40000:50000` | UDP-Portbereich für WebRTC |
| `METRICS_PORT` | `9999` | Prometheus-Endpunkt (nur localhost) |
| `SUMMARY_INTERVAL` | `1h` | Intervall der Log-Zusammenfassung |
| `CAPACITY` | *(leer)* | Max. gleichzeitige Clients; leer = unbegrenzt |
| `DISABLE_SUSPEND` | `ja` | Suspend/Hibernate systemweit deaktivieren |

Nach Änderungen das Skript erneut ausführen.

## snowflake-control.sh

```bash
./snowflake-control.sh           # Gesamtübersicht
./snowflake-control.sh status    # Dienststatus, Laufzeit, RAM, Autostart
./snowflake-control.sh conn      # Metriken und Verbindungen der letzten 24 h
./snowflake-control.sh version   # installierte vs. neueste Upstream-Version
./snowflake-control.sh timer     # Auto-Update-Timer und letztes Update-Log
./snowflake-control.sh live      # Log live verfolgen
```

Die Versionsprüfung fragt die Upstream-Tags per `git ls-remote` ab. Das umgeht
den Bot-Schutz der GitLab-Weboberfläche und funktioniert ohne Anmeldung.

Für die Nutzung ohne `sudo` einmalig den Journal-Zugriff freischalten:

```bash
sudo usermod -aG systemd-journal $USER
```

Danach ab- und wieder anmelden.

## Betriebshinweise

**Bandbreite.** Ein durchgehend laufender Proxy mit gutem NAT bewegt je nach
Nachfrage grob 10–100 GB im Monat. Bei Volumenbegrenzung lässt sich das über
`CAPACITY` deckeln.

**Ressourcen.** Snowflake ist nahezu reines I/O; die CPU-Last bleibt im niedrigen
einstelligen Prozentbereich, der Speicherbedarf unter 100 MB.

**NAT-Typ prüfen.** Bei restriktivem NAT vermittelt der Proxy deutlich weniger:

```bash
sudo apt install stuntman-client
stunclient --mode full stun.stunprotocol.org
```

Erwünscht ist *Independent Mapping*.

**Wo betreiben.** Ein Snowflake-Proxy sollte nur in Ländern und Netzen laufen, in
denen das keine Probleme verursacht. In stark zensierenden Staaten kann der
Betrieb Aufmerksamkeit erregen.

## Deinstallation

```bash
sudo systemctl disable --now snowflake-proxy snowflake-update.timer
sudo rm -f /etc/systemd/system/snowflake-{proxy.service,update.service,update.timer}
sudo systemctl daemon-reload
sudo rm -f /usr/local/bin/snowflake-proxy /usr/local/sbin/snowflake-setup.sh
sudo rm -rf /opt/snowflake-src
sudo userdel snowflake
sudo systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target
```

## Alternativen

Wer keinen Wert auf die jeweils aktuellste Version legt oder ohnehin Docker
einsetzt, kommt auch einfacher ans Ziel:

```bash
sudo apt install snowflake-proxy          # bequem, aber oft veraltet
sudo snap install tor-snowflake           # aktuell, mit Auto-Update
```

Docker (`thetorproject/snowflake-proxy:latest`, zwingend mit
`network_mode: host`) ist auf Servern und NAS-Systemen meist die bessere Wahl.
Ein Flatpak gibt es nicht sinnvoll — Flatpak ist auf GUI-Anwendungen im
Benutzerkontext ausgelegt und bietet keine saubere Integration als
System-Dienst.

## Lizenz

Diese Skripte: MIT.
Snowflake selbst: BSD-3-Clause, © The Tor Project.

## Links

- [Snowflake-Projektseite](https://snowflake.torproject.org/)
- [Tor Community: Standalone-Proxy](https://community.torproject.org/relay/setup/snowflake/standalone/)
- [Quellcode-Repository](https://gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/snowflake)
- [Tor Forum](https://forum.torproject.org/) — für Fragen zum Proxy selbst
