# Execute this directly in the shell
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

cat > "${SCRIPT_PATH}" << EOF
#!/bin/sh
v="v1.4"
# ============================================================
# Tomato64 / FreshTomato – Let's Encrypt helper ${v} - rs232
# ============================================================
BASE="${BASE}"
SCRIPT_NAME="${SCRIPT_NAME}"
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

if [ -f /usr/sbin/nvram_ops ]; then
    . /usr/sbin/nvram_ops
else
    reset="\033[0m"
    f_light_green="\033[92m"
    f_light_yellow="\033[93m"
    f_light_red="\033[91m"
fi

logi(){ echo "$*" | logger -p user.info -t "${SCRIPT_NAME}[$$]"; }
logn(){ echo "$*" | logger -p user.notice -t "${SCRIPT_NAME}[$$]"; }
logw(){ echo "$*" | logger -p user.warn -t "${SCRIPT_NAME}[$$]"; }
loge(){ echo "$*" | logger -p user.err -t "${SCRIPT_NAME}[$$]"; }

msg_info(){   echo -e "${f_light_green}$*${reset}"; logi "$*"; }
msg_notice(){ echo -e "${f_light_green}$*${reset}"; logn "$*"; }
msg_warn(){   echo -e "${f_light_yellow}WARNING: $*${reset}"; logw "WARNING: $*"; }
die(){        echo -e "${f_light_red}ERROR: $*${reset}" >&2; loge "ERROR: $*"; exit 1; }

DOMAIN_DIR="${ACME_HOME}/${DOMAIN}"
PERSIST_CERT="${DOMAIN_DIR}/fullchain.cer"
PERSIST_KEY="${DOMAIN_DIR}/${DOMAIN}.key"

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
    msg_notice "certificate mapped to NVRAM and httpd restarted"
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
    msg_notice "original certificate restored"
}

create_handler(){
    cat > "${HANDLER}" <<'HANDLER'
#!/bin/sh
WEBROOT="/opt/letsencrypt/webroot"

# Hard limit: read at most 1024 bytes total (prevents large/slow payloads)
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

# ------------------------------------------------------------------
# Port-80 forward handling (filter wanin + nat WANPREROUTING)
# ------------------------------------------------------------------
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
        echo -e "${f_light_yellow}temporarily removed existing port 80 forward (filter)${reset}"
    fi

    RULE=$(iptables -t nat -S WANPREROUTING 2>/dev/null | grep -E '^-A WANPREROUTING ' | while read -r r; do
        _port80_in_rule "$r" && { echo "$r"; break; }
    done)
    if [ -n "${RULE}" ]; then
        PORTFWD_NAT="${RULE}"
        iptables -t nat -D $(echo "${RULE}" | cut -d' ' -f2-) 2>/dev/null || true
        logn "temporarily removed nat port-80 forward: ${RULE}"
        echo -e "${f_light_yellow}temporarily removed existing port 80 forward (nat)${reset}"
    fi
}

restore_port80_forward(){
    if [ -n "${PORTFWD_FILTER}" ]; then
        iptables -A $(echo "${PORTFWD_FILTER}" | cut -d' ' -f2-) 2>/dev/null || true
        logn "restored previous filter port-80 forward"
        echo -e "${f_light_green}restored previous port 80 forward (filter)${reset}"
        PORTFWD_FILTER=""
    fi
    if [ -n "${PORTFWD_NAT}" ]; then
        iptables -t nat -A $(echo "${PORTFWD_NAT}" | cut -d' ' -f2-) 2>/dev/null || true
        logn "restored previous nat port-80 forward"
        echo -e "${f_light_green}restored previous port 80 forward (nat)${reset}"
        PORTFWD_NAT=""
    fi
}

# ------------------------------------------------------------------
# Improved INPUT port-80 handling
# Detects both classic --dport 80 and multiport --dports …80…
# Only adds/removes a temporary rule if port 80 was NOT already open
# ------------------------------------------------------------------
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
        echo -e "${f_light_green}port 80 already open in INPUT – skipping temporary rule${reset}"
        logn "port 80 already open in INPUT – skipping temporary rule"
        return 0
    fi

    iptables -I INPUT -p tcp --dport 80 -j ACCEPT || die "could not open port 80"
    echo 1 > "${FWFLAG}"
    echo -e "${f_light_green}opening firewall port 80${reset}"
    logn "opened temporary INPUT accept for port 80"
}

remove_firewall(){
    # Only remove the rule we ourselves added
    if [ -f "${FWFLAG}" ]; then
        iptables -D INPUT -p tcp --dport 80 -j ACCEPT >/dev/null 2>&1 || true
        rm -f "${FWFLAG}"
        echo -e "${f_light_green}closing firewall port 80${reset}"
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
    echo -e "${f_light_green}closing listener on port 80${reset}"
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

    # Temporarily free port 80 (Tomato httpd usually holds it)
    service httpd stop >/dev/null 2>&1 || true
    sleep 1

    if [ -n "$WAN_IP" ]; then
        # -s must come before -e for GNU netcat
        timeout 30 $NC_BIN $NC_LISTEN -s "$WAN_IP" -e "${HANDLER}" &
        echo -e "${f_light_green}opening listener on $WAN_IF ($WAN_IP:80) [timeout 30s]${reset}"
    else
        timeout 30 $NC_BIN $NC_LISTEN -e "${HANDLER}" &
        echo -e "${f_light_green}opening listener on port 80 (all interfaces) [timeout 30s]${reset}"
    fi

    echo "$!" > "${PIDFILE}"
    sleep 1
    kill -0 "$(cat "${PIDFILE}" 2>/dev/null)" 2>/dev/null || die "listener failed to bind port 80"
}

install_cron(){
    cru l 2>/dev/null | grep -F "${CRUNAME}" >/dev/null 2>&1 && return 0
    MIN=$(awk 'BEGIN{srand(); print int(rand()*60)}')
    HOUR=$(awk 'BEGIN{srand(); print int(rand()*5)+1}')
    DOW=$(awk 'BEGIN{srand(); print int(rand()*7)}')
    msg_info "installing cron renewal job (${MIN} ${HOUR} * * ${DOW})"
    cru a "${CRUNAME}" "${MIN} ${HOUR} * * ${DOW} ${SCRIPT_PATH} renew" || die "could not install renewal job"
}

remove_cron(){
    cru d "${CRUNAME}" 2>/dev/null || true
}

certificate_due(){
    [ -s "${CERT}" ] || return 0
    EXPIRY=$(openssl x509 -in "${CERT}" -noout -enddate 2>/dev/null) || return 0
    EXPIRY="${EXPIRY#*=}"
    NOW=$(date +%s)
    END=$(date -d "${EXPIRY}" +%s 2>/dev/null) || return 0
    REMAINING=$((END - NOW))
    [ "${REMAINING}" -le 2592000 ]
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
    msg_info "obtaining initial certificate for ${DOMAIN}"

    SERVER_ARG="letsencrypt"
    if [ "$1" = "--staging" ]; then
        SERVER_ARG="letsencrypt_test"
        msg_warn "using Let's Encrypt Staging server"
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
            die "Validation timed out — WAN port 80 is unreachable from the Internet (check ISP port blocking or upstream firewall)"
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
        msg_warn "staging certificate detected during renewal; requesting production certificate"
        rm -rf "${DOMAIN_DIR}"
        issue_first_certificate
        return 0
    fi

    mkdir "${LOCKDIR}" 2>/dev/null || exit 0
    trap 'stop_server; rm -rf "${LOCKDIR}"; exit' 0 1 2 3 15

    start_server
    msg_info "certificate expires within 30 days; renewing"

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
    install_acme

    if is_staging_cert && [ "$1" != "--staging" ]; then
        msg_warn "staging certificate detected; replacing with production certificate"
        rm -rf "${DOMAIN_DIR}"
        save_original_nvram
        issue_first_certificate
        copy_cert_to_ram
    elif [ -s "${PERSIST_CERT}" ] && [ -s "${PERSIST_KEY}" ]; then
        msg_info "using existing certificate from ${PERSIST_CERT}"
        copy_cert_to_ram
        if certificate_due; then
            save_original_nvram
            renew_certificate
            copy_cert_to_ram
        fi
    else
        save_original_nvram
        issue_first_certificate "$1"
        copy_cert_to_ram
    fi

    save_original_nvram
    map_certificate
    install_cron
    msg_notice "start completed successfully"
}

stop(){
    stop_server
    remove_cron
    restore_original_certificate
    msg_notice "stopped; persistent certificate retained in /opt"
}

reload(){
    map_certificate
}

update(){
    [ -x "${ACME}" ] || die "acme.sh not found"
    run_acme --upgrade --home "${ACME_HOME}" --config-home "${ACME_HOME}" || die "acme.sh update failed"
    msg_notice "acme.sh updated"
}

status() {
    echo -e "=== HTTPS Certificate Status ${v} ======================"
    
    IS_LE_ACTIVE=0
    STAGING_ACTIVE=0
    if [ -s "${CERT}" ]; then
        ACTIVE_FP=$(openssl x509 -noout -fingerprint -in "${CERT}" 2>/dev/null)
        LE_FP=$(openssl x509 -noout -fingerprint -in "${PERSIST_CERT}" 2>/dev/null)
        EXP_DATE=$(openssl x509 -enddate -noout -in "${CERT}" 2>/dev/null | cut -d= -f2)
        EXP_EPOCH=$(date -d "${EXP_DATE}" +%s 2>/dev/null || date -D "%b %d %T %Y %Z" -d "${EXP_DATE}" +%s 2>/dev/null)
        NOW_EPOCH=$(date +%s)
        
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
        SEC_STATUS="${f_light_red}No Active Certificate${reset}"
        EXP_STATUS="${f_light_red}N/A${reset}"
    fi

    if [ -s "${PERSIST_CERT}" ]; then
        if is_staging_cert; then
            LE_DOWNLOAD="${f_light_yellow}Test/Staging Mode (Not a real cert)${reset}"
        else
            LE_DOWNLOAD="${f_light_green}Ready & Installed${reset}"
        fi
    else
        LE_DOWNLOAD="${f_light_yellow}Not Created Yet (Run 'le-tomato.sh start')${reset}"
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

    if [ "${STAGING_ACTIVE}" -eq 1 ] || is_staging_cert; then
        ADVICE="Staging cert active. Run 'le-tomato.sh start' to request production cert."
    elif [ "${IS_LE_ACTIVE}" -eq 1 ]; then
        ADVICE="All good! Router web interface is secure."
    elif [ -s "${PERSIST_CERT}" ]; then
        ADVICE="Certificate downloaded but not applied. Run 'le-tomato.sh reload'."
    else
        ADVICE="Using default cert. Run 'le-tomato.sh start' to get Let's Encrypt."
    fi

    printf "  %-22s : %s\n" "Web Address (Domain)" "${DOMAIN:-Unconfigured}"
    printf "  %-22s : %b\n" "HTTPS Security"       "${SEC_STATUS}"
    printf "  %-22s : %b\n" "Certificate Validity" "${EXP_STATUS}"
    printf "  %-22s : %b\n" "Let's Encrypt Cert"  "${LE_DOWNLOAD}"
    printf "  %-22s : %b\n" "Router Flash Save"   "${FLASH_STATUS}"
    printf "  %-22s : %b\n" "Auto-Renewal"        "${CRON_STATUS}"
    echo -e "--------------------------------------------------------"
    printf "  %-22s : %s\n" "Action / Advice"     "${ADVICE}"
    echo -e "========================================================"
}

help(){
    cat <<USAGE
	
Tomato64 / FreshTomato – Let's Encrypt helper ${v} - rs232

Usage:  ${SCRIPT_NAME} start [--staging]   Install/load/cron cert
        ${SCRIPT_NAME} stop                Restore default cert + remove cron
        ${SCRIPT_NAME} status              Show status
        ${SCRIPT_NAME} reload              Re-map certificate to NVRAM
        ${SCRIPT_NAME} update              Update acme.sh
        ${SCRIPT_NAME} help                Show this help

Add to Init / WAN Up:
        ${SCRIPT_PATH} start
		
USAGE
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
