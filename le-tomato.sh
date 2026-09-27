SCRIPT="$BASE/le-tomato.sh"

cat > "$SCRIPT" <<'EOF'
#!/bin/sh
# Tomato64 – Let's Encrypt helper v1.0 - rs232

BASE="__BASE__"
DEFAULT_DOMAIN="__DOMAIN__"

ACME_HOME="$BASE/.acme.sh"
CONFIG_HOME="$BASE/config"
ACME="$ACME_HOME/acme.sh"
WEBROOT="$BASE/webroot"
ME="$BASE/le-tomato.sh"
HANDLER="$BASE/http-handler.sh"
PIDFILE="/tmp/le-tomato.pid"
FWFLAG="/tmp/le-tomato-fw"
LOCKDIR="/tmp/le-tomato.lock"
CRUNAME="le-tomato-renew"
PORT=80
LOGTAG="le-tomato"

log() { logger -t "$LOGTAG" "$*" 2>/dev/null; echo "$*"; }
die() {
    logger -t "$LOGTAG" -p user.err "ERROR: $*" 2>/dev/null
    echo "ERROR: $*"
    exit 1
}

# Run acme.sh and drop BusyBox date-parse noise
run_acme() {
    out=$("$ACME" "$@" 2>&1)
    rc=$?
    echo "$out" | grep -v 'Cannot parse _ssldate2time' || true
    return $rc
}

get_domain() {
    DOMAIN="$DEFAULT_DOMAIN"
    [ -n "$DOMAIN" ] || die "No domain configured"
}

check_port80() {
    if grep -q ":0050 " /proc/net/tcp /proc/net/tcp6 2>/dev/null; then
        die "port 80 is already in use by a local process – stop it first"
    fi
    if iptables -t nat -S PREROUTING 2>/dev/null | grep -qE -- '--dport 80\b'; then
        die "port 80 has a NAT PREROUTING rule (redirect/DNAT) – remove it first"
    fi
}

add_fw() {
    if ! iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null; then
        iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT || die "Cannot open port $PORT in INPUT"
        echo 1 > "$FWFLAG"
    fi
}

rm_fw() {
    while iptables -D INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null; do
        :
    done
    rm -f "$FWFLAG"
}

create_handler() {
    cat > "$HANDLER" <<'HANDLER'
#!/bin/sh
WEBROOT="__WEBROOT__"
IFS= read -r REQUEST || exit 0
METHOD=$(echo "$REQUEST" | awk '{print $1}')
URI=$(echo "$REQUEST" | awk '{print $2}')
while IFS= read -r line; do
    [ -z "$line" ] || [ "$line" = $'\r' ] && break
done
[ "$METHOD" = "GET" ] || {
    printf 'HTTP/1.0 405 Method Not Allowed\r\nConnection: close\r\n\r\n'
    exit 0
}
case "$URI" in
    /.well-known/acme-challenge/*)
        TOKEN=${URI#/.well-known/acme-challenge/}
        case "$TOKEN" in
            ""|*/*|*"?"*|*"&"*|*" "*|*..*) FILE= ;;
            *) FILE="$WEBROOT/.well-known/acme-challenge/$TOKEN" ;;
        esac
        ;;
    *) FILE= ;;
esac
if [ -n "$FILE" ] && [ -f "$FILE" ]; then
    LEN=$(wc -c < "$FILE" | tr -d ' \n')
    printf 'HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %s\r\nConnection: close\r\n\r\n' "$LEN"
    cat "$FILE"
else
    printf 'HTTP/1.0 404 Not Found\r\nConnection: close\r\n\r\n'
fi
HANDLER
    sed -i "s|__WEBROOT__|$WEBROOT|g" "$HANDLER"
    chmod 700 "$HANDLER"
}

nc_pids() {
    ps w 2>/dev/null | awk -v p="$PORT" '
        /nc/ && /-l/ && ($0 ~ ("-p[ ]*" p) || $0 ~ ("-p" p)) && $0 !~ /awk/ { print $1 }
    '
}

kill_nc() {
    for pid in $(nc_pids); do
        kill "$pid" 2>/dev/null || true
    done
    if [ -f "$PIDFILE" ]; then
        kill "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null || true
        rm -f "$PIDFILE"
    fi
}

start_server() {
    stop_server >/dev/null 2>&1 || true
    check_port80
    mkdir -p "$WEBROOT/.well-known/acme-challenge"
    create_handler
    add_fw

    nc -lk -p "$PORT" -e "$HANDLER" &
    echo $! > "$PIDFILE"
    sleep 1

    if ! kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
        rm_fw
        die "nc failed to bind port $PORT"
    fi
    log "nc listening on port $PORT"
}

stop_server() {
    kill_nc
    rm_fw
}

install_certificate() {
    run_acme --install-cert \
        --domain "$1" \
        --key-file /etc/key.pem \
        --fullchain-file /etc/cert.pem \
        --reloadcmd "$ME reload" \
        --home "$ACME_HOME" \
        --config-home "$CONFIG_HOME" || die "install-cert failed"
    chmod 600 /etc/key.pem 2>/dev/null || true
    chmod 644 /etc/cert.pem 2>/dev/null || true
}

reload() {
    [ -s /etc/cert.pem ] && [ -s /etc/key.pem ] || die "missing cert/key"
    ARCHIVE=/tmp/le-cert.tgz
    ENCODED=/tmp/le-cert.b64
    tar -C / -czf "$ARCHIVE" etc/cert.pem etc/key.pem || die "tar failed"
    openssl enc -base64 -A -in "$ARCHIVE" -out "$ENCODED" || die "base64 failed"
    nvram set https_crt_file="$(cat "$ENCODED")"
    nvram set https_crt_save=1
    nvram commit
    rm -f "$ARCHIVE" "$ENCODED" /etc/server.pem
    service httpd restart >/dev/null 2>&1 || service httpd start >/dev/null 2>&1
    log "certificate loaded"
}

install_cron() {
    cru d "$CRUNAME" 2>/dev/null || true

    SEED="$(od -An -N4 -tu4 /dev/urandom 2>/dev/null | tr -d ' ')"
    [ -n "$SEED" ] || SEED=12345

    MIN=$((SEED % 60))
    HOUR=$((1 + (SEED / 60) % 4))

    cru a "$CRUNAME" "$MIN $HOUR * * 0 $ME renew" ||
        die "could not install weekly renewal job"

    log "scheduled weekly renew: Sunday $(printf '%02d:%02d' "$HOUR" "$MIN")"
}

remove_cron() {
    cru d "$CRUNAME" 2>/dev/null || true
}

issue() {
    get_domain
    [ -x "$ACME" ] || die "acme.sh not found – re-run the installer"

    rm -rf "$LOCKDIR"
    mkdir "$LOCKDIR" || die "another operation is running"
    echo $$ > "$LOCKDIR/pid"
    trap 'stop_server; rm -rf "$LOCKDIR"; exit' 0 1 2 3 15

    start_server
    log "issuing certificate for $DOMAIN"

    if run_acme --issue --force \
            --domain "$DOMAIN" \
            --server letsencrypt \
            --keylength 2048 \
            --webroot "$WEBROOT" \
            --home "$ACME_HOME" \
            --config-home "$CONFIG_HOME" \
            --syslog 0; then
        install_certificate "$DOMAIN"
        install_cron
        log "SUCCESS"
    else
        die "issue failed"
    fi
}

renew() {
    get_domain "$1"
    [ -x "$ACME" ] || die "acme.sh not found"

    rm -rf "$LOCKDIR"
    mkdir "$LOCKDIR" || die "another operation is running"
    echo $$ > "$LOCKDIR/pid"
    trap 'stop_server; rm -rf "$LOCKDIR"; exit' 0 1 2 3 15

    start_server
    log "renewing $DOMAIN"

    if run_acme --renew \
            --domain "$DOMAIN" \
            --home "$ACME_HOME" \
            --config-home "$CONFIG_HOME" \
            --syslog 0; then
        install_certificate "$DOMAIN"
        log "SUCCESS"
    else
        log "renew finished (not due or failed – check status)"
    fi
}

update() {
    [ -x "$ACME" ] || die "not installed"
    run_acme --upgrade --home "$ACME_HOME" --config-home "$CONFIG_HOME"
    log "acme.sh updated"
}

status() {
    [ -x "$ACME" ] || die "not installed"
    run_acme --list --home "$ACME_HOME" --config-home "$CONFIG_HOME"
    echo
    cru l 2>/dev/null | grep -F "$CRUNAME" || echo "No weekly renew job"
    [ -f "$FWFLAG" ] && echo "WARNING: port $PORT firewall flag present"
    iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null && \
        echo "NOTE: INPUT ACCEPT for port $PORT is present"
}

cleanup() {
    stop_server
    remove_cron
    rm -rf "$LOCKDIR"
    log "cleanup done"
}

help() {
    cat << HELP
Tomato64 letsencrypt helper - v1.0 - rs232

Usage: $ME <command>

  issue      Obtain certificate + install it + schedule weekly renew
  renew      Renew if due (also called by cru weekly)
  status     Show certificates and cron job
  update     Upgrade acme.sh
  reload     Force-load cert into Tomato httpd
  cleanup    Stop nc, remove firewall rule and cru job but keeps the crt
  help       This text

Default domain : $DEFAULT_DOMAIN
Script path    : $ME

Examples:
  $ME issue
  $ME status
  $ME cleanup
HELP
}

case "$1" in
    issue)   issue  ;;
    renew)   renew  ;;
    update)  update ;;
    status)  status ;;
    reload)  reload ;;
    cleanup) cleanup ;;
    help|-h|--help|"") help ;;
    *)
        echo "Unknown command: $1"
        help
        exit 1
        ;;
esac
EOF

sed -e "s|__BASE__|$BASE|g" \
    -e "s|__DOMAIN__|$DEFAULT_DOMAIN|g" \
    "$SCRIPT" > "$SCRIPT.tmp" && mv "$SCRIPT.tmp" "$SCRIPT"
chmod 700 "$SCRIPT"
cd "$BASE"
echo "Done. Now run: $SCRIPT help"
