#!/usr/bin/env bash
#
# snowflake-control.sh
# ====================
# Kontroll- und Monitoring-Skript fuer den Snowflake-Proxy.
# Gegenstueck zu snowflake-setup.sh (Installation/Update).
#
# Aufruf:
#   ./snowflake-control.sh              -> Gesamtuebersicht (Standard)
#   ./snowflake-control.sh status       -> nur Dienststatus
#   ./snowflake-control.sh conn         -> Verbindungen und Traffic
#   ./snowflake-control.sh version      -> installierte vs. neueste Version
#   ./snowflake-control.sh live         -> Log live verfolgen (Strg+C zum Beenden)
#   ./snowflake-control.sh timer        -> Auto-Update-Timer pruefen
#
# Fuer die reine Anzeige ist kein sudo noetig (journalctl-Zugriff vorausgesetzt:
#   sudo usermod -aG systemd-journal $USER   -> danach ab- und wieder anmelden)
#
set -euo pipefail

# ----------------------------------------------------------------------------
# Konfiguration - muss zu snowflake-setup.sh passen
# ----------------------------------------------------------------------------
METRICS_PORT="9999"
BIN_PATH="/usr/local/bin/snowflake-proxy"
SRC_DIR="/opt/snowflake-src"
GIT_REPO="https://gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/snowflake.git"
# ----------------------------------------------------------------------------

fett()   { echo -e "\e[1m$*\e[0m"; }
gruen()  { echo -e "\e[32m$*\e[0m"; }
gelb()   { echo -e "\e[33m$*\e[0m"; }
rot()    { echo -e "\e[31m$*\e[0m"; }
titel()  { echo; fett "─── $* ───────────────────────────────"; }

# ----------------------------------------------------------------------------
# Dienststatus
# ----------------------------------------------------------------------------
zeige_status() {
    titel "Dienststatus"
    if systemctl is-active --quiet snowflake-proxy; then
        gruen "● snowflake-proxy laeuft"
    else
        rot "● snowflake-proxy laeuft NICHT"
    fi
    # Laufzeit, PID, Speicherverbrauch
    systemctl show snowflake-proxy \
        --property=ActiveEnterTimestamp,MainPID,MemoryCurrent 2>/dev/null \
        | while IFS='=' read -r key val; do
            case "$key" in
                ActiveEnterTimestamp) echo "  Gestartet:  ${val:-unbekannt}" ;;
                MainPID)              echo "  PID:        ${val:-–}" ;;
                MemoryCurrent)
                    if [[ "$val" =~ ^[0-9]+$ ]]; then
                        echo "  Speicher:   $(( val / 1024 / 1024 )) MiB"
                    fi ;;
            esac
        done
    if systemctl is-enabled --quiet snowflake-proxy 2>/dev/null; then
        echo "  Autostart:  aktiviert"
    else
        gelb "  Autostart:  NICHT aktiviert (sudo systemctl enable snowflake-proxy)"
    fi
}

# ----------------------------------------------------------------------------
# Verbindungen und Traffic
# ----------------------------------------------------------------------------
zeige_verbindungen() {
    titel "Aktive Verbindungen (Metriken)"
    local metriken
    if metriken=$(curl -sf --max-time 3 "localhost:$METRICS_PORT/internal/metrics" 2>/dev/null); then
        # Die wichtigsten Kennzahlen herausfiltern
        echo "$metriken" | grep -E '^tor_snowflake|^snowflake' \
            | grep -vE '^#' \
            | grep -iE 'connect|traffic|inbound|outbound|client' \
            | sed 's/^/  /' || echo "  (keine passenden Metriken gefunden)"
    else
        gelb "  Metrik-Endpunkt localhost:$METRICS_PORT nicht erreichbar."
        gelb "  Laeuft der Proxy mit -metrics -metrics-port $METRICS_PORT ?"
    fi

    titel "Vermittelte Verbindungen (Log, letzte 24h)"
    # Stuendliche Zusammenfassungen aus dem Journal ziehen
    local summaries
    summaries=$(journalctl -u snowflake-proxy --since "24 hours ago" --no-pager 2>/dev/null \
        | grep -E "In the last" || true)
    if [[ -n "$summaries" ]]; then
        echo "$summaries" | tail -6 | sed 's/^/  /'
        # Gesamtzahl der Verbindungen in 24h aufsummieren
        local gesamt
        gesamt=$(echo "$summaries" | grep -oE "there were [0-9]+" | grep -oE "[0-9]+" \
            | awk '{s+=$1} END {print s+0}')
        echo
        gruen "  Summe letzte 24h: $gesamt vermittelte Verbindungen"
    else
        gelb "  Noch keine Zusammenfassungen im Log (erste kann bis zu 1h dauern)"
        gelb "  oder kein Journal-Zugriff (Gruppe systemd-journal, siehe Kopfzeile)."
    fi
}

# ----------------------------------------------------------------------------
# Versionskontrolle: installiert vs. neueste Upstream-Version
# ----------------------------------------------------------------------------
zeige_version() {
    titel "Versionskontrolle"

    # Installierte Version
    local installiert="unbekannt"
    if [[ -x "$BIN_PATH" ]]; then
        installiert=$("$BIN_PATH" -version 2>&1 | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unbekannt")
    fi
    # Fallback: Git-Tag im Quellverzeichnis
    if [[ "$installiert" == "unbekannt" && -d "$SRC_DIR/.git" ]]; then
        installiert=$(git -C "$SRC_DIR" describe --tags --abbrev=0 2>/dev/null || echo "unbekannt")
    fi
    echo "  Installiert: $installiert"

    # Neueste Version per git ls-remote (funktioniert ohne Login, trotz Bot-Schutz der Webseite)
    local neueste
    neueste=$(git ls-remote --tags --refs "$GIT_REPO" 2>/dev/null \
        | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+$' \
        | sort -V | tail -1 || echo "")
    if [[ -n "$neueste" ]]; then
        echo "  Upstream:    $neueste"
        # Vergleich (fuehrendes v vereinheitlichen)
        if [[ "${installiert#v}" == "${neueste#v}" ]]; then
            gruen "  -> Aktuell."
        else
            gelb "  -> Update verfuegbar! Ausfuehren: sudo /usr/local/sbin/snowflake-setup.sh update"
        fi
    else
        gelb "  Upstream-Version konnte nicht abgefragt werden (Netzwerk?)."
    fi
}

# ----------------------------------------------------------------------------
# Auto-Update-Timer
# ----------------------------------------------------------------------------
zeige_timer() {
    titel "Auto-Update-Timer"
    if systemctl list-timers snowflake-update.timer --no-pager 2>/dev/null | grep -q snowflake-update; then
        systemctl list-timers snowflake-update.timer --no-pager | sed 's/^/  /'
        echo
        echo "  Letztes Update-Log:"
        journalctl -u snowflake-update.service -n 5 --no-pager 2>/dev/null | sed 's/^/    /' \
            || echo "    (kein Log verfuegbar)"
    else
        gelb "  Kein Auto-Update-Timer eingerichtet."
        gelb "  Einrichten: sudo /usr/local/sbin/snowflake-setup.sh autoupdate"
    fi
}

# ----------------------------------------------------------------------------
# Hauptablauf
# ----------------------------------------------------------------------------
case "${1:-alles}" in
    status)   zeige_status ;;
    conn)     zeige_verbindungen ;;
    version)  zeige_version ;;
    timer)    zeige_timer ;;
    live)
        fett "Log live (Strg+C zum Beenden):"
        journalctl -u snowflake-proxy -f
        ;;
    alles|*)
        zeige_status
        zeige_verbindungen
        zeige_version
        zeige_timer
        echo
        ;;
esac
