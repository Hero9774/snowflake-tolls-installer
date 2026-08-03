#!/usr/bin/env bash
#
# snowflake-setup.sh
# ==================
# Installiert oder aktualisiert einen Tor Snowflake Standalone-Proxy
# auf einem Ubuntu-/Debian-basierten System (z.B. AnduinOS) als systemd-Dienst.
#
# Aufruf:
#   sudo ./snowflake-setup.sh            -> Installation (oder Update, falls schon vorhanden)
#   sudo ./snowflake-setup.sh update     -> nur Quellcode aktualisieren, neu bauen, Dienst neustarten
#   sudo ./snowflake-setup.sh status     -> Dienststatus und letzte Log-Zeilen anzeigen
#   sudo ./snowflake-setup.sh autoupdate -> woechentliches automatisches Update per systemd-Timer einrichten
#
set -euo pipefail

# ----------------------------------------------------------------------------
# Konfiguration - bei Bedarf anpassen
# ----------------------------------------------------------------------------
SRC_DIR="/opt/snowflake-src"          # Ablage des Quellcodes
BIN_PATH="/usr/local/bin/snowflake-proxy"
SERVICE_USER="hero"              # eigener Dienstbenutzer ohne Login
PORT_RANGE="40000:40255"              # UDP-Portbereich fuer WebRTC
METRICS_PORT="9999"                   # Prometheus-Metriken (nur localhost)
SUMMARY_INTERVAL="1h"                 # Intervall der Log-Zusammenfassung
CAPACITY="15"                           # z.B. "15" um gleichzeitige Clients zu deckeln, leer = unbegrenzt
DISABLE_SUSPEND="ja"                  # "ja" = Suspend/Hibernate systemweit deaktivieren
# ----------------------------------------------------------------------------

UNIT_FILE="/etc/systemd/system/snowflake-proxy.service"

rot()   { echo -e "\e[31m$*\e[0m"; }
gruen() { echo -e "\e[32m$*\e[0m"; }
info()  { echo -e "\e[36m==> $*\e[0m"; }

# Root-Pruefung
if [[ $EUID -ne 0 ]]; then
    rot "Bitte mit sudo ausfuehren: sudo $0"
    exit 1
fi

# ----------------------------------------------------------------------------
# Funktion: Quellcode holen/aktualisieren und bauen
# ----------------------------------------------------------------------------
bauen() {
    info "Abhaengigkeiten installieren (golang, git)..."
    apt-get update -qq
    apt-get install -y -qq golang-go git

    if [[ -d "$SRC_DIR/.git" ]]; then
        info "Quellcode aktualisieren..."
        git -C "$SRC_DIR" pull --ff-only
    else
        info "Quellcode klonen..."
        git clone https://gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/snowflake.git "$SRC_DIR"
    fi

    info "Proxy kompilieren..."
    cd "$SRC_DIR/proxy"
    go build -o snowflake-proxy .

    info "Binary nach $BIN_PATH installieren..."
    install -m 0755 snowflake-proxy "$BIN_PATH"

    gruen "Gebaut: $("$BIN_PATH" -version 2>&1 | head -1 || true)"
}

# ----------------------------------------------------------------------------
# Funktion: systemd-Unit schreiben
# ----------------------------------------------------------------------------
unit_schreiben() {
    info "Dienstbenutzer '$SERVICE_USER' anlegen (falls nicht vorhanden)..."
    id -u "$SERVICE_USER" &>/dev/null || \
        useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"

    # Startkommando zusammensetzen
    local CMD="$BIN_PATH -summary-interval $SUMMARY_INTERVAL -ephemeral-ports-range $PORT_RANGE -metrics -metrics-port $METRICS_PORT"
    [[ -n "$CAPACITY" ]] && CMD="$CMD -capacity $CAPACITY"

    info "systemd-Unit schreiben: $UNIT_FILE"
    cat > "$UNIT_FILE" <<EOF
[Unit]
Description=Tor Snowflake Proxy
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$CMD
User=$SERVICE_USER
Group=$SERVICE_USER
Restart=on-failure
RestartSec=10
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
CapabilityBoundingSet=
MemoryMax=512M

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now snowflake-proxy
}

# ----------------------------------------------------------------------------
# Funktion: Firewall (ufw) - nur wenn ufw aktiv ist
# ----------------------------------------------------------------------------
firewall() {
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        info "ufw aktiv - UDP-Portbereich $PORT_RANGE freigeben..."
        ufw allow "${PORT_RANGE/:/\:}"/udp >/dev/null
    else
        info "ufw nicht aktiv - keine Firewall-Regel noetig."
    fi
}

# ----------------------------------------------------------------------------
# Funktion: Suspend/Hibernate deaktivieren (24/7-Betrieb)
# ----------------------------------------------------------------------------
suspend_aus() {
    if [[ "$DISABLE_SUSPEND" == "ja" ]]; then
        info "Suspend/Hibernate systemweit deaktivieren..."
        systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null || true
        # GNOME-Energieeinstellung fuer den gerade angemeldeten Benutzer setzen
        local DESK_USER
        DESK_USER=$(logname 2>/dev/null || echo "")
        if [[ -n "$DESK_USER" ]]; then
            sudo -u "$DESK_USER" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$DESK_USER")/bus" \
                gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing' 2>/dev/null || true
        fi
    fi
}

# ----------------------------------------------------------------------------
# Funktion: Woechentliches Auto-Update per systemd-Timer einrichten
# ----------------------------------------------------------------------------
autoupdate_einrichten() {
    # Dieses Skript an festen Ort kopieren, damit der Timer es findet
    local SCRIPT_ZIEL="/usr/local/sbin/snowflake-setup.sh"
    info "Skript nach $SCRIPT_ZIEL kopieren..."
    install -m 0755 "$(readlink -f "$0")" "$SCRIPT_ZIEL"

    info "Update-Service schreiben..."
    cat > /etc/systemd/system/snowflake-update.service <<EOF
[Unit]
Description=Snowflake Proxy - Quellcode aktualisieren und neu bauen
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_ZIEL update
EOF

    info "Update-Timer schreiben (woechentlich, Montag 04:30)..."
    cat > /etc/systemd/system/snowflake-update.timer <<EOF
[Unit]
Description=Woechentliches Snowflake-Proxy-Update

[Timer]
OnCalendar=Mon *-*-* 04:30:00
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now snowflake-update.timer
    gruen "Auto-Update aktiv. Naechste Ausfuehrung:"
    systemctl list-timers snowflake-update.timer --no-pager
}

# ----------------------------------------------------------------------------
# Funktion: Status anzeigen
# ----------------------------------------------------------------------------
status_zeigen() {
    systemctl status snowflake-proxy --no-pager || true
    echo
    info "Letzte Log-Eintraege:"
    journalctl -u snowflake-proxy -n 15 --no-pager || true
    echo
    info "Metriken (Auszug):"
    curl -s "localhost:$METRICS_PORT/internal/metrics" 2>/dev/null | grep -m5 snowflake || echo "(noch keine Metriken verfuegbar)"
}

# ----------------------------------------------------------------------------
# Hauptablauf
# ----------------------------------------------------------------------------
case "${1:-install}" in
    update)
        bauen
        systemctl restart snowflake-proxy
        gruen "Update abgeschlossen."
        status_zeigen
        ;;
    status)
        status_zeigen
        ;;
    autoupdate)
        autoupdate_einrichten
        ;;
    install|*)
        bauen
        unit_schreiben
        firewall
        suspend_aus
        gruen "Installation abgeschlossen."
        echo
        status_zeigen
        echo
        gruen "Hinweis: Die erste vermittelte Verbindung kann bis zu einer Stunde dauern."
        gruen "Log verfolgen:   journalctl -u snowflake-proxy -f"
        gruen "Update spaeter:  sudo $0 update"
        ;;
esac
