#!/bin/bash
###############################################################################
# wp-bulk-permalink-flush.sh
# Bulk Flush WordPress Permalinks across cPanel accounts
# Version : 1.1.0
# Location: /usr/local/sbin/wp-bulk-permalink-flush.sh
# Usage   : bash /usr/local/sbin/wp-bulk-permalink-flush.sh
# ─────────────────────────────────────────────────────────────────────────────
# CHANGELOG:
#   v1.1.0 | 2026-04-28 00:53 | เปลี่ยน flush method เป็น wp eval +
#           |                  | set_permalink_structure + is_apache=true
#           |                  | เพื่อบังคับ write .htaccess บน LiteSpeed
#           |                  | เพิ่ม find_php_cli() + PHP_CLI variable
#   v1.0.0 | 2026-04-28 00:00 | Initial release
###############################################################################

VERSION="1.1.0"
LOG_FILE="/usr/local/sbin/wp-bulk-permalink-flush.log"
WP_CLI="/usr/local/bin/wp"
PHP_CLI=""   # ตั้งค่าใน check_requirements() → find_php_cli()

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m';    GREEN='\033[0;32m';  YELLOW='\033[1;33m'
BLUE='\033[0;34m';   CYAN='\033[0;36m';   WHITE='\033[1;37m'
BOLD='\033[1m';      DIM='\033[2m';        RESET='\033[0m'

# ── Global Maps ───────────────────────────────────────────────────────────────
declare -A G_MAIN_DOMAINS=()        # domain       → cpanel_user
declare -A G_USER_MAINDOMAIN=()     # cpanel_user  → main_domain
declare -A G_ADDON_DOMAINS=()       # addon_domain → cpanel_user
declare -A G_PARKED_PARENT=()       # parked_dom   → parent_domain
declare -A G_PARKED_USER=()         # parked_dom   → cpanel_user

# ── Counters ──────────────────────────────────────────────────────────────────
CNT_TOTAL=0; CNT_SUCCESS=0; CNT_FAILED=0; CNT_SKIP=0

###############################################################################
# Logging — OVERWRITE each run (ป้องกัน log บวม)
###############################################################################
log_init() {
    {
        printf "╔══════════════════════════════════════════════════════════╗\n"
        printf "║   WP Bulk Permalink Flush  v%-28s║\n" "${VERSION}"
        printf "╠══════════════════════════════════════════════════════════╣\n"
        printf "║  Started : %-46s║\n" "$(TZ='Asia/Bangkok' date '+%Y-%m-%d %H:%M:%S')"
        printf "╚══════════════════════════════════════════════════════════╝\n"
        echo ""
    } > "$LOG_FILE"
}

log() { echo "$1" >> "$LOG_FILE"; }

###############################################################################
# Header
###############################################################################
print_header() {
    clear
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BLUE}║  ${WHITE}${BOLD}WP Bulk Permalink Flush  v${VERSION}${RESET}${BLUE}                             ║${RESET}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${RESET}"
    echo ""
}

###############################################################################
# Find PHP CLI — sync กับ WHM default PHP (เหมือน website-daily-create.sh)
###############################################################################
find_php_cli() {
    local cli=""

    # 1. WHM default PHP
    local default_php
    default_php=$(whmapi1 php_get_system_default_version 2>/dev/null \
        | grep -o 'ea-php[0-9]*')
    if [[ -n "$default_php" && -f "/opt/cpanel/${default_php}/root/usr/bin/php" ]]; then
        cli="/opt/cpanel/${default_php}/root/usr/bin/php"
    fi

    # 2. Fallback: รองลงมา 1 ตัว
    if [[ -z "$cli" ]]; then
        cli=$(ls -d /opt/cpanel/ea-php*/root/usr/bin/php 2>/dev/null \
            | sort -V | tail -2 | head -1)
    fi

    # 3. Fallback: system php
    if [[ -z "$cli" ]]; then
        cli=$(command -v php 2>/dev/null || true)
    fi

    [[ -z "$cli" ]] && return 1
    echo "$cli"
}

###############################################################################
# Requirements
###############################################################################
check_requirements() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[ERROR]${RESET} กรุณารันด้วย root"; exit 1
    fi

    # หา wp-cli
    for p in /usr/local/bin/wp /usr/bin/wp /root/bin/wp; do
        [[ -x "$p" ]] && WP_CLI="$p" && break
    done
    [[ -z "$WP_CLI" ]] && WP_CLI=$(command -v wp 2>/dev/null || true)
    if [[ -z "$WP_CLI" ]]; then
        echo -e "${RED}[ERROR]${RESET} ไม่พบ wp-cli"; exit 1
    fi

    # หา PHP CLI
    local php_bin
    php_bin=$(find_php_cli)
    if [[ -z "$php_bin" ]]; then
        echo -e "${RED}[ERROR]${RESET} ไม่พบ PHP CLI"; exit 1
    fi
    # เพิ่ม flag suppress Deprecated (เหมือน website-daily-create.sh)
    PHP_CLI="$php_bin -d error_reporting=E_ALL&~E_DEPRECATED"

    for f in /etc/userdomains /etc/trueuserdomains; do
        [[ ! -f "$f" ]] && echo -e "${RED}[ERROR]${RESET} ไม่พบ $f" && exit 1
    done
}

###############################################################################
# Build: Main Domains Map  (/etc/trueuserdomains)
###############################################################################
build_main_domains_map() {
    G_MAIN_DOMAINS=(); G_USER_MAINDOMAIN=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        local domain cpuser
        domain=$(awk '{print $1}' <<< "$line" | tr -d ':' | tr -d ' \t')
        cpuser=$(awk '{print $2}' <<< "$line" | tr -d ' \t')
        [[ -z "$domain" || -z "$cpuser" ]] && continue
        G_MAIN_DOMAINS["$domain"]="$cpuser"
        G_USER_MAINDOMAIN["$cpuser"]="$domain"
    done < /etc/trueuserdomains
}

###############################################################################
# Build: Parked/Alias Map  (/etc/userdatadomains)
###############################################################################
build_parked_alias_map() {
    G_PARKED_PARENT=(); G_PARKED_USER=()
    [[ ! -f /etc/userdatadomains ]] && return
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        local domain rest cpuser parent
        domain=$(cut -d: -f1 <<< "$line" | tr -d ' \t')
        rest=$(cut -d: -f2- <<< "$line")
        cpuser=$(awk -F'==' '{print $1}' <<< "$rest" | tr -d ' \t')
        parent=$(awk -F'==' '{print $2}' <<< "$rest" | tr -d ' \t')
        if echo "$rest" | grep -qE '(^|==)(parked|alias)(==|$)'; then
            [[ -z "$domain" || -z "$cpuser" || -z "$parent" ]] && continue
            G_PARKED_PARENT["$domain"]="$parent"
            G_PARKED_USER["$domain"]="$cpuser"
        fi
    done < /etc/userdatadomains
}

###############################################################################
# Get All cPanel Users
###############################################################################
get_all_cpanel_users() {
    local -n _out=$1
    _out=()
    local -A _seen=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        local u
        u=$(awk '{print $2}' <<< "$line" | tr -d ' \t')
        [[ -z "$u" ]] && continue
        if [[ -z "${_seen[$u]+x}" ]]; then
            _seen["$u"]=1
            _out+=("$u")
        fi
    done < /etc/trueuserdomains
    mapfile -t _out < <(printf '%s\n' "${_out[@]}" | sort)
}

###############################################################################
# Build: Addon Domains Map
###############################################################################
build_addon_domains_map() {
    local filter_users=("$@")
    G_ADDON_DOMAINS=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        [[ "$line" == *".cp:"*   ]] && continue
        [[ "$line" == *"nobody"* ]] && continue
        [[ "$line" == \**        ]] && continue
        local domain cpuser
        domain=$(awk '{print $1}' <<< "$line" | tr -d ':' | tr -d ' \t')
        cpuser=$(awk '{print $2}' <<< "$line" | tr -d ' \t')
        [[ -z "$domain" || -z "$cpuser" ]] && continue
        [[ -n "${G_MAIN_DOMAINS[$domain]+x}" ]] && continue
        local main_dom="${G_USER_MAINDOMAIN[$cpuser]:-}"
        [[ -n "$main_dom" && "$domain" == *".$main_dom" ]] && continue
        if [[ ${#filter_users[@]} -gt 0 ]]; then
            local match=0
            for u in "${filter_users[@]}"; do
                [[ "$cpuser" == "$u" ]] && match=1 && break
            done
            [[ $match -eq 0 ]] && continue
        fi
        G_ADDON_DOMAINS["$domain"]="$cpuser"
    done < /etc/userdomains
}

###############################################################################
# Find WordPress Path (2 โครงสร้าง)
###############################################################################
find_wp_path() {
    local domain=$1 cpuser=$2
    local -n _ret=$3
    _ret=""
    local p1="/home/${cpuser}/public_html/${domain}"
    local p2="/home/${cpuser}/${domain}"
    if   [[ -f "${p1}/wp-config.php" ]]; then _ret="$p1"
    elif [[ -f "${p2}/wp-config.php" ]]; then _ret="$p2"
    fi
}

###############################################################################
# Find WP path for PARENT domain (ครอบคลุม main domain ด้วย)
###############################################################################
find_wp_path_for_parent() {
    local parent_dom=$1 cpuser=$2
    local -n _ret2=$3
    _ret2=""
    find_wp_path "$parent_dom" "$cpuser" _ret2
    [[ -n "$_ret2" ]] && return
    [[ -f "/home/${cpuser}/public_html/wp-config.php" ]] && \
        _ret2="/home/${cpuser}/public_html" && return
    [[ -f "/home/${cpuser}/wp-config.php" ]] && \
        _ret2="/home/${cpuser}"
}

###############################################################################
# Flush Permalink — wp eval method (เหมือน website-daily-create.sh Step 8)
# ─────────────────────────────────────────────────────────────────────────────
# ทำไมต้อง is_apache=true:
#   LiteSpeed ทำให้ WP detect ว่าไม่ใช่ Apache → ไม่ยอม write .htaccess
#   บังคับด้วย $GLOBALS["is_apache"]=true → flush_rewrite_rules() write .htaccess
# ทำไมต้อง set_permalink_structure:
#   ป้องกันกรณี structure ถูก reset → บังคับ /%postname%/ เสมอ
###############################################################################
do_flush() {
    local domain=$1 cpuser=$2 wp_path=$3 use_url=${4:-""}
    local url_arg=""
    [[ -n "$use_url" ]] && url_arg="--url=https://${use_url}"

    local out
    # shellcheck disable=SC2086
    out=$(sudo -u "$cpuser" $PHP_CLI "$WP_CLI" eval '
        global $wp_rewrite;
        $wp_rewrite->set_permalink_structure("/%postname%/");
        $GLOBALS["is_apache"] = true;
        flush_rewrite_rules(true);
        echo "done";
    ' --path="$wp_path" --allow-root $url_arg 2>&1)

    echo "$out"                      # ส่ง output ให้ caller capture
    echo "$out" | grep -q "done"     # exit 0 = สำเร็จ, exit 1 = ไม่ได้ "done"
    return $?
}

###############################################################################
# Inline Spinner + run command
###############################################################################
run_with_spinner() {
    local label=$1 idx=$2 total=$3
    shift 3
    local tmp; tmp=$(mktemp)
    "$@" >"$tmp" 2>&1 &
    local bg=$!
    local sp='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' si=0
    while kill -0 "$bg" 2>/dev/null; do
        si=$(( (si+1) % 10 ))
        printf "\r  ${CYAN}[%4d/%-4d]${RESET} %-55s ${CYAN}%s${RESET}" \
            "$idx" "$total" "$label" "${sp:$si:1}"
        sleep 0.08
    done
    wait "$bg"; local ec=$?
    local out; out=$(cat "$tmp"); rm -f "$tmp"
    if [[ $ec -eq 0 ]]; then
        printf "\r  ${CYAN}[%4d/%-4d]${RESET} %-55s ${GREEN}✔ OK${RESET}\n" \
            "$idx" "$total" "$label"
    else
        printf "\r  ${CYAN}[%4d/%-4d]${RESET} %-55s ${RED}✖ FAIL${RESET}\n" \
            "$idx" "$total" "$label"
    fi
    LAST_RUN_OUTPUT="$out"
    return $ec
}

###############################################################################
# Main Processing
###############################################################################
process_domains() {
    local filter_users=("$@")
    echo ""
    echo -e "${CYAN}  ⟳  กำลังสแกน domain...${RESET}"

    build_main_domains_map
    build_parked_alias_map
    build_addon_domains_map "${filter_users[@]}"

    local -A ALIAS_TODO=()
    for alias_dom in "${!G_PARKED_PARENT[@]}"; do
        local parent="${G_PARKED_PARENT[$alias_dom]}"
        local acpuser="${G_PARKED_USER[$alias_dom]}"
        if [[ ${#filter_users[@]} -gt 0 ]]; then
            local match=0
            for u in "${filter_users[@]}"; do [[ "$acpuser" == "$u" ]] && match=1 && break; done
            [[ $match -eq 0 ]] && continue
        fi
        ALIAS_TODO["$alias_dom"]="${acpuser}|${parent}"
    done

    local total_addon=${#G_ADDON_DOMAINS[@]}
    local total_alias=${#ALIAS_TODO[@]}
    CNT_TOTAL=$(( total_addon + total_alias ))

    echo -e "  ${GREEN}✔${RESET}  Addon domains  : ${WHITE}${total_addon}${RESET}"
    echo -e "  ${GREEN}✔${RESET}  Parked/Alias   : ${WHITE}${total_alias}${RESET}"
    echo -e "  ${GREEN}✔${RESET}  รวมทั้งหมด     : ${WHITE}${CNT_TOTAL}${RESET}"
    echo ""

    log_init
    log "Filter users   : ${filter_users[*]:-ALL}"
    log "Addon domains  : $total_addon"
    log "Parked/Alias   : $total_alias"
    log "Total          : $CNT_TOTAL"
    log ""

    local current=0
    LAST_RUN_OUTPUT=""

    # ── Addon Domains ────────────────────────────────────────────────────────
    if [[ $total_addon -gt 0 ]]; then
        echo -e "${BLUE}━━━  Addon Domains  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        log "=== Addon Domains ==="
        for domain in $(printf '%s\n' "${!G_ADDON_DOMAINS[@]}" | sort); do
            local cpuser="${G_ADDON_DOMAINS[$domain]}"
            current=$(( current + 1 ))
            local wp_path=""
            find_wp_path "$domain" "$cpuser" wp_path
            if [[ -z "$wp_path" ]]; then
                printf "  ${CYAN}[%4d/%-4d]${RESET} %-55s ${YELLOW}⊘ SKIP${RESET}\n" \
                    "$current" "$CNT_TOTAL" "$domain"
                log "[SKIP] $domain ($cpuser) — no wp-config.php"
                CNT_SKIP=$(( CNT_SKIP + 1 )); continue
            fi
            run_with_spinner "$domain" "$current" "$CNT_TOTAL" \
                do_flush "$domain" "$cpuser" "$wp_path" ""
            if [[ $? -eq 0 ]]; then
                log "[OK]   $domain ($cpuser) → $wp_path"
                CNT_SUCCESS=$(( CNT_SUCCESS + 1 ))
            else
                log "[FAIL] $domain ($cpuser) → $wp_path"
                [[ -n "$LAST_RUN_OUTPUT" ]] && log "       ↳ $LAST_RUN_OUTPUT"
                CNT_FAILED=$(( CNT_FAILED + 1 ))
            fi
        done
    fi

    # ── Parked / Alias Domains ────────────────────────────────────────────────
    if [[ $total_alias -gt 0 ]]; then
        echo ""
        echo -e "${BLUE}━━━  Parked / Alias Domains  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        log ""
        log "=== Parked/Alias Domains ==="
        for alias_dom in $(printf '%s\n' "${!ALIAS_TODO[@]}" | sort); do
            IFS='|' read -r acpuser parent_dom <<< "${ALIAS_TODO[$alias_dom]}"
            current=$(( current + 1 ))
            local label="${alias_dom}  →  ${parent_dom}"
            local wp_path=""
            find_wp_path_for_parent "$parent_dom" "$acpuser" wp_path
            if [[ -z "$wp_path" ]]; then
                printf "  ${CYAN}[%4d/%-4d]${RESET} %-55s ${YELLOW}⊘ SKIP${RESET}\n" \
                    "$current" "$CNT_TOTAL" "$label"
                log "[SKIP] $alias_dom → $parent_dom ($acpuser) — parent wp-config.php not found"
                CNT_SKIP=$(( CNT_SKIP + 1 )); continue
            fi
            # --url=alias_domain เพื่อ flush ด้วยชื่อ alias โดยตรง
            run_with_spinner "$label" "$current" "$CNT_TOTAL" \
                do_flush "$alias_dom" "$acpuser" "$wp_path" "$alias_dom"
            if [[ $? -eq 0 ]]; then
                log "[OK]   $alias_dom (alias→$parent_dom) ($acpuser) → $wp_path"
                CNT_SUCCESS=$(( CNT_SUCCESS + 1 ))
            else
                log "[FAIL] $alias_dom (alias→$parent_dom) ($acpuser) → $wp_path"
                [[ -n "$LAST_RUN_OUTPUT" ]] && log "       ↳ $LAST_RUN_OUTPUT"
                CNT_FAILED=$(( CNT_FAILED + 1 ))
            fi
        done
    fi

    # ── Summary ───────────────────────────────────────────────────────────────
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BLUE}║  ${WHITE}${BOLD}SUMMARY${RESET}${BLUE}                                                      ║${RESET}"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════════╣${RESET}"
    printf "${BLUE}║${RESET}  Total   : ${WHITE}%-4d${RESET}%-37s${BLUE}║${RESET}\n" "$CNT_TOTAL" ""
    printf "${BLUE}║${RESET}  ${GREEN}Success${RESET}  : ${GREEN}%-4d${RESET}%-37s${BLUE}║${RESET}\n" "$CNT_SUCCESS" ""
    printf "${BLUE}║${RESET}  ${RED}Failed${RESET}   : ${RED}%-4d${RESET}%-37s${BLUE}║${RESET}\n" "$CNT_FAILED" ""
    printf "${BLUE}║${RESET}  ${YELLOW}Skipped${RESET}  : ${YELLOW}%-4d${RESET}%-37s${BLUE}║${RESET}\n" "$CNT_SKIP" ""
    echo -e "${BLUE}║${RESET}  ${DIM}Log: $LOG_FILE${RESET}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${RESET}"

    log ""
    log "=== SUMMARY ==="
    log "Total  : $CNT_TOTAL"
    log "OK     : $CNT_SUCCESS"
    log "Failed : $CNT_FAILED"
    log "Skipped: $CNT_SKIP"
    log "Finished: $(TZ='Asia/Bangkok' date '+%Y-%m-%d %H:%M:%S')"
}

###############################################################################
# MAIN MENU
###############################################################################
check_requirements
print_header

echo -e "${WHITE}${BOLD}เลือกโหมดการทำงาน:${RESET}"
echo ""
echo -e "  ${CYAN}1.${RESET}  รัน Flush Permalink ${WHITE}ทุกเว็บไซต์${RESET} ใน server นี้ทั้งหมด"
echo -e "  ${CYAN}2.${RESET}  เลือกรันเฉพาะบาง ${WHITE}cPanel${RESET} ในเซิร์ฟเวอร์นี้"
echo ""
printf "กรุณาเลือก [1-2]: "
read -r MODE

build_main_domains_map

declare -a ALL_CPANEL_USERS=()
get_all_cpanel_users ALL_CPANEL_USERS

case "$MODE" in

    1)
        print_header
        echo -e "${WHITE}${BOLD}[ Mode 1 ]  Run ALL cPanel accounts${RESET}"
        echo ""
        echo -e "${CYAN}cPanel accounts ที่มีในระบบ (${#ALL_CPANEL_USERS[@]} accounts):${RESET}"
        echo ""
        for u in "${ALL_CPANEL_USERS[@]}"; do
            echo -e "  ${GREEN}•${RESET}  $u"
        done
        echo ""
        printf "${YELLOW}ยืนยันการรัน Flush Permalink ทุก cPanel ข้างบน? [y/N]: ${RESET}"
        read -r CONFIRM
        [[ "${CONFIRM,,}" != "y" ]] && echo -e "${RED}ยกเลิก${RESET}" && exit 0
        process_domains
        ;;

    2)
        print_header
        echo -e "${WHITE}${BOLD}[ Mode 2 ]  เลือก cPanel account${RESET}"
        echo ""
        echo -e "${CYAN}cPanel accounts ที่มีในระบบ:${RESET}"
        echo ""
        for i in "${!ALL_CPANEL_USERS[@]}"; do
            printf "  ${CYAN}%3d.${RESET}  %s\n" "$(( i + 1 ))" "${ALL_CPANEL_USERS[$i]}"
        done
        echo ""
        echo -e "${YELLOW}เลือกหมายเลข (คั่นด้วย space หรือ comma)${RESET}"
        echo -e "${DIM}เช่น:  1 3 5   หรือ   1,3,5${RESET}"
        echo ""
        printf "เลือก: "
        read -r RAW_SEL
        declare -a SELECTED_USERS=()
        for sel in $(echo "$RAW_SEL" | tr ',' ' '); do
            if [[ "$sel" =~ ^[0-9]+$ ]]; then
                idx=$(( sel - 1 ))
                if [[ $idx -ge 0 && $idx -lt ${#ALL_CPANEL_USERS[@]} ]]; then
                    SELECTED_USERS+=("${ALL_CPANEL_USERS[$idx]}")
                else
                    echo -e "${RED}  [WARN]${RESET} หมายเลข $sel ไม่มีใน list — ข้ามไป"
                fi
            else
                echo -e "${RED}  [WARN]${RESET} '$sel' ไม่ใช่หมายเลข — ข้ามไป"
            fi
        done
        if [[ ${#SELECTED_USERS[@]} -eq 0 ]]; then
            echo -e "${RED}[ERROR]${RESET} ไม่ได้เลือก cPanel ใด"; exit 1
        fi
        mapfile -t SELECTED_USERS < <(printf '%s\n' "${SELECTED_USERS[@]}" | sort -u)
        echo ""
        echo -e "${CYAN}cPanel ที่เลือก:${RESET}"
        for u in "${SELECTED_USERS[@]}"; do
            echo -e "  ${GREEN}✔${RESET}  $u"
        done
        echo ""
        printf "${YELLOW}ยืนยัน? [y/N]: ${RESET}"
        read -r CONFIRM2
        [[ "${CONFIRM2,,}" != "y" ]] && echo -e "${RED}ยกเลิก${RESET}" && exit 0
        process_domains "${SELECTED_USERS[@]}"
        ;;

    *)
        echo -e "${RED}[ERROR]${RESET} กรุณาเลือก 1 หรือ 2"; exit 1
        ;;
esac
