Here is the updated script.

# Execute directly in the shell
# ============================================================
BASE="/opt/letsencrypt"
# ============================================================
SCRIPT_NAME="le-tomato.sh"

DEFAULT_DOMAIN=$(nvram get https_crt_cn)
[ -n "${DEFAULT_DOMAIN}" ] || {
    echo "ERROR: nvram https_crt_cn is empty"
    exit 1
}

mkdir -p "${BASE}" || exit 1
SCRIPT_PATH="${BASE}/${SCRIPT_NAME}"

cat > "${SCRIPT_PATH}" << 'EOF'
#!/bin/sh
v="v1.5"
# ============================================================
# Tomato64 – Let's Encrypt helper - ${v} - rs232
# ============================================================
BASE="/opt/letsencrypt"
SCRIPT_NAME="le-tomato.sh"
EOF

cat >> "${SCRIPT_PATH}" <<'LE_TOMATO_SCRIPT'
SCRIPT_PATH="${BASE}/${SCRIPT_NAME}"

DOMAIN=$(nvram get https_crt_cn)
ACME_HOME="${BASE}/.acme.sh"
ACME="${ACME_HOME}/acme.sh"
WEBROOT="${BASE}/webroot"
HANDLER="${BASE}/http-handler.sh"
PIDFILE="/tmp/le-tomato.pid"
FWFLAG="/tmp/le-tomato-fw"
LOCKDIR="/tmp/le-tomato.lock"
CRUNAME="le-tomato-renew"
CERT="/etc/cert.pem"
KEY="/etc/key.pem"
ORIGINAL_CERT="${BASE}/original-https-crt-file"

PORTFWD_FILTER=""
PORTFWD_NAT=""

. /usr/sbin/nvram_ops

logi(){ echo -e "${f_light_green}$*${reset}"; echo "$*" | logger -p user.info -t "${SCRIPT_NAME}[$$]"; }
logn(){ echo -e "${f_light_green}$*${reset}"; echo "$*" | logger -p user.notice -t "${SCRIPT_NAME}[$$]"; }
logw(){ echo -e "${f_light_yellow}WARNING: $*${reset}"; echo "WARNING: $*" | logger -p user.warn -t "${SCRIPT_NAME}[$$]"; }
loge(){ echo -e "${f_light_red}ERROR: $*${reset}" >&2; echo "ERROR: $*" | logger -p user.err -t "${SCRIPT_NAME}[$$]"; }
die(){  echo -e "${f_light_red}ERROR: $*${reset}" >&2; loge "ERROR: $*"; exit 1; }

DOMAIN_DIR="${ACME_HOME}/${DOMAIN}"
PERSIST_CERT="${DOMAIN_DIR}/fullchain.cer"
PERSIST_KEY="${DOMAIN_DIR}/${DOMAIN}.key"

get_lan_wan_access_status(){
    LAN_IP=$(nvram get lan_ipaddr)
    ENTRY="address=/${DOMAIN}/${LAN_IP}"
    CUR_DNS=$(nvram get dnsmasq_custom 2>/dev/null)

    if echo "${CUR_DNS}" | grep -qF "${ENTRY}"; then
        echo -n -e "${f_light_green}DNS Override (${DOMAIN} -> ${LAN_IP})${reset}"
        return 0
    fi

    if [ "$(nvram get nf_loopback)" = "0" ]; then
        echo -n -e "${f_light_green}NAT Loopback - All (Enabled)${reset}"
        return 0
    fi

    echo -n -e "${f_light_red}None / Unconfigured${reset}"
}

check_lan_wan_access(){
    [ -t 0 ] || return 0
    [ "$(nvram get remote_management)" = "1" ] || return 0
    [ "$(nvram get https_enable)" = "1" ] || return 0

    LAN_PORT=$(nvram get https_lanport)
    WAN_PORT=$(nvram get http_wanport)
    LAN_IP=$(nvram get lan_ipaddr)

    if [ -n "$LAN_PORT" ] && [ "$LAN_PORT" = "$WAN_PORT" ]; then
        RESOLVED_IP=$(nslookup "${DOMAIN}" 127.0.0.1 2>/dev/null | awk '/^Address 1:/ {print $2}' | tail -n1)
        [ -z "$RESOLVED_IP" ] && RESOLVED_IP=$(nslookup "${DOMAIN}" 2>/dev/null | awk '/^Address 1:/ {print $2}' | tail -n1)

        if [ "$RESOLVED_IP" != "$LAN_IP" ]; then
            echo -n -e "${f_light_yellow}${DOMAIN} resolves to WAN IP (${RESOLVED_IP:-unknown}). Add LAN DNS override in dnsmasq? [y/N]: ${reset}"
            read -r ans
            case "$ans" in
                [yY]*)
                    ENTRY="address=/${DOMAIN}/${LAN_IP}"
                    CUR_DNS=$(nvram get dnsmasq_custom)
                    if ! echo "${CUR_DNS}" | grep -qF "${ENTRY}"; then
                        nvram set dnsmasq_custom="$(printf '%s\n%s' "${CUR_DNS}" "${ENTRY}")"
                        nvram commit
                        service dnsmasq restart >/dev/null 2>&1 || true
                        logn "Added LAN DNS override for ${DOMAIN} -> ${LAN_IP}"
                    fi
                    return 0
                    ;;
            esac
        fi
        return 0
    fi

    if [ "$(nvram get nf_loopback)" != "0" ]; then
        echo -n -e "${f_light_yellow}NAT Loopback is required for LAN cert access on distinct WAN ports. Enable NAT Loopback (All)? [y/N]: ${reset}"
        read -r ans
        case "$ans" in
            [yY]*)
                nvram set nf_loopback=0
                nvram commit
                service firewall restart >/dev/null 2>&1 || true
                logn "NAT Loopback enabled (nf_loopback=0)"
                ;;
        esac
    fi
}

run_acme(){
    "${ACME}" "$@" 2>&1 | grep -v "Cannot parse _ssldate2time"
}

install_acme(){
    mkdir -p "${ACME_HOME}" "${WEBROOT}/.well-known/acme-challenge" || die "could not create ACME directories"

    if [ ! -x "${ACME}" ]; then
        TMP="/tmp/acme.sh.$$"
        wget -qO "${TMP}" "https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh" || die "could not download acme.sh"
        chmod 700 "${TMP}"
        mv "${TMP}" "${ACME}"
        chmod 700 "${ACME}"
    fi

    [ -x "${ACME}" ] || die "could not install acme.sh"

    run_acme --set-default-ca --server letsencrypt --home "${ACME_HOME}" --config-home "${ACME_HOME}" >/dev/null 2>&1 || true

    if [ ! -f "${ACME_HOME}/account.conf" ]; then
        run_acme --register-account \
            --server letsencrypt \
            --accountemail "admin@${DOMAIN}" \
            --home "${ACME_HOME}" \
            --config-home "${ACME_HOME}" || die "could not initialize ACME account"
    fi

    logn "acme.sh ready"
}

save_original_nvram(){
    [ -f "${ORIGINAL_CERT}" ] && return 0
    nvram get https_crt_file > "${ORIGINAL_CERT}" || die "could not save original certificate"
    [ -s "${ORIGINAL_CERT}" ] || die "original certificate backup is empty"
    chmod 600 "${ORIGINAL_CERT}"
    logn "original Tomato certificate saved"
}

map_certificate(){
    [ -s "${CERT}" ] || die "missing ${CERT}"
    [ -s "${KEY}" ] || die "missing ${KEY}"

    ARCHIVE="/tmp/le-cert.tgz"
    ENCODED="/tmp/le-cert.b64"

    tar -C / -czf "${ARCHIVE}" etc/cert.pem etc/key.pem || die "could not create certificate archive"
    openssl enc -base64 -A -in "${ARCHIVE}" -out "${ENCODED}" || die "could not encode certificate archive"

    nvram set https_crt_file="$(cat "${ENCODED}")"
    nvram set https_crt_save=1
    nvram commit

    rm -f "${ARCHIVE}" "${ENCODED}"
    service httpd restart >/dev/null 2>&1 || service httpd start >/dev/null 2>&1 || die "could not restart httpd"
    logn "certificate mapped to NVRAM and httpd restarted"
}

restore_original_certificate(){
    [ -s "${ORIGINAL_CERT}" ] || die "original certificate backup not found"
    ORIGINAL="$(cat "${ORIGINAL_CERT}")"
    [ -n "${ORIGINAL}" ] || die "original certificate backup is empty"

    nvram set https_crt_file="${ORIGINAL}"
    nvram set https_crt_save=1
    nvram commit

    rm -f /etc/server.pem
    service httpd restart >/dev/null 2>&1 || service httpd start >/dev/null 2>&1 || die "could not restart httpd"
    logn "original certificate restored"
}

create_handler(){
    cat > "${HANDLER}" <<'HANDLER'
#!/bin/sh
WEBROOT="/opt/letsencrypt/webroot"
REQUEST=$(dd bs=1024 count=1 2>/dev/null)
METHOD=$(printf '%s' "$REQUEST" | awk 'NR==1 {print $1}')
URI=$(printf '%s' "$REQUEST" | awk 'NR==1 {print $2}')

[ "$METHOD" = "GET" ] || {
    printf 'HTTP/1.0 405 Method Not Allowed\r\nConnection: close\r\n\r\n'
    exit 0
}

case "$URI" in
    /.well-known/acme-challenge/*)
        TOKEN="${URI#/.well-known/acme-challenge/}"
        case "$TOKEN" in
            ""|*/*|*'?'*|*'&'*|*' '*|*..*) FILE="" ;;
            *) FILE="${WEBROOT}/.well-known/acme-challenge/${TOKEN}" ;;
        esac
        ;;
    *) FILE="" ;;
esac

if [ -n "$FILE" ] && [ -f "$FILE" ]; then
    LENGTH=$(wc -c < "$FILE" | tr -d '[:space:]')
    printf 'HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %s\r\nConnection: close\r\n\r\n' "$LENGTH"
    cat "$FILE"
else
    printf 'HTTP/1.0 404 Not Found\r\nConnection: close\r\n\r\n'
fi
HANDLER
    chmod 700 "${HANDLER}"
}

_port80_in_rule(){
    echo "$1" | grep -qE -- '--dport[[:space:]]+80([[:space:]]|$)' && return 0
    if echo "$1" | grep -qE -- '--dports[[:space:]]+'; then
        ports=$(echo "$1" | sed -n 's/.*--dports[[:space:]]\+\([^[:space:]]*\).*/\1/p')
        echo ",${ports}," | grep -q ',80,' && return 0
    fi
    return 1
}

remove_port80_forward(){
    RULE=$(iptables -S wanin 2>/dev/null | grep -E '^-A wanin ' | while read -r r; do
        _port80_in_rule "$r" && { echo "$r"; break; }
    done)
    if [ -n "${RULE}" ]; then
        PORTFWD_FILTER="${RULE}"
        iptables -D $(echo "${RULE}" | cut -d' ' -f2-) 2>/dev/null || true
        logn "temporarily removed filter port-80 forward: ${RULE}"
    fi

    RULE=$(iptables -t nat -S WANPREROUTING 2>/dev/null | grep -E '^-A WANPREROUTING ' | while read -r r; do
        _port80_in_rule "$r" && { echo "$r"; break; }
    done)
    if [ -n "${RULE}" ]; then
        PORTFWD_NAT="${RULE}"
        iptables -t nat -D $(echo "${RULE}" | cut -d' ' -f2-) 2>/dev/null || true
        logn "temporarily removed nat port-80 forward: ${RULE}"
    fi
}

restore_port80_forward(){
    if [ -n "${PORTFWD_FILTER}" ]; then
        iptables -A $(echo "${PORTFWD_FILTER}" | cut -d' ' -f2-) 2>/dev/null || true
        logn "restored previous filter port-80 forward"
        PORTFWD_FILTER=""
    fi
    if [ -n "${PORTFWD_NAT}" ]; then
        iptables -t nat -A $(echo "${PORTFWD_NAT}" | cut -d' ' -f2-) 2>/dev/null || true
        logn "restored previous nat port-80 forward"
        PORTFWD_NAT=""
    fi
}

is_port80_open_in_input(){
    iptables -S INPUT 2>/dev/null | while read -r r; do
        case "$r" in
            -A\ INPUT*)
                _port80_in_rule "$r" && return 0
                ;;
        esac
    done
    return 1
}

add_firewall(){
    if is_port80_open_in_input; then
        logn "port 80 already open in INPUT – skipping temporary rule"
        return 0
    fi

    iptables -I INPUT -p tcp --dport 80 -j ACCEPT || die "could not open port 80"
    echo 1 > "${FWFLAG}"
    logn "opened temporary INPUT accept for port 80"
}

remove_firewall(){
    if [ -f "${FWFLAG}" ]; then
        iptables -D INPUT -p tcp --dport 80 -j ACCEPT >/dev/null 2>&1 || true
        rm -f "${FWFLAG}"
        logn "removed temporary INPUT accept for port 80"
    fi
}

stop_server(){
    if [ -f "${PIDFILE}" ]; then
        PID=$(cat "${PIDFILE}" 2>/dev/null)
        [ -n "${PID}" ] && kill "${PID}" 2>/dev/null || true
        rm -f "${PIDFILE}"
    fi
    remove_firewall
    restore_port80_forward
    service httpd start >/dev/null 2>&1 || service httpd restart >/dev/null 2>&1 || true
    logn "closing listener on port 80"
}

find_nc(){
    if command -v nc >/dev/null 2>&1 && nc -h 2>&1 | grep -q -- '-l'; then
        NC_BIN="nc"
        NC_LISTEN="-lk -p 80"
        return 0
    fi

    if [ -x /opt/bin/netcat ] && /opt/bin/netcat -h 2>&1 | grep -q -- '-l'; then
        NC_BIN="/opt/bin/netcat"
        NC_LISTEN="-l -p 80"
        return 0
    fi

    if command -v netcat >/dev/null 2>&1 && netcat -h 2>&1 | grep -q -- '-l'; then
        NC_BIN="netcat"
        NC_LISTEN="-l -p 80"
        return 0
    fi

    return 1
}

start_server(){
    stop_server >/dev/null 2>&1 || true
    mkdir -p "${WEBROOT}/.well-known/acme-challenge" || die "could not create webroot"

    create_handler
    remove_port80_forward
    add_firewall

    find_nc || die "No suitable netcat found (need nc or netcat that supports -l)"

    WAN_IF=$(nvram get wan_ifname)
    WAN_IP=""
    [ -n "$WAN_IF" ] && WAN_IP=$(ip -4 addr show dev "$WAN_IF" 2>/dev/null | awk '/inet / {print $2; exit}' | cut -d/ -f1)

    service httpd stop >/dev/null 2>&1 || true
    sleep 1

    if [ -n "$WAN_IP" ]; then
        $NC_BIN $NC_LISTEN -s "$WAN_IP" -e "${HANDLER}" &
        logn "opening listener on $WAN_IF ($WAN_IP:80)"
    else
        $NC_BIN $NC_LISTEN -e "${HANDLER}" &
        logn "opening listener on port 80 (all interfaces)"
    fi

    echo "$!" > "${PIDFILE}"
    sleep 1

    kill -0 "$(cat "${PIDFILE}" 2>/dev/null)" 2>/dev/null || die "listener failed to bind port 80"
}

install_cron(){
    if cru l 2>/dev/null | grep -F "${CRUNAME}" >/dev/null 2>&1; then
        printf "  %-22s : %b\n" "Scheduled Update" "${f_light_green}enabled${reset}"
        return 0
    fi

    MIN=$(awk 'BEGIN{srand(); print int(rand()*60)}')
    HOUR=$(awk 'BEGIN{srand(); print int(rand()*5)+1}')
    DOW=$(awk 'BEGIN{srand(); print int(rand()*7)}')

    cru a "${CRUNAME}" "${MIN} ${HOUR} * * ${DOW} ${SCRIPT_PATH} renew" || die "could not install renewal job"
    printf "  %-22s : %b\n" "Scheduled Update" "${f_light_yellow}enabling it now${reset}"
}

remove_cron(){
    cru d "${CRUNAME}" 2>/dev/null || true
}

is_staging_cert(){
    [ -s "${PERSIST_CERT}" ] || return 1
    openssl x509 -in "${PERSIST_CERT}" -noout -issuer 2>/dev/null | grep -qiE "(staging|fake)"
}

copy_cert_to_ram(){
    mkdir -p /etc
    cp -f "${PERSIST_CERT}" "${CERT}" || die "failed to write ${CERT}"
    cp -f "${PERSIST_KEY}" "${KEY}" || die "failed to write ${KEY}"
    chmod 600 "${KEY}"
    chmod 644 "${CERT}"
}

issue_first_certificate(){
    mkdir "${LOCKDIR}" 2>/dev/null || die "another operation is running"
    trap 'stop_server; rm -rf "${LOCKDIR}"; exit' 0 1 2 3 15

    start_server
    logi "obtaining initial certificate for ${DOMAIN}"

    SERVER_ARG="letsencrypt"
    if [ "$1" = "--staging" ]; then
        SERVER_ARG="letsencrypt_test"
        logw "using Let's Encrypt Staging server"
    fi

    ACME_LOG="/tmp/acme-issue.$$.log"

    run_acme --issue \
        --domain "${DOMAIN}" \
        --server "${SERVER_ARG}" \
        --keylength 2048 \
        --webroot "${WEBROOT}" \
        --home "${ACME_HOME}" \
        --config-home "${ACME_HOME}" \
        --syslog 0 2>&1 | tee "${ACME_LOG}"

    if [ ! -f "${PERSIST_CERT}" ]; then
        if grep -qiE "(Timeout during connect|likely firewall problem)" "${ACME_LOG}" 2>/dev/null; then
            rm -f "${ACME_LOG}"
            die "Validation timed out — WAN port 80 is unreachable from the Internet"
        else
            rm -f "${ACME_LOG}"
            die "initial certificate issuance failed"
        fi
    fi

    rm -f "${ACME_LOG}"
    stop_server
    rm -rf "${LOCKDIR}"
    trap - 0 1 2 3 15
}

renew_certificate(){
    if is_staging_cert; then
        logw "staging certificate detected during renewal; requesting production certificate"
        rm -rf "${DOMAIN_DIR}"
        issue_first_certificate
        return 0
    fi

    mkdir "${LOCKDIR}" 2>/dev/null || exit 0
    trap 'stop_server; rm -rf "${LOCKDIR}"; exit' 0 1 2 3 15

    start_server
    logi "certificate expires within 30 days; renewing"

    run_acme --renew \
        --domain "${DOMAIN}" \
        --home "${ACME_HOME}" \
        --config-home "${ACME_HOME}" \
        --syslog 0

    stop_server
    rm -rf "${LOCKDIR}"
    trap - 0 1 2 3 15
}

start(){
    [ -n "${DOMAIN}" ] || die "https_crt_cn is empty"

    if [ -s "${PERSIST_CERT}" ] && [ -s "${PERSIST_KEY}" ]; then
        copy_cert_to_ram
        if openssl x509 -checkend 2592000 -noout -in "${PERSIST_CERT}" >/dev/null 2>&1 && ! is_staging_cert; then
            echo ""
            echo "  using valid existing certificate from ${PERSIST_CERT}"
            check_lan_wan_access
            printf "  %-22s : %b\n" "LAN to WAN Access" "$(get_lan_wan_access_status)"
            install_cron
            return 0
        fi
    fi

    install_acme

    if is_staging_cert && [ "$1" != "--staging" ]; then
        logw "staging certificate detected; replacing with production certificate"
        rm -rf "${DOMAIN_DIR}"
        save_original_nvram
        issue_first_certificate
        copy_cert_to_ram
    elif [ -s "${PERSIST_CERT}" ] && [ -s "${PERSIST_KEY}" ]; then
        save_original_nvram
        renew_certificate
        copy_cert_to_ram
    else
        save_original_nvram
        issue_first_certificate "$1"
        copy_cert_to_ram
    fi

    save_original_nvram
    check_lan_wan_access
    map_certificate
    printf "  %-22s : %b\n" "LAN to WAN Access" "$(get_lan_wan_access_status)"
    install_cron
}

stop(){
    stop_server
    remove_cron
    restore_original_certificate
    logn "stopped; persistent certificate retained in /opt"
}

reload(){
    map_certificate
}

update(){
    [ -x "${ACME}" ] || die "acme.sh not found"
    run_acme --upgrade --home "${ACME_HOME}" --config-home "${ACME_HOME}" || die "acme.sh update failed"
    logn "acme.sh updated"
}

status() {
    echo -e "=== HTTPS Certificate Status ${v} ======================"
    IS_LE_ACTIVE=0
    STAGING_ACTIVE=0

    if [ -s "${CERT}" ]; then
        ACTIVE_FP=$(openssl x509 -noout -fingerprint -in "${CERT}" 2>/dev/null)
        LE_FP=$(openssl x509 -noout -fingerprint -in "${PERSIST_CERT}" 2>/dev/null)

        if [ -n "${LE_FP}" ] && [ "${ACTIVE_FP}" = "${LE_FP}" ]; then
            IS_LE_ACTIVE=1
            if is_staging_cert; then
                STAGING_ACTIVE=1
                SEC_STATUS="${f_light_yellow}Let's Encrypt (Staging/Untrusted)${reset}"
            else
                SEC_STATUS="${f_light_green}Let's Encrypt (Secure)${reset}"
            fi
        else
            SEC_STATUS="${f_light_yellow}Built-in Default (Browser warning expected)${reset}"
        fi
    else
        SEC_STATUS="${f_light_red}No Active Certificate${reset}"
    fi

    # Let's Encrypt status and expiration evaluation
    if [ -s "${PERSIST_CERT}" ]; then
        if is_staging_cert; then
            LE_DOWNLOAD="${f_light_yellow}Test/Staging Mode (Not a real cert)${reset}"
        elif [ "${IS_LE_ACTIVE}" -eq 1 ]; then
            LE_DOWNLOAD="${f_light_green}Active & Installed${reset}"
        else
            LE_DOWNLOAD="${f_light_yellow}Ready but not active${reset}"
        fi

        EXP_DATE=$(openssl x509 -enddate -noout -in "${PERSIST_CERT}" 2>/dev/null | cut -d= -f2)
        EXP_EPOCH=$(date -d "${EXP_DATE}" +%s 2>/dev/null || date -D "%b %d %T %Y %Z" -d "${EXP_DATE}" +%s 2>/dev/null)
        NOW_EPOCH=$(date +%s)

        if [ -n "${EXP_EPOCH}" ] && [ "${EXP_EPOCH}" -lt 31536000 ]; then
            EXP_STATUS="${f_light_yellow}Expired (Generated pre-NTP sync in 1970)${reset}"
        elif [ -n "${EXP_EPOCH}" ] && [ -n "${NOW_EPOCH}" ]; then
            DAYS_LEFT=$(( (EXP_EPOCH - NOW_EPOCH) / 86400 ))
            if [ "${DAYS_LEFT}" -gt 30 ]; then
                EXP_STATUS="${f_light_green}Valid (${DAYS_LEFT} days left)${reset}"
            elif [ "${DAYS_LEFT}" -gt 0 ]; then
                EXP_STATUS="${f_light_yellow}Expiring soon (${DAYS_LEFT} days left)${reset}"
            else
                ABS_DAYS=$(( -DAYS_LEFT ))
                EXP_STATUS="${f_light_red}Expired (${ABS_DAYS} days ago)${reset}"
            fi
        else
            EXP_STATUS="${f_light_yellow}Unknown${reset}"
        fi
    else
        LE_DOWNLOAD="${f_light_yellow}Not Created Yet (Run 'le-tomato.sh start')${reset}"
        EXP_STATUS="${f_light_red}N/A${reset}"
    fi

    NV_CRT=$(nvram get https_crt_file 2>/dev/null)
    if [ -n "${NV_CRT}" ]; then
        NV_ISSUER=$(echo "${NV_CRT}" | openssl enc -base64 -d 2>/dev/null | tar -xzO etc/cert.pem 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null)
        if echo "${NV_ISSUER}" | grep -qiE "(staging|fake)"; then
            FLASH_STATUS="${f_light_yellow}Saved (Let's Encrypt test cert)${reset}"
        elif echo "${NV_ISSUER}" | grep -qi "Let's Encrypt"; then
            FLASH_STATUS="${f_light_green}Saved (Will survive router reboots)${reset}"
        else
            if [ "${STAGING_ACTIVE}" -eq 1 ] || is_staging_cert; then
                FLASH_STATUS="${f_light_yellow}Saved (Let's Encrypt test cert)${reset}"
            elif [ "${IS_LE_ACTIVE}" -eq 1 ]; then
                FLASH_STATUS="${f_light_green}Saved (Will survive router reboots)${reset}"
            else
                FLASH_STATUS="${f_light_yellow}Saved (Built-in Tomato default cert)${reset}"
            fi
        fi
    else
        FLASH_STATUS="${f_light_red}Not Saved${reset}"
    fi

    CRON_ENTRY=$(cru l 2>/dev/null | grep -F "${CRUNAME}")
    if [ -s "${PERSIST_CERT}" ]; then
        if is_staging_cert; then
            CRON_STATUS="${f_light_yellow}Pending Upgrade (Will request prod cert on next run)${reset}"
        elif [ -n "${CRON_ENTRY}" ]; then
            CRON_STATUS="${f_light_green}Scheduled (Automatic weekly check)${reset}"
        else
            CRON_STATUS="${f_light_yellow}Off (Run 'le-tomato.sh start' to enable)${reset}"
        fi
    else
        CRON_STATUS="${f_light_yellow}Inactive (Requires initial Let's Encrypt setup)${reset}"
    fi

    ROUTE_STATUS=$(get_lan_wan_access_status)

    if [ "${STAGING_ACTIVE}" -eq 1 ] || is_staging_cert; then
        ADVICE="Staging cert active. Run 'le-tomato.sh start' to request production cert."
    elif [ "${IS_LE_ACTIVE}" -eq 1 ]; then
        ADVICE="All good! Router web interface is secure."
    elif [ -s "${PERSIST_CERT}" ]; then
        ADVICE="Certificate downloaded but not applied. Run 'le-tomato.sh reload'."
    else
        ADVICE="Using default cert. Run 'le-tomato.sh start' to get Let's Encrypt."
    fi

    printf "
  %-22s : %s\n" "Web Address (Domain)" "${DOMAIN:-Unconfigured}"
    printf "  %-22s : %b\n" "LAN to WAN Access"   "${ROUTE_STATUS}"
    printf "  %-22s : %b\n" "HTTPS Security"       "${SEC_STATUS}"
    printf "  %-22s : %b\n" "LE Certificate Status"  "${LE_DOWNLOAD}"
    printf "  %-22s : %b\n" "LE Certificate Term" "${EXP_STATUS}"
    printf "  %-22s : %b\n" "Router Flash Save"   "${FLASH_STATUS}"
    printf "  %-22s : %b\n" "Auto-Renewal"        "${CRON_STATUS}"
    echo -e "--------------------------------------------------------"
    printf "  %-22s : %s\n" "Action / Advice"     "${ADVICE}"
    echo -e "========================================================
	"
}

help(){
    echo "
	Tomato64 / FreshTomato – Let's Encrypt helper ${v} - rs232
	"
    echo "Usage:  ${SCRIPT_NAME} start [--staging]   Install/load/cron cert"
    echo "        ${SCRIPT_NAME} stop                Restore default cert + remove cron"
    echo "        ${SCRIPT_NAME} status              Show status"
    echo "        ${SCRIPT_NAME} reload              Re-map certificate to NVRAM"
    echo "        ${SCRIPT_NAME} update              Update acme.sh"
    echo "        ${SCRIPT_NAME} help                Show this help"
    echo ""
    echo "Add to Init / WAN Up:"
    echo "        ${SCRIPT_PATH} start
	"
}

case "$1" in
    start) start "$2" ;;
    stop) stop ;;
    status) status ;;
    reload) reload ;;
    renew) renew_certificate; copy_cert_to_ram; map_certificate ;;
    update) update ;;
    help|-h|--help|"") help ;;
    *) help; exit 1 ;;
esac
LE_TOMATO_SCRIPT

chmod 700 "${SCRIPT_PATH}"
cd "${BASE}"
