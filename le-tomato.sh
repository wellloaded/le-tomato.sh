# Execute this directly in the shell
# ============================================================
BASE="/opt/letsencrypt"
DEFAULT_DOMAIN=$(nvram get https_crt_cn)
# ============================================================

SCRIPT_NAME="le-tomato.sh"

[ -n "${DEFAULT_DOMAIN}" ] || {
    echo "ERROR: nvram https_crt_cn is empty"
    exit 1
}

mkdir -p "${BASE}" || exit 1
SCRIPT_PATH="${BASE}/${SCRIPT_NAME}"

cat > "${SCRIPT_PATH}" <<'LE_TOMATO_SCRIPT'
#!/bin/sh
# ============================================================
# Tomato64 – Let's Encrypt helper v1.1 - rs232
# ============================================================
BASE="/opt/letsencrypt"
SCRIPT_NAME="le-tomato.sh"
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

# Source NVRAM ops and system color definitions if available
if [ -f /usr/sbin/nvram_ops ]; then
    . /usr/sbin/nvram_ops
else
    reset="\033[0m"
    f_light_green="\033[92m"
    f_light_yellow="\033[93m"
    f_light_red="\033[91m"
fi

# Logging Helpers
logi(){ echo "$*" | logger -p user.info -t "${SCRIPT_NAME}[$$]"; }
logn(){ echo "$*" | logger -p user.notice -t "${SCRIPT_NAME}[$$]"; }
logw(){ echo "$*" | logger -p user.warn -t "${SCRIPT_NAME}[$$]"; }
loge(){ echo "$*" | logger -p user.err -t "${SCRIPT_NAME}[$$]"; }

msg_info(){   echo -e "${f_light_green}$*${reset}"; logi "$*"; }
msg_notice(){ echo -e "${f_light_green}$*${reset}"; logn "$*"; }
msg_warn(){   echo -e "${f_light_yellow}WARNING: $*${reset}"; logw "WARNING: $*"; }
die(){        echo -e "${f_light_red}ERROR: $*${reset}" >&2; loge "ERROR: $*"; exit 1; }

# Persistent paths for domain keys/certs
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
IFS= read -r REQUEST || exit 0
METHOD=$(echo "${REQUEST}" | awk '{print $1}')
URI=$(echo "${REQUEST}" | awk '{print $2}')

while IFS= read -r HEADER; do
    case "${HEADER}" in
        ""|$(printf '\r')) break ;;
    esac
done

[ "${METHOD}" = "GET" ] || {
    printf 'HTTP/1.0 405 Method Not Allowed\r\nConnection: close\r\n\r\n'
    exit 0
}

case "${URI}" in
    /.well-known/acme-challenge/*)
        TOKEN="${URI#/.well-known/acme-challenge/}"
        case "${TOKEN}" in
            ""|*/*|*'?'*|*'&'*|*' '*|*..*) FILE="" ;;
            *) FILE="${WEBROOT}/.well-known/acme-challenge/${TOKEN}" ;;
        esac
        ;;
    *) FILE="" ;;
esac

if [ -n "${FILE}" ] && [ -f "${FILE}" ]; then
    LENGTH=$(wc -c < "${FILE}" | tr -d '[:space:]')
    printf 'HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %s\r\nConnection: close\r\n\r\n' "${LENGTH}"
    cat "${FILE}"
else
    printf 'HTTP/1.0 404 Not Found\r\nConnection: close\r\n\r\n'
fi
HANDLER
    chmod 700 "${HANDLER}"
}

add_firewall(){
    if ! iptables -C INPUT -p tcp --dport 80 -j ACCEPT >/dev/null 2>&1; then
        iptables -I INPUT -p tcp --dport 80 -j ACCEPT || die "could not open port 80"
        echo 1 > "${FWFLAG}"
    fi
}

remove_firewall(){
    if [ -f "${FWFLAG}" ]; then
        iptables -D INPUT -p tcp --dport 80 -j ACCEPT >/dev/null 2>&1 || true
        rm -f "${FWFLAG}"
    fi
}

stop_server(){
    if [ -f "${PIDFILE}" ]; then
        PID=$(cat "${PIDFILE}" 2>/dev/null)
        [ -n "${PID}" ] && kill "${PID}" 2>/dev/null || true
        rm -f "${PIDFILE}"
    fi
    remove_firewall
    msg_info "closing nc on port 80"
}

start_server(){
    stop_server >/dev/null 2>&1 || true
    mkdir -p "${WEBROOT}/.well-known/acme-challenge" || die "could not create webroot"
    create_handler
    add_firewall
    nc -lk -p 80 -e "${HANDLER}" &
    echo "$!" > "${PIDFILE}"
    sleep 1
    kill -0 "$(cat "${PIDFILE}" 2>/dev/null)" 2>/dev/null || die "nc failed to bind port 80"
    msg_info "opening nc on port 80"
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

    run_acme --issue \
        --domain "${DOMAIN}" \
        --server "${SERVER_ARG}" \
        --keylength 2048 \
        --webroot "${WEBROOT}" \
        --home "${ACME_HOME}" \
        --config-home "${ACME_HOME}" \
        --syslog 0

    [ -f "${PERSIST_CERT}" ] || die "initial certificate issuance failed"
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
    echo -e "=== Let's Encrypt Status ==============================="

    # 1. Check persistent cert existence
    if [ -s "${PERSIST_CERT}" ]; then
        EXP_DATE=$(openssl x509 -enddate -noout -in "${PERSIST_CERT}" 2>/dev/null | cut -d= -f2)
        EXP_EPOCH=$(date -d "${EXP_DATE}" +%s 2>/dev/null || date -D "%b %d %T %Y %Z" -d "${EXP_DATE}" +%s 2>/dev/null)
        NOW_EPOCH=$(date +%s)
        
        if is_staging_cert; then
            CERT_STATUS="${f_light_yellow}STAGING CERTIFICATE (needs replacement)${reset}"
        elif [ -n "${EXP_EPOCH}" ]; then
            DAYS_LEFT=$(( (EXP_EPOCH - NOW_EPOCH) / 86400 ))
            if [ "${DAYS_LEFT}" -gt 30 ]; then
                CERT_STATUS="${f_light_green}VALID (${DAYS_LEFT} days left)${reset}"
            elif [ "${DAYS_LEFT}" -gt 0 ]; then
                CERT_STATUS="${f_light_yellow}EXPIRING SOON (${DAYS_LEFT} days left)${reset}"
            else
                CERT_STATUS="${f_light_red}EXPIRED (${DAYS_LEFT} days ago)${reset}"
            fi
        else
            CERT_STATUS="${f_light_yellow}EXISTS (Could not parse expiry date)${reset}"
        fi
    else
        CERT_STATUS="${f_light_red}NOT FOUND (${PERSIST_CERT})${reset}"
    fi

    # 2. Check RAM file placement
    if [ -s "/etc/cert.pem" ] && [ -s "/etc/key.pem" ]; then
        RAM_STATUS="${f_light_green}ACTIVE (/etc/cert.pem, /etc/key.pem)${reset}"
    else
        RAM_STATUS="${f_light_red}MISSING${reset}"
    fi

    # 3. Check NVRAM mapping
    NV_CRT=$(nvram get https_crt_file 2>/dev/null)
    if [ -n "${NV_CRT}" ]; then
        NVRAM_STATUS="${f_light_green}MAPPED (${#NV_CRT} bytes)${reset}"
    else
        NVRAM_STATUS="${f_light_red}UNSET (https_crt_file is empty)${reset}"
    fi

    # 4. Check Cron Schedule
    CRON_ENTRY=$(cru l 2>/dev/null | grep -F "${CRUNAME}")
    if [ -n "${CRON_ENTRY}" ]; then
        CRON_SCHED=$(echo "${CRON_ENTRY}" | awk '{print $1,$2,$3,$4,$5}')
        CRON_STATUS="${f_light_green}ACTIVE (${CRON_SCHED})${reset}"
    else
        CRON_STATUS="${f_light_red}NOT SCHEDULED${reset}"
    fi

    # Print Aligned Summary
    printf "  %-20s : %b\n" "Domain"           "${DOMAIN:-Unconfigured}"
    printf "  %-20s : %b\n" "Certificate"      "${CERT_STATUS}"
    printf "  %-20s : %b\n" "RAM Copy"         "${RAM_STATUS}"
    printf "  %-20s : %b\n" "NVRAM Status"     "${NVRAM_STATUS}"
    printf "  %-20s : %b\n" "Cron Job"         "${CRON_STATUS}"
    echo -e "========================================================"
}

help(){
    cat <<USAGE
	
Tomato64 – Let's Encrypt helper v1.1 - rs232

Usage:  ${SCRIPT_NAME} start [--staging]   Install/load/cron cert (use --staging to bypass production rate limit)
        ${SCRIPT_NAME} stop                Unload certificate, restore default Tomato cert, remove cron
        ${SCRIPT_NAME} status              Show certificate and renewal status
        ${SCRIPT_NAME} reload              Re-map saved certificate to Tomato NVRAM
        ${SCRIPT_NAME} update              Update acme.sh
        ${SCRIPT_NAME} help                Show this help

Add to Tomato64 Init or WAN Up:
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
