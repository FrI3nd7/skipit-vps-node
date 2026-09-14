#!/usr/bin/env bash
# SkipIt - панель управления VPS (текстовое меню)
#
# Разделы: нода Remnawave (установка и управление), пользователи и SSH,
#         фаервол UFW, ядро Linux (sysctl, BBR)
#
# Установка:  bash skipit.sh install     -> команда: skipit
# Удаление:   skipit uninstall

SKIPIT_VERSION="1.0.0a"
SKIPIT_CMD="skipit"
SKIPIT_BIN="/usr/local/bin/${SKIPIT_CMD}"
SKIPIT_ETC="/etc/skipit"
SKIPIT_BACKUPS="/var/backups/skipit"
SKIPIT_LOG="/var/log/skipit.log"
SKIPIT_LOCK="/run/skipit.lock"

SSHD_MAIN="/etc/ssh/sshd_config"
SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"
SSHD_DROPIN="${SSHD_DROPIN_DIR}/00-skipit.conf"
SYSCTL_FILE="/etc/sysctl.d/99-xray-node.conf"
SYSCTL_MODULES_FILE="/etc/modules-load.d/99-xray-node.conf"
SYSCTL_MODPROBE_FILE="/etc/modprobe.d/99-xray-node.conf"
SYSCTL_ORIG="${SKIPIT_ETC}/sysctl.orig"
NODE_DIR="/opt/remnanode"
NODE_COMPOSE="${NODE_DIR}/docker-compose.yml"
NODE_ENV="${NODE_DIR}/.env"
NODE_NGINX="${NODE_DIR}/nginx.conf"
NODE_STATE="${SKIPIT_ETC}/node.conf"
F2B_STATE="${SKIPIT_ETC}/fail2ban.conf"
NODE_WEBROOT="/var/www/html"
NODE_SOCK="/dev/shm/nginx.sock"
NODE_IMAGE="remnawave/node:latest"
NODE_NGINX_IMAGE="nginx:1.30"
NODE_XHTTP_PORT=2096          # XHTTP REALITY - Xray
NODE_WS_PORT=2098             # WS - Xray, только 127.0.0.1
NODE_WS_PUBLIC=8443           # WS - публичный TLS-листенер nginx
CF_CREDS="${SKIPIT_ETC}/cloudflare.ini"
ACME_OPEN="/etc/letsencrypt/renewal-hooks/pre/skipit-open80.sh"
ACME_CLOSE="/etc/letsencrypt/renewal-hooks/post/skipit-close80.sh"
F2B_JAIL="/etc/fail2ban/jail.d/skipit.local"
F2B_FILTER="/etc/fail2ban/filter.d/skipit-portscan.conf"
F2B_LOG="/var/log/fail2ban.log"
ACME_DEPLOY="/etc/letsencrypt/renewal-hooks/deploy/skipit-restart-node.sh"
ACME_DEPLOY_OLD="/etc/letsencrypt/renewal-hooks/deploy/skipit-nginx-reload.sh"

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

# ==== Общие утилиты ====
say()  { printf '\n  %sSkipIt%s %s›%s %b\n' "${C_BRAND:-$'\e[1;35m'}" $'\e[0m' "${C_ACC:-}" $'\e[0m' "$*"; }
die()  { printf '\n  %sSkipIt%s %s✗%s %b\n' "${C_BRAND:-$'\e[1;35m'}" $'\e[0m' "${C_ERR:-$'\e[1;31m'}" $'\e[0m' "$*" >&2; exit 1; }
log()  { printf '%s  %s\n' "$(date '+%F %T')" "$*" >>"$SKIPIT_LOG" 2>/dev/null; }
pause(){ echo; printf '  %s ' "$(ui_keys "Enter — вернуться в меню")"; ui_readline _ || echo; }

# Строка с терминала. Читаем в подпроцессе: в основном процессе Ctrl+C перехвачен
# (trap ':' INT, чтобы не закрывать панель), и read там не прерывается.
# Код != 0 - нажат Ctrl+C или ввод закрыт.
ui_readline() { # имя-переменной
    local _l
    _l=$(IFS= read -r _x <"$TTY" || exit 1; printf '%s' "$_x") || return 1
    printf -v "$1" '%s' "$_l"
}

# Дополнить строку пробелами до ширины w (с учётом кириллицы)
pad() { local s=$1 w=$2; printf '%s%*s' "$s" $(( w > ${#s} ? w - ${#s} : 0 )) ''; }

require_root() {
    [[ $EUID -eq 0 ]] && return 0
    local self; self=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null)
    if command -v sudo >/dev/null 2>&1 && [[ -f $self ]]; then
        exec sudo bash "$self" "$@"
    fi
    die "Нужны права root. Запустите от root: su - , затем bash $0"
}

setup_env() {
    # UTF-8 для кириллицы в окнах
    if [[ "$(locale charmap 2>/dev/null)" != "UTF-8" ]]; then
        local l
        for l in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
            if locale -a 2>/dev/null | grep -qx "$l"; then export LC_ALL="$l"; break; fi
        done
        [[ -z ${LC_ALL:-} ]] && export LC_ALL=C.UTF-8
    fi
    [[ -z ${TERM:-} || $TERM == dumb ]] && export TERM=xterm
    mkdir -p "$SKIPIT_ETC" "$SKIPIT_BACKUPS" 2>/dev/null
    chmod 700 "$SKIPIT_BACKUPS" 2>/dev/null
}

# ---- Пакетный менеджер ----
PM=""
detect_pm() {
    if   command -v apt-get >/dev/null 2>&1; then PM=apt
    elif command -v dnf     >/dev/null 2>&1; then PM=dnf
    elif command -v yum     >/dev/null 2>&1; then PM=yum
    else PM=""; fi
}

pkg_real_name() {
    case "$PM:$1" in
        *) echo "$1" ;;
    esac
}

pkg_install() {
    local pkgs=() p
    for p in "$@"; do pkgs+=("$(pkg_real_name "$p")"); done
    case "$PM" in
        apt)
            local opts=(-y -q -o DPkg::Lock::Timeout=180
                        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
            DEBIAN_FRONTEND=noninteractive apt-get install "${opts[@]}" "${pkgs[@]}" && return 0
            DEBIAN_FRONTEND=noninteractive apt-get update -q -o DPkg::Lock::Timeout=180 &&
            DEBIAN_FRONTEND=noninteractive apt-get install "${opts[@]}" "${pkgs[@]}"
            ;;
        dnf|yum)
            if [[ " ${pkgs[*]} " == *" ufw "* || " ${pkgs[*]} " == *" btop "* ]] && ! rpm -q epel-release >/dev/null 2>&1; then
                "$PM" install -y epel-release
            fi
            "$PM" install -y "${pkgs[@]}"
            ;;
        *) return 1 ;;
    esac
}

# Проверка при запуске: curl, sudo
# Обновить систему (apt update && apt upgrade). Ошибка не останавливает SkipIt.
# first - первый запуск SkipIt на сервере (только меняет текст сообщения)
sys_upgrade() {
    local rc=0 pre=""
    [[ ${1:-} == first ]] && pre="Первый запуск: "
    case $PM in
        apt)
            say "${pre}Обновляю пакеты системы..."
            DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get update -o DPkg::Lock::Timeout=180 &&
            DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get upgrade -y -o DPkg::Lock::Timeout=180 \
                -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold || rc=$? ;;
        dnf|yum)
            say "${pre}Обновляю пакеты системы..."
            # Ядро не обновляем: новое ядро требует перезагрузки и может не загрузиться
            "$PM" -y upgrade --exclude='kernel*' || rc=$? ;;
        *) return 0 ;;
    esac
    if (( rc == 0 )); then
        log "first run: system upgrade ok"
        say "Пакеты системы обновлены."
    else
        log "first run: system upgrade rc=$rc"
        say "Не удалось обновить пакеты (код $rc) — продолжаю без обновления."
    fi
    [[ -f /var/run/reboot-required ]] && say "Обновилось ядро или системные библиотеки — после настройки перезагрузите сервер: reboot"
    return 0
}

# Главное меню -> Сервер -> Обновление сервера
menu_sys_upgrade() {
    [[ -n $PM ]] || { ui_msg "Обновление сервера" "Не найден менеджер пакетов — обновите систему вручную."; return; }
    ui_yesno "Обновление сервера" "Обновится:     программы и библиотеки системы
Не тронется:   ядро Linux — так безопаснее
Займёт:        несколько минут, не закрывайте окно

! Если обновится Docker, клиенты VPN отключатся на 5–10 секунд

Обновить сервер?" || return
    clear >"$TTY"
    sys_upgrade
    if [[ -f /var/run/reboot-required ]]; then
        echo
        if ui_yesno "Нужна перезагрузка" "Обновилось ядро или системные библиотеки — изменения заработают после перезагрузки.
SSH-сессия оборвётся, сервер будет недоступен около минуты. Нода запустится сама.

Перезагрузить сервер сейчас?" no; then
            log "server reboot after upgrade"
            say "Перезагружаю сервер..."
            systemctl reboot
            return
        fi
    else
        pause
    fi
}

bootstrap_deps() {
    local need=() c
    for c in curl sudo; do
        command -v "$c" >/dev/null 2>&1 || need+=("$c")
    done
    (( ${#need[@]} )) || return 0
    [[ -n $PM ]] || die "Не найден apt/dnf/yum. Установите вручную: ${need[*]}"
    say "Устанавливаю недостающие пакеты: ${need[*]}"
    pkg_install "${need[@]}" || die "Не удалось установить: ${need[*]}"
    for c in "${need[@]}"; do
        command -v "$c" >/dev/null 2>&1 || die "После установки не найдена команда: $c"
    done
    log "bootstrap: установлены ${need[*]}"
}

self_install() {
    local src; src=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null)
    [[ -f $src ]] || die "Сохраните скрипт в файл и запустите: bash skipit.sh install"
    if [[ $src != "$SKIPIT_BIN" ]]; then
        install -m 0755 "$src" "$SKIPIT_BIN" || die "Не удалось скопировать в $SKIPIT_BIN"
    fi
    log "install v${SKIPIT_VERSION}"
}

self_uninstall() {
    rm -f "$SKIPIT_BIN"
    say "Команда ${SKIPIT_CMD} удалена."
    say "Не тронуты: нода (${NODE_DIR}), ${SSHD_DROPIN}, ${SYSCTL_FILE}, правила UFW, ${SKIPIT_ETC}"
}

usage() {
    cat <<EOF
SkipIt v${SKIPIT_VERSION} — панель управления VPS

  ${SKIPIT_CMD}              открыть меню
  ${SKIPIT_CMD} install      установить команду ${SKIPIT_CMD} (${SKIPIT_BIN})
  ${SKIPIT_CMD} uninstall    удалить команду
  ${SKIPIT_CMD} update       обновить SkipIt с GitHub (--yes: без вопросов)
  ${SKIPIT_CMD} version      версия
EOF
}

# ---- Конфиг SkipIt и бэкапы ----
backup_prefix() { echo "${SKIPIT_BACKUPS}/$(echo "${1#/}" | tr '/' '_')"; }

# Копия файла в /var/backups/skipit (хранятся последние 20). Печатает путь.
backup_file() {
    local f=$1 prefix dst
    [[ -f $f ]] || return 1
    prefix=$(backup_prefix "$f")
    dst="${prefix}.$(date +%Y%m%d-%H%M%S)"
    cp -a "$f" "$dst" || return 1
    ls -1t "${prefix}".* 2>/dev/null | tail -n +21 | xargs -r rm -f
    echo "$dst"
}

# Транзакция: запоминаем файлы до изменения, чтобы откатить при ошибке
TX_DIR=""; TX_FILES=()
tx_begin() { tx_end; TX_DIR=$(mktemp -d); TX_FILES=(); }
tx_add() {
    local f=$1 i
    for i in "${TX_FILES[@]}"; do [[ $i == "$f" ]] && return 0; done
    local idx=${#TX_FILES[@]}
    TX_FILES+=("$f")
    if [[ -e $f ]]; then
        cp -a "$f" "$TX_DIR/$idx"; backup_file "$f" >/dev/null
    else
        : > "$TX_DIR/$idx.absent"
    fi
}
tx_rollback() {
    local i f
    for i in "${!TX_FILES[@]}"; do
        f=${TX_FILES[$i]}
        if [[ -e $TX_DIR/$i.absent ]]; then rm -f "$f"; else cp -a "$TX_DIR/$i" "$f"; fi
    done
    tx_end
}
tx_end() { [[ -n $TX_DIR && -d $TX_DIR ]] && rm -rf "$TX_DIR"; TX_DIR=""; TX_FILES=(); }

# Интерфейс SkipIt: текстовое меню с номерами
# Всё выводится в /dev/tty, в stdout - только результат выбора/ввода.
C_RESET=$'\e[0m'
if (( $(tput colors 2>/dev/null || echo 8) >= 256 )) || [[ ${COLORTERM:-} == *color* || ${TERM:-} == *256* ]]; then
    C_BRAND=$'\e[1;38;5;169m' # SkipIt
    C_ACC=$'\e[1;38;5;74m'    # номера, приглашение
    C_KEY=$'\e[38;5;74m'      # клавиши в подсказках
    C_TXT=$'\e[38;5;252m'     # основной текст
    C_OK=$'\e[1;38;5;72m'     # значения
    C_ERR=$'\e[1;38;5;167m'
    C_WARN=$'\e[1;38;5;179m'
    C_LABEL=$'\e[38;5;103m'   # подписи "ключ - значение"
    C_NOTE=$'\e[38;5;110m'    # пояснения
    C_BADGE=$'\e[1;38;5;234;48;5;179m' # плашка «i» у пояснений
    C_SECTION=$'\e[1;38;5;255;48;5;60m' # плашка названия раздела
    C_HINT=$'\e[38;5;246m'    # подсказки внизу экрана
    C_DIM=$'\e[38;5;60m'      # линии и разделители
else
    C_BRAND=$'\e[1;35m'; C_ACC=$'\e[1;36m'; C_KEY=$'\e[36m'; C_TXT=$'\e[97m'
    C_OK=$'\e[1;32m'; C_ERR=$'\e[1;31m'; C_WARN=$'\e[1;33m'; C_LABEL=$'\e[37m'; C_NOTE=$'\e[96m'
    C_HINT=$'\e[37m'; C_DIM=$'\e[90m'; C_BADGE=$'\e[1;30;43m'; C_SECTION=$'\e[1;97;44m'
fi
C_GRAY=$C_HINT
TTY=/dev/tty
UI_CANCEL="Назад"
UI_FOOTER=""
UI_BANNER=0
UI_W=78

ui_dims() {
    local c; c=$(tput cols 2>/dev/null)
    [[ $c =~ ^[0-9]+$ ]] || c=80
    UI_W=$(( c - 4 )); (( UI_W > 110 )) && UI_W=110; (( UI_W < 40 )) && UI_W=40
}

ui_rule() {
    local w=$(( UI_W - 2 )); (( w > 72 )) && w=72
    printf '  %s%s%s\n' "$C_DIM" "$(printf '─%.0s' $(seq 1 "$w"))" "$C_RESET"
}

ui_banner() {
    local plain="SkipIt  ·  панель управления VPS  ·  v${SKIPIT_VERSION}" line
    line=$(printf '─%.0s' $(seq 1 $(( ${#plain} + 4 ))))
    printf '  %s╭%s╮%s\n' "$C_BRAND" "$line" "$C_RESET"
    printf '  %s│%s  %sSkipIt%s  %s·  панель управления VPS  ·  v%s%s  %s│%s\n' \
        "$C_BRAND" "$C_RESET" "$C_BRAND" "$C_RESET" "$C_HINT" "$SKIPIT_VERSION" "$C_RESET" "$C_BRAND" "$C_RESET"
    printf '  %s╰%s╯%s\n' "$C_BRAND" "$line" "$C_RESET"
}

# Шапка окна: чистый экран, "SkipIt › Заголовок", линия
ui_head() {
    G_STEP=0
    ui_dims
    {
        clear
        printf '\n  %sSkipIt%s %s›%s %s%s%s\n' "$C_BRAND" "$C_RESET" "$C_ACC" "$C_RESET" "$C_TXT" "$1" "$C_RESET"
        ui_rule
        echo
        ui_ctx
    } >"$TTY"
}

ui_indent() { sed 's/^/  /'; }

# "Ключ: значение" (и "ключ   значение", если plain=1) -> KV_K, KV_V
ui_kvline() { # строка plain
    local re1='^[[:space:]]*([^[:space:]:]{1,32}):[[:space:]]+(.+)$'
    local re2='^[[:space:]]*([^:]{1,32}):[[:space:]]{2,}(.+)$'
    local re3='^[[:space:]]*([[:alpha:]]{1,16})[[:space:]]{2,}(.+)$'
    if [[ $1 =~ $re2 || $1 =~ $re1 ]] || { [[ ${2:-0} == 1 ]] && [[ $1 =~ $re3 ]]; }; then
        KV_K=${BASH_REMATCH[1]}; KV_V=${BASH_REMATCH[2]}; return 0
    fi
    return 1
}

# Текст экрана в едином стиле: строки "ключ - значение" -> таблица, ✓ ! ✗ - цветные, остальное - цветом color
ui_textblock() { # текст цвет [plain]
    local color=$2 plain=${3:-0} line rest p ok i
    local -a ks vs
    while IFS= read -r line; do
        ks=(); vs=(); ok=0
        local tl=${line#"${line%%[![:space:]]*}"}
        if [[ $tl == '▸ '* ]]; then g_flush; g_path "${tl#▸ }"; continue; fi
        # "1. Текст" - нумерованный шаг, как на экранах мастера (номер из текста)
        if [[ $tl =~ ^([0-9]+)\.\ (.+)$ ]]; then g_flush; G_STEP=$(( BASH_REMATCH[1] - 1 )); g_steps "${BASH_REMATCH[2]}"; continue; fi
        if [[ $tl == 'ℹ '* ]]; then g_flush; g_note "${tl#ℹ }"; continue; fi
        if [[ $line == '    '* && $tl != [✓✗!]' '* ]]; then
            g_flush; printf '  %s%s%s\n' "$color" "$line" "$C_RESET" >"$TTY"; continue
        fi
        if [[ $line == *$'\t'* ]]; then
            (( ${#G_ROWS[@]} )) && { local _t=("${T_ROWS[@]}"); T_ROWS=(); g_flush; T_ROWS=("${_t[@]}"); }
            T_ROWS+=("$line"); continue
        fi
        t_flush
        if [[ $line == *' · '* ]]; then
            ok=1; rest=$line
            while [[ -n $rest ]]; do
                p=${rest%% · *}; [[ $p == "$rest" ]] && rest="" || rest=${rest#* · }
                p=${p#"${p%%[![:space:]]*}"}; p=${p%"${p##*[![:space:]]}"}
                if ui_kvline "$p" 0; then ks+=("$KV_K"); vs+=("$KV_V"); else ok=0; break; fi
            done
        fi
        if (( ok )); then
            for i in "${!ks[@]}"; do g_kv "${ks[$i]}" "${vs[$i]}"; done
        elif ui_kvline "$line" "$plain"; then
            g_kv "$KV_K" "$KV_V"
        else
            g_flush
            case $line in
                '') echo ;;
                '── '*) printf '  %s %s %s\n' "$C_SECTION" "${line#── }" "$C_RESET" ;;
                '▸ '*) g_path "${line#▸ }"; continue ;;
                *'✓ '*) printf '  %s\n' "${line/✓/$C_OK✓$C_RESET$C_HINT}$C_RESET" ;;
                *'✗ '*) printf '  %s\n' "${line/✗/$C_ERR✗$C_RESET$C_TXT}$C_RESET" ;;
                *'! '*) printf '  %s\n' "${line/!/$C_WARN!$C_RESET$C_TXT}$C_RESET" ;;
                *) printf '  %s%s%s\n' "$color" "$line" "$C_RESET" ;;
            esac >"$TTY"
        fi
    done <<< "$1"
    g_flush
}

# Ответы мастера, которые видны на каждом следующем экране: строки "ключ<TAB>значение"
UI_CTX=""
ui_ctx_add() { UI_CTX+="$1"$'\t'"$2"$'\n'; }
ui_ctx() {
    [[ -n $UI_CTX ]] || return 0
    local k v
    while IFS=$'\t' read -r k v; do
        [[ -z $k ]] && continue
        printf '  %s%s%s %s✓%s %s%s%s\n' "$C_LABEL" "$(pad "$k" 12)" "$C_RESET" "$C_OK" "$C_RESET" "$C_TXT" "$v" "$C_RESET"
    done <<< "$UI_CTX"
    ui_rule
    echo
}

ui_body() { [[ -n $1 ]] && ui_textblock "$1" "$C_TXT"; }

# "Enter - дальше, Ctrl+C - выйти" -> клавиши подсвечены, действия светло-серые
ui_keys() {
    local out="" sep="" part rest=$1
    while [[ -n $rest ]]; do
        part=${rest%% · *}
        [[ $part == "$rest" ]] && rest="" || rest=${rest#* · }
        if [[ $part == *' — '* ]]; then
            out+="$sep$C_KEY${part%% — *}$C_RESET$C_HINT — ${part#* — }$C_RESET"
        else
            out+="$sep$C_HINT$part$C_RESET"
        fi
        sep="$C_DIM · $C_RESET"
    done
    printf '%s' "$out"
}

ui_hint() { printf '\n  %s\n' "$(ui_keys "$1")" >"$TTY"; }

ui_prompt() { printf '\n  %sskipit%s %s(%s)%s %s❯%s ' "$C_BRAND" "$C_RESET" "$C_HINT" "$1" "$C_RESET" "$C_ACC" "$C_RESET" >"$TTY"; }

# Поле ответа в едином стиле: ❯ между линиями, под ним ошибка (если есть) и подсказка по клавишам.
# ui_ask_open - верхняя линия; ui_ask - поле (курсор в начале строки ❯); ui_ask_retry - вернуться на строку ❯ после Enter
ui_ask_open()  { { echo; ui_rule; } >"$TTY"; }
ui_ask() { # подсказка [ошибка]
    local up=3
    {
        printf '\e[J\n'; ui_rule; echo
        if [[ -n ${2:-} ]]; then printf '  %s✗%s %s%s%s\n' "$C_ERR" "$C_RESET" "$C_TXT" "$2" "$C_RESET"; up=4; fi
        printf '  %s\e[%dA\r  %s❯%s ' "$(ui_keys "$1")" "$up" "$C_ACC" "$C_RESET"
    } >"$TTY"
}
ui_ask_retry() { printf '\e[1A\r' >"$TTY"; }

# Строка ожидания на месте курсора: всё ниже стирается
# "Проверяю: Сервер..." -> действие голубым, предмет светлым
ui_loading() {
    local t=${1:-Собираю информацию…} act rest=""
    if [[ $t == *': '* ]]; then act=${t%%: *}; rest=": ${t#*: }"; else act=$t; fi
    printf '\r\e[J  %s•%s %s%s%s%s%s%s' "$C_ACC" "$C_RESET" "$C_ACC" "$act" "$C_RESET" "$C_TXT" "$rest" "$C_RESET" >"$TTY"
}

ui_msg() {   # заголовок текст
    ui_head "$1"
    ui_body "$2"
    printf '\n  %s ' "$(ui_keys "Enter — продолжить")" >"$TTY"
    ui_readline _
}

ui_yesno() { # заголовок текст [no — по умолчанию «нет»]
    local def=y keys="y — да · n — нет · Enter — да" a err=""
    [[ ${3:-} == no ]] && { def=n; keys="y — да · n — нет · Enter — нет"; }
    ui_head "$1"
    ui_field "$2" yesno
    ui_ask_open
    while :; do
        ui_ask "$keys" "$err"
        ui_readline a || return 1
        a=${a,,}; a=${a//[[:space:]]/}; [[ -z $a ]] && a=$def
        case $a in
            y|yes|д|да) return 0 ;;
            n|no|н|нет) return 1 ;;
        esac
        err="введите y или n"; ui_ask_retry
    done
}

# Приглашение для read -e: цвет внутри \001...\002, чтобы readline не сбивал курсор
UI_READ_PROMPT_IN=$'  \001'"$C_ACC"$'\002❯\001'"$C_RESET"$'\002 '

# Единый вид экранов подтверждения и ввода - сверху вниз:
#   1) таблица фактов "Ключ:  короткое значение" (что затронется, сколько займёт)
#   2) шаги "1. Текст" - что сделать в панели ("кнопки" в "ёлочках")
#   3) "! Текст" - последствие для клиентов VPN, одной строкой над вопросом
#   4) "ℹ Текст" - необязательная подсказка
#   5) вопрос "...?" или поле "Поле (правило):"
# Текст перед полем ввода: последняя строка "Поле (правило):" -> ▸ Поле + плашка i с правилом
ui_field() { # текст [yesno]
    local text=$1 last body field note
    last=${text##*$'\n'}
    [[ $text == *$'\n'* ]] && body=${text%$'\n'*} || body=""
    if [[ ${2:-} == yesno && $last != *'?' ]]; then
        local -a L; local k q=-1 nt=""
        mapfile -t L <<< "$text"
        for k in "${!L[@]}"; do [[ ${L[$k]} == *'?' && ${L[$k]} != ' '* ]] && q=$k; done
        if (( q >= 0 )); then
            for k in "${!L[@]}"; do (( k == q )) || nt+="${L[$k]}"$'\n'; done
            while [[ $nt == $'\n'* ]]; do nt=${nt#$'\n'}; done
            last=${L[$q]}; body=$nt
        fi
    fi
    while [[ $body == *$'\n' ]]; do body=${body%$'\n'}; done
    if [[ $last == *'?' && -n ${last//[[:space:]]/} && $last != ' '* ]]; then
        [[ -n $body ]] && { ui_body "$body"; echo >"$TTY"; }
        printf '  %s▸%s %s%s%s\n' "$C_ACC" "$C_RESET" "$C_BRAND" "$last" "$C_RESET" >"$TTY"
    elif [[ $last == *: ]]; then
        field=${last%:}
        if [[ $field =~ ^(.+)[[:space:]]\((.+)\)$ ]]; then field=${BASH_REMATCH[1]}; note=${BASH_REMATCH[2]}; fi
        [[ -n $body ]] && { ui_body "$body"; echo >"$TTY"; }
        printf '  %s▸%s %s%s%s\n' "$C_ACC" "$C_RESET" "$C_BRAND" "$field" "$C_RESET" >"$TTY"
        [[ -n $note ]] && g_note "$note"
    else
        ui_body "$text"
    fi
}

# Поле ввода между линиями, подсказка по клавишам под ним; курсор возвращается на строку ❯
ui_field_box() { # подсказка
    { echo; ui_rule; echo; ui_rule; printf '\n  %s\e[3A\r' "$(ui_keys "$1")"; } >"$TTY"
}

ui_input() { # заголовок текст [значение] → stdout
    ui_head "$1"
    ui_field "$2"
    ui_field_box "Enter — готово · Ctrl+C — отмена"
    local v
    { read -e -r -i "${3:-}" -p "$UI_READ_PROMPT_IN" v; } <"$TTY" >"$TTY" 2>"$TTY" || return 1
    printf '%s' "$v"
}

ui_pass() {  # заголовок текст -> stdout
    trap 'stty echo <"$TTY" 2>/dev/null; echo >"$TTY"; exit 130' INT
    ui_head "$1"
    ui_field "$2"
    ui_field_box "ввод скрыт · Enter — готово · Ctrl+C — отмена"
    local v
    { read -r -s -p "  ${C_ACC}❯${C_RESET} " v; } <"$TTY" 2>"$TTY" || { stty echo <"$TTY" 2>/dev/null; return 1; }
    echo >"$TTY"
    printf '%s' "$v"
}

# Нумерованный список.
# Пара "" "Подпись" - заголовок группы, пара "" "" - пустая строка.
_ui_list() { # заголовок текст тег описание ... → stdout: тег
    local title=$1 text=$2; shift 2
    local tags=() n=0 a
    ui_dims
    {
        if (( UI_BANNER )); then
            ui_banner
        else
            printf '\n  %sSkipIt%s %s›%s %s%s%s\n' "$C_BRAND" "$C_RESET" "$C_ACC" "$C_RESET" "$C_TXT" "$title" "$C_RESET"
            ui_rule
            [[ -n $UI_CTX ]] && { echo; ui_ctx; }
        fi
        if [[ -n $text ]]; then
            echo
            ui_textblock "$text" "$C_NOTE" 1
        fi
        (( UI_BANNER )) || echo
        local total=0 i=1 nw
        while (( i < $# )); do [[ -n ${!i} ]] && total=$((total + 1)); i=$((i + 2)); done
        nw=$(( ${#total} + 2 ))
        local lead=1; (( UI_BANNER )) && lead=0
        while (( $# >= 2 )); do
            if [[ -z $1 ]]; then
                if [[ -n $2 ]]; then
                    (( lead )) || echo
                    printf '  %s %s %s\n' "$C_SECTION" "$2" "$C_RESET"
                else
                    echo
                fi
                lead=0
            else
                lead=0
                n=$((n + 1)); tags+=("$1")
                printf '   %s%*s%s  %s%s%s\n' "$C_ACC" "$nw" "[$n]" "$C_RESET" "$C_TXT" "$2" "$C_RESET"
            fi
            shift 2
        done
        printf '\n   %s%*s%s  %s%s%s\n' "$C_LABEL" "$nw" "[0]" "$C_RESET" "$C_HINT" "$UI_CANCEL" "$C_RESET"
        [[ -n $UI_FOOTER ]] && printf '%s\n' "$UI_FOOTER"
    } >"$TTY"
    local err="" keys="1-$n — выбрать · 0 — ${UI_CANCEL,,}"
    (( n == 1 )) && keys="1 — выбрать · 0 — ${UI_CANCEL,,}"
    ui_ask_open
    while :; do
        ui_ask "$keys" "$err"
        ui_readline a || return 1
        a=${a//[[:space:]]/}
        [[ $a == 0 ]] && return 1
        if [[ $a =~ ^[0-9]+$ ]] && (( a >= 1 && a <= n )); then
            { printf '\r\e[J'; ui_rule; echo; } >"$TTY"
            ui_loading
            printf '%s' "${tags[$((a - 1))]}"
            return 0
        fi
        err="нет такого пункта: «$a»"; ui_ask_retry
    done
}

ui_menu()   { clear >"$TTY"; _ui_list "$@"; }   # меню раздела
ui_choose() { clear >"$TTY"; _ui_list "$@"; }   # выбор внутри действия

ui_checklist() { # заголовок текст тег описание ON|OFF ... → stdout: теги по строке
    local title=$1 text=$2; shift 2
    local tags=() n=0 a x out
    ui_head "$title"
    ui_body "$text"
    local cnt=$(( $# / 3 )) nw err=""
    nw=$(( ${#cnt} + 2 ))
    {
        echo
        while (( $# >= 3 )); do
            n=$((n + 1)); tags+=("$1")
            printf '   %s%*s%s  %s%s%s\n' "$C_ACC" "$nw" "[$n]" "$C_RESET" "$C_TXT" "$2" "$C_RESET"
            shift 3
        done
    } >"$TTY"
    ui_ask_open
    while :; do
        ui_ask "номера через пробел или запятую · 0 — отмена" "$err"
        ui_readline a || return 1
        a=${a//,/ }
        [[ -z ${a//[[:space:]]/} || ${a//[[:space:]]/} == 0 ]] && return 1
        out=""
        for x in $a; do
            if [[ ! $x =~ ^[0-9]+$ ]] || (( x < 1 || x > n )); then out="!"; break; fi
            [[ $'\n'$out == *$'\n'${tags[$((x - 1))]}$'\n'* ]] || out+="${tags[$((x - 1))]}"$'\n'
        done
        if [[ $out != "!" ]]; then printf '%s' "$out"; return 0; fi
        err="допустимы номера 1-$n"; ui_ask_retry
    done
}

ui_textfile() { # заголовок файл
    ui_head "$1"
    ui_textblock "$(cat "$2")" "$C_TXT"
    printf '\n  %s ' "$(ui_keys "Enter — продолжить")" >"$TTY"
    ui_readline _
}

ui_text() { ui_msg "$1" "$2"; }

# Установить пакет с подтверждением (вывод apt виден в терминале)
ensure_pkg() { # команда пакет
    command -v "$1" >/dev/null 2>&1 && return 0
    ui_yesno "Нужен пакет" "Для этого действия нужен пакет «$2», он не установлен.

Установить сейчас?" || return 1
    clear; say "Устанавливаю $2..."
    if ! pkg_install "$2" || ! command -v "$1" >/dev/null 2>&1; then
        echo; printf '%s✗ Не удалось установить %s%s\n' "$C_ERR" "$2" "$C_RESET"; pause; return 1
    fi
    log "pkg install $2"
}

# ==== Сведения о сервере ====
SERVER_IP=""; OS_NAME=""; VIRT=""
server_info_init() {
    SERVER_IP=$(curl -4 -fsS --max-time 3 https://api.ipify.org 2>/dev/null)
    [[ $SERVER_IP =~ ^[0-9]+(\.[0-9]+){3}$ ]] ||
        SERVER_IP=$(curl -4 -fsS --max-time 3 https://ifconfig.me 2>/dev/null)
    [[ $SERVER_IP =~ ^[0-9]+(\.[0-9]+){3}$ ]] ||
        SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -n $SERVER_IP ]] || SERVER_IP="IP-сервера"
    OS_NAME=$( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Linux}" )
    VIRT=$(systemd-detect-virt 2>/dev/null)
    if [[ -z $VIRT ]]; then
        if [[ -d /proc/vz && ! -d /proc/bc ]]; then VIRT=openvz; else VIRT="?"; fi
    fi
}

# ==== SSH-сервер: чтение и запись настроек ====
sshd_dump() { mkdir -p /run/sshd 2>/dev/null; sshd -T 2>/dev/null; }

sshd_eff() { # ключ → действующее значение
    sshd_dump | awk -v k="${1,,}" '$1==k { $1=""; sub(/^ /, ""); print; exit }'
}

ssh_ports() {
    local p
    p=$(sshd_dump | awk '$1=="port"{print $2}' | sort -un | xargs)
    if [[ -z $p ]]; then
        p=$(cat "$SSHD_MAIN" "$SSHD_DROPIN_DIR"/*.conf 2>/dev/null |
            awk 'tolower($1)=="port"{print $2}' | sort -un | xargs)
    fi
    echo "${p:-22}"
}

ssh_first_port() { local p; p=$(ssh_ports); echo "${p%% *}"; }

ssh_cmd_hint() { # пользователь → строка подключения
    local port; port=$(ssh_first_port)
    if [[ $port == 22 ]]; then echo "ssh $1@$SERVER_IP"; else echo "ssh -p $port $1@$SERVER_IP"; fi
}

sshd_uses_dropin() {
    [[ -d $SSHD_DROPIN_DIR ]] &&
    grep -Eiq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$SSHD_MAIN"
}

# Записать директиву (одно или несколько значений; без значений - удалить).
# Современные системы: /etc/ssh/sshd_config.d/00-skipit.conf (читается первым).
# Старые без Include: блок "# BEGIN SkipIt" в начале sshd_config.
sshd_write() {
    local key=$1; shift
    local v
    if sshd_uses_dropin; then
        tx_add "$SSHD_DROPIN"
        [[ -f $SSHD_DROPIN ]] || echo "# Управляется SkipIt. Этот файл читается первым — его значения приоритетны." > "$SSHD_DROPIN"
        sed -i "/^[[:space:]]*${key}[[:space:]]/Id" "$SSHD_DROPIN"
        for v in "$@"; do echo "$key $v" >> "$SSHD_DROPIN"; done
        chmod 644 "$SSHD_DROPIN"
    else
        tx_add "$SSHD_MAIN"
        grep -q '^# BEGIN SkipIt' "$SSHD_MAIN" || sed -i '1i # BEGIN SkipIt\n# END SkipIt' "$SSHD_MAIN"
        sed -i "/^# BEGIN SkipIt/,/^# END SkipIt/{/^[[:space:]]*${key}[[:space:]]/Id}" "$SSHD_MAIN"
        for v in "$@"; do sed -i "/^# END SkipIt/i ${key} ${v}" "$SSHD_MAIN"; done
    fi
}

# Закомментировать директиву вне блоков Match (и вне блока SkipIt)
sshd_comment_key() { # файл ключ
    local f=$1 k=${2,,} tmp
    [[ -f $f ]] || return 0
    awk -v k="$k" 'BEGIN{r="^[ \t]*" k "[ \t=]"} {l=tolower($0)}
        l ~ /^[ \t]*match[ \t]/ {m=1}
        /^# BEGIN SkipIt/ {s=1}  /^# END SkipIt/ {s=0}
        !m && !s && l ~ r {found=1} END{exit !found}' "$f" || return 0
    tx_add "$f"
    tmp=$(mktemp)
    awk -v k="$k" 'BEGIN{r="^[ \t]*" k "[ \t=]"} {l=tolower($0)}
        l ~ /^[ \t]*match[ \t]/ {m=1}
        /^# BEGIN SkipIt/ {s=1}  /^# END SkipIt/ {s=0}
        !m && !s && l ~ r { print "#SkipIt# " $0; next } { print }' "$f" > "$tmp" &&
        cat "$tmp" > "$f"
    rm -f "$tmp"
}

sshd_comment_everywhere() { # ключ — в sshd_config и чужих drop-in файлах
    local f
    sshd_comment_key "$SSHD_MAIN" "$1"
    for f in "$SSHD_DROPIN_DIR"/*.conf; do
        [[ -f $f && $f != "$SSHD_DROPIN" ]] && sshd_comment_key "$f" "$1"
    done
}

norm_sshd_val() { local v=${1,,}; [[ $v == without-password ]] && v=prohibit-password; echo "$v"; }

# Установить директиву и убедиться, что она действительно действует
sshd_set() { # ключ значение
    sshd_write "$1" "$2"
    [[ $(norm_sshd_val "$(sshd_eff "$1")") == "$(norm_sshd_val "$2")" ]] && return 0
    sshd_comment_everywhere "$1"
}

ssh_service_name() {
    if systemctl cat ssh.service >/dev/null 2>&1; then echo ssh; else echo sshd; fi
}

ssh_reload() {
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        # Ubuntu 22.10+: сокет-активация, порт задаётся ssh.socket
        if systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
            systemctl daemon-reload
            if ! systemctl restart ssh.socket 2>/dev/null; then
                systemctl stop ssh.service; systemctl restart ssh.socket || return 1
            fi
            systemctl try-reload-or-restart ssh.service 2>/dev/null
            return 0
        fi
        systemctl reload-or-restart "$(ssh_service_name)"
    else
        service ssh reload 2>/dev/null || service sshd reload
    fi
}

# Проверить sshd -t и применить; при ошибке - откатить
sshd_commit() {
    local out
    mkdir -p /run/sshd 2>/dev/null
    if ! out=$(sshd -t 2>&1); then
        tx_rollback
        ui_msg "Ошибка конфигурации SSH" "Проверка sshd -t не пройдена, изменения отменены:

$out"
        return 1
    fi
    if ! out=$(ssh_reload 2>&1); then
        tx_rollback; ssh_reload >/dev/null 2>&1
        ui_msg "Ошибка" "Не удалось перезапустить SSH, изменения отменены:

$out"
        return 1
    fi
    tx_end
    return 0
}

# Сколько валидных ключей в authorized_keys пользователя
user_key_count() {
    local home; home=$(getent passwd "$1" | cut -d: -f6)
    [[ -f $home/.ssh/authorized_keys ]] || { echo 0; return; }
    grep -Ec '^[[:space:]]*(ssh-|ecdsa-|sk-)' "$home/.ssh/authorized_keys" 2>/dev/null || true
}

# ==== Пользователи ====
uid_min() { local m; m=$(awk '/^UID_MIN/{print $2; exit}' /etc/login.defs 2>/dev/null); echo "${m:-1000}"; }

list_human_users() {
    getent passwd | awk -F: -v m="$(uid_min)" '$3>=m && $3<65534 {print $1}'
}

sudo_group() {
    if getent group sudo >/dev/null; then echo sudo
    elif getent group wheel >/dev/null; then echo wheel
    else echo sudo; fi
}

sudoers_file() { echo "/etc/sudoers.d/skipit-${1//./_}"; }

user_has_sudo() {
    [[ $1 == root ]] && return 0
    id -nG "$1" 2>/dev/null | tr ' ' '\n' | grep -qx "$(sudo_group)" || [[ -f $(sudoers_file "$1") ]]
}

user_has_password() { # есть ли рабочий пароль
    local h; h=$(getent shadow "$1" | cut -d: -f2)
    [[ -n $h && $h != \!* && $h != \** ]]
}

user_is_locked() {
    local e; e=$(getent shadow "$1" | cut -d: -f8)
    [[ $e == 1 || $e == 0 ]]
}

valid_login() { [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }

gen_password() {
    local p=""
    while (( ${#p} < 20 )); do
        p+=$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')
    done
    echo "${p:0:20}"
}

user_brief() {
    local s=""
    user_has_sudo "$1" && s+="sudo · "
    s+="ключей: $(user_key_count "$1")"
    user_has_password "$1" && s+=" · пароль"
    user_is_locked "$1" && s+=" · ЗАБЛОКИРОВАН"
    echo "$s"
}

pick_user() { # заголовок текст → логин
    local items=() u
    for u in $(list_human_users); do items+=("$u" "$u"); done
    if (( ${#items[@]} == 0 )); then
        ui_msg "$1" "На сервере нет обычных пользователей (UID ≥ $(uid_min))."
        return 1
    fi
    ui_choose "$1" "$(users_table_text noroot)

$2" "${items[@]}"
}

REPLY_PASS=""; REPLY_PASS_GEN=0
ask_password() { # логин
    local mode p1 p2
    mode=$(ui_choose "Пароль для $1" "Как задать пароль?" \
        gen    "Сгенерировать надёжный пароль (20 символов)" \
        manual "Ввести вручную") || return 1
    if [[ $mode == gen ]]; then
        REPLY_PASS=$(gen_password); REPLY_PASS_GEN=1; return 0
    fi
    while :; do
        p1=$(ui_pass "Пароль для $1" "Введите пароль (минимум 8 символов):") || return 1
        if (( ${#p1} < 8 )); then ui_msg "Ошибка" "Пароль короче 8 символов."; continue; fi
        p2=$(ui_pass "Пароль для $1" "Повторите пароль:") || return 1
        if [[ $p1 != "$p2" ]]; then ui_msg "Ошибка" "Пароли не совпадают."; continue; fi
        REPLY_PASS=$p1; REPLY_PASS_GEN=0; return 0
    done
}

REPLY_KEYS=""; REPLY_KEYS_SRC=""
ask_ssh_key() { # логин
    local mode raw gh path line tmp ok=0 bad=0
    mode=$(ui_choose "SSH-ключ для $1" "Откуда взять публичный ключ?" \
        paste  "Вставить ключ (ssh-ed25519 AAAA... / ssh-rsa ...)" \
        github "Импорт с GitHub (github.com/<ник>.keys)" \
        root   "Скопировать ключи root (/root/.ssh/authorized_keys)" \
        file   "Из файла на сервере") || return 1
    case $mode in
        paste)
            raw=$(ui_input "SSH-ключ" "На своём ПК:  cat ~/.ssh/id_ed25519.pub

Публичный ключ (одной строкой):") || return 1 ;;
        github)
            gh=$(ui_input "GitHub" "Ник на GitHub:") || return 1
            if [[ ! $gh =~ ^[A-Za-z0-9-]+$ ]]; then ui_msg "Ошибка" "Некорректный ник."; return 1; fi
            if ! raw=$(curl -fsSL --max-time 15 "https://github.com/${gh}.keys" 2>&1); then
                ui_msg "Ошибка" "Не удалось скачать ключи:
$raw"; return 1
            fi ;;
        root)
            raw=$(cat /root/.ssh/authorized_keys 2>/dev/null) ;;
        file)
            path=$(ui_input "Файл с ключами" "Путь к .pub или authorized_keys:") || return 1
            if [[ ! -r $path ]]; then ui_msg "Ошибка" "Файл не найден: $path"; return 1; fi
            raw=$(cat "$path") ;;
    esac
    case $mode in
        paste)  REPLY_KEYS_SRC="вставлен" ;;
        github) REPLY_KEYS_SRC="GitHub: $gh" ;;
        root)   REPLY_KEYS_SRC="ключи root" ;;
        file)   REPLY_KEYS_SRC="файл $path" ;;
    esac
    REPLY_KEYS=""
    tmp=$(mktemp)
    while IFS= read -r line; do
        line=${line%$'\r'}
        [[ -z ${line//[[:space:]]/} || $line == \#* ]] && continue
        printf '%s\n' "$line" > "$tmp"
        if ssh-keygen -l -f "$tmp" >/dev/null 2>&1; then
            REPLY_KEYS+="$line"$'\n'; ok=$((ok + 1))
        else
            bad=$((bad + 1))
        fi
    done <<< "$raw"
    rm -f "$tmp"
    if (( ok == 0 )); then
        ui_msg "Ошибка" "Не найдено ни одного корректного публичного SSH-ключа."
        return 1
    fi
    (( bad )) && ui_msg "Внимание" "Корректных ключей: $ok. Пропущено некорректных строк: $bad."
    return 0
}

install_keys() { # логин ключи → печатает число добавленных
    local u=$1 keys=$2 home grp ak line added=0
    home=$(getent passwd "$u" | cut -d: -f6); grp=$(id -gn "$u")
    ak="$home/.ssh/authorized_keys"
    install -d -m 700 -o "$u" -g "$grp" "$home/.ssh"
    touch "$ak"
    [[ -s $ak && -n $(tail -c1 "$ak") ]] && echo >> "$ak"
    while IFS= read -r line; do
        [[ -z $line ]] && continue
        grep -qxF -- "$line" "$ak" || { printf '%s\n' "$line" >> "$ak"; added=$((added + 1)); }
    done <<< "$keys"
    chown "$u:$grp" "$ak"; chmod 600 "$ak"
    echo "$added"
}

grant_sudo() { # логин nopasswd(0|1)
    local u=$1 nopass=$2 f
    if ! command -v sudo >/dev/null 2>&1; then
        pkg_install sudo >/dev/null 2>&1 || { ui_msg "Ошибка" "Не удалось установить sudo."; return 1; }
    fi
    usermod -aG "$(sudo_group)" "$u" || return 1
    f=$(sudoers_file "$u")
    if [[ $nopass == 1 ]]; then
        echo "$u ALL=(ALL:ALL) NOPASSWD: ALL" > "$f.tmp"
        chmod 440 "$f.tmp"
        if visudo -cf "$f.tmp" >/dev/null 2>&1; then mv "$f.tmp" "$f"; else rm -f "$f.tmp"; return 1; fi
    else
        rm -f "$f"
    fi
}

revoke_sudo() {
    gpasswd -d "$1" "$(sudo_group)" >/dev/null 2>&1
    rm -f "$(sudoers_file "$1")"
}

user_create() { UI_CTX=""; _user_create; local rc=$?; UI_CTX=""; return $rc; }

_user_create() {
    local u auth pass="" gen=0 keys="" want_sudo=0 nopass=0 shell=/bin/bash out summary nkeys
    while :; do
        u=$(ui_input "Новый пользователь" "── Уже есть на сервере
$(users_table_text)

Пример:  admin, deploy, vasya_1

Логин (строчные латинские буквы, цифры, _ и -):") || return
        if ! valid_login "$u"; then
            ui_msg "Ошибка" "Некорректный логин «$u».
Пример: admin, deploy, vasya_1"; continue
        fi
        if id "$u" >/dev/null 2>&1; then ui_msg "Ошибка" "Пользователь «$u» уже существует."; continue; fi
        break
    done
    ui_ctx_add "Пользователь" "$u"

    auth=$(ui_choose "Вход по SSH: $u" "Как пользователь будет входить на сервер?" \
        key  "По SSH-ключу (рекомендуется)" \
        pass "По паролю" \
        both "Ключ + пароль (пароль пригодится для sudo)") || return
    local auth_ru sudo_ru
    case $auth in key) auth_ru="SSH-ключ";; pass) auth_ru="пароль";; both) auth_ru="SSH-ключ + пароль";; esac
    ui_ctx_add "Вход" "$auth_ru"

    if [[ $auth != key ]]; then
        ask_password "$u" || return; pass=$REPLY_PASS; gen=$REPLY_PASS_GEN
        (( gen )) && ui_ctx_add "Пароль" "сгенерирован (20 символов)" || ui_ctx_add "Пароль" "задан вручную"
    else
        ui_ctx_add "Пароль" "не используется"
    fi
    if [[ $auth != pass ]]; then
        ask_ssh_key "$u" || return; keys=$REPLY_KEYS
        nkeys=$(grep -c . <<< "$keys")
        ui_ctx_add "SSH-ключ" "ключей: $nkeys · $REPLY_KEYS_SRC"
    else
        ui_ctx_add "SSH-ключ" "не используется"
    fi

    if ui_yesno "Права администратора" "Выдать пользователю $u права sudo?"; then
        want_sudo=1
        if [[ -z $pass ]]; then
            nopass=1
        elif [[ $(ui_choose "sudo для $u" "Как sudo будет спрашивать пароль?" \
                    pass   "С паролем (рекомендуется)" \
                    nopass "Без пароля (NOPASSWD)") == nopass ]]; then
            nopass=1
        fi
    fi
    if (( want_sudo )); then
        if (( nopass )); then sudo_ru="да, без пароля"; else sudo_ru="да, с паролем"; fi
    else
        sudo_ru="нет"
    fi
    ui_ctx_add "sudo" "$sudo_ru"

    if [[ $auth == pass && $(sshd_eff passwordauthentication) == no ]]; then
        ui_yesno "Внимание" "На сервере ОТКЛЮЧЁН вход по паролю (PasswordAuthentication no).
Пользователь $u не сможет войти по SSH, пока вход по паролю не будет разрешён.

Всё равно создать?" no || return
    fi

    ui_yesno "Подтверждение" "Создать пользователя $u?" || return

    [[ -x /bin/bash ]] || shell=/bin/sh
    if ! out=$(useradd -m -s "$shell" "$u" 2>&1); then
        ui_msg "Ошибка" "useradd завершился с ошибкой:
$out"; return
    fi
    if [[ -n $pass ]]; then
        printf '%s:%s\n' "$u" "$pass" | chpasswd
    else
        usermod -p '*' "$u"   # без пароля, но вход по ключу разрешён
    fi
    [[ -n $keys ]] && install_keys "$u" "$keys" >/dev/null
    if (( want_sudo )) && ! grant_sudo "$u" "$nopass"; then
        ui_msg "Внимание" "Пользователь создан, но выдать sudo не удалось."
    fi
    log "user create: $u auth=$auth sudo=$want_sudo nopasswd=$nopass"

    summary="Пользователь $u создан.

Подключение:
  $(ssh_cmd_hint "$u")"
    if (( gen )); then
        summary+="

Пароль:  $pass

Сохраните пароль — больше он показан не будет!"
    fi
    local au; au=$(sshd_eff allowusers)
    if [[ -n $au && " $au " != *" $u "* ]]; then
        summary+="

ВНИМАНИЕ: в sshd включён AllowUsers ($au) — $u туда не входит."
    fi
    ui_msg "Готово" "$summary"
}

users_table_text() { # [noroot]
    local u st
    printf 'Логин\tUID\tsudo\tКлючи\tПароль\tСтатус\n'
    for u in $([[ ${1:-} == noroot ]] || echo root) $(list_human_users); do
        st="активен"; user_is_locked "$u" && st="заблокирован"
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$u" "$(id -u "$u")" \
            "$(user_has_sudo "$u" && echo да || echo нет)" "$(user_key_count "$u")" \
            "$(user_has_password "$u" && echo да || echo нет)" "$st"
    done
}


user_add_key() {
    local u n
    u=$(pick_user "Добавить SSH-ключ" "Кому добавить ключ?") || return
    ask_ssh_key "$u" || return
    n=$(install_keys "$u" "$REPLY_KEYS")
    log "user addkey: $u added=$n"
    ui_msg "Готово" "Добавлено ключей: $n (дубликаты пропущены).
Всего у $u ключей: $(user_key_count "$u")"
}

user_passwd() {
    local u x items=(root root)
    for x in $(list_human_users); do items+=("$x" "$x"); done
    u=$(ui_choose "Смена пароля" "$(users_table_text)

Чей пароль сменить?" "${items[@]}") || return
    ask_password "$u" || return
    printf '%s:%s\n' "$u" "$REPLY_PASS" | chpasswd
    log "user passwd: $u"
    if (( REPLY_PASS_GEN )); then
        ui_msg "Готово" "Новый пароль для $u:

  $REPLY_PASS

Сохраните его — больше он показан не будет!"
    else
        ui_msg "Готово" "Пароль для $u изменён."
    fi
}

user_sudo_toggle() {
    local u cur choice nopass=0
    u=$(pick_user "Права sudo" "Выберите пользователя:") || return
    if ! user_has_sudo "$u"; then cur=none
    elif [[ -f $(sudoers_file "$u") ]]; then cur=nopass
    else cur=pass; fi
    choice=$(ui_choose "Права sudo: $u" "Пользователь:  $u
Сейчас:        $(case $cur in none) echo нет ;; pass) echo "да, с паролем" ;; nopass) echo "да, без пароля" ;; esac)
Пароль:        $(user_has_password "$u" && echo задан || echo нет)" \
        pass   "Выдать sudo с паролем" \
        nopass "Выдать sudo без пароля (NOPASSWD)" \
        ""     "" \
        none   "Забрать sudo") || return
    [[ $choice == "$cur" ]] && { ui_msg "Права sudo" "Уже установлено."; return; }
    if [[ $choice == none ]]; then
        revoke_sudo "$u"; log "user sudo revoke: $u"
        ui_msg "Готово" "Права sudo у $u отозваны."
        return
    fi
    if [[ $choice == pass ]] && ! user_has_password "$u"; then
        ui_msg "Права sudo" "У $u нет пароля — sudo с паролем он использовать не сможет.
Задайте пароль (Пользователи → Сменить пароль) или выберите «без пароля»."
        return
    fi
    [[ $choice == nopass ]] && nopass=1
    grant_sudo "$u" "$nopass" || { ui_msg "Ошибка" "Не удалось выдать sudo."; return; }
    log "user sudo grant: $u nopasswd=$nopass"
    ui_msg "Готово" "$u получил права sudo. Действует со следующего входа."
}

user_lock_toggle() {
    local u
    u=$(pick_user "Блокировка" "Выберите пользователя:") || return
    if user_is_locked "$u"; then
        ui_yesno "Разблокировать" "Разблокировать $u?" || return
        usermod -U "$u" >/dev/null 2>&1; chage -E -1 "$u"
        log "user unlock: $u"; ui_msg "Готово" "$u разблокирован."
    else
        ui_yesno "Заблокировать" "Заблокировать $u?
Вход будет запрещён и по паролю, и по ключу." no || return
        usermod -L -e 1 "$u"
        if [[ -n $(pgrep -u "$u" 2>/dev/null) ]] &&
           ui_yesno "Активные сессии" "У $u есть запущенные процессы. Завершить их (выкинуть из SSH)?"; then
            pkill -KILL -u "$u"
        fi
        log "user lock: $u"; ui_msg "Готово" "$u заблокирован."
    fi
}

user_delete() {
    local u mode out
    u=$(pick_user "Удаление пользователя" "Кого удалить?") || return
    if [[ $u == "${SUDO_USER:-}" ]]; then
        ui_msg "Нельзя" "Вы сейчас работаете от имени $u — его нельзя удалить."; return
    fi
    ui_yesno "Удаление" "Удалить пользователя $u?" no || return
    mode=$(ui_choose "Домашняя папка" "Что сделать с /home/$u?" \
        keep "Оставить файлы" \
        rm   "Удалить вместе с файлами") || return
    pkill -KILL -u "$u" 2>/dev/null; sleep 1
    if [[ $mode == rm ]]; then out=$(userdel -r "$u" 2>&1); else out=$(userdel "$u" 2>&1); fi
    if id "$u" >/dev/null 2>&1; then ui_msg "Ошибка" "Не удалось удалить:
$out"; return; fi
    rm -f "$(sudoers_file "$u")"
    log "user delete: $u mode=$mode"
    ui_msg "Готово" "Пользователь $u удалён."
}

# ---- Настройки SSH-сервера ----
ssh_change_port() {
    local cur new p busy
    cur=$(ssh_ports)
    new=$(ui_input "Порт SSH" "Сейчас:  $cur
UFW:     $(ufw_active && echo "новый порт откроется автоматически" || echo "не включён")

── Занятые порты
$(ports_used_table)

Старый порт закроется только после того, как вы проверите вход через новый.

Новый порт SSH (от 1 до 65535):") || return
    new=${new//[[:space:]]/}
    if [[ ! $new =~ ^[0-9]+$ ]] || (( new < 1 || new > 65535 )); then
        ui_msg "Ошибка" "Некорректный порт: $new"; return
    fi
    if port_in_ephemeral "$new"; then
        ui_yesno "Порт SSH" "$(port_ephemeral_warning "$new" "SSH")" no || return
    fi
    local reserved; reserved=$(port_node_reserved "$new")
    if [[ -n $reserved ]]; then
        ui_msg "Порт занят" "Порт:    $new
Занят:   $reserved

Выберите другой порт для SSH."; return
    fi

    # Уже слушаем этот порт среди нескольких -> оставить только его
    if [[ " $cur " == *" $new "* ]]; then
        [[ $cur == "$new" ]] && { ui_msg "Порт SSH" "SSH уже работает на порту $new."; return; }
        ui_yesno "Порт SSH" "Сейчас:    $cur
Оставить:  $new

Убедитесь, что подключение через порт $new работает!

Закрыть остальные порты?" no || return
        tx_begin; sshd_comment_everywhere port; sshd_write Port "$new"
        sshd_commit || return
        ssh_after_port_close "$cur" "$new"
        return
    fi

    busy=$(ss -Htlnp "sport = :$new" 2>/dev/null | grep -v sshd)
    if [[ -n $busy ]]; then
        ui_msg "Порт занят" "Порт $new уже занят другим процессом:

$busy"; return
    fi

    ui_yesno "Безопасная смена порта" "Сейчас:  $cur
Новый:   $new

1. SSH сразу начнёт слушать оба порта.
2. Вы проверите вход через новый порт в новом окне терминала.
3. Только после этого старый порт закроется.

Продолжить?" || return

    # SELinux (RHEL/CentOS/Alma/Rocky)
    if command -v getenforce >/dev/null 2>&1 && [[ $(getenforce 2>/dev/null) == Enforcing ]]; then
        command -v semanage >/dev/null 2>&1 || pkg_install policycoreutils-python-utils >/dev/null 2>&1
        semanage port -a -t ssh_port_t -p tcp "$new" 2>/dev/null ||
            semanage port -m -t ssh_port_t -p tcp "$new" 2>/dev/null
    fi
    # Фаерволы: открыть новый порт заранее
    if ufw_active; then ufwc allow "$new/tcp" comment 'SSH (SkipIt)' >/dev/null; fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="$new/tcp" >/dev/null && firewall-cmd --reload >/dev/null
    fi

    tx_begin
    sshd_comment_everywhere port
    # shellcheck disable=SC2086
    sshd_write Port $cur "$new"
    sshd_commit || return
    log "ssh port: $cur -> +$new"
    f2b_sync
    sleep 1

    local listening="нет"
    ss -Htln "sport = :$new" 2>/dev/null | grep -q . && listening="да"
    if ui_yesno "Проверьте подключение" "Порты SSH:          $(ssh_ports | sed 's/ /, /g')
Новый порт поднят:  $listening
Команда:            ssh -p $new ${SUDO_USER:-root}@$SERVER_IP

Откройте новое окно терминала и подключитесь этой командой.

Вход работает? Закрыть старый порт ($cur)?" no; then
        tx_begin; sshd_comment_everywhere port; sshd_write Port "$new"
        sshd_commit || return
        log "ssh port: only $new"
        f2b_sync
        ssh_after_port_close "$cur" "$new"
    else
        ui_msg "Порт SSH" "Открыты:  $cur, $new

Когда проверите вход, снова откройте «Порт SSH» и введите $new — останется только он."
    fi
}

ssh_after_port_close() { # старые_порты новый
    local p msg="SSH теперь работает только на порту $2."
    if ufw_active && ui_yesno "UFW" "Удалить правила UFW для старых портов SSH ($1)?"; then
        for p in $1; do
            [[ $p == "$2" ]] && continue
            ufwc --force delete allow "$p/tcp" >/dev/null 2>&1
            ufwc --force delete allow "$p/tcp" comment 'SSH (SkipIt)' >/dev/null 2>&1
            ufwc --force delete allow "$p" >/dev/null 2>&1
            [[ $p == 22 ]] && ufwc --force delete allow OpenSSH >/dev/null 2>&1
        done
        msg+=$'\n'"Правила UFW для старых портов удалены."
    fi
    ui_msg "Готово" "$msg"
}

ssh_root_login() {
    local cur choice warn="" su keys
    cur=$(norm_sshd_val "$(sshd_eff permitrootlogin)")
    choice=$(ui_choose "Вход root по SSH" "Сейчас: $(ru_root "$cur")" \
        yes               "Разрешить (пароль и ключ)" \
        prohibit-password "Только по SSH-ключу" \
        no                "Запретить полностью") || return
    [[ $choice == "$cur" ]] && { ui_msg "Вход root" "Уже установлено."; return; }

    keys=$(user_key_count root)
    if [[ $choice == prohibit-password && $keys == 0 ]]; then
        warn="У root НЕТ SSH-ключей — войти под root станет невозможно!"$'\n'
    fi
    if [[ $choice == no ]]; then
        su=""
        for u in $(list_human_users); do
            if user_has_sudo "$u" && ! user_is_locked "$u"; then su+="$u "; fi
        done
        if [[ -z $su ]]; then
            warn="Нет ни одного пользователя с sudo — после запрета вы потеряете права администратора по SSH!"$'\n'
        else
            warn="Пользователи с sudo: $su— проверьте, что можете войти под одним из них."$'\n'
        fi
    fi
    ui_yesno "Вход root" "${warn}
Установить «$(ru_root "$choice")»?" "$([[ -n $warn ]] && echo no)" || return
    tx_begin; sshd_set PermitRootLogin "$choice"; sshd_commit || return
    log "ssh PermitRootLogin $choice"
    ui_msg "Готово" "Вход root: $(ru_root "$(norm_sshd_val "$(sshd_eff permitrootlogin)")")
Текущие подключения не разорваны."
}

ssh_password_auth() {
    local cur choice info="" u k total=0
    cur=$(sshd_eff passwordauthentication)
    for u in root $(list_human_users); do
        k=$(user_key_count "$u")
        (( k > 0 )) && { info+="${info:+ · }$u: $k"; total=$((total + k)); }
    done
    choice=$(ui_choose "Вход по паролю" "Сейчас:       $([[ $cur == yes ]] && echo разрешён || echo запрещён)
SSH-ключи:    ${info:-ни у кого нет}" \
        yes "Разрешить (пароль и ключ)" \
        no  "Запретить (только SSH-ключ)") || return
    [[ $choice == "$cur" ]] && { ui_msg "Вход по паролю" "Уже установлено."; return; }
    if [[ $choice == no ]]; then
        if (( total == 0 )); then
            ui_yesno "Запрет входа по паролю" "SSH-ключи:       нет ни у одного пользователя
Вход по паролю:  будет запрещён

! Вы потеряете доступ к серверу — зайти будет нечем

ℹ Сначала добавьте SSH-ключ: главное меню → SSH и пользователи

Всё равно запретить вход по паролю?" no || return
        fi
        tx_begin
        sshd_set PasswordAuthentication no
        sshd_set ChallengeResponseAuthentication no
        sshd_commit || return
    else
        tx_begin; sshd_set PasswordAuthentication yes; sshd_commit || return
    fi
    log "ssh PasswordAuthentication $(sshd_eff passwordauthentication)"
    ui_msg "Готово" "Вход по паролю:  $([[ $(sshd_eff passwordauthentication) == yes ]] && echo разрешён || echo запрещён)"
}

ssh_show_config() {
    local dump out line k v
    dump=$(sshd_dump)
    _sv() { awk -v k="$1" '$1==k{$1=""; sub(/^ /,""); print}' <<< "$dump" | paste -sd'\n' | sed ':a;N;$!ba;s/\n/ · /g'; }
    _yn() { case $1 in yes) echo "разрешён" ;; no) echo "запрещён" ;; '') echo "—" ;; *) echo "$1" ;; esac; }
    _root() {
        case $1 in
            yes) echo "разрешён" ;; no) echo "запрещён" ;;
            prohibit-password|without-password) echo "только по ключу" ;;
            forced-commands-only) echo "только разрешённые команды" ;;
            *) echo "${1:-—}" ;;
        esac
    }
    out="── Подключение
Порт:               $(_sv port)
Адреса:             $(_sv listenaddress)

── Вход
root по SSH:        $(_root "$(_sv permitrootlogin)")
По SSH-ключу:       $(_yn "$(_sv pubkeyauthentication)")
По паролю:          $(_yn "$(_sv passwordauthentication)")
Клавиатурный ввод:  $(_yn "$(_sv kbdinteractiveauthentication)")
Пустые пароли:      $(_yn "$(_sv permitemptypasswords)")
Попыток входа:      $(_sv maxauthtries)"
    v=$(_sv allowusers);  [[ -n $v ]] && out+=$'\n'"AllowUsers:         $v"
    v=$(_sv allowgroups); [[ -n $v ]] && out+=$'\n'"AllowGroups:        $v"
    out+="

── Прочее
Проброс X11:        $(_yn "$(_sv x11forwarding)")

── Файл SkipIt"
    if sshd_uses_dropin; then
        out+=$'\n'"Файл:               $SSHD_DROPIN"
        if [[ -r $SSHD_DROPIN ]]; then
            while read -r k v; do
                [[ -z $k || $k == \#* ]] && continue
                out+=$'\n'"$(pad "$k:" 18)  $v"
            done < "$SSHD_DROPIN"
        else
            out+=$'\n'"Содержимое:         пока нет"
        fi
    else
        out+=$'\n'"Где:                блок «# BEGIN SkipIt» в $SSHD_MAIN"
    fi
    ui_text "SSH-сервер" "$out"
}

ssh_reset() {
    ui_yesno "Сброс настроек SSH" "Удалятся:    все настройки SSH, сделанные SkipIt
Вернутся:    исходные строки sshd_config
Порт SSH:    сейчас $(ssh_ports | sed 's/ /, /g')

! Порт SSH может смениться на прежний — подключайтесь по нему

Сбросить настройки SSH?" no || return
    local f ports
    tx_begin
    if [[ -f $SSHD_DROPIN ]]; then tx_add "$SSHD_DROPIN"; rm -f "$SSHD_DROPIN"; fi
    if grep -q '^# BEGIN SkipIt' "$SSHD_MAIN"; then
        tx_add "$SSHD_MAIN"; sed -i '/^# BEGIN SkipIt/,/^# END SkipIt/d' "$SSHD_MAIN"
    fi
    for f in "$SSHD_MAIN" "$SSHD_DROPIN_DIR"/*.conf; do
        [[ -f $f ]] && grep -q '^#SkipIt# ' "$f" && { tx_add "$f"; sed -i 's/^#SkipIt# //' "$f"; }
    done
    ports=$(ssh_ports)
    if ufw_active; then
        for f in $ports; do ufwc allow "$f/tcp" comment 'SSH (SkipIt)' >/dev/null; done
    fi
    sshd_commit || return
    log "ssh reset"
    ui_msg "Настройки SSH сброшены" "Настройки SSH:  исходные
Порт SSH:       $(sed 's/ /, /g' <<< "$ports")

ℹ Если порт изменился, подключайтесь по нему — в UFW он уже открыт"
}

ru_root() {
    case $1 in
        yes) echo "разрешён" ;; no) echo "запрещён" ;;
        prohibit-password|without-password) echo "только по ключу" ;;
        forced-commands-only) echo "только forced-commands" ;; *) echo "$1" ;;
    esac
}
yn_ru() { [[ $1 == yes ]] && echo "разрешён" || echo "запрещён"; }

menu_ssh_server() {
    local c ports root pass
    while :; do
        ports=$(ssh_ports)
        root=$(norm_sshd_val "$(sshd_eff permitrootlogin)")
        pass=$(sshd_eff passwordauthentication)
        c=$(ui_menu "SSH-сервер" "Порт SSH:        ${ports// /, }
Вход root:       $(ru_root "$root")
Вход по паролю:  $(yn_ru "$pass")

Изменения проверяются через sshd -t, при ошибке откатываются.
Текущие подключения не разрываются." \
            ""    "Настройки" \
            port  "Сменить порт SSH" \
            root  "Вход root" \
            pass  "Вход по паролю" \
            ""    "Обзор и сброс" \
            show  "Показать итоговые настройки" \
            reset "Сбросить настройки SkipIt") || return
        case $c in
            port)  ssh_change_port ;;
            root)  ssh_root_login ;;
            pass)  ssh_password_auth ;;
            show)  ssh_show_config ;;
            reset) ssh_reset ;;
        esac
    done
}

menu_users() {
    local c root pass
    while :; do
        root=$(sshd_eff permitrootlogin); pass=$(sshd_eff passwordauthentication)
        case $root in yes) root="разрешён" ;; no) root="запрещён" ;; prohibit-password|without-password) root="только по ключу" ;; esac
        case $pass in yes) pass="разрешён" ;; no) pass="запрещён" ;; esac
        c=$(ui_menu "SSH и пользователи" "Сервер:       $SERVER_IP
SSH-порт:     $(ssh_ports)
Вход root:    ${root:-—}
По паролю:    ${pass:-—}" \
            accounts "Пользователи (создать, ключи, пароли, sudo)" \
            sshd     "SSH-сервер (порт, вход root, пароли)") || return
        case $c in
            accounts) menu_user_accounts ;;
            sshd)     menu_ssh_server ;;
        esac
    done
}

menu_user_accounts() {
    local c
    while :; do
        c=$(ui_menu "Пользователи" "$(users_table_text)" \
            ""     "Создание" \
            create "Создать пользователя" \
            ""     "Управление" \
            key    "Добавить SSH-ключ" \
            passwd "Сменить пароль" \
            sudo   "Выдать / забрать sudo" \
            lock   "Заблокировать / разблокировать" \
            ""     "Опасные действия" \
            delete "Удалить пользователя") || return
        case $c in
            create) user_create ;;
            key)    user_add_key ;;
            passwd) user_passwd ;;
            sudo)   user_sudo_toggle ;;
            lock)   user_lock_toggle ;;
            delete) user_delete ;;
        esac
    done
}

# ==== UFW ====
ufwc() { LC_ALL=C ufw "$@"; }
ufw_active() { command -v ufw >/dev/null 2>&1 && ufwc status 2>/dev/null | grep -q '^Status: active'; }

# IPv6 в UFW: IPV6=yes|no в /etc/default/ufw (нет строки - yes, как у ufw по умолчанию)
UFW_DEFAULTS="/etc/default/ufw"
ufw_ipv6() { local v; v=$(sed -n 's/^IPV6=\"\{0,1\}\([a-z]*\)\"\{0,1\}/\1/p' "$UFW_DEFAULTS" 2>/dev/null | tail -n 1); echo "${v:-yes}"; }

ufw_ipv6_toggle() {
    local cur new sys text
    cur=$(ufw_ipv6)
    [[ $cur == yes ]] && new=no || new=yes
    if ipv6_supported && ! ipv6_off; then sys="включён"; else sys="выключен"; fi
    if [[ $new == no ]]; then
        text="IPv6 на сервере:  $sys
Правила IPv6:     перестанут применяться"
        if [[ $sys == включён ]]; then
            text+=$'\n\n'"! IPv6-трафик останется без фаервола — сначала выключите IPv6"$'\n\n'"ℹ Выключить IPv6: главное меню → IPv6"
            text+=$'\n\n'"Всё равно отключить IPv6 в UFW?"
            ui_yesno "IPv6 в UFW" "$text" no || return
        else
            text+=$'\n\n'"Отключить IPv6 в UFW?"
            ui_yesno "IPv6 в UFW" "$text" || return
        fi
    else
        ui_yesno "IPv6 в UFW" "IPv6 на сервере:  $sys
Правила IPv6:     снова начнут применяться

ℹ Сохранённые правила IPv6 вернутся сами

Включить IPv6 в UFW?" || return
    fi
    backup_file "$UFW_DEFAULTS" >/dev/null
    if grep -q '^IPV6=' "$UFW_DEFAULTS" 2>/dev/null; then
        sed -i "s/^IPV6=.*/IPV6=$new/" "$UFW_DEFAULTS"
    else
        echo "IPV6=$new" >> "$UFW_DEFAULTS"
    fi
    # IPV6= читается только при запуске UFW - перезапускаем, если он включён
    if ufw_active; then
        ui_loading "Перезапускаю UFW…"
        ufwc --force disable >/dev/null 2>&1
        if ! ufwc --force enable >/dev/null 2>&1; then
            log "ufw ipv6=$new: FAIL enable"
            ui_msg "Ошибка" "UFW не включился после изменения. Включите его: Фаервол UFW → Включить UFW"
            return
        fi
    fi
    log "ufw ipv6=$new"
    ui_msg "Готово" "IPv6 в UFW:  $([[ $new == yes ]] && echo включён || echo отключён)
UFW:         $(ufw_active && echo включён || echo выключен)"
}

ufw_policy() { # INPUT|OUTPUT|FORWARD → deny/allow/reject
    local v; v=$(sed -n "s/^DEFAULT_${1}_POLICY=\"\{0,1\}\([A-Z]*\)\"\{0,1\}/\1/p" /etc/default/ufw 2>/dev/null)
    case $v in DROP) echo deny ;; ACCEPT) echo allow ;; REJECT) echo reject ;; *) echo "?" ;; esac
}

ufw_rules() { # правила в формате команд (работает и при выключенном UFW)
    ufwc show added 2>/dev/null | sed -n 's/^ufw //p'
}

valid_port_spec() { # 443 | 8000:8100 | 80,443
    local item a b
    [[ $1 =~ ^[0-9]+(:[0-9]+)?(,[0-9]+(:[0-9]+)?)*$ ]] || return 1
    IFS=',' read -ra items <<< "$1"
    for item in "${items[@]}"; do
        if [[ $item =~ ^([0-9]+):([0-9]+)$ ]]; then
            a=${BASH_REMATCH[1]}; b=${BASH_REMATCH[2]}
            (( a >= 1 && b <= 65535 && a < b )) || return 1
        elif [[ $item =~ ^[0-9]+$ ]]; then
            (( item >= 1 && item <= 65535 )) || return 1
        else
            return 1
        fi
    done
}

valid_ip_spec() {
    [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] ||
    [[ $1 =~ ^[0-9A-Fa-f:]*:[0-9A-Fa-f:.]*(/[0-9]{1,3})?$ ]]
}

ufw_policy_ru() { case $1 in deny) echo "запрещать" ;; allow) echo "разрешать" ;; reject) echo "отклонять" ;; *) echo "${1:-—}" ;; esac; }

ufw_show_status() {
    local out line n to act from cmt re
    re='^\[ *([0-9]+)\] (.*[^ ]) {2,}(ALLOW|DENY|REJECT|LIMIT)( (IN|OUT|FWD))? {2,}(.*)$'
    if ufw_active; then
        out="Состояние:               включён
Логи:                    $(ufwc status verbose | awk -F': ' '/^Logging:/ {print $2; exit}')
Входящие по умолчанию:   $(ufw_policy_ru "$(ufw_policy INPUT)")
Исходящие по умолчанию:  $(ufw_policy_ru "$(ufw_policy OUTPUT)")

── Правила"
        n=0
        while IFS= read -r line; do
            [[ $line =~ $re ]] || continue
            n=$((n + 1))
            to=${BASH_REMATCH[2]}; from=${BASH_REMATCH[6]}
            case ${BASH_REMATCH[3]} in ALLOW) act="разрешить" ;; DENY) act="запретить" ;; REJECT) act="отклонить" ;; LIMIT) act="ограничить" ;; esac
            [[ ${BASH_REMATCH[5]} == OUT ]] && act+=" (исх.)"
            cmt=""; [[ $from == *'#'* ]] && { cmt=${from#*#}; cmt=${cmt# }; from=${from%%#*}; }
            from=${from%"${from##*[![:space:]]}"}
            from=${from/Anywhere (v6)/все (IPv6)}; from=${from/Anywhere/все}
            (( n == 1 )) && out+=$'\n'"№"$'\t'"Порт"$'\t'"Действие"$'\t'"Откуда"$'\t'"Комментарий"
            out+=$'\n'"${BASH_REMATCH[1]}"$'\t'"$to"$'\t'"$act"$'\t'"$from"$'\t'"${cmt:-—}"
        done < <(ufwc status numbered)
        (( n )) || out+=$'\n'"Правил нет."
    else
        out="Состояние:                 выключен — правила не действуют
Входящие после включения:  $(ufw_policy_ru "$(ufw_policy INPUT)")

── Правила после включения"
        n=0
        while IFS= read -r line; do
            [[ -z $line ]] && continue
            n=$((n + 1))
            (( n == 1 )) && out+=$'\n'"№"$'\t'"Правило"
            out+=$'\n'"$n"$'\t'"ufw $line"
        done < <(ufw_rules)
        (( n )) || out+=$'\n'"Правил нет."
    fi
    ui_text "Статус UFW" "$out"
}

# Правило UFW (как в ufw_rules) -> R_ACT R_PORT R_PROTO R_SRC R_COMMENT
# R_PROTO пусто - TCP и UDP, R_SRC пусто - с любого адреса
ufw_rule_parse() {
    local r=${1#route }
    local re_cm=" comment '(.*)'\$" re_simple='^(allow|deny|reject|limit) (in )?([0-9][0-9:,]*)(/(tcp|udp))?$'
    local re_port=' port ([0-9][0-9:,]*)' re_proto=' proto (tcp|udp)' re_from=' from ([^ ]+)'
    R_ACT=""; R_PORT=""; R_PROTO=""; R_SRC=""; R_COMMENT=""
    [[ $r =~ $re_cm ]] && R_COMMENT=${BASH_REMATCH[1]}
    r=${r%% comment *}
    R_ACT=${r%% *}
    if [[ $r =~ $re_simple ]]; then
        R_PORT=${BASH_REMATCH[3]}; R_PROTO=${BASH_REMATCH[5]}
    else
        [[ $r =~ $re_port ]] && R_PORT=${BASH_REMATCH[1]}
        [[ $r =~ $re_proto ]] && R_PROTO=${BASH_REMATCH[1]}
        [[ $r =~ $re_from ]] && R_SRC=${BASH_REMATCH[1]}
    fi
    [[ $R_SRC == any ]] && R_SRC=""
    return 0
}

# Правило UFW -> "22/TCP           с любого адреса , SSH (SkipIt)"
ufw_rule_ru() {
    local what src out r=${1%% comment *}
    ufw_rule_parse "$1"
    if [[ -n $R_PORT ]]; then
        what="$R_PORT/$([[ -z $R_PROTO ]] && echo TCP+UDP || echo "${R_PROTO^^}")"
    elif [[ -z $R_SRC ]]; then
        what=${r#route }; what=${what#* }          # профиль приложения, например OpenSSH
    else
        what="весь трафик"
    fi
    src=${R_SRC:+с $R_SRC}; src=${src:-с любого адреса}
    out="$(pad "$what" 16) $src"
    # Колонки не сдвигаем: действие, отличное от "разрешить", - пометкой в конце
    case $R_ACT in
        deny)   out+="  · запрещено" ;;
        reject) out+="  · отклоняется" ;;
        limit)  out+="  · с лимитом" ;;
    esac
    [[ -n $R_COMMENT ]] && out+="  · $R_COMMENT"
    printf '%s' "$out"
}

# Открытые порты из правил UFW -> строки "порт<TAB>протокол<TAB>откуда"
# (протокол пусто - TCP и UDP, откуда пусто - с любого адреса). Работает и при выключенном UFW.
ufw_allowed() {
    local r
    while IFS= read -r r; do
        ufw_rule_parse "$r"
        [[ $R_ACT == allow && -n $R_PORT && $r != route\ * ]] || continue
        printf '%s\t%s\t%s\n' "$R_PORT" "$R_PROTO" "$R_SRC"
    done < <(ufw_rules)
}

ufw_proto_ru() { case $1 in tcp) echo TCP ;; udp) echo UDP ;; *) echo "TCP и UDP" ;; esac; }

# Уже открыт для всех адресов? порт (число или диапазон a:b) протокол (tcp|udp)
ufw_port_covered() {
    local want=$1 p=$2 lport lproto lsrc item a b
    local -a items
    while IFS=$'\t' read -r lport lproto lsrc; do
        [[ -z $lsrc ]] || continue
        [[ -z $lproto || $lproto == "$p" ]] || continue
        IFS=, read -ra items <<< "$lport"
        for item in "${items[@]}"; do
            if [[ $want == *:* ]]; then
                [[ $item == "$want" ]] && return 0
            elif [[ $item == *:* ]]; then
                a=${item%%:*}; b=${item##*:}
                (( want >= a && want <= b )) && return 0
            elif [[ $item == "$want" ]]; then
                return 0
            fi
        done
    done < <(ufw_allowed)
    return 1
}

ufw_open_port() {
    local port proto src comment multi=0 out="" p
    local cmds=()
    local body="" lport lproto lsrc
    while IFS=$'\t' read -r lport lproto lsrc; do
        body+="$lport"$'\t'"$(ufw_proto_ru "$lproto")"$'\t'"${lsrc:-с любого адреса}"$'\n'
    done < <(ufw_allowed)
    if [[ -n $body ]]; then
        body="Открытый порт"$'\t'"Протокол"$'\t'"Откуда"$'\n'"$body"$'\n'
    else
        body="ℹ Открытых портов пока нет"$'\n\n'
    fi
    body+="ℹ Например: 443 · 8000:8100 · 80,443"$'\n\n'"Порт (диапазон — через двоеточие, несколько — через запятую):"
    port=$(ui_input "Открыть порт" "$body") || return
    port=${port//[[:space:]]/}
    valid_port_spec "$port" || { ui_msg "Ошибка" "Некорректный порт: «$port»"; return; }
    [[ $port == *[:,]* ]] && multi=1

    proto=$(ui_choose "Протокол" "Порт: $port" \
        tcp  "TCP" \
        udp  "UDP" \
        both "TCP и UDP") || return

    # Уже открытые для всех адресов - сказать сразу, до вопросов об источнике и комментарии
    local item covered=() fresh=()
    local -a pp items
    [[ $proto == both ]] && pp=(tcp udp) || pp=("$proto")
    IFS=, read -ra items <<< "$port"
    for item in "${items[@]}"; do
        for p in "${pp[@]}"; do
            if ufw_port_covered "$item" "$p"; then covered+=("$item/$p"); else fresh+=("$item/$p"); fi
        done
    done
    if (( ${#covered[@]} && ! ${#fresh[@]} )); then
        ui_msg "Порт уже открыт" "Открыт:  $(printf '%s, ' "${covered[@]}" | sed 's/, $//')
Откуда:  с любого адреса

ℹ Новое правило не нужно"
        return
    elif (( ${#covered[@]} )); then
        ui_yesno "Часть портов уже открыта" "Уже открыты:   $(printf '%s, ' "${covered[@]}" | sed 's/, $//')
Будут открыты:  $(printf '%s, ' "${fresh[@]}" | sed 's/, $//')

Продолжить?" || return
    fi

    src=$(ui_input "Откуда разрешить" "ℹ Например: 203.0.113.5 или подсеть 10.0.0.0/8

IP или подсеть (пусто — с любого адреса):") || return
    src=${src//[[:space:]]/}
    if [[ -n $src ]] && ! valid_ip_spec "$src"; then ui_msg "Ошибка" "Некорректный IP: «$src»"; return; fi

    comment=$(ui_input "Комментарий" "Например:  xray, panel

Комментарий к правилу (необязательно):") || return
    comment=${comment//[\'\"\\]/}

    local base=(allow from "${src:-any}" to any port "$port")
    if [[ $proto == both && $multi == 0 ]]; then
        cmds+=("tcp+udp")
    elif [[ $proto == both ]]; then
        cmds+=(tcp udp)
    else
        cmds+=("$proto")
    fi
    for p in "${cmds[@]}"; do
        local args=("${base[@]}")
        [[ $p != "tcp+udp" ]] && args+=(proto "$p")
        [[ -n $comment ]] && args+=(comment "$comment")
        out+="\$ ufw ${args[*]}"$'\n'"$(ufwc "${args[@]}" 2>&1)"$'\n'
    done
    log "ufw open: port=$port proto=$proto src=${src:-any}"
    ufw_active || out+=$'\n'"Примечание: UFW выключен — правило заработает после включения."
    ui_msg "Открыть порт" "$out"
}

ufw_close_port() {
    local rules=() items=() i sel p rule txt res item list="" out="" warn_ssh=0 warn_panel=0
    local -a ports
    mapfile -t rules < <(ufw_rules)
    if (( ${#rules[@]} == 0 )); then ui_msg "Закрыть порт" "ℹ Правил пока нет"; return; fi
    for i in "${!rules[@]}"; do
        items+=("$((i + 1))" "$(ufw_rule_ru "${rules[$i]}")" OFF)
    done
    sel=$(ui_checklist "Закрыть порт" "ℹ Правила SkipIt для SSH и панели лучше не удалять" "${items[@]}") || return
    [[ -z $sel ]] && return

    for i in $sel; do
        rule=${rules[$((i - 1))]}
        list+="    $(ufw_rule_ru "$rule")"$'\n'
        ufw_rule_parse "$rule"
        IFS=, read -ra ports <<< "$R_PORT"
        for p in $(ssh_ports); do
            for item in "${ports[@]}"; do [[ $item == "$p" ]] && warn_ssh=1; done
        done
        [[ $R_COMMENT == SSH* || $rule == *OpenSSH* ]] && warn_ssh=1
        [[ $R_COMMENT == *"Remnawave panel"* ]] && warn_panel=1
    done
    if (( warn_ssh || warn_panel )) && ufw_active; then
        local text="Удалятся:"$'\n'"${list%$'\n'}"$'\n'
        (( warn_ssh ))   && text+=$'\n'"! Удаляется правило SSH — можно потерять доступ к серверу"
        (( warn_panel )) && text+=$'\n'"! Удаляется правило панели — нода потеряет связь с Remnawave"
        text+=$'\n\n'"Всё равно удалить?"
        ui_yesno "Удаление правил" "$text" no || return
    fi

    # удаляем с конца, чтобы не съезжала нумерация
    for i in $(echo "$sel" | sort -rn); do
        rule=${rules[$((i - 1))]}
        txt=$(ufw_rule_ru "$rule")
        if [[ $rule == route\ * ]]; then
            res=$(printf '%s' "${rule#route }" | xargs env LC_ALL=C ufw --force route delete 2>&1)
        else
            res=$(printf '%s' "$rule" | xargs env LC_ALL=C ufw --force delete 2>&1)
        fi
        if [[ $res == *[Dd]eleted* && $res != *ERROR* ]]; then
            out="✓ $txt"$'\n'"$out"
        else
            out="✗ $txt — ${res##*$'\n'}"$'\n'"$out"
            log "ufw close FAIL: $rule: $res"
        fi
    done
    log "ufw close: $(echo "$sel" | xargs)"
    ui_msg "Закрыть порт" "${out%$'\n'}"
}

ufw_enable() {
    local ports p
    ports=$(ssh_ports)
    ui_yesno "Включить UFW" "Перед включением автоматически будут разрешены порты SSH: ${ports// /, } (tcp),
чтобы вы не потеряли доступ к серверу.

Входящие по умолчанию: $(ufw_policy INPUT)
Исходящие по умолчанию: $(ufw_policy OUTPUT)

Включить UFW?" || return
    for p in $ports; do ufwc allow "$p/tcp" comment 'SSH (SkipIt)' >/dev/null 2>&1; done
    local out; out=$(ufwc --force enable 2>&1)
    log "ufw enable"
    local note=""
    command -v docker >/dev/null 2>&1 &&
        note=$'\n\n'"Docker: порты контейнеров с проброшенными портами (-p) обходят UFW. Контейнеры с network_mode: host (как remnanode) подчиняются UFW."
    ui_msg "UFW" "$out

Разрешены порты SSH: $ports${note}"
}

ufw_disable() {
    ui_yesno "Выключить UFW" "Все порты станут доступны.
Правила сохранятся и вернутся при включении.

Выключить фаервол?" no || return
    local out; out=$(ufwc disable 2>&1)
    log "ufw disable"
    ui_msg "UFW" "$out"
}

ufw_ip_rule() { # allow|deny
    local act=$1 ip out comment title
    [[ $act == deny ]] && title="Заблокировать IP" || title="Разрешить всё с IP"
    ip=$(ui_input "$title" "Пример:  203.0.113.5 или 198.51.100.0/24

IP-адрес или подсеть:") || return
    ip=${ip//[[:space:]]/}
    valid_ip_spec "$ip" || { ui_msg "Ошибка" "Некорректный IP: «$ip»"; return; }
    if [[ $act == deny ]]; then
        local me=${SSH_CLIENT%% *} hit=""
        [[ -n $me ]] && ip_matches "$ip" "$me" && hit="ваш текущий IP ($me) — вы потеряете доступ к серверу"
        if [[ -z $hit ]] && node_state_load 2>/dev/null && [[ -n $NODE_PANEL_IP ]] && ip_matches "$ip" "$NODE_PANEL_IP"; then
            hit="IP панели ($NODE_PANEL_IP) — нода перестанет работать"
        fi
        if [[ -n $hit ]]; then
            ui_yesno "ОПАСНО" "Блокировка:  $ip
Попадает:    $hit

Заблокировать всё равно?" no || return
        fi
    fi
    comment=$(ui_input "Комментарий" "Комментарий (необязательно):") || return
    comment=${comment//[\'\"\\]/}
    local args=("$act" from "$ip")
    [[ -n $comment ]] && args+=(comment "$comment")
    if [[ $act == deny && -n $(ufw_rules) ]]; then
        # блокировка должна стоять выше разрешающих правил
        out=$(ufwc insert 1 "${args[@]}" 2>&1) || out=$(ufwc "${args[@]}" 2>&1)
    else
        out=$(ufwc "${args[@]}" 2>&1)
    fi
    log "ufw $act from $ip"
    ui_msg "$title" "$out"
}

ufw_policies() {
    local which pol out
    which=$(ui_choose "Политики по умолчанию" "Что делать с трафиком, для которого нет правил:" \
        incoming "Входящие:   $(ufw_policy INPUT)" \
        outgoing "Исходящие:  $(ufw_policy OUTPUT)" \
        routed   "Транзитные: $(ufw_policy FORWARD)  (VPN, Docker)") || return
    pol=$(ui_choose "Политика: $which" "Выберите действие:" \
        deny   "deny — молча отбрасывать" \
        reject "reject — отклонять с ответом" \
        allow  "allow — разрешать") || return
    if [[ $which == outgoing && $pol != allow ]]; then
        ui_yesno "Внимание" "Запрет исходящих сломает apt, DNS, curl и работу ноды, если не добавить разрешающие правила.

Продолжить?" no || return
    fi
    out=$(ufwc default "$pol" "$which" 2>&1)
    log "ufw default $pol $which"
    ui_msg "Политика" "$out"
}

ufw_reset() {
    ui_yesno "Сброс UFW" "Удалить ВСЕ правила и выключить UFW?
(ufw сохранит резервную копию в /etc/ufw/*.rules.*)" no || return
    local out; out=$(ufwc --force reset 2>&1)
    log "ufw reset"
    ui_msg "Сброс UFW" "$out"
}

menu_ufw() {
    ensure_pkg ufw ufw || return
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        ui_msg "Внимание" "На сервере работает firewalld. Одновременная работа с UFW приведёт к конфликтам — лучше оставить только один фаервол."
    fi
    local c st toggle_tag toggle_txt
    while :; do
        if ufw_active; then
            st="включён"; toggle_tag=off; toggle_txt="Выключить UFW"
        else
            st="выключен"; toggle_tag=on; toggle_txt="Включить UFW"
        fi
        c=$(ui_menu "Фаервол UFW" "Состояние:  $st
Правил:     $(ufw_rules | wc -l)
SSH-порт:   $(ssh_ports | sed 's/ /, /g')
IPv6:       $([[ $(ufw_ipv6) == yes ]] && echo включён || echo отключён)" \
            ""       "Правила" \
            status   "Статус и список правил" \
            open     "Открыть порт" \
            close    "Закрыть порт (удалить правила)" \
            ""       "Доступ" \
            "$toggle_tag" "$toggle_txt" \
            ipv6     "$([[ $(ufw_ipv6) == yes ]] && echo "Отключить IPv6 в UFW" || echo "Включить IPv6 в UFW")" \
            block    "Заблокировать IP / подсеть" \
            allowip  "Разрешить весь трафик с IP" \
            ""       "Политики и сброс" \
            policy   "Политики по умолчанию" \
            reset    "Сбросить все правила") || return
        case $c in
            status)  ufw_show_status ;;
            open)    ufw_open_port ;;
            close)   ufw_close_port ;;
            on)      ufw_enable ;;
            off)     ufw_disable ;;
            ipv6)    ufw_ipv6_toggle ;;
            block)   ufw_ip_rule deny ;;
            allowip) ufw_ip_rule allow ;;
            policy)  ufw_policies ;;
            reset)   ufw_reset ;;
        esac
    done
}

# ==== Ядро Linux: /etc/sysctl.d/99-xray-node.conf ====
# Размер таблицы соединений по RAM: 1 ГБ -> 262144, 2 ГБ -> 524288, 4 ГБ+ -> 1048576
sysctl_ct_max() {
    local mb p=131072
    mb=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)
    [[ $mb =~ ^[0-9]+$ ]] || mb=1024
    while (( p * 2 <= mb * 256 && p < 1048576 )); do p=$(( p * 2 )); done
    echo "$p"
}

sysctl_ram_mb() { awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null; }

# Основной сетевой интерфейс и его очередь
sysctl_iface()  { ip -o route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<NF;i++) if ($i=="dev") {print $(i+1); exit}}'; }
qdisc_now()     { tc qdisc show dev "$1" root 2>/dev/null | awk '{print $2; exit}'; }
sysctl_profile_ru() { case $1 in fq) echo "fq + BBR" ;; cake) echo "CAKE + BBR" ;; *) echo "${1:-не записан}" ;; esac; }
sysctl_file_profile() { [[ -f $SYSCTL_FILE ]] && sysctl_file_value net.core.default_qdisc; }

sysctl_template() { # fq|cake
    local q=${1:-fq} ct; ct=$(sysctl_ct_max)
    cat <<EOF
# Оптимизация ядра для xray-ноды (100+ пользователей). Файл записан SkipIt.
# Профиль: $(sysctl_profile_ru "$q")
# Применить вручную: sysctl -p $SYSCTL_FILE
# TCP Fast Open намеренно не включается.

EOF
    if [[ $q == cake ]]; then
        cat <<'EOF'
# Очередь CAKE + BBR
# CAKE делит канал поровну между потоками и клиентами: один тяжёлый
# пользователь (торрент, 4K) не забивает остальных, пинг стабильнее под нагрузкой.
# Расходует больше CPU, чем fq. Нужен модуль sch_cake.
net.core.default_qdisc = cake
EOF
    else
        cat <<'EOF'
# Очередь fq + BBR
# fq точно выдерживает темп отправки, который задаёт BBR, и почти не тратит CPU.
net.core.default_qdisc = fq
EOF
    fi
    cat <<EOF
net.ipv4.tcp_congestion_control = bbr

# Буферы TCP/UDP - потолок автотюнинга. Память берётся только под реальный
# трафик, поэтому высокий потолок не съедает RAM на простаивающих клиентах
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.optmem_max = 65536
net.ipv4.tcp_rmem = 4096 131072 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# Задержка: не копить неотправленное в ядре, не сбрасывать разгон на паузах
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1

# Много одновременных подключений и пакетов
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65536
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_tw_buckets = 1048576
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_rfc1337 = 1

# Мёртвые соединения: мобильные клиенты пропадают без FIN - убирать за ~12 мин
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# Таблица соединений: размер по RAM ($(sysctl_ram_mb) МБ), hashsize = max/4 - см. /etc/modprobe.d
net.netfilter.nf_conntrack_max = $ct
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 60
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 60
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 180

# Исходящие порты с 10000: не займут порты сервисов ноды (2222, 8443...)
net.ipv4.ip_local_port_range = 10000 65535

# Память: не уходить в swap, пока есть RAM
vm.swappiness = 10
EOF
}

sysctl_keys() { # ключи из текста на stdin
    awk -F= '!/^[ \t]*[#;]/ && NF>=2 { gsub(/^[ \t]+|[ \t]+$/, "", $1); print $1 }'
}

sysctl_file_keys() { [[ -f $SYSCTL_FILE ]] && sysctl_keys < "$SYSCTL_FILE"; }

sysctl_file_value() { # ключ → значение из файла
    awk -F= -v k="$1" '!/^[ \t]*[#;]/ && NF>=2 { x=$1; gsub(/^[ \t]+|[ \t]+$/, "", x)
        if (x==k) { v=substr($0, index($0, "=")+1); gsub(/^[ \t]+|[ \t]+$/, "", v); r=v } } END{print r}' "$SYSCTL_FILE" 2>/dev/null
}

# Запомнить исходные значения, чтобы вернуть их при удалении
sysctl_remember() { # ключи...
    local k v
    touch "$SYSCTL_ORIG"
    for k in "$@"; do
        awk -v k="$k" -F' = ' '$1==k {f=1} END{exit !f}' "$SYSCTL_ORIG" && continue
        v=$(sysctl -n "$k" 2>/dev/null) || continue
        printf '%s = %s\n' "$k" "$(echo $v)" >> "$SYSCTL_ORIG"
    done
}

sysctl_restore_keys() { # ключи... → исходные значения
    local k v
    for k in "$@"; do
        v=$(awk -v k="$k" -F' = ' '$1==k {print $2; exit}' "$SYSCTL_ORIG" 2>/dev/null)
        [[ -n $v ]] && sysctl -w "$k=$v" >/dev/null 2>&1
    done
}

conntrack_hashsize() { cat /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null; }

# Модули: tcp_bbr и nf_conntrack - сейчас и при каждой загрузке
# Модули: tcp_bbr, nf_conntrack и очередь - сейчас и при каждой загрузке
sysctl_load_modules() { # fq|cake
    local m loaded=() cur hs
    hs=$(( $(sysctl_ct_max) / 4 ))
    for m in tcp_bbr nf_conntrack "sch_${1:-fq}"; do
        modprobe "$m" 2>/dev/null && loaded+=("$m")
    done
    if (( ${#loaded[@]} )); then
        mkdir -p "$(dirname "$SYSCTL_MODULES_FILE")"
        printf '%s\n' "${loaded[@]}" > "$SYSCTL_MODULES_FILE"
    fi
    if [[ -d /sys/module/nf_conntrack ]]; then
        mkdir -p "$(dirname "$SYSCTL_MODPROBE_FILE")"
        echo "options nf_conntrack hashsize=${hs}" > "$SYSCTL_MODPROBE_FILE"
        cur=$(conntrack_hashsize)
        if [[ $cur =~ ^[0-9]+$ ]] && (( cur < hs )); then
            grep -q '^nf_conntrack.hashsize = ' "$SYSCTL_ORIG" 2>/dev/null ||
                echo "nf_conntrack.hashsize = $cur" >> "$SYSCTL_ORIG"
            echo "$hs" > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null
        fi
    fi
}

# default_qdisc действует только на новые интерфейсы - основной переключаем сразу
sysctl_apply_qdisc() { # qdisc → ошибка или пусто
    local ifc; ifc=$(sysctl_iface)
    [[ -n $ifc ]] && command -v tc >/dev/null 2>&1 || return 0
    tc qdisc replace dev "$ifc" root "$1" 2>&1 | head -n 2
}

sysctl_apply_file() { # → ошибки
    [[ -f $SYSCTL_FILE ]] || return 0
    sysctl -p "$SYSCTL_FILE" 2>&1 >/dev/null | grep -E '^sysctl:' || true
}

sysctl_summary() {
    local ifc; ifc=$(sysctl_iface)
    echo "TCP:        $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    echo "Очередь:    $(qdisc_now "$ifc") (${ifc:-?})"
    echo "conntrack:  max $(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo —) · hashsize $(conntrack_hashsize || echo —)"
    echo "Порты:      $(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null | tr -s "\t " " ")"
}

sysctl_errors_text() { # ошибки
    [[ -z $1 ]] && return
    printf '\nНе все параметры применились'
    [[ $VIRT == lxc || $VIRT == openvz ]] && printf ' (%s: ядро общее с хостом)' "$VIRT"
    printf ':\n%s\n' "$1"
}

# Выбор профиля с текущим состоянием сверху -> fq|cake
sysctl_choose_profile() { # заголовок
    local ifc; ifc=$(sysctl_iface)
    ui_choose "$1" "TCP сейчас:      $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
Очередь сейчас:  $(qdisc_now "$ifc") (${ifc:-?})
Профиль SkipIt:  $(sysctl_profile_ru "$(sysctl_file_profile)")
Сервер:          RAM $(sysctl_ram_mb) МБ · CPU $(nproc 2>/dev/null)

── Профили
fq + BBR:    точный темп отправки, минимальная нагрузка на CPU
CAKE + BBR:  делит канал поровну между пользователями, нагрузка на CPU выше

Какой профиль?" \
        fq   "fq + BBR" \
        cake "CAKE + BBR"
}

sysctl_install() {
    local prof exists="" n old_keys new_keys removed errs qerr bak="" ifc
    prof=$(sysctl_choose_profile "Профиль ядра") || return
    if [[ $prof == cake ]] && ! modprobe sch_cake 2>/dev/null; then
        ui_msg "CAKE недоступен" "Модуль:  sch_cake не загружается
Ядро:    $(uname -r) · $VIRT

Выберите профиль fq + BBR."
        return
    fi
    ifc=$(sysctl_iface)
    n=$(sysctl_template "$prof" | sysctl_keys | wc -l)
    [[ -f $SYSCTL_FILE ]] && exists=$'\n'"Файл уже есть — текущая версия сохранится в бэкап."
    ui_yesno "Оптимизация ядра" "Профиль:     $(sysctl_profile_ru "$prof")
Файл:        $SYSCTL_FILE
Параметров:  $n
conntrack:   $(sysctl_ct_max) соединений (по RAM $(sysctl_ram_mb) МБ)
Интерфейс:   ${ifc:-?} → очередь $prof
${exists}
Применяется сразу и сохраняется после перезагрузки.

Продолжить?" || return

    mkdir -p "$(dirname "$SYSCTL_FILE")" "$SKIPIT_ETC"
    old_keys=$(sysctl_file_keys)
    new_keys=$(sysctl_template "$prof" | sysctl_keys)
    sysctl_load_modules "$prof"
    # shellcheck disable=SC2046
    sysctl_remember $(echo "$new_keys")
    [[ -f $SYSCTL_FILE ]] && bak=$(backup_file "$SYSCTL_FILE")
    sysctl_template "$prof" > "$SYSCTL_FILE"
    chmod 644 "$SYSCTL_FILE"
    removed=$(comm -23 <(sort -u <<< "$old_keys") <(sort -u <<< "$new_keys"))
    # shellcheck disable=SC2046
    [[ -n $removed ]] && sysctl_restore_keys $(echo "$removed")
    errs=$(sysctl_apply_file)
    qerr=$(sysctl_apply_qdisc "$prof")
    [[ -n $qerr ]] && errs+=$'\n'"tc: $qerr"
    log "sysctl install $SYSCTL_FILE profile=$prof${bak:+ (backup: $bak)}"
    ui_msg "Готово" "Профиль:  $(sysctl_profile_ru "$prof")
Файл:     $SYSCTL_FILE
${bak:+Бэкап:    $bak
}
$(sysctl_summary)
$(sysctl_errors_text "$errs")"
}

sysctl_view_template() {
    local prof; prof=$(sysctl_choose_profile "Что будет записано") || return
    ui_msg "Профиль $(sysctl_profile_ru "$prof")" "$(sysctl_template "$prof")"
}

sysctl_show() {
    local out k cur fv st
    out="Ядро:                $(uname -r)
Виртуализация:       $VIRT
Алгоритмы TCP:       $(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)
Файл:                $SYSCTL_FILE — $([[ -f $SYSCTL_FILE ]] && echo записан || echo нет)
conntrack hashsize:  $(conntrack_hashsize || echo 'модуль не загружен')"
    [[ $VIRT == lxc || $VIRT == openvz ]] &&
        out+=$'\n\n'"ВНИМАНИЕ: $VIRT — ядро общее с хостом, часть параметров менять нельзя."
    out+=$'\n\n'"── Параметры"$'\n'"Параметр"$'\t'"Сейчас"$'\t'"В файле"
    while IFS= read -r k; do
        [[ -z $k ]] && continue
        cur=$(sysctl -n "$k" 2>/dev/null) && cur=$(echo $cur) || cur="недоступен"
        st="—"
        if [[ -f $SYSCTL_FILE ]]; then
            fv=$(sysctl_file_value "$k")
            if [[ -n $fv ]]; then [[ $(echo $fv) == "$cur" ]] && st="совпадает" || st="≠ $(echo $fv)"; fi
        fi
        out+=$'\n'"$k"$'\t'"$cur"$'\t'"$st"
    done < <( { sysctl_template | sysctl_keys; sysctl_file_keys; } | awk '!s[$0]++' )
    ui_msg "Параметры ядра" "$out"
}

sysctl_edit_file() {
    if [[ ! -f $SYSCTL_FILE ]]; then
        ui_msg "Файла нет" "$SYSCTL_FILE ещё не записан.
Сначала выберите «Записать профиль ядра»."
        return
    fi
    ensure_pkg nano nano || return
    local bak old_keys new_keys removed errs
    bak=$(backup_file "$SYSCTL_FILE")
    old_keys=$(sysctl_file_keys)
    clear; nano "$SYSCTL_FILE"
    if cmp -s "$bak" "$SYSCTL_FILE"; then rm -f "$bak"; ui_msg "Ядро" "Файл не изменён."; return; fi
    new_keys=$(sysctl_file_keys)
    # shellcheck disable=SC2046
    sysctl_remember $(echo "$new_keys")
    removed=$(comm -23 <(sort -u <<< "$old_keys") <(sort -u <<< "$new_keys"))
    # shellcheck disable=SC2046
    [[ -n $removed ]] && sysctl_restore_keys $(echo "$removed")
    errs=$(sysctl_apply_file)
    log "sysctl edit $SYSCTL_FILE (backup: $bak)"
    ui_msg "Применено" "Изменения сохранены и применены. Бэкап: $bak

$(sysctl_summary)
$(sysctl_errors_text "$errs")"
}

sysctl_reset() {
    if [[ ! -f $SYSCTL_FILE && ! -f $SYSCTL_MODULES_FILE && ! -f $SYSCTL_MODPROBE_FILE ]]; then
        ui_msg "Сброс" "Настройки ядра SkipIt не записаны."; return
    fi
    ui_yesno "Сброс" "Удалить $SYSCTL_FILE и вернуть исходные значения параметров?" no || return
    local keys hs
    keys=$( { sysctl_file_keys; sysctl_template | sysctl_keys; } | sort -u)
    [[ -f $SYSCTL_FILE ]] && backup_file "$SYSCTL_FILE" >/dev/null
    rm -f "$SYSCTL_FILE" "$SYSCTL_MODULES_FILE" "$SYSCTL_MODPROBE_FILE"
    # shellcheck disable=SC2046
    sysctl_restore_keys $(echo "$keys")
    hs=$(awk -F' = ' '$1=="nf_conntrack.hashsize" {print $2; exit}' "$SYSCTL_ORIG" 2>/dev/null)
    [[ -n $hs && -w /sys/module/nf_conntrack/parameters/hashsize ]] &&
        echo "$hs" > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null
    sysctl_apply_qdisc "$(sysctl -n net.core.default_qdisc 2>/dev/null)" >/dev/null
    log "sysctl reset"
    ui_msg "Готово" "Файлы удалены, значения возвращены к исходным.

$(sysctl_summary)"
}

menu_kernel() {
    local c hdr ifc
    while :; do
        ifc=$(sysctl_iface)
        hdr="Ядро:            $(uname -r) · $VIRT
TCP:             $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
Очередь:         $(qdisc_now "$ifc") (${ifc:-?})
Профиль SkipIt:  $(sysctl_profile_ru "$(sysctl_file_profile)")"
        [[ $VIRT == lxc || $VIRT == openvz ]] && hdr+=$'\n\n'"ВНИМАНИЕ: $VIRT — многие параметры ядра недоступны."
        c=$(ui_menu "Ядро Linux (sysctl)" "$hdr" \
            ""       "Профиль" \
            install  "Записать профиль (fq + BBR / CAKE + BBR)" \
            template "Что будет записано" \
            ""       "Параметры" \
            show     "Текущие значения параметров" \
            edit     "Редактировать файл вручную (nano)" \
            ""       "Опасные действия" \
            reset    "Удалить файл и вернуть исходные значения") || return
        case $c in
            install)  sysctl_install ;;
            template) sysctl_view_template ;;
            show)     sysctl_show ;;
            edit)     sysctl_edit_file ;;
            reset)    sysctl_reset ;;
        esac
    done
}

# Нода Remnawave
# Схема: клиент -> 443 Xray (remnanode, REALITY, xver 1)
#        -> unix:/dev/shm/nginx.sock (nginx, proxy_protocol) -> сайт-заглушка
NODE_DOMAIN=""; NODE_PANEL_IP=""; NODE_PORT=2222; NODE_CERT_METHOD=""; NODE_CERT_NAME=""
NODE_TEMPLATE=""; NODE_PRIV=""; NODE_PUB=""; NODE_SID=""
NODE_LAYOUT="steal"; NODE_WS_PATH=""; NODE_XHTTP_PATH=""
NODE_KEYS=(NODE_DOMAIN NODE_PANEL_IP NODE_PORT NODE_CERT_METHOD NODE_CERT_NAME NODE_TEMPLATE NODE_PRIV NODE_PUB NODE_SID
           NODE_LAYOUT NODE_WS_PATH NODE_XHTTP_PATH)

# Схемы ноды: steal - шаблонная (selfsteal TCP); balancer - selfsteal TCP + XHTTP + WS через nginx (балансир)
node_layout_ru() {
    case $1 in
        balancer) echo "Selfsteal TCP + XHTTP + WS (балансир)" ;;
        *)        echo "Шаблонная: selfsteal TCP" ;;
    esac
}
node_public_ports() { [[ $1 == balancer ]] && echo "443 $NODE_XHTTP_PORT $NODE_WS_PUBLIC" || echo "443"; }
node_gen_paths() {
    # ноды старых версий хранят один shortId - дописать второй, первый не менять
    [[ -n $NODE_SID && $NODE_SID != *,* ]] && NODE_SID+=",$(openssl rand -hex 8)"
    [[ -n $NODE_WS_PATH ]]    || NODE_WS_PATH="/ws-$(openssl rand -hex 4)-$(openssl rand -hex 1)"
    [[ -n $NODE_XHTTP_PATH ]] || NODE_XHTTP_PATH="/xh-$(openssl rand -hex 5)"
}

# Ключи REALITY и пути сохраняются сразу при создании, а не только в конце установки:
# если мастер прервать после вставки профиля в панель, следующий запуск возьмёт те же значения
NODE_KEYS_FILE="${SKIPIT_ETC}/node-keys.conf"
NODE_KEYS_SECRET=(NODE_PRIV NODE_PUB NODE_SID NODE_WS_PATH NODE_XHTTP_PATH)
node_keys_ensure() {
    local k v
    if [[ -z $NODE_PRIV || -z $NODE_SID ]] && [[ -f $NODE_KEYS_FILE ]]; then
        while IFS='=' read -r k v; do
            [[ " ${NODE_KEYS_SECRET[*]} " == *" $k "* && -z ${!k} ]] && printf -v "$k" '%s' "$v"
        done < "$NODE_KEYS_FILE"
    fi
    if [[ -z $NODE_PRIV || -z $NODE_SID ]]; then
        reality_keys || return 1
    fi
    node_gen_paths
    mkdir -p "$SKIPIT_ETC"
    ( umask 077; for k in "${NODE_KEYS_SECRET[@]}"; do printf '%s=%s\n' "$k" "${!k}"; done > "$NODE_KEYS_FILE" )
    log "node keys: $(basename "$NODE_KEYS_FILE") ws=$NODE_WS_PATH xhttp=$NODE_XHTTP_PATH"
}

# Путь WS, который реально стоит в nginx.conf ноды (пусто - файла или WS-блока нет)
node_nginx_ws_path() {
    sed -n 's/^[[:space:]]*location[[:space:]]\+\(\/ws-[^[:space:]]*\)[[:space:]]*{.*/\1/p' "$NODE_NGINX" 2>/dev/null | head -n 1
}

node_state_load() {
    local k v
    [[ -f $NODE_STATE ]] || return 1
    while IFS='=' read -r k v; do
        [[ " ${NODE_KEYS[*]} " == *" $k "* ]] && printf -v "$k" '%s' "$v"
    done < "$NODE_STATE"
    [[ -n $NODE_DOMAIN ]]
}

node_state_save() {
    local k
    mkdir -p "$SKIPIT_ETC"
    ( umask 077; for k in "${NODE_KEYS[@]}"; do printf '%s=%s\n' "$k" "${!k}"; done > "$NODE_STATE" )
    chmod 600 "$NODE_STATE"
}

node_installed() { node_state_load && [[ -f $NODE_COMPOSE ]]; }

node_env_get() { sed -n "s/^$1=//p" "$NODE_ENV" 2>/dev/null | head -n 1; }

node_write_env() { # SECRET_KEY
    ( umask 077; printf 'NODE_PORT=%s\nSECRET_KEY=%s\n' "$NODE_PORT" "$1" > "$NODE_ENV" )
    chmod 600 "$NODE_ENV"
}

# ---- Проверки ввода, DNS, порты ----
valid_domain() { [[ ${#1} -le 253 && $1 =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]; }

valid_ipv4() {
    local IFS=. o
    [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    for o in $1; do (( 10#$o <= 255 )) || return 1; done
}

valid_host_ip() { valid_ipv4 "$1" || [[ $1 == *:* && $1 =~ ^[0-9A-Fa-f:]+$ ]]; }

base_domain() { awk -F. '{ if (NF >= 2) print $(NF-1) "." $NF; else print }' <<< "$1"; }

# SECRET_KEY из панели: принимаем и "SECRET_KEY=...", и "SECRET_KEY: "...""
norm_secret() {
    local s=${1//$'\r'/}
    s=${s#"${s%%[![:space:]]*}"}; s=${s%"${s##*[![:space:]]}"}
    s=${s#- }; s=${s#SECRET_KEY=}; s=${s#SECRET_KEY:}; s=${s# }
    s=${s#\"}; s=${s%\"}; s=${s#\'}; s=${s%\'}
    printf '%s' "$s"
}
valid_secret() { [[ ${#1} -ge 32 && $1 =~ ^[A-Za-z0-9+/=_.-]+$ ]]; }

dns_a() { # домен → A-записи
    local r=""
    if command -v dig >/dev/null 2>&1; then
        r=$(dig +short +time=3 +tries=1 A "$1" @1.1.1.1 2>/dev/null | grep -E '^[0-9]+(\.[0-9]+){3}$')
        [[ -z $r ]] && r=$(dig +short +time=3 +tries=1 A "$1" 2>/dev/null | grep -E '^[0-9]+(\.[0-9]+){3}$')
    else
        r=$(getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u)
    fi
    printf '%s\n' "$r" | sed '/^$/d'
}

CF_RANGES="173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18
108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17
162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22"

ip2int() { local IFS=. a b c d; read -r a b c d <<< "$1"; echo $(( (a << 24) + (b << 16) + (c << 8) + d )); }

ip_is_cloudflare() {
    local ip net bits n
    ip=$(ip2int "$1")
    for net in $CF_RANGES; do
        bits=${net#*/}; n=$(ip2int "${net%/*}")
        (( (ip >> (32 - bits)) == (n >> (32 - bits)) )) && return 0
    done
    return 1
}

# 0 - указывает на этот сервер, 1 - нет/не туда, 2 - прокси Cloudflare, 3 - есть лишние адреса
DNS_MSG=""
node_check_dns() { # домен
    local ips ip
    ips=$(dns_a "$1" | xargs)
    if [[ -z $ips ]]; then DNS_MSG="У домена $1 нет A-записи."; return 1; fi
    for ip in $ips; do
        if ip_is_cloudflare "$ip"; then
            DNS_MSG="$1 → $ips — это адрес Cloudflare (включён прокси, оранжевое облако)."
            return 2
        fi
    done
    if [[ $ips == "$SERVER_IP" ]]; then DNS_MSG="$1 → $ips"; return 0; fi
    if [[ " $ips " == *" $SERVER_IP "* ]]; then
        DNS_MSG="$1 → $ips (кроме этого сервера есть лишние адреса)"; return 3
    fi
    DNS_MSG="$1 → $ips, а IP этого сервера $SERVER_IP."
    return 1
}

port_listeners() { ss -Htlnp "sport = :$1" 2>/dev/null; }

# Процессы самой ноды (при переустановке порты заняты ими - это нормально)
port_foreign() { port_listeners "$1" | grep -vE '"(xray|rw-core|node|nginx)"'; }

# Порт в диапазоне исходящих портов ядра - его может занять исходящее соединение
port_in_ephemeral() { # порт
    local lo hi
    read -r lo hi < /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null || return 1
    (( $1 >= lo && $1 <= hi ))
}

port_ephemeral_warning() { # порт служба → текст предупреждения
    local lo hi
    read -r lo hi < /proc/sys/net/ipv4/ip_local_port_range
    printf 'Порт:                    %s\nИсходящие порты ядра:    %s–%s\n\nИсходящее соединение может занять этот порт, и %s не запустится после перезапуска.\nЛучше выбрать порт ниже %s.\n\nОставить порт %s?' "$1" "$lo" "$hi" "$2" "$lo" "$1"
}

# IP или подсеть IPv4 содержит адрес
ip_matches() { # IP_или_подсеть адрес
    [[ $1 == "$2" ]] && return 0
    [[ $1 == */* ]] || return 1
    local re='^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$' a b bits=${1#*/} mask
    [[ $bits =~ ^[0-9]+$ ]] && (( bits <= 32 )) || return 1
    [[ $2 =~ $re ]] || return 1
    b=$(( (BASH_REMATCH[1] << 24) + (BASH_REMATCH[2] << 16) + (BASH_REMATCH[3] << 8) + BASH_REMATCH[4] ))
    [[ ${1%/*} =~ $re ]] || return 1
    a=$(( (BASH_REMATCH[1] << 24) + (BASH_REMATCH[2] << 16) + (BASH_REMATCH[3] << 8) + BASH_REMATCH[4] ))
    mask=$(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
    (( (a & mask) == (b & mask) ))
}

# Порт закреплён за нодой SkipIt по схеме -> причина (или пусто)
port_node_reserved() { # порт
    node_state_load || return 0
    case $1 in
        443) echo "Xray ноды (REALITY)" ;;
        "$NODE_PORT") echo "нода Remnawave (подключение панели)" ;;
        *)
            [[ $NODE_LAYOUT == balancer ]] || return 0
            case $1 in
                "$NODE_XHTTP_PORT") echo "Xray ноды (XHTTP)" ;;
                "$NODE_WS_PORT")    echo "Xray ноды (WS, локально)" ;;
                "$NODE_WS_PUBLIC")  echo "nginx ноды (WS балансира)" ;;
            esac ;;
    esac
}

# Таблица занятых TCP-портов: "Порт<TAB>Кто использует<TAB>Доступ"
ports_used_table() {
    local line addr port host name who
    local -A by_name by_scope
    while IFS= read -r line; do
        addr=$(awk '{print $4}' <<< "$line")
        port=${addr##*:}; host=${addr%:*}
        [[ $line =~ users:\(\(\"([^\"]+)\" ]] && name=${BASH_REMATCH[1]} || name="?"
        case $name in
            sshd) who="SSH" ;;
            rw-core|xray) who="Xray ноды" ;;
            rw-node|node) who="нода Remnawave" ;;
            nginx) who="nginx" ;;
            *) who=$name ;;
        esac
        by_name[$port]=$who
        if [[ $host == 127.0.0.1 || $host == "[::1]" ]]; then
            [[ -z ${by_scope[$port]:-} ]] && by_scope[$port]="только локально"
        else
            by_scope[$port]="все адреса"
        fi
    done < <(ss -Htlnp 2>/dev/null)
    if node_state_load; then
        for port in 443 "$NODE_PORT" $([[ $NODE_LAYOUT == balancer ]] && echo "$NODE_XHTTP_PORT $NODE_WS_PORT $NODE_WS_PUBLIC"); do
            if [[ -z ${by_name[$port]:-} ]]; then
                by_name[$port]="$(port_node_reserved "$port")"; by_scope[$port]="зарезервирован"
            fi
        done
    fi
    printf 'Порт\tКто использует\tДоступ\n'
    for port in $(printf '%s\n' "${!by_name[@]}" | sort -n); do
        printf '%s\t%s\t%s\n' "$port" "${by_name[$port]}" "${by_scope[$port]}"
    done
}

ctr_status() { docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null; }

ctr_state_ru() {
    case $(ctr_status "$1") in
        running) echo "работает" ;; restarting) echo "ПЕРЕЗАПУСКАЕТСЯ" ;;
        exited|dead) echo "ОСТАНОВЛЕН" ;; "") echo "нет" ;; *) ctr_status "$1" ;;
    esac
}

# Ключи REALITY (x25519, base64url без паддинга - как у xray x25519)
reality_keys() {
    local k
    k=$(openssl genpkey -algorithm x25519 2>/dev/null) || return 1
    NODE_PRIV=$(printf '%s\n' "$k" | openssl pkey -outform DER 2>/dev/null | tail -c 32 | base64 -w0 | tr '+/' '-_' | tr -d '=')
    NODE_PUB=$(printf '%s\n' "$k" | openssl pkey -pubout -outform DER 2>/dev/null | tail -c 32 | base64 -w0 | tr '+/' '-_' | tr -d '=')
    NODE_SID="$(openssl rand -hex 8),$(openssl rand -hex 8)"   # два shortId через запятую
    [[ ${#NODE_PRIV} == 43 && ${#NODE_PUB} == 43 ]]
}

# IPv6: адрес и маршрут есть, а трафик не ходит. curl переключается на IPv4 сам,
# а Python (certbot, плагин Cloudflare) висит на IPv6 без таймаута.
GAI_CONF="/etc/gai.conf"
GAI_LINE="precedence ::ffff:0:0/96  100"

ipv6_prefer_v4() { grep -Eq '^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96[[:space:]]+100' "$GAI_CONF" 2>/dev/null; }

ipv6_broken() {
    ip -6 route show default 2>/dev/null | grep -q . || return 1
    curl -4 -s -o /dev/null --max-time 8 https://api.cloudflare.com/client/v4/ 2>/dev/null || return 1
    ! curl -6 -s -o /dev/null --max-time 3 https://api.cloudflare.com/client/v4/ 2>/dev/null
}

ipv6_set_prefer_v4() {
    [[ -f $GAI_CONF ]] && backup_file "$GAI_CONF" >/dev/null
    printf '\n# SkipIt: IPv6 на сервере не работает — сначала пробовать IPv4\n%s\n' "$GAI_LINE" >> "$GAI_CONF"
    log "gai.conf: prefer IPv4"
}

# В мастере: предложить исправление до запуска certbot и Docker
ipv6_check_wizard() {
    ipv6_prefer_v4 && return 0
    ipv6_broken || return 0
    if ui_yesno "IPv6 не работает" "На сервере включён IPv6, но интернет через него не открывается.
Программы сначала пробуют IPv6 и зависают — из-за этого не выпустится сертификат.

SkipIt может это исправить — сервер будет подключаться сначала по IPv4, а IPv6 оставит запасным.

ℹ IPv6 не выключается. Меняется один системный файл: $GAI_CONF
ℹ Копия файла до изменения сохранится в $SKIPIT_BACKUPS
ℹ Выключить IPv6 полностью можно в главном меню → IPv6

Исправить?"; then
        ipv6_set_prefer_v4
    else
        ui_yesno "Продолжить без исправления?" "Выпуск сертификата и загрузка шаблонов могут зависнуть.

Продолжить всё равно?" no || return 1
    fi
}

# IPv6: выключить / включить, IPv4 первым
# Выключаем через sysctl, ::1 (lo) оставляем - на него слушают локальные службы.
IPV6_SYSCTL="/etc/sysctl.d/98-skipit-ipv6.conf"

ipv6_supported() { [[ -d /proc/sys/net/ipv6 ]]; }
ipv6_off()       { [[ $(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null) == 1 ]]; }
ipv6_addr()      { ip -6 addr show scope global 2>/dev/null | awk '/inet6/ {print $2; exit}'; }

ipv6_state_ru() {
    if ! ipv6_supported; then echo "выключен в ядре"
    elif ipv6_off; then echo "выключен"
    elif ipv6_prefer_v4; then echo "включён, основной IPv4"
    else echo "включён"; fi
}

# Другие файлы sysctl, которые тоже выключают IPv6 (после перезагрузки он снова выключится)
ipv6_other_off_files() {
    grep -lsE '^[[:space:]]*net\.ipv6\.conf\.(all|default)\.disable_ipv6[[:space:]]*=[[:space:]]*1' \
        /etc/sysctl.conf /etc/sysctl.d/*.conf /run/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf 2>/dev/null |
        grep -vxF "$IPV6_SYSCTL"
}

ipv6_disable() {
    printf '%s\n' "# SkipIt: IPv6 выключен (включить: ${SKIPIT_CMD} → IPv6)" \
        "net.ipv6.conf.all.disable_ipv6 = 1" \
        "net.ipv6.conf.default.disable_ipv6 = 1" \
        "net.ipv6.conf.lo.disable_ipv6 = 0" > "$IPV6_SYSCTL"
    sysctl -q -p "$IPV6_SYSCTL" >/dev/null 2>&1
    log "ipv6: disabled"
    ipv6_off
}

ipv6_enable() {
    local f
    rm -f "$IPV6_SYSCTL"
    for f in /proc/sys/net/ipv6/conf/*/disable_ipv6; do echo 0 > "$f"; done 2>/dev/null
    log "ipv6: enabled"
    ! ipv6_off
}

ipv6_unset_prefer_v4() {
    backup_file "$GAI_CONF" >/dev/null
    sed -i -e '/^# SkipIt: IPv6 на сервере не работает/d' \
        -e '/^[[:space:]]*precedence[[:space:]]\+::ffff:0:0\/96[[:space:]]\+100/d' "$GAI_CONF"
    log "gai.conf: default order"
}

ipv6_menu_off() {
    local client=${SSH_CONNECTION%% *} text
    if [[ $client == *:* && $client != ::ffff:* ]]; then
        ui_msg "IPv6 не выключен" "Вы подключены к серверу по IPv6 ($client).
После выключения эта SSH-сессия оборвётся.

Подключитесь по IPv4 ($SERVER_IP) и повторите."
        return
    fi
    text="Сервер перестанет использовать IPv6 — все соединения пойдут по IPv4.
Настройка сохранится и после перезагрузки."
    if node_installed && getent ahosts "$NODE_DOMAIN" 2>/dev/null | awk '{print $1}' | grep -q ':'; then
        text+=$'\n\n'"! У домена $NODE_DOMAIN есть AAAA-запись (IPv6-адрес)."$'\n'"  Удалите её в DNS, иначе клиенты с IPv6 не смогут подключиться к ноде."
    fi
    text+=$'\n\n'"ℹ Включить обратно можно здесь же: главное меню → IPv6"$'\n\n'"Выключить IPv6?"
    ui_yesno "Выключить IPv6" "$text" no || return
    ui_loading "Выключаю IPv6…"
    if ipv6_disable; then
        ui_msg "Готово" "IPv6 выключен. Сервер работает только по IPv4."
    else
        rm -f "$IPV6_SYSCTL"
        ui_msg "Ошибка" "Не удалось выключить IPv6 (на $VIRT это может быть запрещено)."
    fi
}

ipv6_menu_on() {
    ui_yesno "Включить IPv6" "Сервер снова будет использовать IPv6.

Включить IPv6?" || return
    ui_loading "Включаю IPv6…"
    if ! ipv6_enable; then
        ui_msg "Ошибка" "Не удалось включить IPv6 (на $VIRT это может быть запрещено)."; return
    fi
    sleep 3
    local addr other msg
    addr=$(ipv6_addr)
    other=$(ipv6_other_off_files)
    if [[ -n $addr ]]; then
        msg="IPv6 включён."$'\n\n'"Адрес:  $addr"
    else
        msg="IPv6 включён, но IPv6-адрес пока не появился.
Обычно он возвращается после перезагрузки сервера (команда reboot)."
    fi
    [[ -n $other ]] && msg+=$'\n\n'"! IPv6 выключен ещё и в других файлах — после перезагрузки он снова выключится."$'\n'"  Удалите из них строки disable_ipv6:"$'\n'"$(sed 's/^/    /' <<< "$other")"
    ui_msg "Готово" "$msg"
}

menu_ipv6() {
    local c addr items
    if ! ipv6_supported; then
        ui_msg "IPv6" "IPv6 выключен в ядре (параметр загрузки ipv6.disable=1) — из SkipIt его не включить."
        return
    fi
    local hdr
    while :; do
        addr=$(ipv6_addr); addr=${addr%/*}
        items=()
        if ipv6_off; then
            hdr="IPv6:  выключен"
            items+=(on "Включить IPv6")
        else
            hdr="IPv6:  включён"
            if ipv6_prefer_v4; then
                hdr+=$'\n'"Основной:  IPv4, IPv6 — запасной"
                items+=(off "Выключить IPv6" prio "Сделать основным IPv6")
            else
                hdr+=$'\n'"Основной:  IPv6, IPv4 — запасной"
                items+=(off "Выключить IPv6" prio "Сделать основным IPv4")
            fi
            hdr+=$'\n'"Адрес:  ${addr:-нет}"
            items+=(check "Проверить, работает ли IPv6")
        fi
        c=$(ui_menu "IPv6" "$hdr" "${items[@]}") || return
        case $c in
            off) ipv6_menu_off ;;
            on)  ipv6_menu_on ;;
            prio)
                if ipv6_prefer_v4; then
                    ipv6_unset_prefer_v4
                    ui_msg "Готово" "Основной теперь IPv6: сервер подключается сначала по IPv6, а если не вышло — по IPv4."
                else
                    ipv6_set_prefer_v4
                    ui_msg "Готово" "Основной теперь IPv4: сервер подключается сначала по IPv4, а если не вышло — по IPv6."
                fi ;;
            check)
                ui_loading "Проверяю IPv6…"
                if curl -6 -s -o /dev/null --max-time 5 https://api.cloudflare.com/client/v4/ 2>/dev/null; then
                    ui_msg "IPv6 работает" "✓ Сервер открывает сайты по IPv6."
                else
                    ui_msg "IPv6 не работает" "✗ Сервер не может открыть сайты по IPv6.

Если IPv6 не нужен — выключите его в этом меню."
                fi ;;
        esac
    done
}

node_step() { # "1/6  Docker"
    printf '\n  %s[%s]%s %s%s%s\n' "$C_ACC" "${1%% *}" "$C_RESET" "$C_TXT" "${1#*  }" "$C_RESET"
}
n_say()     { printf '       %s%s%s\n' "$C_NOTE" "$*" "$C_RESET"; }
node_fail() { printf '\n  %s✗%s %s%s%s\n' "$C_ERR" "$C_RESET" "$C_TXT" "$*" "$C_RESET"; log "node: FAIL $*"; pause; }

# ---- Сертификаты Let's Encrypt ----
cert_file() { echo "/etc/letsencrypt/live/$1/fullchain.pem"; }

cert_days_left() { # имя
    local end
    [[ -f $(cert_file "$1") ]] || return 1
    end=$(openssl x509 -enddate -noout -in "$(cert_file "$1")" 2>/dev/null | cut -d= -f2)
    [[ -n $end ]] || return 1
    echo $(( ($(date -d "$end" +%s) - $(date +%s)) / 86400 ))
}

cert_covers() { # имя домен
    openssl x509 -noout -checkhost "$2" -in "$(cert_file "$1")" 2>/dev/null | grep -q 'does match'
}

cert_domains() { openssl x509 -noout -ext subjectAltName -in "$(cert_file "$1")" 2>/dev/null | tail -n +2 | sed 's/DNS://g; s/,//g' | xargs; }

cert_method_ru() { # имя
    local a; a=$(awk -F' = ' '$1=="authenticator"{print $2}' "/etc/letsencrypt/renewal/$1.conf" 2>/dev/null)
    case $a in
        standalone) echo "HTTP-01" ;; dns-cloudflare) echo "Cloudflare DNS (wildcard)" ;;
        "") echo "неизвестно" ;; *) echo "$a" ;;
    esac
}

node_cert_state() {
    local d end
    d=$(cert_days_left "$NODE_CERT_NAME") || { echo "НЕТ"; return; }
    end=$(date -d "$(openssl x509 -enddate -noout -in "$(cert_file "$NODE_CERT_NAME")" 2>/dev/null | cut -d= -f2)" +%d.%m.%Y 2>/dev/null)
    if (( d < 0 )); then echo "истёк"
    elif (( d < 20 )); then echo "скоро истекает · $d дн."
    else echo "действует · $d дн.${end:+ (до $end)}"; fi
}

cert_brief() {
    local d; d=$(cert_days_left "$NODE_CERT_NAME") || { echo "НЕТ"; return; }
    if (( d < 0 )); then echo "ИСТЁК"; else echo "$d дн."; fi
}

cert_renew_scheduled() {
    systemctl list-timers --all 2>/dev/null | grep -q certbot ||
        [[ -f /etc/cron.d/certbot || -f /etc/cron.d/skipit-certbot ]]
}

cert_ensure_renew() {
    if systemctl cat certbot.timer >/dev/null 2>&1; then
        systemctl enable --now certbot.timer >/dev/null 2>&1
    fi
    cert_renew_scheduled && return 0
    echo "17 3,15 * * * root certbot -q renew" > /etc/cron.d/skipit-certbot
}

# Хуки certbot: 80/tcp открывается только на время проверки HTTP-01,
# после продления nginx перечитывает сертификат
cert_write_hooks() {
    mkdir -p "$(dirname "$ACME_OPEN")" "$(dirname "$ACME_CLOSE")" "$(dirname "$ACME_DEPLOY")"
    cat > "$ACME_OPEN" <<'EOF'
#!/bin/sh
# SkipIt: открыть 80/tcp на время проверки HTTP-01 (аргумент force - при первом выпуске)
if [ "$1" != force ]; then
    grep -qs '^authenticator = standalone' /etc/letsencrypt/renewal/*.conf || exit 0
fi
command -v ufw >/dev/null 2>&1 || exit 0
LC_ALL=C ufw status 2>/dev/null | grep -q '^Status: active' || exit 0
LC_ALL=C ufw status 2>/dev/null | grep -Eq '^80(/tcp)?[[:space:]]+ALLOW[[:space:]]+Anywhere[[:space:]]*($|#)' && exit 0
ufw allow 80/tcp comment 'ACME (SkipIt)' >/dev/null 2>&1 && touch /run/skipit-acme80
exit 0
EOF
    cat > "$ACME_CLOSE" <<'EOF'
#!/bin/sh
# SkipIt: закрыть 80/tcp, если его открыл хук skipit-open80.sh
[ -f /run/skipit-acme80 ] || exit 0
ufw --force delete allow 80/tcp >/dev/null 2>&1
rm -f /run/skipit-acme80
exit 0
EOF
    cat > "$ACME_DEPLOY" <<'EOF'
#!/bin/sh
# SkipIt: после перевыпуска сертификата ноды перезапустить nginx и remnanode
command -v docker >/dev/null 2>&1 || exit 0
# certbot передаёт RENEWED_LINEAGE - перезапускаем, только если обновился сертификат ноды
if [ -n "$RENEWED_LINEAGE" ] && [ -f /etc/skipit/node.conf ]; then
    name=$(sed -n 's/^NODE_CERT_NAME=//p' /etc/skipit/node.conf)
    [ -z "$name" ] || [ "${RENEWED_LINEAGE##*/}" = "$name" ] || exit 0
fi
for c in remnawave-nginx remnanode; do
    docker inspect "$c" >/dev/null 2>&1 || continue
    if docker restart "$c" >/dev/null 2>&1; then r=ok; else r=FAIL; fi
    echo "$(date '+%F %T')  cert renew: restart $c $r" >> /var/log/skipit.log
done
exit 0
EOF
    chmod 755 "$ACME_OPEN" "$ACME_CLOSE" "$ACME_DEPLOY"
    rm -f "$ACME_DEPLOY_OLD"
}

cert_issue_http() { # домен email
    local rc em=(--register-unsafely-without-email)
    [[ -n $2 ]] && em=(-m "$2")
    "$ACME_OPEN" force
    certbot certonly --standalone --non-interactive --agree-tos "${em[@]}" \
        --cert-name "$1" -d "$1" --key-type ecdsa
    rc=$?
    "$ACME_CLOSE"
    return $rc
}

cert_issue_cf() { # базовый-домен email
    local em=(--register-unsafely-without-email)
    [[ -n $2 ]] && em=(-m "$2")
    certbot certonly --dns-cloudflare --dns-cloudflare-credentials "$CF_CREDS" \
        --dns-cloudflare-propagation-seconds 30 --non-interactive --agree-tos "${em[@]}" \
        --cert-name "$1" -d "$1" -d "*.$1" --key-type ecdsa
}

# Токен из вставки: убрать маркеры bracketed paste, "Bearer", пробелы и непечатные символы
cf_clean_token() {
    local t=$1
    t=${t//$'\e[200~'/}; t=${t//$'\e[201~'/}
    t=${t#Bearer }; t=${t#bearer }
    printf '%s' "$t" | tr -cd 'A-Za-z0-9_-'
}

cf_mask() { local t=$1; (( ${#t} > 8 )) && echo "${t:0:4}…${t: -4} (${#t} симв.)" || echo "(${#t} симв.)"; }

# Проверка через список зон - работает и для токенов из My Profile, и для Account API Tokens
CF_ERR=""
cf_zone_check() { # токен зона
    local r
    CF_ERR=""
    r=$(curl -sS --max-time 20 -H "Authorization: Bearer $1" \
        "https://api.cloudflare.com/client/v4/zones?name=$2" 2>&1) || { CF_ERR="нет связи с api.cloudflare.com: $r"; return 2; }
    if grep -Eq '"success" *: *true' <<< "$r"; then
        grep -Eq "\"name\" *: *\"$2\"" <<< "$r" && return 0
        CF_ERR="Токен рабочий, но зона $2 ему не видна.
При создании токена выберите (или All zones):
▸ Zone Resources → Include → Specific zone → $2"
        return 1
    fi
    CF_ERR=$(grep -oE '"message" *: *"[^"]*"' <<< "$r" | head -n 2 | sed -E 's/"message" *: *"//; s/"$//')
    CF_ERR="Cloudflare отклонил токен: ${CF_ERR:-$r}"
    return 1
}

# Сайт-заглушка: шаблоны Mrvibecodic - github.com/Mrvibecodic/node-templates
# Версия закреплена коммитом. Файлы шаблона копируются как есть; не копируются
# README.md, previews/, screenshots/ и неиспользуемые картинки-превью,
# удаляются og/twitter-метки со ссылками на mrvibecodic.github.io.
SITE_REPO="Mrvibecodic/node-templates"
SITE_SHA="845187fbee8fff72f66d1570af436438e859e40d"
SITE_CACHE="/var/cache/skipit/node-templates-${SITE_SHA:0:7}.tar.gz"
# Manual32: генератор из личной копии пользователя - ссылка хранится только на сервере
M32_CONF="${SKIPIT_ETC}/manual32.conf"
M32_CACHE="/var/cache/skipit/manual32-selfsteal.sh"

# тег|название (из <title>)|язык|размер|что страница грузит с внешних сайтов
SITE_LIST=(
"endless-verify|Технозона — новости технологий (окно «бесконечной капчи»)|RU|3.2 МБ|Google Fonts"
"esports-stream-template|ArenaCast — 24/7 Esports Live Streaming|EN|0.5 МБ|Google Fonts, фото Pexels, плеер Twitch"
"levelup-hub|LevelUp Hub — игры, рейтинги и скидки|RU|<0.1 МБ|данные и обложки Steam, CheapShark"
"playza-game-catalog|PLAYZA — флеш-игры в браузере|RU|6.4 МБ|Google Fonts"
"rybaliti-2.0|Рыбалити 2.2 — браузерная игра-рыбалка|RU|0.6 МБ|"
"screenwire-digest|ScreenWire — дайджест ссылок: игры, фильмы, сериалы|RU|<0.1 МБ|данные Steam, CheapShark, TVMaze, IMDb"
"vibrai-photo-editor|Vibrai — AI online photo editor|EN|2.3 МБ|"
"worldzoo-stream-template|WildPlanet — Zoos of the World|EN|1.0 МБ|Google Fonts, трансляции с сайтов зоопарков"
)

site_field() { # тег номер-поля
    local e
    for e in "${SITE_LIST[@]}"; do
        [[ ${e%%|*} == "$1" ]] && { cut -d'|' -f"$2" <<< "$e"; return 0; }
    done
    return 1
}

site_tags() { local e; for e in "${SITE_LIST[@]}"; do echo "${e%%|*}"; done; }

site_title() {
    local t rest type name
    [[ $1 == keep ]] && { echo "текущий сайт без изменений"; return; }
    if [[ $1 == m32:* ]]; then
        rest=${1#m32:}; type=${rest%%:*}; name=${rest#*:}
        [[ $name == "$rest" ]] && name=""
        echo "$(m32_type_ru "$type")${name:+ «$name»} — шаблон Manual32"
        return
    fi
    t=$(site_field "$1" 2) && echo "$t — шаблон Mrvibecodic" || echo "$1"
}

m32_types() { printf '%s\n' blog cafe studio saas docs photo; }

m32_type_ru() {
    case $1 in
        blog) echo "Блог" ;; cafe) echo "Кафе" ;; studio) echo "Студия" ;;
        saas) echo "SaaS-сервис" ;; docs) echo "Документация" ;; photo) echo "Фотоблог" ;;
        *) echo "$1" ;;
    esac
}

# Ссылка на личную копию selfsteal.sh (спросит и сохранит, если ещё нет)
m32_url() {
    local url="" re='^https://manual32\.online/dl/selfsteal\.sh\?t=[A-Za-z0-9_-]+$'
    [[ -f $M32_CONF ]] && url=$(sed -n 's/^M32_URL=//p' "$M32_CONF" | head -n 1)
    if [[ ! $url =~ $re ]]; then
        url=$(ui_input "Ссылка Manual32" "Шаблоны Manual32 генерируются скриптом из вашей личной копии.
SkipIt сохранит ссылку только на этом сервере ($M32_CONF).
Пример:  https://manual32.online/dl/selfsteal.sh?t=…

Ссылка на selfsteal.sh:") || return 1
        url=${url//[[:space:]]/}
        [[ $url =~ $re ]] || { ui_msg "Ошибка" "Это не похоже на ссылку Manual32: «$url»"; return 1; }
        mkdir -p "$SKIPIT_ETC" && ( umask 077; printf 'M32_URL=%s\n' "$url" > "$M32_CONF" )
    fi
    printf '%s' "$url"
}

# Скачать генератор; при ошибке ссылки (HTTP 4xx) - забыть её, чтобы спросить заново
m32_fetch() {
    local url rc
    url=$(m32_url) || return 1
    mkdir -p "$(dirname "$M32_CACHE")" || return 1
    curl -fsSL --retry 2 --connect-timeout 15 --max-time 60 "$url" -o "$M32_CACHE.part"
    rc=$?
    if (( rc == 0 )) && [[ $(head -c 2 "$M32_CACHE.part") == '#!' ]] && grep -q 'MANUAL32' "$M32_CACHE.part"; then
        mv "$M32_CACHE.part" "$M32_CACHE"
        return 0
    fi
    rm -f "$M32_CACHE.part"
    (( rc == 22 )) && rm -f "$M32_CONF"
    return 1
}

site_external() { # тег → «С внешних сайтов: …» или пусто
    local x; x=$(site_field "$1" 5)
    [[ -n $x ]] && echo "С внешних сайтов грузит: $x"
}

site_choose() { # [keep] [домен] → тег
    local mode=${1:-} domain=${2:-$NODE_DOMAIN} t x name items tags=()
    items=(random "Случайный шаблон от Mrvibecodic" m32random "Случайный шаблон от Manual32" pick "Выбрать шаблон")
    [[ $mode == keep ]] && items+=("" "" keep "Оставить текущий сайт в $NODE_WEBROOT")
    t=$(ui_choose "Сайт-заглушка" "Mrvibecodic:  github.com/$SITE_REPO
Manual32:     manual32.online

ℹ Эту страницу увидит любой, кто откроет домен ноды в браузере." "${items[@]}") || return 1
    case $t in
        random)
            mapfile -t tags < <(site_tags)
            t=${tags[RANDOM % ${#tags[@]}]} ;;
        m32random)
            mapfile -t tags < <(m32_types)
            t="m32:${tags[RANDOM % ${#tags[@]}]}" ;;
        pick)
            items=("" "Mrvibecodic")
            while IFS= read -r x; do
                items+=("$x" "$(site_field "$x" 2) · $(site_field "$x" 3) · $(site_field "$x" 4)")
            done < <(site_tags)
            items+=("" "Manual32")
            while IFS= read -r x; do
                items+=("m32:$x" "$(m32_type_ru "$x")")
            done < <(m32_types)
            t=$(ui_choose "Выбрать шаблон" "Для Mrvibecodic указаны название · язык · размер." "${items[@]}") || return 1 ;;
    esac
    if [[ $t == m32:* ]]; then
        m32_url >/dev/null || return 1
        name=$(ui_input "Название сайта" "Шаблон:  $(m32_type_ru "${t#m32:}") от Manual32
Пример:  Планер

Название сайта (пусто — из домена):") || return 1
        name=${name//[|:$'\t']/}
        name=$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<< "$name")
        [[ -z $name ]] && name=${domain%%.*}
        t="$t:$name"
    fi
    printf '%s' "$t"
}

# Скачать архив шаблонов (закреплённый коммит) в кеш
site_fetch() {
    [[ -s $SITE_CACHE ]] && tar -tzf "$SITE_CACHE" >/dev/null 2>&1 && return 0
    mkdir -p "$(dirname "$SITE_CACHE")" || return 1
    printf '\n  %sСкачиваю шаблоны Mrvibecodic с GitHub (~23 МБ)...%s\n' "$C_GRAY" "$C_RESET" >"$TTY"
    if curl -fsSL --retry 2 --connect-timeout 15 --max-time 300 -o "$SITE_CACHE.part" \
            "https://codeload.github.com/$SITE_REPO/tar.gz/$SITE_SHA" &&
        tar -tzf "$SITE_CACHE.part" >/dev/null 2>&1; then
        mv "$SITE_CACHE.part" "$SITE_CACHE"
        return 0
    fi
    rm -f "$SITE_CACHE.part"
    return 1
}

SITE_BAK=""
site_install() { # тег [домен]
    local tpl=$1 domain=${2:-$NODE_DOMAIN} tmp src rc rest type name
    SITE_BAK=""
    [[ $tpl == keep ]] && return 0
    tmp=$(mktemp -d)
    if [[ $tpl == m32:* ]]; then
        rest=${tpl#m32:}; type=${rest%%:*}; name=${rest#*:}
        [[ $name == "$rest" ]] && name=${domain%%.*}
        m32_fetch || { rm -rf "$tmp"; return 1; }
        src="$tmp/site"
        bash "$M32_CACHE" --domain="$domain" --type="$type" --name="$name" --dir="$src" >/dev/null 2>&1
        [[ -f $src/index.html ]] || { rm -rf "$tmp"; return 1; }
    else
        site_field "$tpl" 1 >/dev/null || { rm -rf "$tmp"; return 1; }
        site_fetch || { rm -rf "$tmp"; return 1; }
        src="$tmp/node-templates-$SITE_SHA/$tpl"
        if ! tar -xzf "$SITE_CACHE" --no-same-owner -C "$tmp" "node-templates-$SITE_SHA/$tpl" 2>/dev/null ||
            [[ ! -f $src/index.html ]]; then
            rm -rf "$tmp"; return 1
        fi
        # То, что страницы не используют, на сайт не попадает
        rm -rf "$src/README.md" "$src/previews" "$src/screenshots" "$src/vibrai-photo-editor.png"
        # og/twitter-метки указывают на mrvibecodic.github.io - на ноде это чужой адрес
        find "$src" -name '*.html' -exec sed -i -E '/<meta[^>]*content="https?:\/\/mrvibecodic\.github\.io[^"]*"[^>]*>/d' {} +
        [[ -f $src/robots.txt ]] || printf 'User-agent: *\nDisallow: /\n' > "$src/robots.txt"
    fi

    mkdir -p "$NODE_WEBROOT" || { rm -rf "$tmp"; return 1; }
    # Сайт, поставленный не SkipIt, - в архив перед заменой
    if [[ ( -z $NODE_TEMPLATE || $NODE_TEMPLATE == keep ) && -n $(ls -A "$NODE_WEBROOT" 2>/dev/null) ]]; then
        mkdir -p "$SKIPIT_BACKUPS"
        SITE_BAK="${SKIPIT_BACKUPS}/www-$(date +%Y%m%d-%H%M%S).tar.gz"
        tar -czf "$SITE_BAK" -C "$NODE_WEBROOT" . 2>/dev/null || { rm -rf "$tmp"; return 1; }
    fi
    find "$NODE_WEBROOT" -mindepth 1 -delete
    cp -a "$src/." "$NODE_WEBROOT/" && chmod -R a+rX "$NODE_WEBROOT"
    rc=$?
    rm -rf "$tmp"
    return $rc
}

# ---- Файлы ноды ----
node_nginx_conf() { # домен имя-сертификата схема
cat <<EOF
# Файл записан SkipIt, схема: $(node_layout_ru "$3")
server_names_hash_bucket_size 64;

map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ""      close;
}

ssl_protocols TLSv1.2 TLSv1.3;
ssl_ecdh_curve X25519:prime256v1:secp384r1;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305;
ssl_prefer_server_ciphers on;
ssl_session_timeout 1d;
ssl_session_cache shared:MozSSL:10m;
ssl_session_tickets off;

resolver 1.1.1.1 8.8.8.8 valid=300s;
resolver_timeout 5s;

EOF
if [[ $3 == balancer ]]; then
cat <<EOF
# STEAL + XHTTP (оба REALITY self-steal): Xray держит 443 и ${NODE_XHTTP_PORT},
#    сюда, в сокет, отдаёт только фолбэк на декой. Общий блок на оба.
EOF
else
cat <<EOF
# STEAL (REALITY self-steal): Xray держит 443,
#    сюда, в сокет, отдаёт только фолбэк на декой.
EOF
fi
cat <<EOF
server {
    server_name $1;
    listen unix:${NODE_SOCK} ssl proxy_protocol;
    http2 on;

    ssl_certificate "/etc/nginx/ssl/$2/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/$2/privkey.pem";
    ssl_trusted_certificate "/etc/nginx/ssl/$2/fullchain.pem";

    root ${NODE_WEBROOT};
    index index.html;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet, noimageindex" always;
}

# Дефолт-блок на сокете: рубим всё, что не по SNI.
server {
    listen unix:${NODE_SOCK} ssl proxy_protocol default_server;
    server_name _;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet, noimageindex" always;
    ssl_reject_handshake on;
    return 444;
}
EOF
[[ $3 == balancer ]] || return 0
cat <<EOF

# WS: отдельный публичный TLS-листенер на ${NODE_WS_PUBLIC}. nginx снимает TLS и
#    проксирует секретный путь на локальный plaintext WS-инбаунд Xray (127.0.0.1:${NODE_WS_PORT}).
#    Клиент коннектится к nginx напрямую -> тут БЕЗ proxy_protocol.
server {
    server_name $1;
    listen ${NODE_WS_PUBLIC} ssl;
EOF
# [::] только если в системе есть IPv6, иначе nginx не запустится
[[ -f /proc/net/if_inet6 ]] && echo "    listen [::]:${NODE_WS_PUBLIC} ssl;"
cat <<EOF
    http2 on;

    ssl_certificate "/etc/nginx/ssl/$2/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/$2/privkey.pem";
    ssl_trusted_certificate "/etc/nginx/ssl/$2/fullchain.pem";

    root ${NODE_WEBROOT};
    index index.html;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet, noimageindex" always;

    # секретный путь = path в WS-инбаунде Xray, посимвольно
    location ${NODE_WS_PATH} {
        proxy_pass http://127.0.0.1:${NODE_WS_PORT};
        proxy_http_version 1.1;

        proxy_set_header Upgrade           \$http_upgrade;
        proxy_set_header Connection        \$connection_upgrade;   # из map-блока выше
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }

    # всё, что не секретный путь - декой
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
}

node_compose() {
cat <<EOF
# Файл записан SkipIt. SECRET_KEY и NODE_PORT - в .env рядом.
x-common: &common
  restart: always
  ulimits:
    nofile:
      soft: 1048576
      hard: 1048576
  logging:
    driver: json-file
    options:
      max-size: 50m
      max-file: "3"

services:
  remnanode:
    <<: *common
    image: ${NODE_IMAGE}
    container_name: remnanode
    hostname: remnanode
    network_mode: host
    cap_add:
      - NET_ADMIN
    env_file: .env
    volumes:
      - /dev/shm:/dev/shm:rw

  remnawave-nginx:
    <<: *common
    image: ${NODE_NGINX_IMAGE}
    container_name: remnawave-nginx
    hostname: remnawave-nginx
    network_mode: host
    command: sh -c 'rm -f ${NODE_SOCK} && exec nginx -g "daemon off;"'
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      # live -> /etc/nginx/ssl, archive -> /etc/nginx/archive: симлинки certbot
      # (../../archive/...) разрешаются, nginx -s reload видит продлённый сертификат
      - /etc/letsencrypt/live:/etc/nginx/ssl:ro
      - /etc/letsencrypt/archive:/etc/nginx/archive:ro
      - ${NODE_WEBROOT}:${NODE_WEBROOT}:ro
      - /dev/shm:/dev/shm:rw
EOF
}

node_compose_run() { ( cd "$NODE_DIR" && docker compose "$@" ); }

# UFW для ноды: установить, если нет; SSH разрешается до любых других действий
node_ufw_ensure() {
    local p fresh=0
    if ! command -v ufw >/dev/null 2>&1; then
        n_say "UFW не установлен — устанавливаю..."
        pkg_install ufw && command -v ufw >/dev/null 2>&1 || return 1
        fresh=1; log "node: ufw installed"
    fi
    for p in $(ssh_ports); do ufwc allow "$p/tcp" comment 'SSH (SkipIt)' >/dev/null 2>&1; done
    if (( fresh )); then
        ufwc default deny incoming >/dev/null 2>&1
        ufwc default allow outgoing >/dev/null 2>&1
    fi
    return 0
}

# Открыть порты ноды в UFW без переустановки: SSH, порты схемы, порт ноды для панели
node_ufw_fix() {
    node_state_load || { ui_msg "UFW" "Нода не установлена."; return 1; }
    local ssh st out
    ssh=$(ssh_ports)
    if ! command -v ufw >/dev/null 2>&1; then st="будет установлен и включён"
    elif ufw_active; then st="включён"
    else st="будет включён"; fi
    ui_yesno "Порты ноды в UFW" "SSH:          ${ssh// /, }/tcp для всех
Порты схемы:  $(node_public_ports "$NODE_LAYOUT" | sed 's/ /, /g')/tcp для всех
Порт ноды:    $NODE_PORT/tcp только для $NODE_PANEL_IP
UFW:          $st

SSH разрешается первым — доступ к серверу не пропадёт.

Открыть порты?" || return 1
    ui_loading "Открываю порты…"
    if ! out=$(node_ufw_ensure 2>&1); then
        ui_msg "Ошибка" "Не удалось установить UFW.

$out"
        return 1
    fi
    node_ufw_apply "$NODE_PANEL_IP" "$NODE_PORT" "$NODE_LAYOUT"
    ufw_active || ufwc --force enable >/dev/null 2>&1
    log "node ufw fix: layout=$NODE_LAYOUT panel=$NODE_PANEL_IP port=$NODE_PORT"
    if ufw_active; then
        ui_msg "Готово" "UFW:          включён
SSH:          ${ssh// /, }/tcp для всех
Порты схемы:  $(node_public_ports "$NODE_LAYOUT" | sed 's/ /, /g')/tcp для всех
Порт ноды:    $NODE_PORT/tcp только для $NODE_PANEL_IP"
    else
        ui_msg "Ошибка" "Правила добавлены, но UFW не включился.
Проверьте вручную: ufw status verbose"
        return 1
    fi
}

node_ufw_apply() { # ip порт схема
    command -v ufw >/dev/null 2>&1 || return 0
    [[ $3 == balancer ]] || node_ufw_close_balancer
    ufwc allow 443/tcp comment 'Xray STEAL (SkipIt)' >/dev/null 2>&1
    if [[ ${3:-steal} == balancer ]]; then
        ufwc allow "$NODE_XHTTP_PORT/tcp" comment 'Xray XHTTP (SkipIt)' >/dev/null 2>&1
        ufwc allow "$NODE_WS_PUBLIC/tcp" comment 'nginx WS (SkipIt)' >/dev/null 2>&1
    fi
    ufwc allow proto tcp from "$1" to any port "$2" comment 'Remnawave panel (SkipIt)' >/dev/null 2>&1
}

node_ufw_close_balancer() {
    command -v ufw >/dev/null 2>&1 || return 0
    ufwc --force delete allow "$NODE_XHTTP_PORT/tcp" >/dev/null 2>&1
    ufwc --force delete allow "$NODE_WS_PUBLIC/tcp" >/dev/null 2>&1
}

node_ufw_remove() { # ip порт
    command -v ufw >/dev/null 2>&1 || return 0
    ufwc --force delete allow proto tcp from "$1" to any port "$2" >/dev/null 2>&1
}

node_ensure_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        n_say "Docker не найден — устанавливаю через get.docker.com..."
        local s; s=$(mktemp)
        if ! curl -fsSL --max-time 120 https://get.docker.com -o "$s" || ! sh "$s"; then
            rm -f "$s"; return 1
        fi
        rm -f "$s"
    fi
    systemctl is-active --quiet docker 2>/dev/null || systemctl enable --now docker >/dev/null 2>&1
    if ! docker compose version >/dev/null 2>&1; then
        n_say "Нет docker compose — устанавливаю плагин..."
        pkg_install docker-compose-plugin >/dev/null 2>&1
    fi
    docker info >/dev/null 2>&1 && docker compose version
}

node_nginx_ok() { # → текст ошибки
    local out
    [[ $(ctr_status remnawave-nginx) == running ]] || { echo "контейнер remnawave-nginx не работает"; return 1; }
    out=$(docker exec remnawave-nginx nginx -t 2>&1) || { echo "$out"; return 1; }
    [[ -S $NODE_SOCK ]] || { echo "нет сокета $NODE_SOCK"; return 1; }
}

# Полный конфиг профиля для панели (по рабочему конфигу): вставляется целиком.
# Теги inbound: steal-<префикс>, xhttp-<префикс>, ws-bal-<префикс>; префикс - первая часть домена.
node_tag() { # домен тип(steal|xhttp|ws)
    local n=${1%%.*}
    case $2 in ws) echo "ws-bal-$n" ;; *) echo "$2-$n" ;; esac
}

node_reality_json() { # домен → realitySettings (отступ 8)
cat <<EOF
        "realitySettings": {
          "dest": "$NODE_SOCK",
          "show": false,
          "xver": 2,
          "shortIds": [$(sed 's/[^,]*/"&"/g; s/,/, /g' <<< "$NODE_SID")],
          "privateKey": "$NODE_PRIV",
          "serverNames": ["$1"]
        }
EOF
}

# TCP-параметры сокета для каждого inbound (внутри streamSettings, отступ 8)
node_sockopt_json() {
cat <<'EOF'
        "sockopt": {
          "tcpNoDelay": true,
          "tcpKeepAliveIdle": 30,
          "tcpKeepAliveInterval": 10
        }
EOF
}

node_sniffing_json() {
cat <<'EOF'
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      },
EOF
}

node_profile_json() { # домен схема
cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "dns": {
    "tag": "dns-in",
    "servers": [
      { "address": "1.1.1.1" },
      { "address": "8.8.8.8" }
    ],
    "disableCache": false,
    "queryStrategy": "UseIPv4"
  },
  "inbounds": [
    {
      "tag": "$(node_tag "$1" steal)",
      "port": 443,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
$(node_sniffing_json)
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
$(node_reality_json "$1"),
$(node_sockopt_json)
      }
EOF
if [[ $2 == balancer ]]; then
cat <<EOF
    },
    {
      "tag": "$(node_tag "$1" xhttp)",
      "port": $NODE_XHTTP_PORT,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
$(node_sniffing_json)
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "xhttpSettings": {
          "mode": "auto",
          "path": "$NODE_XHTTP_PATH",
          "extra": {
            "xmux": {
              "cMaxReuseTimes": "50-100",
              "maxConcurrency": "4-8",
              "maxConnections": 0,
              "hKeepAlivePeriod": 0,
              "hMaxRequestTimes": "200-400",
              "hMaxReusableSecs": "20-40"
            },
            "headers": {},
            "noGRPCHeader": false,
            "xPaddingBytes": "100-1000",
            "scMaxEachPostBytes": 262144,
            "scMinPostsIntervalMs": 50,
            "scStreamUpServerSecs": "10-40"
          }
        },
$(node_reality_json "$1"),
$(node_sockopt_json)
      }
    },
    {
      "tag": "$(node_tag "$1" ws)",
      "port": $NODE_WS_PORT,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "host": "$1",
          "path": "$NODE_WS_PATH"
        },
$(node_sockopt_json)
      }
EOF
fi
cat <<'EOF'
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIPv4"
      }
    },
    {
      "tag": "dns-out",
      "protocol": "dns"
    },
    {
      "tag": "BLOCK",
      "protocol": "blackhole",
      "settings": {}
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "inboundTag": ["dns-in"],
        "outboundTag": "direct"
      },
      {
        "port": 53,
        "type": "field",
        "outboundTag": "dns-out"
      },
      {
        "type": "field",
        "protocol": ["bittorrent"],
        "outboundTag": "BLOCK"
      },
      {
        "ip": ["geoip:private"],
        "type": "field",
        "outboundTag": "BLOCK"
      },
      {
        "type": "field",
        "domain": ["geosite:category-ads-all"],
        "outboundTag": "BLOCK"
      }
    ],
    "domainStrategy": "IPIfNonMatch"
  }
}
EOF
}

# Строки экранов-инструкций: текст белый, подписи светло-сиреневые, значения зелёные
g_line() { g_flush; printf '  %s%s%s\n' "$C_TXT" "$1" "$C_RESET" >"$TTY"; }
g_note() { g_flush; printf '  %s i %s %s%s%s\n' "$C_BADGE" "$C_RESET" "$C_NOTE" "$1" "$C_RESET" >"$TTY"; }
g_gap()  { g_flush; echo >"$TTY"; }
# Что делать в панели Remnawave - нумерованными шагами.
# В тексте шага "..." - кнопки и разделы панели (розовые), ⟦...⟧ - что вписать (зелёное).
# Нумерация сквозная в пределах экрана (ui_head сбрасывает): пункт 1, таблица, пункт 2.
G_STEP=0
g_steps() { # шаг ...
    local s
    g_flush
    for s in "$@"; do
        G_STEP=$((G_STEP + 1))
        s=${s//«/$C_BRAND«}; s=${s//»/»$C_RESET$C_TXT}
        s=${s//⟦/$C_OK}; s=${s//⟧/$C_RESET$C_TXT}
        printf '   %s%d.%s %s%s%s\n' "$C_ACC" "$G_STEP" "$C_RESET" "$C_TXT" "$s" "$C_RESET" >"$TTY"
    done
}
# g_panel "Шаблоны" "Xray JSON" "Создать" -> один пункт: раздел в меню слева, [вкладки], "+" справа вверху
g_panel() { # раздел [вкладка ...] кнопка
    local s="В меню слева выберите раздел «$1»" i
    for (( i = 2; i < $#; i++ )); do s+=", откройте вкладку «${!i}»"; done
    g_steps "$s и нажмите «+» справа вверху"
}
# Путь в панели: "Панель -> Хосты -> Создать хост" -> навигация с подсвеченным последним шагом
g_path() {
    local rest=${1%.} part out=""
    while [[ -n $rest ]]; do
        part=${rest%% → *}; [[ $part == "$rest" ]] && rest="" || rest=${rest#* → }
        if [[ -n $rest ]]; then out+="$C_KEY$part$C_RESET $C_DIM›$C_RESET "
        else out+="$C_BRAND$part$C_RESET"; fi
    done
    g_flush; printf '  %s▸%s %s\n' "$C_ACC" "$C_RESET" "$out" >"$TTY"
}
# Строки "ключ - значение" копятся и выводятся рамкой-таблицей перед следующим выводом
G_ROWS=()
g_kv()   { G_ROWS+=("$1"$'\t'"$2"); }
# Цвет значения в таблицах по смыслу; если не распознано - цвет по умолчанию
ui_cell_color() { # значение цвет_по_умолчанию
    local re='^[▰▱]+ ([0-9]+)%'
    if [[ $1 =~ $re ]]; then
        if (( BASH_REMATCH[1] < 60 )); then printf '%s' "$C_OK"
        elif (( BASH_REMATCH[1] < 85 )); then printf '%s' "$C_WARN"
        else printf '%s' "$C_ERR"; fi
        return
    fi
    case $1 in
        да|активен|работает|включён|включена|действует*|разрешить|совпадает|разбан) printf '%s' "$C_OK" ;;
        нет|0|—|выключена) printf '%s' "$C_HINT" ;;
        выключен*|"не установлен"|скоро*|≠*|остановлен) printf '%s' "$C_WARN" ;;
        заблокирован|ОСТАНОВЛЕН|ПЕРЕЗАПУСКАЕТСЯ|истёк|НЕТ|запретить|отклонить|бан) printf '%s' "$C_ERR" ;;
        *) printf '%s' "$2" ;;
    esac
}

# Таблица с колонками: строки "a<TAB>b<TAB>c", первая - заголовок
T_ROWS=()
t_flush() {
    (( ${#T_ROWS[@]} )) || return 0
    local -a w cells; local r i c col line sep top bot
    for r in "${T_ROWS[@]}"; do
        IFS=$'\t' read -ra cells <<< "$r"
        for i in "${!cells[@]}"; do (( ${#cells[$i]} > ${w[$i]:-0} )) && w[$i]=${#cells[$i]}; done
    done
    top="╭"; sep="├"; bot="╰"
    for i in "${!w[@]}"; do
        line=$(printf '─%.0s' $(seq 1 $(( w[i] + 2 ))))
        top+=$line; sep+=$line; bot+=$line
        if (( i < ${#w[@]} - 1 )); then top+="┬"; sep+="┼"; bot+="┴"; fi
    done
    top+="╮"; sep+="┤"; bot+="╯"
    {
        printf '  %s%s%s\n' "$C_DIM" "$top" "$C_RESET"
        local n=0; local -a hdr; IFS=$'\t' read -ra hdr <<< "${T_ROWS[0]}"
        for r in "${T_ROWS[@]}"; do
            IFS=$'\t' read -ra cells <<< "$r"
            line="$C_DIM│$C_RESET"
            for i in "${!w[@]}"; do
                c=${cells[$i]:-}
                if (( n == 0 )); then col=$C_LABEL
                elif [[ ${hdr[$i]:-} == Успешно ]]; then col=$C_OK
                elif [[ ${hdr[$i]:-} == Внимание ]]; then (( ${c:-0} > 0 )) && col=$C_WARN || col=$C_HINT
                elif [[ ${hdr[$i]:-} == Ошибки ]]; then (( ${c:-0} > 0 )) && col=$C_ERR || col=$C_HINT
                elif (( i == 0 )); then col=$C_OK
                else
                    col=$(ui_cell_color "$c" "$C_TXT")
                fi
                line+=" $col$(pad "$c" "${w[$i]}")$C_RESET $C_DIM│$C_RESET"
            done
            printf '  %s\n' "$line"
            (( n == 0 )) && printf '  %s%s%s\n' "$C_DIM" "$sep" "$C_RESET"
            n=$((n + 1))
        done
        printf '  %s%s%s\n' "$C_DIM" "$bot" "$C_RESET"
    } >"$TTY"
    T_ROWS=()
}

g_flush() {
    t_flush
    (( ${#G_ROWS[@]} )) || return 0
    local r k v kw=0 vw=0 hk hv
    for r in "${G_ROWS[@]}"; do
        k=${r%%$'\t'*}; v=${r#*$'\t'}
        (( ${#k} > kw )) && kw=${#k}; (( ${#v} > vw )) && vw=${#v}
    done
    hk=$(printf '─%.0s' $(seq 1 $((kw + 2)))); hv=$(printf '─%.0s' $(seq 1 $((vw + 2))))
    {
        printf '  %s╭%s┬%s╮%s\n' "$C_DIM" "$hk" "$hv" "$C_RESET"
        for r in "${G_ROWS[@]}"; do
            k=${r%%$'\t'*}; v=${r#*$'\t'}
            printf '  %s│%s %s%s%s %s│%s %s%s%s %s│%s\n' "$C_DIM" "$C_RESET" "$C_LABEL" "$(pad "$k" "$kw")" "$C_RESET" \
                "$C_DIM" "$C_RESET" "$(ui_cell_color "$v" "$C_OK")" "$(pad "$v" "$vw")" "$C_RESET" "$C_DIM" "$C_RESET"
        done
        printf '  %s╰%s┴%s╯%s\n' "$C_DIM" "$hk" "$hv" "$C_RESET"
    } >"$TTY"
    G_ROWS=()
}
# Блок для копирования (stdin): между линиями, без рамки по бокам - чтобы копировался чисто
g_code() { g_flush; { ui_rule; printf '%s' "$C_TXT"; sed 's/^/    /'; printf '%s' "$C_RESET"; ui_rule; } >"$TTY"; }
# Доп. параметры XHTTP для хоста: клиентская часть extra из inbound профиля
node_xhttp_extra_json() {
    cat <<'EOF'
{
  "xmux": {
    "cMaxReuseTimes": "50-100",
    "maxConcurrency": "4-8",
    "maxConnections": 0,
    "hKeepAlivePeriod": 0,
    "hMaxRequestTimes": "200-400",
    "hMaxReusableSecs": "20-40"
  },
  "headers": {},
  "noGRPCHeader": false,
  "xPaddingBytes": "100-1000",
  "scMaxEachPostBytes": 262144,
  "scMinPostsIntervalMs": 50
}
EOF
}
# Клиентский шаблон Xray JSON для хоста балансира: leastPing между хостами steal-<имя> и xhttp-<имя>
node_client_template_json() { # имя
    sed "s/__NAME__/$1/g" <<'EOF'
{
  "dns": {
    "hosts": {
      "dns.google": ["8.8.8.8", "8.8.4.4"],
      "cloudflare-dns.com": ["1.1.1.1", "1.0.0.1"]
    },
    "servers": [
      "https://dns.google/dns-query",
      "https://cloudflare-dns.com/dns-query"
    ],
    "queryStrategy": "UseIPv4"
  },
  "routing": {
    "rules": [
      { "type": "field", "inboundTag": ["dns-in"], "balancerTag": "BEST" },
      { "port": 53, "type": "field", "outboundTag": "dns-out" },
      { "type": "field", "protocol": ["bittorrent"], "outboundTag": "block" },
      { "ip": ["::/0"], "type": "field", "outboundTag": "block" },
      {
        "ip": [
          "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
          "172.16.0.0/12", "192.168.0.0/16", "::1/128", "fc00::/7", "fe80::/10"
        ],
        "type": "field",
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "domain": [
          "regexp:[.]ru$", "regexp:[.]su$", "regexp:[.]xn--p1ai$",
          "domain:ipify.org", "domain:checkip.amazonaws.com", "domain:ifconfig.me", "domain:ipapi.is",
          "domain:iplocate.io", "domain:ip.sb", "domain:2ip.ru", "domain:mangalib.me", "domain:animego.me",
          "domain:showip.net", "domain:avtoto.ru", "domain:tilda.cc", "domain:kinescope.io",
          "domain:kinescopecdn.net", "domain:redheadsound.studio", "domain:vtbglobalperspectives.com",
          "domain:vtb-direct.com", "domain:sber.world", "domain:sber.ws", "domain:sbercoin.com",
          "domain:ssb.msk.ru", "domain:vlb100.ru", "domain:slavbank.ru", "domain:prvbank.ru",
          "domain:pvubank.com", "domain:vtb-grants.fut.ru", "domain:selkombank.ru", "domain:ankb.ru",
          "domain:bank-arzamas.ru", "domain:bankermak.ru", "domain:alefbank.com", "domain:forshtadt.ru",
          "domain:bfa.ru", "domain:rkbank.ru", "domain:mvs-bank.ru", "domain:bank-credit-suisse-moscow.ru",
          "domain:ziraatbank.ru", "domain:jpmorgan.ru", "domain:noosferabank.ru", "domain:westernunion.ru",
          "domain:tagbank.ru", "domain:korona.com", "domain:credit-zenit.ru", "domain:zenit-card.ru",
          "domain:autobahn.db.com", "domain:commerzbank.ru", "domain:mizuhogroup.com", "domain:ibamoscow.ru",
          "domain:ubs.com", "domain:smbcr-bank.ru", "domain:yoobusiness.ru", "domain:ru.ccb.com",
          "domain:bank131.com", "domain:asia-pay.ru", "domain:rncoluminis.ru", "domain:government.ru",
          "domain:gov.ru", "domain:gosuslugi.ru", "domain:gu-st.ru", "domain:emias.info", "domain:mgfoms.ru",
          "domain:edu.ru", "domain:cbr.ru", "domain:cikrf.ru", "domain:ebs.ru", "domain:goskey.ru",
          "domain:grfc.ru", "domain:izbirkom.ru", "domain:kremlin.ru", "domain:mil.ru", "domain:nalog.ru",
          "domain:xn--80ajghhoc2aj1c8b.xn--p1ai", "domain:mos.ru", "domain:mosreg.ru", "domain:spb.ru",
          "domain:sevastopol.ru", "domain:sev.ru", "domain:adygeya.ru", "domain:bashkiria.ru",
          "domain:buryatia.ru", "domain:chuvashia.ru", "domain:crimea.ru", "domain:dagestan.ru",
          "domain:grozny.ru", "domain:i-ola.ru", "domain:izhevsk.ru", "domain:kalmykia.ru",
          "domain:karelia.ru", "domain:kazan.ru", "domain:kchr.ru", "domain:khakassia.ru",
          "domain:mari-el.ru", "domain:mari.ru", "domain:mordovia.ru", "domain:nalchik.ru", "domain:ptz.ru",
          "domain:rkomi.ru", "domain:tatarstan.ru", "domain:tuva.ru", "domain:udm.ru", "domain:udmurtia.ru",
          "domain:ulan-ude.ru", "domain:vladikavkaz.ru", "domain:yakutia.ru", "domain:altai.ru",
          "domain:chita.ru", "domain:kamchatka.ru", "domain:khabarovsk.ru", "domain:khv.ru",
          "domain:krasnodar.su", "domain:krasnoyarsk.ru", "domain:kuban.ru", "domain:marine.ru",
          "domain:perm.ru", "domain:stavropol.ru", "domain:stv.ru", "domain:vl.ru", "domain:vladivostok.ru",
          "domain:amur.ru", "domain:arkhangelsk.ru", "domain:astrakhan.ru", "domain:belgorod.ru",
          "domain:bir.ru", "domain:bryansk.ru", "domain:cbg.ru", "domain:chel.ru", "domain:chelyabinsk.ru",
          "domain:ekburg.ru", "domain:xn--80acgfbsl1azdqr.xn--p1ai", "domain:irk.ru", "domain:irkutsk.ru",
          "domain:ivanovo.ru", "domain:jar.ru", "domain:kaluga.ru", "domain:kemerovo.ru", "domain:kirov.ru",
          "domain:koenig.ru", "domain:kostroma.ru", "domain:kurgan.ru", "domain:kursk.ru",
          "domain:lipetsk.ru", "domain:magadan.ru", "domain:murmansk.ru", "domain:nn.ru", "domain:nov.ru",
          "domain:novosibirsk.ru", "domain:nsk.ru", "domain:omsk.ru", "domain:orb.ru", "domain:oryol.ru",
          "domain:penza.ru", "domain:psk", "domain:psk.ru", "domain:pskov.ru", "domain:rnd.ru",
          "domain:ryazan.ru", "domain:sakhalin.ru", "domain:samara.ru", "domain:saratov.ru",
          "domain:simbirsk.ru", "domain:smolensk.ru", "domain:tambov.ru", "domain:tom.ru", "domain:tomsk.ru",
          "domain:tsaritsyn.ru", "domain:tsk.ru", "domain:tula.ru", "domain:tver.ru", "domain:tyumen.ru",
          "domain:vladimir.ru", "domain:vlg.ru", "domain:volgograd.ru", "domain:vologda.ru",
          "domain:voronezh.ru", "domain:vrn.ru", "domain:vyatka.ru", "domain:yaroslavl.ru",
          "domain:yuzhno-sakhalinsk.ru", "domain:chukotka.ru", "domain:jamal.ru", "domain:surgut.ru",
          "domain:yamal.ru", "domain:zdrav10.ru", "domain:1c-bitrix.ru", "domain:1c.ru", "domain:1cfresh.com",
          "domain:1cloud.ru", "domain:1internet.tv", "domain:2gis.ae", "domain:2gis.am", "domain:2gis.az",
          "domain:2gis.by", "domain:2gis.com", "domain:2gis.com.cy", "domain:2gis.cz", "domain:2gis.ge",
          "domain:2gis.kg", "domain:2gis.kz", "domain:2gis.ru", "domain:2gis.tj", "domain:2gis.ua",
          "domain:2gis.uz", "domain:47news.ru", "domain:4meeting.me", "domain:5ka.ru", "domain:5post.market",
          "domain:abr.ru", "domain:aclub.ru", "domain:adfox.ru", "domain:admetrica.ru", "domain:aeroflot.ru",
          "domain:alfa-bank.com", "domain:alfa-bank.ru", "domain:alfa-finance.com", "domain:alfa-fx.com",
          "domain:alfa-pc.com", "domain:alfa-usa.com", "domain:alfabank.com", "domain:alfabank.ru",
          "domain:alfafinance.biz", "domain:alfafinance.ru", "domain:alfafuture.com", "domain:alfafuture.ru",
          "domain:alfafx.com", "domain:alfaleasing.ru", "domain:alfaprivate.com", "domain:alformacap.com",
          "domain:alformacapital.com", "domain:auth-nsdi.ru", "domain:auto.ru", "domain:av.ru",
          "domain:avito.ru", "domain:avito.st", "domain:baltbank.ru", "domain:banka-ui.dev",
          "domain:banki.ru", "domain:bankline.ru", "domain:beeline.ru", "domain:beta-bank.com",
          "domain:bitrix24.ru", "domain:bronevik.com", "domain:cdn-tinkoff.ru", "domain:cdn-vk.ru",
          "domain:chizhik.club", "domain:citydrive.ru", "domain:clstorage.net", "domain:credistory.ru",
          "domain:csat.ru", "domain:cscampus.ru", "domain:dbo-dengi.online", "domain:dellin.ru",
          "domain:dixy.ru", "domain:dnevnik.ru", "domain:dns-shop.ru", "domain:dodopizza.ru", "domain:dom.ru",
          "domain:domclick.ru", "domain:donationalerts.com", "domain:drweb.ru", "domain:dzen.ru",
          "domain:dzeninfra.ru", "domain:e5.ru", "domain:edadeal.io", "domain:edadeal.ru",
          "domain:fastvps.ru", "domain:finuslugi.ru", "domain:fivepost.ru", "domain:fix-price.com",
          "domain:gazeta.ru", "domain:gazprombank.ru", "domain:gazprombank.tech", "domain:gazprompay.ru",
          "domain:gorodpay.ru", "domain:gpb.ru", "domain:gpmdi.ru", "domain:hh.ru", "domain:idx5.ru",
          "domain:imgsmail.ru", "domain:investalfabank.com", "domain:iz.ru", "domain:jivo.ru",
          "domain:jivochat.com", "domain:jivosite.com", "domain:jx5.ru", "domain:kaspersky.com",
          "domain:kaspersky.ru", "domain:kazanexpress.ru", "domain:kinopoisk-ru.clstorage.net",
          "domain:kinopoisk.ru", "domain:kommersant.ru", "domain:kp.ru", "domain:krasyar.ru", "domain:krd.ru",
          "domain:kuper.ru", "domain:lead-pro2023.online", "domain:lemanapro.ru", "domain:lenta.com",
          "domain:lenta.ru", "domain:lmru.tech", "domain:magnit.ru", "domain:mail.ru", "domain:max.ru",
          "domain:megafon.ru", "domain:megamarket.ru", "domain:megamarket.tech", "domain:memealerts.com",
          "domain:mirpayonline.ru", "domain:miya-news.online", "domain:mm.ru", "domain:mnogolososya.ru",
          "domain:moex.com", "domain:mradx.net", "domain:mts.ru", "domain:mtsdengi.ru", "domain:mvk.com",
          "domain:myapelsin.ru", "domain:mycdn.me", "domain:mymts.ru", "domain:naydex.net", "domain:nbki.ru",
          "domain:netmonet.co", "domain:nspk.ru", "domain:ok.ru", "domain:okcdn.ru", "domain:okko.sport",
          "domain:okko.tv", "domain:okolo.app", "domain:oneme.ru", "domain:ozon.ru", "domain:ozone.ru",
          "domain:ozonusercontent.com", "domain:perekrestok.ru", "domain:pochta.ru", "domain:psbank.ru",
          "domain:psblog.ru", "domain:qms.ru", "domain:rambler.ru", "domain:rbc.ru", "domain:res-nsdi.ru",
          "domain:rostaxi.org", "domain:rostelecom.ru", "domain:rshb.ru", "domain:rt.ru", "domain:rtbcdn.ru",
          "domain:russiacalling.com", "domain:rutube.ru", "domain:rutubelist.ru", "domain:rzd-bonus.ru",
          "domain:rzd.ru", "domain:sbermarket.ru", "domain:sbermegamarket.ru", "domain:sbpgpb.ru",
          "domain:sistema-capital.com", "domain:spvb.ru", "domain:static-storage.net", "domain:svoy.academy",
          "domain:t2.ru", "domain:tamtam.chat", "domain:taximaxim.ru", "domain:taxsee.com",
          "domain:tbank-online.com", "domain:tele2.ru", "domain:timeweb.cloud", "domain:timeweb.com",
          "domain:tips.tips", "domain:tnt-online.ru", "domain:tochka-tech.com", "domain:tochka.com",
          "domain:topdelivery.ru", "domain:trbcdn.net", "domain:tsx.x5static.net", "domain:tu-tu.ru",
          "domain:turbopages.org", "domain:tutu.ru", "domain:usedesk.ru", "domain:userapi.com",
          "domain:uxfeedback.ru", "domain:vgtrk.ru", "domain:victoria-group.ru", "domain:vk-analytics.ru",
          "domain:vk-apps.com", "domain:vk-apps.ru", "domain:vk-cdn.me", "domain:vk-cdn.net",
          "domain:vk-portal.net", "domain:vk.cc", "domain:vk.com", "domain:vk.company", "domain:vk.design",
          "domain:vk.link", "domain:vk.me", "domain:vk.ru", "domain:vk.team", "domain:vkcache.com",
          "domain:vkcloud-static.ru", "domain:vkgo.app", "domain:vklive.app", "domain:vkmessenger.app",
          "domain:vkmessenger.com", "domain:vkontakte.ru", "domain:vkuser.net", "domain:vkuseraudio.com",
          "domain:vkuseraudio.net", "domain:vkuseraudio.ru", "domain:vkusercdn.ru", "domain:vkuserlive.net",
          "domain:vkuserphoto.ru", "domain:vkuservideo.com", "domain:vkuservideo.net",
          "domain:vkuservideo.ru", "domain:vkusnoitochka.ru", "domain:vkusvill.ru", "domain:vkvideo.ru",
          "domain:vtb-liga.fut.ru", "domain:vtb-russia.com", "domain:vtb.bank.in", "domain:vtb.com",
          "domain:vtb.corp.ru", "domain:vtb.digital", "domain:vtb.fut.ru", "domain:vtb.promo", "domain:vtb.ru",
          "domain:vtb24.com", "domain:vtb24.ru", "domain:vtbcareer.com", "domain:vtbfamily.ru",
          "domain:vtbindia.com", "domain:vtbkep.site", "domain:vtbpartners.com", "domain:vtbrussia.com",
          "domain:vtbrussia.ru", "domain:vtbstrana.ru", "domain:wb.ru", "domain:webvisor.com",
          "domain:webvisor.org", "domain:whoosh.bike", "domain:wildberries.ru", "domain:wink.ru",
          "domain:x5.ru", "domain:x5.tech", "domain:x5club.ru", "domain:x5id.ru", "domain:x5l.ru",
          "domain:x5paket.ru", "domain:x5q.ru", "domain:xn----7sb7akeedqd.xn--p1ai",
          "domain:xn--80aacoonefzg3am8b1fsb.xn--p1ai", "domain:xn--90ab2c.xn--p1ai",
          "domain:xn--90aifd0aza.site", "domain:xn--b1aew.xn--p1ai", "domain:xn--d1acpjx3f.xn--p1ai",
          "domain:ya.ru", "domain:yads.tech", "domain:yandex", "domain:yandex-bank.net",
          "domain:yandex-images.clstorage.net", "domain:yandex-team.ru", "domain:yandex.aero",
          "domain:yandex.az", "domain:yandex.by", "domain:yandex.cloud", "domain:yandex.co.il",
          "domain:yandex.com", "domain:yandex.com.am", "domain:yandex.com.ge", "domain:yandex.com.ru",
          "domain:yandex.com.tr", "domain:yandex.com.ua", "domain:yandex.de", "domain:yandex.ee",
          "domain:yandex.eu", "domain:yandex.fi", "domain:yandex.fr", "domain:yandex.jobs",
          "domain:yandex.kg", "domain:yandex.kz", "domain:yandex.lt", "domain:yandex.lv", "domain:yandex.md",
          "domain:yandex.net", "domain:yandex.org", "domain:yandex.pl", "domain:yandex.ru",
          "domain:yandex.st", "domain:yandex.sx", "domain:yandex.tj", "domain:yandex.tm", "domain:yandex.tr",
          "domain:yandex.ua", "domain:yandex.uz", "domain:yandexadexchange.net", "domain:yandexcloud.net",
          "domain:yandexcom.net", "domain:yandexmetrica.com", "domain:yandexwebcache.net",
          "domain:yandexwebcache.org", "domain:yastat.net", "domain:yastatic-net.ru", "domain:yastatic.net",
          "domain:yota.ru", "domain:youla-web-static.mrgcdn.ru", "domain:youla.io", "domain:youla.ru",
          "domain:zentotem.net", "domain:hematonix.ru", "domain:medtrum.ru", "domain:medtrum.eu",
          "domain:anytimeru.com", "domain:lumiflex.ru", "domain:ican-sinocare.ru",
          "domain:freestylediabetes.ru", "domain:rsscenter.cloud", "domain:dbankcloud.ru"
        ],
        "outboundTag": "direct"
      },
      { "ip": ["geoip:ru"], "type": "field", "outboundTag": "direct" },
      {
        "type": "field",
        "domain": [
          "domain:telegram.org", "domain:t.me", "domain:telegram.me",
          "domain:tdesktop.com", "domain:telesco.pe", "domain:telegram.dog"
        ],
        "balancerTag": "BEST"
      },
      {
        "ip": [
          "91.108.4.0/22", "91.108.8.0/22", "91.108.12.0/22", "91.108.16.0/22",
          "91.108.56.0/22", "149.154.160.0/20", "185.76.151.0/24"
        ],
        "type": "field",
        "balancerTag": "BEST"
      },
      { "type": "field", "network": "tcp,udp", "balancerTag": "BEST" }
    ],
    "balancers": [
      { "tag": "BEST", "selector": ["proxy"], "strategy": { "type": "leastPing" } }
    ],
    "domainMatcher": "hybrid",
    "domainStrategy": "AsIs"
  },
  "inbounds": [
    {
      "tag": "socks",
      "port": 10808,
      "listen": "127.0.0.1",
      "protocol": "socks",
      "settings": { "udp": true, "auth": "noauth" },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    },
    {
      "tag": "http",
      "port": 10809,
      "listen": "127.0.0.1",
      "protocol": "http",
      "settings": { "allowTransparent": false },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    }
  ],
  "outbounds": [
    { "tag": "dns-out", "protocol": "dns" },
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "remnawave": {
    "injectHosts": [
      {
        "selector": {
          "type": "uuids",
          "values": [
            "UUID хоста steal-__NAME__",
            "UUID хоста xhttp-__NAME__"
          ]
        },
        "tagPrefix": "proxy"
      }
    ]
  },
  "burstObservatory": {
    "pingConfig": {
      "pingConfig": {
        "timeout": "3s",
        "interval": "30s",
        "sampling": 3,
        "destination": "http://www.gstatic.com/generate_204"
      },
      "connectivity": ""
    },
    "subjectSelector": ["proxy"]
  }
}
EOF
}
g_next() { g_flush; printf '\n  %s ' "$(ui_keys "${1:-Enter — дальше · Ctrl+C — выйти}")" >"$TTY"; ui_readline _; }

node_guide() { # домен порт схема [wizard]
    local domain=$1 port=$2 layout=$3 mode=${4:-} name=${1%%.*} saved_ctx=$UI_CTX rc=0
    local total=3 hosts=(STEAL) h n=0 inb
    if [[ $layout == balancer ]]; then
        total=6; hosts=(STEAL XHTTP TPL WS)
        inb="отметьте все три: $(node_tag "$domain" steal), $(node_tag "$domain" xhttp), $(node_tag "$domain" ws)"
    else
        inb="отметьте $(node_tag "$domain" steal)"
    fi
    UI_CTX=""
    ui_ctx_add "Схема" "$(node_layout_ru "$layout")"
    while :; do
        ui_head "Панель · шаг 1 из $total · Профиль"
        g_steps "Откройте панель Remnawave в браузере" \
                "В меню слева, в группе «Управление», выберите «Профили» и нажмите «+» справа вверху" \
                "В поле «Название профиля» впишите ⟦$name⟧ и нажмите «Создать»" \
                "Откройте профиль ⟦$name⟧, удалите весь текст конфига и вставьте вместо него этот:"
        g_gap
        node_profile_json "$domain" "$layout" | g_code
        g_gap
        g_steps "Сохраните профиль"
        g_gap
        g_note "Ключи REALITY, shortId и пути созданы SkipIt, сохранены и не меняются при переустановке."
        g_next || { rc=1; break; }

        ui_head "Панель · шаг 2 из $total · Нода"
        # Xray слушает 443 только после того, как панель подключилась и передала профиль
        if [[ $mode != wizard && -n $(port_listeners 443) ]]; then
            printf '  %s✓ Нода уже подключена к панели%s\n' "$C_OK" "$C_RESET" >"$TTY"
            g_gap
            g_line "Этот шаг пропустите — нода уже создана в панели и работает."
            g_gap
            g_note "Пересоздали ноду в панели? Смените SECRET_KEY: SkipIt → Нода Remnawave → Сменить SECRET_KEY"
            g_next "Enter — пропустить шаг · Ctrl+C — выйти" || { rc=1; break; }
        else
        g_steps "В меню слева нажмите «Ноды» → «Управление», затем «+» справа вверху"
        g_gap
        g_line "Заполните поля:"
        g_kv "Название" "$name"
        g_kv "Адрес" "$domain"
        g_kv "Порт" "$port"
        g_kv "Профиль" "выберите $name (создан на шаге 1)"
        g_kv "Inbounds" "$inb"
        g_gap
        if [[ $mode == wizard ]]; then
            g_steps "Сохраните ноду"
            g_gap
            g_note "SECRET_KEY ноды SkipIt попросит в конце, после шагов с хостами."
        else
            g_steps "Сохраните ноду"
            g_gap
            if [[ -n $(port_listeners 443) ]]; then
                g_note "Нода уже подключена к панели."
            else
                g_note "SECRET_KEY уже записан — нода подключится, когда её создадут в панели."
            fi
        fi
        g_next || { rc=1; break; }
        fi

        for h in "${hosts[@]}"; do
            n=$((n + 1))
            if [[ $h == TPL ]]; then
                ui_head "Панель · шаг $((n + 2)) из $total · Шаблон Xray JSON"
                g_panel "Шаблоны" "Xray JSON" "Создать"
                g_steps "Впишите название ⟦balancer-$name⟧, удалите весь текст в редакторе и вставьте вместо него этот:"
                g_gap
                node_client_template_json "$name" | g_code
                g_gap
                g_steps "Не закрывая шаблон, откройте панель Remnawave в новой вкладке браузера, перейдите в «Управление» → «Хосты» → хост ⟦$(node_tag "$domain" steal)⟧ и скопируйте его UUID" \
                        "В шаблоне, в блоке «values», сотрите текст-заглушку ⟦UUID хоста $(node_tag "$domain" steal)⟧ и вставьте скопированный UUID (кавычки оставьте)" \
                        "Так же скопируйте UUID хоста ⟦$(node_tag "$domain" xhttp)⟧ и вставьте его вместо заглушки ⟦UUID хоста $(node_tag "$domain" xhttp)⟧" \
                        "Сохраните шаблон"
                # Копия JSON в папке ноды. Мастер показывает этот шаг до установки - папки может ещё не быть
                { mkdir -p "$NODE_DIR" && node_client_template_json "$name" > "$NODE_DIR/client-template.json"; } 2>/dev/null
                g_gap
                g_note "Балансир BEST выбирает по пингу между хостами $(node_tag "$domain" steal) и $(node_tag "$domain" xhttp)."
                g_next || { rc=1; break; }
                continue
            fi
            ui_head "Панель · шаг $((n + 2)) из $total · Хост $(node_tag "$domain" "${h,,}")"
            g_steps "В меню слева, в группе «Управление», выберите «Хосты» и нажмите «+» справа вверху"
            g_gap
            g_line "Заполните поля:"
            g_kv "Видимость хоста" "включить"
            g_kv "Примечание" "$(node_tag "$domain" "${h,,}")"
            g_kv "Инбаунд" "$name → $(node_tag "$domain" "${h,,}")"
            g_kv "Адрес" "$domain"
            case $h in
                STEAL) g_kv "Порт" "443" ;;
                XHTTP) g_kv "Порт" "$NODE_XHTTP_PORT" ;;
                WS)    g_kv "Порт" "$NODE_WS_PUBLIC" ;;
            esac
            g_gap
            g_steps "В разделе «Опции» нажмите «Добавить» и добавьте:"
            # В балансире steal и xhttp клиенту не выдаются - их подставляет шаблон balancer-*
            [[ $layout == balancer && $h != WS ]] && g_kv "Скрыть хост" "включить"
            case $h in
                STEAL)
                    g_kv "SNI" "$domain"
                    g_kv "Отпечаток" "firefox" ;;
                XHTTP)
                    g_kv "Путь" "$NODE_XHTTP_PATH"
                    g_kv "SNI" "$domain"
                    g_kv "Отпечаток" "firefox"
                    g_kv "Доп. параметры XHTTP" "вставьте целиком JSON ниже"
                    g_gap
                    node_xhttp_extra_json | g_code ;;
                WS)
                    local ngp; ngp=$(node_nginx_ws_path)
                    if [[ -n $ngp && $ngp != "$NODE_WS_PATH" ]]; then
                        g_flush
                        printf '  %s!%s %sПуть WS в %s — %s, а в профиле — %s. Переустановите ноду, чтобы пути совпали.%s\n' \
                            "$C_WARN" "$C_RESET" "$C_TXT" "$NODE_NGINX" "$ngp" "$NODE_WS_PATH" "$C_RESET" >"$TTY"
                    fi
                    g_kv "Путь" "$NODE_WS_PATH"
                    g_kv "Host" "$domain"
                    g_kv "Security Layer" "TLS"
                    g_kv "SNI" "$domain"
                    g_kv "Отпечаток" "firefox"
                    g_kv "Шаблон Xray JSON" "balancer-$name" ;;
            esac
            g_gap
            g_steps "Сохраните хост"
            if [[ $h == WS ]]; then
                g_gap
                g_note "Хост балансира: сидит на nginx :$NODE_WS_PUBLIC и несёт шаблон balancer-$name."
                g_note "Трафик идёт через $(node_tag "$domain" steal) и $(node_tag "$domain" xhttp) — BEST выбирает по пингу."
            fi
            if [[ $mode == wizard ]]; then
                g_gap
                g_note "Хосты можно создать и после установки ноды."
            fi
            if (( n == ${#hosts[@]} )); then
                if [[ $mode == wizard ]]; then g_next "Enter — продолжить установку"; else g_next "Enter — готово"; fi || rc=1
            else
                g_next || { rc=1; break; }
            fi
        done
        break
    done
    UI_CTX=$saved_ctx
    return $rc
}

node_done_screen() { # домен
    UI_CTX=""
    ui_head "Нода установлена"
    g_kv "Домен" "$1"
    g_kv "Сайт" "https://$1"
    g_kv "Папка" "$NODE_DIR"
    g_gap
    g_line "Что осталось:"
    g_gap
    g_line "1. Создать в панели хосты, если ещё не созданы:"
    g_path "SkipIt → Нода Remnawave → Что создать в панели"
    g_gap
    g_line "2. Проверить связь с панелью:"
    g_path "SkipIt → Нода Remnawave → Диагностика"
    g_gap
    g_note "Xray начинает слушать 443, когда панель подключится к ноде и передаст профиль."
    local a
    printf '\n  %s ' "$(ui_keys "Enter — в меню · d — запустить диагностику")" >"$TTY"
    ui_readline a || return 0
    a=${a,,}; a=${a//[[:space:]]/}
    [[ $a == d || $a == д ]] && node_diag
    return 0
}

# ---- Установка ----
node_install() { UI_CTX=""; _node_install; local rc=$?; UI_CTX=""; return $rc; }

_node_install() {
    local domain panel_ip port secret method="" base="" token="" email="" tpl cert_name="" name d busy
    local old_ip="" old_port="" had_state=0 warn=""
    if node_state_load; then
        had_state=1; old_ip=$NODE_PANEL_IP; old_port=$NODE_PORT
        ui_yesno "Переустановка" "Нода уже установлена: $NODE_DOMAIN

docker-compose.yml, .env и nginx.conf будут перезаписаны (старые — в бэкап).
Ключи REALITY сохранятся — профиль в панели менять не придётся.

Продолжить?" no || return
    else
        NODE_PORT=2222
    fi
    ui_yesno "Установка ноды Remnawave" "── Что понадобится
Домен:       A-запись на IP этого сервера ($SERVER_IP)
IP панели:   сервер с панелью Remnawave
SECRET_KEY:  ключ ноды из панели

ℹ Если домен в Cloudflare — только режим «DNS only» (серое облако).

── Что будет сделано
Программы:   Docker, certbot, сертификат Let's Encrypt
Контейнеры:  remnanode (Xray) и nginx в $NODE_DIR
Трафик:      Xray :443 → unix-сокет → nginx с сайтом-заглушкой
UFW:         порты схемы для всех, порт ноды только для IP панели

Начать?" || return
    ipv6_check_wizard || return

    local layout
    layout=$(ui_choose "Схема ноды" "Схема"$'\t'"Порты"$'\t'"Как работает
Шаблонная"$'\t'"443"$'\t'"selfsteal TCP: Xray на 443, сайт-заглушка через nginx
Балансир"$'\t'"443, $NODE_XHTTP_PORT, $NODE_WS_PUBLIC"$'\t'"selfsteal TCP + XHTTP + WS через nginx, BEST выбирает по пингу

Какую схему установить?" \
        steal    "Шаблонная" \
        balancer "Балансир") || return
    ui_ctx_add "Схема" "$(node_layout_ru "$layout")"

    while :; do
        domain=$(ui_input "Домен ноды" "Он же SNI для REALITY.
Пример:  node1.example.com

Домен, на который подключаются клиенты:" "$NODE_DOMAIN") || return
        domain=${domain//[[:space:]]/}; domain=${domain,,}; domain=${domain%.}
        valid_domain "$domain" && break
        ui_msg "Ошибка" "Некорректный домен: «$domain»"
    done
    node_check_dns "$domain"
    case $? in
        0) ;;
        2) ui_yesno "DNS: прокси Cloudflare" "$DNS_MSG

REALITY через прокси Cloudflare не работает, сертификат HTTP-01 тоже не выпустится.
Переключите запись в режим «DNS only» (серое облако).

Продолжить всё равно?" no || return ;;
        *) ui_yesno "DNS не совпадает" "$DNS_MSG

Если запись только что создана — подождите пару минут.
Без правильной A-записи сертификат HTTP-01 не выпустится.

Продолжить всё равно?" no || return ;;
    esac
    ui_ctx_add "Домен" "$domain"

    while :; do
        panel_ip=$(ui_input "IP панели" "Порт ноды в UFW будет открыт только для него.

IP-адрес сервера с панелью Remnawave:" "$NODE_PANEL_IP") || return
        panel_ip=${panel_ip//[[:space:]]/}
        valid_host_ip "$panel_ip" && break
        ui_msg "Ошибка" "Некорректный IP: «$panel_ip»"
    done
    if [[ $panel_ip == "$SERVER_IP" ]]; then
        ui_yesno "Внимание" "IP панели совпадает с IP этого сервера.
Панель и нода на одном сервере в SkipIt 1.0 не поддерживаются: схемы конфликтуют за порт 443.

Продолжить всё равно?" no || return
    fi

    ui_ctx_add "IP панели" "$panel_ip"

    while :; do
        port=$(ui_input "Порт ноды" "Этот же порт укажите в панели (NODE_PORT).

Порт, на который панель подключается к ноде:" "$NODE_PORT") || return
        port=${port//[[:space:]]/}
        if [[ ! $port =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 || port == 80 || port == 443 )) ||
           [[ $layout == balancer && ( $port == "$NODE_XHTTP_PORT" || $port == "$NODE_WS_PORT" || $port == "$NODE_WS_PUBLIC" ) ]]; then
            ui_msg "Ошибка" "Некорректный порт: «$port» (80, 443$([[ $layout == balancer ]] && echo ", $NODE_XHTTP_PORT, $NODE_WS_PORT, $NODE_WS_PUBLIC") заняты схемой ноды)."; continue
        fi
        busy=$(port_foreign "$port")
        [[ -n $busy ]] && { ui_msg "Порт занят" "Порт $port уже занят:

$busy"; continue; }
        break
    done

    if port_in_ephemeral "$port"; then
        ui_yesno "Порт ноды" "$(port_ephemeral_warning "$port" "нода")" no || return
    fi
    ui_ctx_add "Порт ноды" "$port"

    node_keys_ensure || { ui_msg "Ошибка" "Не удалось сгенерировать ключи REALITY (нужен openssl 1.1.1+)."; return; }
    local have
    have=$(ui_choose "Нода в панели" "SECRET_KEY выдаёт панель, когда вы создаёте в ней ноду.
Для ноды нужен профиль с ключами REALITY — SkipIt их уже сгенерировал." \
        guide "Показать, что создать в панели (3 шага)" \
        ready "Нода уже создана — у меня есть SECRET_KEY") || return
    [[ $have == guide ]] && { node_guide "$domain" "$port" "$layout" wizard || return; }

    while :; do
        secret=$(ui_input "SECRET_KEY" "1. В меню панели слева нажмите «Ноды» → «Управление»
2. Откройте ноду ${domain%%.*} и скопируйте её SECRET_KEY

SECRET_KEY из панели (можно вставить строку «SECRET_KEY=...» целиком):" "$(node_env_get SECRET_KEY)") || return
        secret=$(norm_secret "$secret")
        valid_secret "$secret" && break
        ui_msg "Ошибка" "Это не похоже на SECRET_KEY: ожидается длинная строка без пробелов."
    done

    ui_ctx_add "SECRET_KEY" "$(cf_mask "$secret")"

    # Уже есть подходящий сертификат - предложить его
    for d in /etc/letsencrypt/live/*/; do
        name=$(basename "$d")
        [[ -f $(cert_file "$name") ]] && cert_covers "$name" "$domain" || continue
        (( $(cert_days_left "$name") >= 30 )) || continue
        if ui_yesno "Сертификат уже есть" "Найден действующий сертификат для $domain:
  $name — $(cert_domains "$name")
  осталось $(cert_days_left "$name") дн., способ: $(cert_method_ru "$name")

Использовать его?"; then
            method=reuse; cert_name=$name
        fi
        break
    done

    if [[ -z $method ]]; then
        method=$(ui_choose "SSL-сертификат" "Как выпустить сертификат Let's Encrypt для $domain?" \
            http "HTTP-01 — просто, без токенов (80 порт откроется на время проверки)" \
            cf   "Cloudflare DNS — wildcard *.домен (нужен API-токен)") || return
    fi
    case $method in
        reuse) ui_ctx_add "Сертификат" "существующий ($cert_name)" ;;
        http)  ui_ctx_add "Сертификат" "HTTP-01" ;;
        cf)    ui_ctx_add "Сертификат" "Cloudflare DNS" ;;
    esac
    if [[ $method == http ]]; then
        busy=$(port_listeners 80)
        if [[ -n $busy ]]; then
            ui_msg "Порт 80 занят" "HTTP-01 не сработает — порт 80 занят:

$busy

Освободите порт или выберите способ Cloudflare DNS."
            return
        fi
    fi
    if [[ $method == cf ]]; then
        while :; do
            base=$(ui_input "Зона Cloudflare" "Сертификат будет выпущен на домен и *.домен.

Зона Cloudflare (должна быть в вашем аккаунте):" "$(base_domain "$domain")") || return
            base=${base//[[:space:]]/}; base=${base,,}
            if valid_domain "$base" && [[ $domain == "$base" || $domain == *".$base" ]]; then break; fi
            ui_msg "Ошибка" "«$base» не подходит: $domain должен быть этим доменом или его поддоменом."
        done
        ui_ctx_add "Зона CF" "$base (*.$base)"
        if [[ $domain != "$base" && $domain == *.*".$base" ]]; then
            ui_yesno "Внимание" "Wildcard *.$base не покрывает $domain (поддомен второго уровня).

Продолжить всё равно?" no || return
        fi
        while :; do
            token=$(ui_input "Cloudflare API-токен" "▸ Cloudflare → My Profile → API Tokens → Create Token
Шаблон:          «Edit zone DNS»
Zone Resources:  зона $base
Вставить:        правая кнопка мыши или Ctrl+Shift+V

API-токен Cloudflare:") || return
            token=$(cf_clean_token "$token")
            if (( ${#token} < 20 )); then
                ui_msg "Ошибка" "Токен не вставился или слишком короткий: $(cf_mask "$token").
API-токен Cloudflare — строка примерно из 40 символов."
                continue
            fi
            cf_zone_check "$token" "$base" && break
            ui_yesno "Проверка токена не прошла" "Токен: $(cf_mask "$token")

$CF_ERR

n — ввести токен заново.

Продолжить с этим токеном без проверки?" no && break
        done
        ui_ctx_add "Токен CF" "$(cf_mask "$token")"
    fi
    if [[ $method != reuse ]]; then
        while :; do
            email=$(ui_input "Email для Let's Encrypt" "На него придёт предупреждение, если сертификат не продлится.

Email (можно оставить пустым):") || return
            email=${email//[[:space:]]/}
            [[ -z $email || $email =~ ^[^@]+@[^@]+\.[^@]+$ ]] && break
            ui_msg "Ошибка" "Некорректный email: «$email»"
        done
        ui_ctx_add "Email" "${email:-не указан}"
    fi

    if [[ -f $NODE_WEBROOT/index.html ]]; then tpl=$(site_choose keep "$domain") || return
    else tpl=$(site_choose "" "$domain") || return; fi
    if [[ $tpl == m32:* ]]; then
        if ! m32_fetch; then
            ui_msg "Ошибка" "Не удалось скачать генератор Manual32.

Проверьте ссылку и доступ сервера к manual32.online, затем запустите установку снова."
            return
        fi
    elif [[ $tpl != keep ]] && ! site_fetch; then
        ui_msg "Ошибка" "Не удалось скачать шаблоны с GitHub (codeload.github.com).
Проверьте доступ сервера к GitHub и запустите установку снова."
        return
    fi

    local p
    for p in 443 $([[ $layout == balancer ]] && echo "$NODE_XHTTP_PORT $NODE_WS_PORT $NODE_WS_PUBLIC"); do
        busy=$(port_foreign "$p")
        [[ -n $busy ]] && warn+="
ВНИМАНИЕ: порт $p занят другим процессом — схема не запустится:
$busy
"
    done
    local cert_ru
    case $method in
        reuse) cert_ru="существующий ($cert_name)" ;;
        http)  cert_ru="HTTP-01" ;;
        cf)    cert_ru="Cloudflare DNS, *.$base" ;;
    esac
    UI_CTX=""
    ui_yesno "Подтверждение" "Установить ноду?

  Схема:        $(node_layout_ru "$layout")
  Порты:        $(node_public_ports "$layout" | sed 's/ /, /g')/tcp для всех
  Домен:        $domain
  IP панели:    $panel_ip
  Порт ноды:    $port
  Сертификат:   $cert_ru
  Заглушка:     $(site_title "$tpl")
$([[ -n $(site_external "$tpl") ]] && echo "  Источник:     $(site_external "$tpl")")
  Папка:        $NODE_DIR
$warn" || return

    ui_head "Установка ноды · $domain"
    log "node install: domain=$domain layout=$layout panel=$panel_ip port=$port cert=$method tpl=$tpl"

    node_step "1/6  Docker"
    node_ensure_docker || { node_fail "Не удалось установить или запустить Docker."; return; }

    node_step "2/6  SSL-сертификат"
    if [[ $method != reuse ]]; then
        if ! command -v certbot >/dev/null 2>&1; then
            pkg_install certbot || { node_fail "Не удалось установить certbot."; return; }
        fi
        cert_write_hooks
        if [[ $method == cf ]]; then
            if ! certbot plugins 2>/dev/null | grep -q dns-cloudflare; then
                pkg_install python3-certbot-dns-cloudflare || { node_fail "Не удалось установить плагин certbot для Cloudflare."; return; }
            fi
            mkdir -p "$SKIPIT_ETC"
            ( umask 077; printf 'dns_cloudflare_api_token = %s\n' "$token" > "$CF_CREDS" )
            chmod 600 "$CF_CREDS"
            cert_name=$base
            cert_issue_cf "$base" "$email" || { node_fail "Certbot не смог выпустить сертификат (подробности выше)."; return; }
        else
            cert_name=$domain
            cert_issue_http "$domain" "$email" || { node_fail "Certbot не смог выпустить сертификат (подробности выше). Проверьте A-запись и доступность 80 порта."; return; }
        fi
    else
        cert_write_hooks
    fi
    cert_ensure_renew
    cert_covers "$cert_name" "$domain" || { node_fail "Сертификат $cert_name не подходит для $domain."; return; }
    n_say "Сертификат: /etc/letsencrypt/live/$cert_name — осталось $(cert_days_left "$cert_name") дн."

    node_step "3/6  Сайт-заглушка"
    [[ $had_state == 1 ]] || NODE_TEMPLATE=""
    if [[ $tpl == keep ]]; then
        n_say "Оставлен текущий сайт в $NODE_WEBROOT"
    else
        site_install "$tpl" "$domain" || { node_fail "Не удалось установить шаблон «$(site_title "$tpl")» в $NODE_WEBROOT."; return; }
        n_say "$(site_title "$tpl") → $NODE_WEBROOT${SITE_BAK:+ (прежние файлы: $SITE_BAK)}"
    fi

    node_step "4/6  Файлы ноды"
    mkdir -p "$NODE_DIR" || { node_fail "Не удалось создать $NODE_DIR"; return; }
    local f
    for f in "$NODE_COMPOSE" "$NODE_ENV" "$NODE_NGINX"; do [[ -f $f ]] && backup_file "$f" >/dev/null; done
    NODE_DOMAIN=$domain; NODE_PANEL_IP=$panel_ip; NODE_PORT=$port
    NODE_CERT_METHOD=$method; NODE_CERT_NAME=$cert_name; NODE_TEMPLATE=$tpl; NODE_LAYOUT=$layout
    if [[ -z $NODE_PRIV || -z $NODE_SID ]]; then
        reality_keys || { node_fail "Не удалось сгенерировать ключи REALITY (нужен openssl 1.1.1+)."; return; }
    fi
    node_compose > "$NODE_COMPOSE"
    node_write_env "$secret"
    node_nginx_conf "$domain" "$cert_name" "$layout" > "$NODE_NGINX"
    node_state_save
    n_say "$NODE_COMPOSE, $NODE_ENV, $NODE_NGINX"

    node_step "5/6  UFW"
    if [[ -n $old_ip && ( $old_ip != "$panel_ip" || $old_port != "$port" ) ]]; then
        node_ufw_remove "$old_ip" "$old_port"
    fi
    if ! node_ufw_ensure; then
        n_say "Не удалось установить UFW — порты не ограничены. Настройте фаервол в разделе «Фаервол UFW»."
    else
        node_ufw_apply "$panel_ip" "$port" "$layout"
        if ! ufw_active; then
            ufwc --force enable >/dev/null 2>&1 && log "node: ufw enabled"
        fi
        if ufw_active; then
            n_say "UFW включён."
            n_say "Открыто: SSH $(ssh_ports | sed 's/ /, /g')/tcp; $(node_public_ports "$layout" | sed 's/ /, /g')/tcp для всех; $port/tcp только для $panel_ip"
            [[ $layout == balancer ]] || echo "Порты балансира $NODE_XHTTP_PORT, $NODE_WS_PUBLIC закрыты (схема шаблонная)."
        else
            n_say "Правила добавлены, но UFW не включился — включите его в разделе «Фаервол UFW»."
        fi
    fi

    f2b_sync

    node_step "6/6  Запуск контейнеров"
    node_compose_run pull || { node_fail "Не удалось скачать образы. Проверьте доступ сервера к Docker Hub."; return; }
    node_compose_run up -d --force-recreate --remove-orphans || { node_fail "docker compose up завершился с ошибкой."; return; }
    sleep 4
    local err
    if ! err=$(node_nginx_ok); then
        node_fail "nginx не запустился: $err"; return
    fi
    log "node install: ok"

    node_done_screen "$domain"
}

# ---- Диагностика ----
DIAG=""; DIAG_OK=0; DIAG_WARN=0; DIAG_BAD=0; DIAG_PROBLEMS=""
# Конфиг, с которым сейчас работает Xray ноды: rw-core получает его от remnanode по внутреннему сокету
node_live_config() {
    local pid arg sock path
    pid=$(pgrep -x rw-core 2>/dev/null | head -n 1); [[ -n $pid ]] || return 1
    arg=$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | grep -m 1 '^@') || return 1
    sock=${arg%%:*}; sock=${sock#@}; path=${arg#*:}
    [[ -n $sock && $path == /* ]] || return 1
    nsenter -t "$pid" -n curl -s --max-time 5 --abstract-unix-socket "$sock" "http://localhost$path" 2>/dev/null
}

# Что в профиле панели не совпадает с настройками SkipIt -> "ключ REALITY, путь WS" (пусто - всё совпадает)
# Код 2 - проверить не удалось (Xray не запущен, нет python3)
node_profile_diff() {
    local cfg
    command -v python3 >/dev/null 2>&1 || return 2
    cfg=$(node_live_config) || return 2
    python3 -c '
import json, sys
ws, xh, sid, priv = sys.argv[1:5]
c = json.load(sys.stdin)
c = c.get("response", c)
bad = []
def add(x):
    if x not in bad: bad.append(x)
for i in c.get("inbounds", []):
    s = i.get("streamSettings") or {}
    r = s.get("realitySettings")
    if r:
        if r.get("privateKey") != priv: add("ключ REALITY")
        if set(r.get("shortIds", [])) != set(sid.split(",")): add("shortId")
    if s.get("network") == "xhttp" and (s.get("xhttpSettings") or {}).get("path") != xh: add("путь XHTTP")
    if s.get("network") == "ws" and (s.get("wsSettings") or {}).get("path") != ws: add("путь WS")
print(", ".join(bad))
' "$NODE_WS_PATH" "$NODE_XHTTP_PATH" "$NODE_SID" "$NODE_PRIV" <<< "$cfg" 2>/dev/null || return 2
}

diag_ok()   { DIAG+="  ✓ $*"$'\n'; DIAG_OK=$((DIAG_OK + 1)); }
diag_warn() { DIAG+="  ! $*"$'\n'; DIAG_PROBLEMS+="  ! $*"$'\n'; DIAG_WARN=$((DIAG_WARN + 1)); }
diag_bad()  { DIAG+="  ✗ $*"$'\n'; DIAG_PROBLEMS="  ✗ $*"$'\n'"$DIAG_PROBLEMS"; DIAG_BAD=$((DIAG_BAD + 1)); }

# Итог таблицей, сверху - всё, что требует внимания, ниже - проверки по разделам
diag_show() { # заголовок [дополнение]
    local out
    out="Успешно"$'\t'"Внимание"$'\t'"Ошибки"$'\n'"$DIAG_OK"$'\t'"$DIAG_WARN"$'\t'"$DIAG_BAD"
    [[ -n $DIAG_PROBLEMS ]] && out+=$'\n\n'"── Требует внимания"$'\n'"${DIAG_PROBLEMS%$'\n'}"
    out+=$'\n'"${DIAG%$'\n'}"
    [[ -n ${2:-} ]] && out+=$'\n\n'"$2"
    if [[ ${DIAG_FIX_UFW:-0} == 1 ]]; then
        local a
        ui_head "$1"; ui_body "$out"
        printf '\n  %s ' "$(ui_keys "Enter — назад · u — открыть порты ноды в UFW")" >"$TTY"
        ui_readline a || return 0
        ui_loading
        a=${a,,}; a=${a//[[:space:]]/}
        [[ $a == u || $a == г ]] && node_ufw_fix && node_diag
        return 0
    fi
    ui_msg "$1" "$out"
}
diag_head() { DIAG+=$'\n'"── $*"$'\n'; ui_loading "Проверяю: $*…"; }

node_diag() {
    local v d code restarts installed=0
    DIAG=""; DIAG_OK=0; DIAG_WARN=0; DIAG_BAD=0; DIAG_PROBLEMS=""; DIAG_FIX_UFW=0
    node_installed && installed=1

    diag_head "Сервер"
    v=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
    case $v in
        yes) diag_ok "Время синхронизировано (важно для REALITY)" ;;
        no)  diag_bad "Время НЕ синхронизировано — REALITY отклоняет клиентов при расхождении. Включите: timedatectl set-ntp true" ;;
        *)   diag_warn "Не удалось проверить синхронизацию времени" ;;
    esac
    if ipv6_off || ! ipv6_supported; then
        diag_ok "IPv6 выключен"
    elif ipv6_prefer_v4; then
        diag_ok "IPv4 приоритетнее IPv6 ($GAI_CONF)"
    elif ipv6_broken; then
        diag_bad "IPv6 не работает, а программы пробуют его первым — certbot может зависать.
      Исправление: мастер установки ноды предложит его, или добавьте в $GAI_CONF строку «$GAI_LINE»"
    elif ip -6 route show default 2>/dev/null | grep -q .; then
        diag_ok "IPv6 работает"
    fi
    v=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    [[ $v == bbr ]] && diag_ok "TCP: BBR" || diag_warn "TCP: $v — BBR можно включить в разделе «Ядро Linux»"
    if ! command -v ufw >/dev/null 2>&1; then diag_warn "UFW не установлен"; DIAG_FIX_UFW=$installed
    elif ufw_active; then diag_ok "UFW включён"
    else diag_warn "UFW выключен — порты не ограничены"; DIAG_FIX_UFW=$installed; fi

    diag_head "Docker"
    if ! command -v docker >/dev/null 2>&1; then
        diag_bad "Docker не установлен"
    elif ! docker info >/dev/null 2>&1; then
        diag_bad "Docker установлен, но служба не работает: systemctl start docker"
    else
        diag_ok "Docker $(docker version -f '{{.Server.Version}}' 2>/dev/null) работает"
    fi

    if (( ! installed )); then
        diag_head "Порты для установки ноды"
        v=$(port_listeners 443); [[ -z $v ]] && diag_ok "443 свободен" || diag_bad "443 занят: $(awk '{print $NF}' <<< "$v" | head -n 1)"
        v=$(port_listeners 80);  [[ -z $v ]] && diag_ok "80 свободен (нужен для HTTP-01)" || diag_warn "80 занят — HTTP-01 не сработает, используйте Cloudflare DNS"
        diag_show "Диагностика" "Нода не установлена."
        return
    fi

    diag_head "Контейнеры"
    for v in remnanode remnawave-nginx; do
        case $(ctr_status "$v") in
            running)
                restarts=$(docker inspect -f '{{.RestartCount}}' "$v" 2>/dev/null)
                if (( ${restarts:-0} > 3 )); then diag_warn "$v работает, но перезапускался $restarts раз — смотрите логи"
                else diag_ok "$v работает"; fi ;;
            "") diag_bad "$v не создан — перезапустите контейнеры" ;;
            *)  diag_bad "$v: $(ctr_state_ru "$v") — смотрите логи" ;;
        esac
    done
    if v=$(node_nginx_ok); then diag_ok "nginx: конфигурация верна, сокет $NODE_SOCK есть"
    else diag_bad "nginx: $v"; fi

    diag_head "Домен и сертификат"
    node_check_dns "$NODE_DOMAIN"
    case $? in
        0) diag_ok "DNS: $DNS_MSG" ;;
        3) diag_warn "DNS: $DNS_MSG" ;;
        2) diag_bad "DNS: $DNS_MSG Нужен режим «DNS only»" ;;
        *) diag_bad "DNS: $DNS_MSG" ;;
    esac
    if d=$(cert_days_left "$NODE_CERT_NAME"); then
        if ! cert_covers "$NODE_CERT_NAME" "$NODE_DOMAIN"; then diag_bad "Сертификат $NODE_CERT_NAME не подходит для $NODE_DOMAIN"
        elif (( d < 7 )); then diag_bad "Сертификат истекает через $d дн. — перевыпустите"
        elif (( d < 20 )); then diag_warn "Сертификат: осталось $d дн. (автопродление должно было сработать)"
        else diag_ok "Сертификат: осталось $d дн."; fi
    else
        diag_bad "Сертификат /etc/letsencrypt/live/$NODE_CERT_NAME не найден"
    fi
    cert_renew_scheduled && diag_ok "Автопродление сертификата настроено" || diag_bad "Автопродление сертификата НЕ настроено"

    diag_head "Xray и связь с панелью"
    if [[ -n $(port_listeners 443) ]]; then
        diag_ok "Порт 443 слушается"
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --resolve "$NODE_DOMAIN:443:127.0.0.1" "https://$NODE_DOMAIN/" 2>/dev/null)
        [[ $code == 200 ]] && diag_ok "https://$NODE_DOMAIN через Xray → nginx отдаёт сайт-заглушку" ||
            diag_bad "https://$NODE_DOMAIN через 443 не отвечает (код ${code:-нет}) — проверьте dest и xver в профиле"
    else
        diag_bad "Порт 443 не слушается — Xray не получил конфиг от панели.
      Проверьте: нода создана в панели ($SERVER_IP:$NODE_PORT), SECRET_KEY совпадает,
      ноде назначен профиль с inbound на порт 443."
    fi
    local pdiff
    if pdiff=$(node_profile_diff); then
        if [[ -z $pdiff ]]; then
            diag_ok "Профиль в панели совпадает с настройками SkipIt"
        else
            diag_bad "Профиль в панели устарел — не совпадает: $pdiff. Клиенты не подключатся.
      Вставьте профиль заново: SkipIt → Нода Remnawave → Что создать в панели → шаг 1"
        fi
    fi
    if [[ $NODE_LAYOUT == balancer ]]; then
        if [[ -n $(port_listeners "$NODE_XHTTP_PORT") ]]; then
            code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --resolve "$NODE_DOMAIN:$NODE_XHTTP_PORT:127.0.0.1" "https://$NODE_DOMAIN:$NODE_XHTTP_PORT/" 2>/dev/null)
            [[ $code == 200 ]] && diag_ok "XHTTP :$NODE_XHTTP_PORT слушается, фолбэк → сайт-заглушка" ||
                diag_warn "XHTTP :$NODE_XHTTP_PORT слушается, но фолбэк отвечает кодом ${code:-нет}"
        else
            diag_bad "XHTTP :$NODE_XHTTP_PORT не слушается — в профиле нет inbound $(node_tag "$NODE_DOMAIN" xhttp) или он не включён у ноды"
        fi
        [[ -n $(port_listeners "$NODE_WS_PORT") ]] && diag_ok "WS-inbound Xray слушает 127.0.0.1:$NODE_WS_PORT" ||
            diag_bad "WS-inbound Xray не слушает $NODE_WS_PORT — в профиле нет inbound $(node_tag "$NODE_DOMAIN" ws) или он не включён у ноды"
        if [[ -n $(port_listeners "$NODE_WS_PUBLIC") ]]; then
            code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --resolve "$NODE_DOMAIN:$NODE_WS_PUBLIC:127.0.0.1" "https://$NODE_DOMAIN:$NODE_WS_PUBLIC/" 2>/dev/null)
            [[ $code == 200 ]] && diag_ok "nginx :$NODE_WS_PUBLIC отдаёт сайт-заглушку" || diag_bad "nginx :$NODE_WS_PUBLIC ответил кодом ${code:-нет}"
            code=$(curl -s -o /dev/null -w '%{http_code}' --http1.1 --max-time 5 --resolve "$NODE_DOMAIN:$NODE_WS_PUBLIC:127.0.0.1" \
                -H "Connection: Upgrade" -H "Upgrade: websocket" -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: c2tpcGl0LXNraXBpdC0xMg==" \
                "https://$NODE_DOMAIN:$NODE_WS_PUBLIC$NODE_WS_PATH" 2>/dev/null)
            case $code in
                101) diag_ok "WS $NODE_WS_PATH: nginx → Xray, рукопожатие WebSocket проходит" ;;
                502) diag_bad "WS $NODE_WS_PATH: nginx не достучался до Xray 127.0.0.1:$NODE_WS_PORT (502)" ;;
                404) [[ $pdiff == *"путь WS"* ]] ||
                         diag_warn "WS $NODE_WS_PATH: Xray ответил 404 — путь WS в профиле панели отличается от пути в nginx" ;;
                *)   diag_warn "WS $NODE_WS_PATH: код ${code:-нет} — рукопожатие WebSocket не прошло" ;;
            esac
        else
            diag_bad "nginx не слушает :$NODE_WS_PUBLIC — смотрите логи nginx"
        fi
    fi
    if [[ $NODE_LAYOUT != balancer ]]; then
        if port_listeners "$NODE_WS_PUBLIC" | grep -q '"nginx"'; then
            diag_warn "nginx слушает :$NODE_WS_PUBLIC, хотя схема шаблонная — nginx работает со старым конфигом.
      Исправить: SkipIt → Нода Remnawave → Перезапустить контейнеры"
        fi
        if port_listeners "$NODE_XHTTP_PORT" | grep -qE '"(rw-core|xray)"'; then
            diag_warn "Xray слушает :$NODE_XHTTP_PORT, хотя схема шаблонная — в профиле панели остались inbound балансира.
      Исправить: Панель → Профили конфигурации → профиль ноды (SkipIt → Нода Remnawave → Что создать в панели)"
        fi
    fi
    [[ -n $(port_listeners "$NODE_PORT") ]] && diag_ok "Порт ноды $NODE_PORT слушается" ||
        diag_bad "Порт ноды $NODE_PORT не слушается — смотрите логи remnanode"
    if command -v ufw >/dev/null 2>&1; then
        local miss=() pub=() miss_txt=""
        v=$(ufw_rules)
        for d in $(node_public_ports "$NODE_LAYOUT"); do
            pub+=("$d")
            grep -Eq "^allow $d(/tcp)?( |\$)" <<< "$v" || miss+=("$d")
        done
        if (( ${#miss[@]} )); then miss_txt="${miss[*]}"; miss_txt="${miss_txt// /, }/tcp"; fi
        if ! grep -Fq "from $NODE_PANEL_IP to any port $NODE_PORT" <<< "$v"; then
            miss_txt+="${miss_txt:+; }$NODE_PORT/tcp с $NODE_PANEL_IP"
        fi
        if [[ -n $miss_txt ]]; then
            diag_bad "UFW: нет правил — $miss_txt"; DIAG_FIX_UFW=1
        else
            local pub_txt="${pub[*]}"
            diag_ok "UFW: правила ноды на месте (${pub_txt// /, }/tcp, $NODE_PORT/tcp для панели)"
        fi
    fi

    diag_show "Диагностика: $NODE_DOMAIN"
}

# ---- Управление ----
node_logs() {
    local c
    local hdr v r
    hdr="Контейнер"$'\t'"Состояние"$'\t'"Перезапусков"
    for v in remnanode remnawave-nginx; do
        r=$(docker inspect -f '{{.RestartCount}}' "$v" 2>/dev/null)
        hdr+=$'\n'"$v"$'\t'"$(ctr_state_ru "$v")"$'\t'"${r:-—}"
    done
    c=$(ui_choose "Логи" "$hdr" \
        remnanode       "remnanode — Xray и связь с панелью" \
        remnawave-nginx "nginx — сайт-заглушка и WS балансира") || return
    ui_head "Логи: $c"
    printf '  %sпоследние 200 строк, дальше новые в реальном времени%s\n  %s\n\n' \
        "$C_NOTE" "$C_RESET" "$(ui_keys "Ctrl+C — остановить просмотр")" >"$TTY"
    docker logs --tail 200 -f "$c" 2>&1
    pause
}

node_restart() {
    ui_yesno "Перезапуск ноды" "Перезапустятся:  Xray и сайт-заглушка
Займёт:          5–10 секунд

! Клиенты VPN отключатся и подключатся сами

Перезапустить ноду?" || return
    clear; say "Перезапускаю контейнеры..."
    node_compose_run up -d --remove-orphans && node_compose_run restart
    log "node restart"
    pause
}

node_update() {
    ui_yesno "Обновление ноды" "Проверит:        Remnawave Node (Xray) и nginx
Есть новая:      скачает и перезапустит ноду
Нет новой:       ничего не изменится

! При обновлении клиенты VPN отключатся на 5–10 секунд

Проверить обновления?" || return
    clear; say "Скачиваю образы..."
    local before after
    before=$(docker inspect -f '{{.Image}}' remnanode remnawave-nginx 2>/dev/null)
    node_compose_run pull || { node_fail "Не удалось скачать образы."; return; }
    node_compose_run up -d --remove-orphans || { node_fail "docker compose up завершился с ошибкой."; return; }
    after=$(docker inspect -f '{{.Image}}' remnanode remnawave-nginx 2>/dev/null)
    docker image prune -f >/dev/null 2>&1
    echo
    if [[ $before == "$after" ]]; then say "Обновлений нет — контейнеры не тронуты."
    else say "Образы обновлены, контейнеры пересозданы."; log "node update: images changed"; fi
    pause
}

node_change_secret() {
    local secret
    while :; do
        secret=$(ui_input "Новый SECRET_KEY" "1. В меню панели слева нажмите «Ноды» → «Управление»
2. Откройте ноду ${NODE_DOMAIN%%.*} и скопируйте её SECRET_KEY

! После замены нода перезапустится — клиенты VPN отключатся на 5–10 секунд

SECRET_KEY из панели (можно вставить строку «SECRET_KEY=...» целиком):") || return
        secret=$(norm_secret "$secret")
        valid_secret "$secret" && break
        ui_msg "Ошибка" "Это не похоже на SECRET_KEY: ожидается длинная строка без пробелов."
    done
    backup_file "$NODE_ENV" >/dev/null
    node_write_env "$secret"
    clear; say "Пересоздаю remnanode..."
    node_compose_run up -d --force-recreate remnanode
    log "node secret changed"
    pause
}

node_change_panel() { UI_CTX=""; _node_change_panel; local rc=$?; UI_CTX=""; return $rc; }

_node_change_panel() {
    local ip port busy old_ip=$NODE_PANEL_IP old_port=$NODE_PORT
    while :; do
        ip=$(ui_input "IP панели" "IP-адрес сервера с панелью:" "$NODE_PANEL_IP") || return
        ip=${ip//[[:space:]]/}
        valid_host_ip "$ip" && break
        ui_msg "Ошибка" "Некорректный IP: «$ip»"
    done
    ui_ctx_add "IP панели" "$ip"
    while :; do
        port=$(ui_input "Порт ноды" "Порт, на который панель подключается к ноде:" "$NODE_PORT") || return
        port=${port//[[:space:]]/}
        if [[ ! $port =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 || port == 80 || port == 443 )) ||
           [[ $NODE_LAYOUT == balancer && ( $port == "$NODE_XHTTP_PORT" || $port == "$NODE_WS_PORT" || $port == "$NODE_WS_PUBLIC" ) ]]; then
            ui_msg "Ошибка" "Некорректный порт: «$port» (занят схемой ноды)"; continue
        fi
        if [[ $port != "$old_port" ]]; then
            busy=$(port_listeners "$port")
            [[ -n $busy ]] && { ui_msg "Порт занят" "$busy"; continue; }
            if port_in_ephemeral "$port" && ! ui_yesno "Порт ноды" "$(port_ephemeral_warning "$port" "нода")" no; then continue; fi
        fi
        break
    done
    UI_CTX=""
    [[ $ip == "$old_ip" && $port == "$old_port" ]] && { ui_msg "Без изменений" "Ничего не изменилось."; return; }
    node_ufw_remove "$old_ip" "$old_port"
    NODE_PANEL_IP=$ip; NODE_PORT=$port
    node_ufw_apply "$ip" "$port" "$NODE_LAYOUT"
    node_state_save
    f2b_sync
    if [[ $port != "$old_port" ]]; then
        local secret; secret=$(node_env_get SECRET_KEY)
        backup_file "$NODE_ENV" >/dev/null
        node_write_env "$secret"
        clear; say "Пересоздаю remnanode с портом $port..."
        node_compose_run up -d --force-recreate remnanode
        pause
    fi
    log "node panel: $old_ip:$old_port -> $ip:$port"
    ui_msg "Готово" "IP панели: $ip
Порт ноды: $port
UFW: $port/tcp открыт только для $ip
$([[ $port != "$old_port" ]] && echo "
Не забудьте поменять порт ноды в панели на $port.")"
}

node_change_site() {
    local tpl
    tpl=$(site_choose "" "$NODE_DOMAIN") || return
    ui_loading "Устанавливаю сайт-заглушку…"
    if ! site_install "$tpl" "$NODE_DOMAIN"; then
        ui_msg "Ошибка" "Не удалось установить шаблон «$(site_title "$tpl")».

Mrvibecodic:  проверьте доступ сервера к codeload.github.com
Manual32:     проверьте ссылку и доступ к manual32.online"
        return
    fi
    NODE_TEMPLATE=$tpl; node_state_save
    log "node site: $tpl"
    ui_msg "Готово" "Заглушка: $(site_title "$tpl")
$(site_external "$tpl")${SITE_BAK:+
Прежние файлы сайта: $SITE_BAK}

Проверьте в браузере: https://$NODE_DOMAIN"
}

node_cert() {
    local d c info rc
    d=$(cert_days_left "$NODE_CERT_NAME") || d="—"
    info="Сертификат:  /etc/letsencrypt/live/$NODE_CERT_NAME
Домены:      $(cert_domains "$NODE_CERT_NAME")
Способ:      $(cert_method_ru "$NODE_CERT_NAME")
Действует:   ещё $d дн.
Продление:   $(cert_renew_scheduled && echo "автоматически (certbot), затем перезапуск nginx и remnanode" || echo "НЕ НАСТРОЕНО")"
    c=$(ui_choose "Сертификат" "$info" \
        test  "Проверить автопродление (certbot renew --dry-run)" \
        renew "Перевыпустить сейчас") || return
    [[ $c == renew ]] && { ui_yesno "Перевыпуск" "Принудительно перевыпустить сертификат $NODE_CERT_NAME?
Let's Encrypt ограничивает число выпусков (5 в неделю на один набор доменов)." no || return; }
    command -v certbot >/dev/null 2>&1 || { ui_msg "Ошибка" "certbot не установлен."; return; }
    cert_write_hooks; cert_ensure_renew
    clear
    [[ $(cert_method_ru "$NODE_CERT_NAME") == HTTP-01 ]] && "$ACME_OPEN" force
    if [[ $c == test ]]; then
        certbot renew --dry-run --no-random-sleep-on-renew --cert-name "$NODE_CERT_NAME"; rc=$?
    else
        certbot renew --force-renewal --no-random-sleep-on-renew --cert-name "$NODE_CERT_NAME"; rc=$?
    fi
    "$ACME_CLOSE"
    # Перезапуск nginx и remnanode делает хук $ACME_DEPLOY - certbot запускает его сам после перевыпуска
    log "node cert $c rc=$rc"
    echo
    if (( rc != 0 )); then printf '%s✗ certbot завершился с ошибкой (код %s)%s\n' "$C_ERR" "$rc" "$C_RESET"
    elif [[ $c == renew ]]; then say "Готово. Сертификат перевыпущен, nginx и remnanode перезапущены."
    else say "Готово."; fi
    pause
}

node_nginx_menu() {
    local c bak err
    c=$(ui_choose "nginx.conf" "Файл:   $NODE_NGINX
Схема:  $(node_layout_ru "$NODE_LAYOUT")
nginx:  $(ctr_state_ru remnawave-nginx)" \
        view  "Просмотреть" \
        edit  "Редактировать (nano) — с проверкой nginx -t и откатом") || return
    case $c in
        view) ui_textfile "$NODE_NGINX" "$NODE_NGINX"; return ;;
        edit)
            ensure_pkg nano nano || return
            bak=$(backup_file "$NODE_NGINX")
            clear; nano "$NODE_NGINX"
            if cmp -s "$bak" "$NODE_NGINX"; then rm -f "$bak"; ui_msg "nginx.conf" "Файл не изменён."; return; fi ;;
    esac
    if [[ $(ctr_status remnawave-nginx) != running ]]; then
        log "node nginx $c (backup: $bak)"
        ui_msg "Сохранено" "Файл сохранён, но контейнер nginx не работает — проверить нельзя.
Бэкап: $bak"
        return
    fi
    if ! err=$(docker exec remnawave-nginx nginx -t 2>&1); then
        cat "$bak" > "$NODE_NGINX"
        ui_msg "Ошибка в nginx.conf" "Проверка nginx -t не пройдена — файл возвращён к прежней версии:

$err"
        return
    fi
    docker exec remnawave-nginx nginx -s reload >/dev/null 2>&1
    log "node nginx $c (backup: $bak)"
    ui_msg "Готово" "nginx.conf проверен и применён. Бэкап: $bak"
}

# Пересоздать nginx.conf и docker-compose.yml по шаблону SkipIt (можно сменить схему).
# docker-compose тоже переписывается: у нод, поставленных старой версией, другие
# монтирования сертификатов, и новый nginx.conf без них не запустится.
node_regen_layout() {
    local layout old=$NODE_LAYOUT bak_n bak_c err p busy="" changed=0
    layout=$(ui_choose "Схема ноды" "Сейчас:          $(node_layout_ru "$old")
Пересоздадутся:  nginx.conf и docker-compose.yml
Ручные правки:   пропадут, старые файлы — в бэкап" \
        "$old" "Оставить текущую схему, только пересоздать файлы" \
        "$([[ $old == balancer ]] && echo steal || echo balancer)" \
        "Сменить на: $(node_layout_ru "$([[ $old == balancer ]] && echo steal || echo balancer)")") || return
    [[ $layout != "$old" ]] && changed=1
    if [[ $layout == balancer && $changed == 1 ]]; then
        for p in "$NODE_XHTTP_PORT" "$NODE_WS_PORT" "$NODE_WS_PUBLIC"; do
            [[ -n $(port_foreign "$p") ]] && busy+="  $p: $(port_foreign "$p" | awk '{print $NF}' | head -n 1)"$'\n'
        done
        if [[ -n $busy ]]; then
            ui_msg "Порты заняты" "Для балансира нужны свободные порты:
$busy"
            return
        fi
    fi
    ui_yesno "$( (( changed )) && echo "Смена схемы" || echo "Пересоздание файлов")" "Схема:          $(node_layout_ru "$layout")
Пересоздастся:  контейнер nginx
Если сбой:      файлы и контейнер вернутся к прежним

! Клиенты VPN отключатся на 5–10 секунд

Продолжить?" || return

    bak_n=$(backup_file "$NODE_NGINX"); bak_c=$(backup_file "$NODE_COMPOSE")
    node_gen_paths
    node_compose > "$NODE_COMPOSE"
    node_nginx_conf "$NODE_DOMAIN" "$NODE_CERT_NAME" "$layout" > "$NODE_NGINX"
    clear; say "Пересоздаю контейнер nginx..."
    node_compose_run up -d --force-recreate remnawave-nginx
    sleep 4
    if ! err=$(node_nginx_ok); then
        [[ -n $bak_n ]] && cat "$bak_n" > "$NODE_NGINX"
        [[ -n $bak_c ]] && cat "$bak_c" > "$NODE_COMPOSE"
        say "Откатываю..."
        node_compose_run up -d --force-recreate remnawave-nginx
        log "node regen: FAIL layout=$layout, rolled back"
        ui_msg "nginx не запустился" "Файлы и контейнер возвращены к прежним.

$err

Смотрите логи:
▸ SkipIt → Нода Remnawave → Логи → nginx"
        return
    fi

    [[ $old == balancer && $layout != balancer ]] && node_ufw_close_balancer
    node_ufw_apply "$NODE_PANEL_IP" "$NODE_PORT" "$layout"
    NODE_LAYOUT=$layout; node_state_save
    log "node regen: layout $old -> $layout (backup: $bak_n, $bak_c)"
    if (( changed )); then
        ui_msg "Схема изменена" "Схема: $(node_layout_ru "$layout")
Порты UFW: $(node_public_ports "$layout" | sed 's/ /, /g')/tcp

Теперь обновите панель: профиль (inbounds) и хосты.
Инструкция откроется на следующем экране."
        node_guide "$NODE_DOMAIN" "$NODE_PORT" "$layout"
    else
        ui_msg "Готово" "nginx.conf и docker-compose.yml пересозданы, nginx работает.
Бэкапы:
  $bak_n
  $bak_c"
    fi
}

node_remove() {
    local del_cert=0 del_site=0 del_443=0 bak
    ui_yesno "Удаление ноды" "Будут удалены:
  · контейнеры remnanode и remnawave-nginx
  · папка $NODE_DIR (архив — в $SKIPIT_BACKUPS)
  · правило UFW «$NODE_PORT/tcp с $NODE_PANEL_IP»

Удалить ноду $NODE_DOMAIN?" no || return
    ui_yesno "Сертификат" "Удалить и сертификат $NODE_CERT_NAME?" no && del_cert=1
    ui_yesno "Сайт-заглушка" "Удалить файлы сайта из $NODE_WEBROOT?" no && del_site=1
    ui_yesno "Порты" "Закрыть в UFW публичные порты ноды: $(node_public_ports "$NODE_LAYOUT" | sed 's/ /, /g')/tcp?" no && del_443=1

    clear; say "Удаляю ноду $NODE_DOMAIN..."
    [[ -f $NODE_COMPOSE ]] && node_compose_run down --remove-orphans
    bak="${SKIPIT_BACKUPS}/remnanode-$(date +%Y%m%d-%H%M%S).tar.gz"
    tar -czf "$bak" -C "$(dirname "$NODE_DIR")" "$(basename "$NODE_DIR")" 2>/dev/null && chmod 600 "$bak"
    rm -rf "$NODE_DIR" "$NODE_SOCK"
    node_ufw_remove "$NODE_PANEL_IP" "$NODE_PORT"
    if (( del_443 )) && command -v ufw >/dev/null 2>&1; then
        ufwc --force delete allow 443/tcp >/dev/null 2>&1
        [[ $NODE_LAYOUT == balancer ]] && node_ufw_close_balancer
    fi
    if (( del_cert )); then
        certbot delete --non-interactive --cert-name "$NODE_CERT_NAME"
        [[ $NODE_CERT_METHOD == cf ]] && rm -f "$CF_CREDS"
    fi
    (( del_site )) && find "$NODE_WEBROOT" -mindepth 1 -delete 2>/dev/null
    rm -f "$NODE_STATE" "$NODE_KEYS_FILE"
    f2b_sync
    log "node remove: $NODE_DOMAIN cert=$del_cert site=$del_site ufw443=$del_443 (archive: $bak)"
    NODE_DOMAIN=""; NODE_TEMPLATE=""; NODE_PRIV=""; NODE_PUB=""; NODE_SID=""; NODE_WS_PATH=""; NODE_XHTTP_PATH=""
    echo
    say "Нода удалена. Архив файлов: $bak"
    pause
}

node_menu_label() {
    if node_installed; then echo "Нода Remnawave · $NODE_DOMAIN"; else echo "Установить ноду Remnawave"; fi
}

menu_node() {
    local c hdr
    while :; do
        if ! node_installed; then
            c=$(ui_menu "Нода Remnawave" "Нода не установлена.
Схема: Xray (REALITY) на 443 → unix-сокет → nginx с сайтом-заглушкой." \
                install "Установить ноду" \
                ""      "" \
                diag    "Диагностика сервера") || return
            case $c in
                install) node_install ;;
                diag)    node_diag ;;
            esac
            continue
        fi
        local tab=$'\t'
        hdr="Схема:      $(node_layout_ru "$NODE_LAYOUT")
Домен:      $NODE_DOMAIN
IP панели:  $NODE_PANEL_IP
Порт ноды:  $NODE_PORT

Компонент${tab}Состояние
remnanode${tab}$(ctr_state_ru remnanode)
nginx${tab}$(ctr_state_ru remnawave-nginx)
Сертификат${tab}$(node_cert_state)
UFW${tab}$(if ! command -v ufw >/dev/null 2>&1; then echo "не установлен"; elif ufw_active; then echo "включён"; else echo "выключен"; fi)"
        c=$(ui_menu "Нода Remnawave" "$hdr" \
            ""        "Проверка и панель" \
            diag      "Диагностика" \
            panel     "Что создать в панели (профиль, нода, хост)" \
            ""        "Управление" \
            logs      "Логи" \
            restart   "Перезапустить контейнеры" \
            update    "Обновить образы" \
            ""        "Настройки" \
            secret    "Сменить SECRET_KEY" \
            panelip   "Сменить IP панели / порт ноды" \
            layout    "Сменить схему (шаблонная / балансир)" \
            site      "Сменить сайт-заглушку" \
            cert      "Сертификат: статус, проверка, перевыпуск" \
            nginx     "nginx.conf: просмотр и редактирование" \
            ""        "Опасные действия" \
            reinstall "Переустановить" \
            remove    "Удалить ноду") || return
        case $c in
            diag)      node_diag ;;
            panel)     node_gen_paths; node_guide "$NODE_DOMAIN" "$NODE_PORT" "$NODE_LAYOUT" ;;
            logs)      node_logs ;;
            restart)   node_restart ;;
            update)    node_update ;;
            secret)    node_change_secret ;;
            panelip)   node_change_panel ;;
            layout)    node_regen_layout ;;
            site)      node_change_site ;;
            cert)      node_cert ;;
            nginx)     node_nginx_menu ;;
            reinstall) node_install ;;
            remove)    node_remove ;;
        esac
    done
}

# ==== Главное меню ====
# ==== Нагрузка сервера для главного экрана ====
ru_plural() { # число одна две много
    local n=$(( ${1#-} % 100 )) m
    m=$(( n % 10 ))
    if (( n >= 11 && n <= 14 )); then echo "$4"
    elif (( m == 1 )); then echo "$2"
    elif (( m >= 2 && m <= 4 )); then echo "$3"
    else echo "$4"; fi
}

sys_bar() { # процент [ширина] → «▰▰▰▱▱▱ 42%»
    local p=${1:-0} w=${2:-12} f i s=""
    (( p < 0 )) && p=0; (( p > 100 )) && p=100
    f=$(( (p * w + 50) / 100 ))
    for (( i = 0; i < w; i++ )); do if (( i < f )); then s+="▰"; else s+="▱"; fi; done
    printf '%s %s%%' "$s" "$p"
}

sys_cpu_line() { # загрузка CPU по двум замерам /proc/stat
    local -a a b
    local dt di p=0 cores
    read -ra a < <(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8+$9, $5+$6; exit}' /proc/stat)
    sleep 0.3
    read -ra b < <(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8+$9, $5+$6; exit}' /proc/stat)
    dt=$(( b[0] - a[0] )); di=$(( b[1] - a[1] ))
    (( dt > 0 )) && p=$(( 100 * (dt - di) / dt ))
    cores=$(nproc 2>/dev/null || echo 1)
    echo "$(sys_bar "$p") · $cores $(ru_plural "$cores" ядро ядра ядер)"
}

sys_mem_line() {
    local p u t
    read -r p u t < <(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{u=t-a; printf "%d %.1f %.1f\n", (t>0 ? u*100/t : 0), u/1048576, t/1048576}' /proc/meminfo)
    echo "$(sys_bar "$p") · $u / $t ГБ"
}

sys_disk_line() {
    local p u t
    read -r p u t < <(df -P / 2>/dev/null | awk 'NR==2 {gsub("%","",$5); printf "%d %.0f %.0f\n", $5, $3/1048576, $2/1048576}')
    echo "$(sys_bar "$p") · $u / $t ГБ"
}

sys_load_line() {
    local l1 l2 l3 up d h m
    read -r l1 l2 l3 _ < /proc/loadavg
    up=$(cut -d. -f1 /proc/uptime); d=$(( up / 86400 )); h=$(( up % 86400 / 3600 )); m=$(( up % 3600 / 60 ))
    if (( d > 0 )); then up="$d дн $h ч"; elif (( h > 0 )); then up="$h ч $m мин"; else up="$m мин"; fi
    echo "$l1 $l2 $l3 · работает $up"
}

# ==== fail2ban: /etc/fail2ban/jail.d/skipit.local (перезаписывается целиком) ====
f2b_state_load() {
    F2B_SSH=1; F2B_BANTIME=3600; F2B_FINDTIME=600; F2B_MAXRETRY=5; F2B_RECIDIVE=1
    F2B_PORTSCAN=0; F2B_PS_FINDTIME=600; F2B_PS_MAXRETRY=20; F2B_IGNORE=""
    local k v
    [[ -f $F2B_STATE ]] || return 0
    while IFS='=' read -r k v; do
        case $k in
            F2B_SSH|F2B_BANTIME|F2B_FINDTIME|F2B_MAXRETRY|F2B_RECIDIVE|F2B_PORTSCAN|F2B_PS_FINDTIME|F2B_PS_MAXRETRY|F2B_IGNORE)
                printf -v "$k" '%s' "$v" ;;
        esac
    done < "$F2B_STATE"
}

f2b_state_save() {
    mkdir -p "$SKIPIT_ETC"
    printf 'F2B_SSH=%s\nF2B_BANTIME=%s\nF2B_FINDTIME=%s\nF2B_MAXRETRY=%s\nF2B_RECIDIVE=%s\nF2B_PORTSCAN=%s\nF2B_PS_FINDTIME=%s\nF2B_PS_MAXRETRY=%s\nF2B_IGNORE=%s\n' \
        "${F2B_SSH:-1}" "$F2B_BANTIME" "$F2B_FINDTIME" "$F2B_MAXRETRY" "$F2B_RECIDIVE" "$F2B_PORTSCAN" "$F2B_PS_FINDTIME" "$F2B_PS_MAXRETRY" "$F2B_IGNORE" > "$F2B_STATE"
}

f2b_time_ru() { # секунды → «1 ч»
    local t=$1
    if [[ $t == -1 ]]; then echo "навсегда"
    elif (( t < 3600 )); then echo "$(( t / 60 )) мин"
    elif (( t < 86400 )); then echo "$(( t / 3600 )) ч"
    else echo "$(( t / 86400 )) дн"; fi
}

f2b_state_ru() {
    if ! command -v fail2ban-client >/dev/null 2>&1; then echo "не установлен"
    elif systemctl is-active --quiet fail2ban; then echo "работает"
    else echo "остановлен"; fi
}

f2b_jail_ru() { case $1 in sshd) echo "Подбор паролей SSH" ;; recidive) echo "Повторные нарушители" ;; skipit-portscan) echo "Сканирование портов" ;; *) echo "$1" ;; esac; }

# Атаки на SSH за сутки по журналу sshd
f2b_ssh_attacks() {
    local lines n ips
    lines=$(journalctl _COMM=sshd --since '24 hours ago' -q --no-pager 2>/dev/null |
        grep -E 'Failed password|Invalid user|Connection closed by (authenticating|invalid) user|Disconnected from (authenticating|invalid) user')
    n=$(grep -c . <<< "$lines")
    ips=$(grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' <<< "$lines" | sort -u | grep -c .)
    echo "$n $(ru_plural "$n" попытка попытки попыток) с $ips IP за сутки"
}

# Белый список: "IP<TAB>почему" - добавляется всегда
f2b_auto_ignore() {
    local c
    printf '127.0.0.1/8\tлокальный\n::1\tлокальный\n'
    [[ $SERVER_IP =~ ^[0-9]+(\.[0-9]+){3}$ ]] && printf '%s\tэтот сервер\n' "$SERVER_IP"
    if node_state_load 2>/dev/null && [[ -n $NODE_PANEL_IP ]]; then printf '%s\tпанель Remnawave\n' "$NODE_PANEL_IP"; fi
    c=${SSH_CLIENT%% *}
    [[ -z $c ]] && c=$(who -m 2>/dev/null | grep -oE '\([0-9a-fA-F:.]+\)' | tr -d '()')
    [[ -n $c ]] && printf '%s\tваше SSH-подключение\n' "$c"
    return 0
}

f2b_ignore_list() {
    { f2b_auto_ignore | cut -f1; local ip; for ip in $F2B_IGNORE; do echo "$ip"; done; } | awk 'NF && !s[$0]++' | xargs
}

f2b_render_jail() {
    cat <<EOF
# fail2ban - настройки SkipIt. Файл перезаписывается из меню
# "Защита -> fail2ban", ручные правки будут потеряны.

[DEFAULT]
bantime  = $F2B_BANTIME
findtime = $F2B_FINDTIME
maxretry = $F2B_MAXRETRY
ignoreip = $(f2b_ignore_list)
banaction = nftables-multiport
banaction_allports = nftables-allports

# SSH. На Debian логи sshd только в journald (служба ssh.service, а не sshd.service),
# поэтому backend = systemd и поиск по имени процесса
[sshd]
enabled  = $([[ ${F2B_SSH:-1} == 1 ]] && echo true || echo false)
port     = $(ssh_ports | tr ' ' ',')
backend  = systemd
journalmatch = _COMM=sshd
mode     = aggressive

# Повторные нарушители: попался 3 раза за сутки - бан на неделю на все порты
[recidive]
enabled  = $([[ $F2B_RECIDIVE == 1 ]] && echo true || echo false)
backend  = auto
logpath  = $F2B_LOG
banaction = nftables-allports
bantime  = 1w
findtime = 1d
maxretry = 3

# Сканирование портов: попытки подключиться к закрытым портам (по логам UFW)
[skipit-portscan]
enabled  = $([[ $F2B_PORTSCAN == 1 ]] && echo true || echo false)
filter   = skipit-portscan
backend  = systemd
journalmatch = _TRANSPORT=kernel
banaction = nftables-allports
maxretry = $F2B_PS_MAXRETRY
findtime = $F2B_PS_FINDTIME
EOF
}

f2b_render_filter() {
    cat <<'EOF'
# SkipIt: сканирование портов по логам UFW ([UFW BLOCK] в журнале ядра)
[Definition]
failregex = \[UFW BLOCK\] .*SRC=<HOST>\s
ignoreregex =
EOF
}

f2b_write_files() {
    mkdir -p "$(dirname "$F2B_JAIL")" "$(dirname "$F2B_FILTER")"
    f2b_render_jail > "$F2B_JAIL"
    f2b_render_filter > "$F2B_FILTER"
    chmod 644 "$F2B_JAIL" "$F2B_FILTER"
}

# Записать, проверить fail2ban-client -t, перечитать/запустить -> текст ошибки
f2b_apply() {
    local bak="" err
    if [[ -f $F2B_JAIL ]]; then bak=$(mktemp); cp -a "$F2B_JAIL" "$bak"; fi
    f2b_write_files
    if ! err=$(fail2ban-client -t 2>&1); then
        if [[ -n $bak ]]; then cp -a "$bak" "$F2B_JAIL"; else rm -f "$F2B_JAIL"; fi
        rm -f "$bak"
        printf 'Проверка fail2ban-client -t не пройдена, прежние настройки возвращены.\n\n%s' "$(tail -n 5 <<< "$err")"
        return 1
    fi
    rm -f "$bak"
    systemctl enable fail2ban >/dev/null 2>&1
    if systemctl is-active --quiet fail2ban; then
        err=$(fail2ban-client reload 2>&1) || { printf 'fail2ban не перечитал настройки.\n\n%s' "$(tail -n 5 <<< "$err")"; return 1; }
    else
        systemctl restart fail2ban >/dev/null 2>&1
    fi
    sleep 1
    if ! systemctl is-active --quiet fail2ban; then
        printf 'fail2ban не запустился.\n\n%s' "$(journalctl -u fail2ban -n 5 --no-pager -q 2>/dev/null)"
        return 1
    fi
    return 0
}

# После смены порта SSH - тихо обновить порт в защите
f2b_sync() {
    command -v fail2ban-client >/dev/null 2>&1 && [[ -f $F2B_JAIL ]] || return 0
    f2b_state_load
    f2b_apply >/dev/null 2>&1
    return 0
}

f2b_save_apply() { # итог для сообщения
    local old err
    old=$(cat "$F2B_STATE" 2>/dev/null)
    f2b_state_save
    ui_loading "Применяю настройки…"
    if ! err=$(f2b_apply); then
        if [[ -n $old ]]; then printf '%s\n' "$old" > "$F2B_STATE"; else rm -f "$F2B_STATE"; fi
        f2b_state_load
        ui_msg "Ошибка" "$err"
        return 1
    fi
    log "fail2ban: bantime=$F2B_BANTIME ssh=$F2B_SSH:$F2B_MAXRETRY/$F2B_FINDTIME recidive=$F2B_RECIDIVE portscan=$F2B_PORTSCAN ($F2B_PS_MAXRETRY/$F2B_PS_FINDTIME) ignore=$F2B_IGNORE"
    ui_msg "Готово" "$1"
}

f2b_jails_active() { fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p' | tr -d ','; }

f2b_jail_field() { # jail «Currently banned» | «Total banned» | «Banned IP list»
    fail2ban-client status "$1" 2>/dev/null | awk -v k="$2" 'index($0, k) {sub(/^[^:]*:[ \t]*/, ""); print; exit}'
}

f2b_need_running() {
    systemctl is-active --quiet fail2ban && return 0
    ui_msg "fail2ban" "Состояние:  $(f2b_state_ru)

Запустите fail2ban: «Опасные действия → Запустить fail2ban»."
    return 1
}

f2b_jails_table() {
    local active j st cur tot
    active=" $(f2b_jails_active) "
    printf 'Защита\tСостояние\tЗабанено сейчас\tВсего банов\n'
    for j in sshd recidive skipit-portscan; do
        if [[ $active == *" $j "* ]]; then
            st="включена"; cur=$(f2b_jail_field "$j" "Currently banned"); tot=$(f2b_jail_field "$j" "Total banned")
        else
            st="выключена"; cur="—"; tot="—"
        fi
        printf '%s\t%s\t%s\t%s\n' "$(f2b_jail_ru "$j")" "$st" "${cur:-0}" "${tot:-0}"
    done
}

f2b_install() { local saved_ctx=$UI_CTX; UI_CTX=""; _f2b_install; local rc=$?; UI_CTX=$saved_ctx; return $rc; }

# Мастер установки: каждый параметр - отдельный шаг, рекомендация считается по этому серверу
_f2b_install() {
    local auto out err c n pw ps_ok=0 knocks rec why total step=0 ip bad
    local -a extra
    f2b_state_load
    n=$(journalctl _COMM=sshd --since '24 hours ago' -q --no-pager 2>/dev/null |
        grep -cE 'Failed password|Invalid user|Connection closed by (authenticating|invalid) user|Disconnected from (authenticating|invalid) user')
    pw=$(sshd_eff passwordauthentication)
    if ufw_active && ! ufwc status verbose 2>/dev/null | grep -q '^Logging: off'; then ps_ok=1; fi
    knocks=$(journalctl -k --since '1 hour ago' -q --no-pager 2>/dev/null | grep -c 'UFW BLOCK')
    total=$(( ps_ok ? 5 : 4 ))
    f2b_mark() { [[ $1 == "$rec" ]] && printf ' — рекомендуется'; }

    # 1. Подбор паролей SSH
    if [[ $pw != yes ]]; then
        rec=soft;   why="Вход только по ключу — подобрать пароль нельзя, можно мягче"
    elif (( n >= 100 )); then
        rec=strict; why="Вход по паролю разрешён, а атак много — лучше строже"
    else
        rec=normal; why="Обычная настройка для большинства серверов"
    fi
    step=$((step + 1))
    c=$(ui_choose "fail2ban · шаг $step из $total · Подбор паролей SSH" "Порт SSH:        $(ssh_ports | sed 's/ /, /g')
Вход по паролю:  $([[ $pw == yes ]] && echo разрешён || echo "запрещён, только ключи")
Атаки за сутки:  $n $(ru_plural "$n" попытка попытки попыток)

ℹ $why" \
        soft   "Мягко — 10 попыток за 10 мин$(f2b_mark soft)" \
        normal "Обычно — 5 попыток за 10 мин$(f2b_mark normal)" \
        strict "Строго — 3 попытки за 1 ч$(f2b_mark strict)") || return
    case $c in
        soft)   F2B_MAXRETRY=10; F2B_FINDTIME=600 ;;
        normal) F2B_MAXRETRY=5;  F2B_FINDTIME=600 ;;
        strict) F2B_MAXRETRY=3;  F2B_FINDTIME=3600 ;;
    esac
    ui_ctx_add "Подбор SSH" "$F2B_MAXRETRY $(ru_plural "$F2B_MAXRETRY" попытка попытки попыток) за $(f2b_time_ru "$F2B_FINDTIME")"

    # 2. Время бана
    if (( n >= 1000 )); then
        rec=86400; why="Атак очень много — сутки бана отобьют охоту возвращаться"
    else
        rec=3600;  why="Если по ошибке заблокирует ваш новый IP, бан быстро пройдёт"
    fi
    step=$((step + 1))
    c=$(ui_choose "fail2ban · шаг $step из $total · Время бана" "Атаки за сутки:  $n $(ru_plural "$n" попытка попытки попыток)

ℹ $why" \
        3600   "1 час$(f2b_mark 3600)" \
        86400  "24 часа$(f2b_mark 86400)" \
        604800 "7 дней$(f2b_mark 604800)" \
        -1     "Навсегда$(f2b_mark -1)") || return
    F2B_BANTIME=$c
    ui_ctx_add "Время бана" "$(f2b_time_ru "$F2B_BANTIME")"

    # 3. Повторные нарушители
    rec=1
    step=$((step + 1))
    c=$(ui_choose "fail2ban · шаг $step из $total · Повторные нарушители" "Правило:  попался 3 раза за сутки — бан на неделю

ℹ Боты, которые возвращаются после бана, уйдут надолго" \
        1 "Включить$(f2b_mark 1)" \
        0 "Выключить$(f2b_mark 0)") || return
    F2B_RECIDIVE=$c
    ui_ctx_add "Повторные" "$([[ $F2B_RECIDIVE == 1 ]] && echo включены || echo выключены)"

    # 4. Сканирование портов (нужны логи UFW)
    if (( ps_ok )); then
        if (( knocks >= 200 )); then
            rec=1; why="Сервер активно сканируют — защита уберёт этот шум"
        else
            rec=0; why="Сканов немного — защита не нужна"
        fi
        step=$((step + 1))
        c=$(ui_choose "fail2ban · шаг $step из $total · Сканирование портов" "Стуков в закрытые порты:  $knocks за час
Строгость:                20 попыток за 10 мин

ℹ $why
ℹ VPN-клиентов это не затронет — они подключаются к открытым портам" \
            0 "Выключить$(f2b_mark 0)" \
            1 "Включить$(f2b_mark 1)") || return
        F2B_PORTSCAN=$c
        ui_ctx_add "Сканирование" "$([[ $F2B_PORTSCAN == 1 ]] && echo включено || echo выключено)"
    else
        F2B_PORTSCAN=0
    fi

    # 5. Белый список
    step=$((step + 1))
    while :; do
        ip=$(ui_input "fail2ban · шаг $step из $total · Белый список" "── Добавятся сами
IP	Почему
$(f2b_auto_ignore)

ℹ Добавьте IP, с которых заходите на сервер: дом, офис, другой VPS

Ещё IP или подсети (через пробел, пусто — не добавлять):" "$F2B_IGNORE") || return
        read -ra extra <<< "${ip//,/ }"
        bad=""
        for ip in "${extra[@]}"; do valid_ip_spec "$ip" || bad+="${bad:+, }$ip"; done
        [[ -z $bad ]] && break
        ui_msg "Ошибка" "Некорректный IP:  $bad"
    done
    F2B_IGNORE=$(printf '%s\n' "${extra[@]}" | awk 'NF && !s[$0]++' | xargs)

    # Итог
    auto=$(f2b_ignore_list)
    UI_CTX=""
    ui_yesno "Установка fail2ban" "Пакеты:          fail2ban, python3-systemd
Подбор SSH:      $F2B_MAXRETRY $(ru_plural "$F2B_MAXRETRY" попытка попытки попыток) за $(f2b_time_ru "$F2B_FINDTIME"), порт $(ssh_ports | sed 's/ /, /g')
Время бана:      $(f2b_time_ru "$F2B_BANTIME")
Повторные:       $([[ $F2B_RECIDIVE == 1 ]] && echo "включены, бан на неделю" || echo выключены)
Сканирование:    $( (( ps_ok )) || { echo "недоступно, нет логов UFW"; exit; }; [[ $F2B_PORTSCAN == 1 ]] && echo включено || echo выключено)
Белый список:    $auto

ℹ IP из белого списка никогда не блокируются

Установить?" || return
    f2b_state_save
    # Настройки до установки: иначе пакет запустит fail2ban со стандартным конфигом, который на Debian 12 падает
    f2b_write_files
    ui_loading "Устанавливаю fail2ban…"
    if ! out=$(pkg_install fail2ban python3-systemd 2>&1) || ! command -v fail2ban-client >/dev/null 2>&1; then
        ui_msg "Ошибка" "Не удалось установить fail2ban.

$(tail -n 8 <<< "$out")"
        return
    fi
    ui_loading "Применяю настройки…"
    if ! err=$(f2b_apply); then ui_msg "Ошибка" "$err"; return; fi
    log "fail2ban install"
    ui_msg "Готово" "fail2ban:      работает
Защита SSH:    включена
Белый список:  $auto"
}

f2b_banned_screen() {
    f2b_need_running || return
    local j ip out="" n=0
    for j in $(f2b_jails_active); do
        for ip in $(f2b_jail_field "$j" "Banned IP list"); do
            (( n == 0 )) && out="IP"$'\t'"Защита"
            out+=$'\n'"$ip"$'\t'"$(f2b_jail_ru "$j")"
            n=$((n + 1))
        done
    done
    (( n )) || out="Сейчас никто не заблокирован."
    ui_text "Заблокированные IP" "Всего:  $n

$out"
}

f2b_unban() {
    f2b_need_running || return
    local items=() j ip c n=0 text
    for j in $(f2b_jails_active); do
        for ip in $(f2b_jail_field "$j" "Banned IP list"); do items+=("$ip" "$ip — $(f2b_jail_ru "$j")"); n=$((n + 1)); done
    done
    if (( n )); then text="Заблокировано:  $n

Какой IP разблокировать?"; else text="Сейчас никто не заблокирован."; fi
    items+=("" "" manual "Ввести IP вручную")
    c=$(ui_choose "Разблокировать IP" "$text" "${items[@]}") || return
    if [[ $c == manual ]]; then
        c=$(ui_input "Разблокировать IP" "Пример:  203.0.113.5

IP-адрес:") || return
        c=${c//[[:space:]]/}
    fi
    valid_host_ip "$c" || { ui_msg "Ошибка" "Некорректный IP: «$c»"; return; }
    fail2ban-client unban "$c" >/dev/null 2>&1
    log "fail2ban unban $c"
    ui_msg "Готово" "IP:      $c
Статус:  разблокирован во всех защитах"
}

f2b_ban_manual() {
    f2b_need_running || return
    local ip
    ip=$(ui_input "Заблокировать IP" "Защита:  SSH
Срок:    $(f2b_time_ru "$F2B_BANTIME")
Пример:  203.0.113.5

IP-адрес:") || return
    ip=${ip//[[:space:]]/}
    valid_host_ip "$ip" || { ui_msg "Ошибка" "Некорректный IP: «$ip»"; return; }
    if [[ " $(f2b_ignore_list) " == *" $ip "* ]]; then
        ui_msg "Нельзя заблокировать" "IP:       $ip
Причина:  в белом списке"
        return
    fi
    fail2ban-client set sshd banip "$ip" >/dev/null 2>&1 || { ui_msg "Ошибка" "fail2ban не заблокировал $ip."; return; }
    log "fail2ban ban $ip"
    ui_msg "Готово" "IP:      $ip
Статус:  заблокирован
Срок:    $(f2b_time_ru "$F2B_BANTIME")"
}

f2b_bantime_menu() {
    local c m
    c=$(ui_choose "Время бана" "Сейчас:  $(f2b_time_ru "$F2B_BANTIME")

На сколько блокировать IP?" \
        3600   "1 час" \
        86400  "24 часа" \
        604800 "7 дней" \
        -1     "Навсегда" \
        ""     "" \
        custom "Указать в минутах") || return
    if [[ $c == custom ]]; then
        m=$(ui_input "Время бана" "Сейчас:  $(f2b_time_ru "$F2B_BANTIME")

Время бана в минутах (от 1 до 525600):") || return
        m=${m//[[:space:]]/}
        [[ $m =~ ^[0-9]+$ ]] && (( m >= 1 && m <= 525600 )) || { ui_msg "Ошибка" "Некорректное число минут: «$m»"; return; }
        c=$(( m * 60 ))
    fi
    [[ $c == "$F2B_BANTIME" ]] && { ui_msg "Время бана" "Уже установлено."; return; }
    F2B_BANTIME=$c
    f2b_save_apply "Время бана:  $(f2b_time_ru "$c")"
}

f2b_strict_menu() { # ssh | portscan
    local what=$1 c r f cur_r cur_f title question maxr
    local -a presets
    if [[ $what == portscan ]]; then
        cur_r=$F2B_PS_MAXRETRY; cur_f=$F2B_PS_FINDTIME; title="Сканирование портов"; maxr=1000
        question="Сколько попыток подключиться к закрытым портам разрешить, прежде чем заблокировать IP?"
        presets=(soft "Мягко — 40 попыток за 10 мин" normal "Обычно — 20 попыток за 10 мин" strict "Строго — 10 попыток за 10 мин")
    else
        cur_r=$F2B_MAXRETRY; cur_f=$F2B_FINDTIME; title="Подбор паролей SSH"; maxr=100
        question="Сколько неудачных входов разрешить, прежде чем заблокировать IP?"
        presets=(soft "Мягко — 10 попыток за 10 мин" normal "Обычно — 5 попыток за 10 мин" strict "Строго — 3 попытки за 1 ч")
    fi
    c=$(ui_choose "Строгость · $title" "Сейчас:  $cur_r $(ru_plural "$cur_r" попытка попытки попыток) за $(f2b_time_ru "$cur_f")

$question" \
        "${presets[@]}" \
        ""     "" \
        custom "Указать вручную") || return
    case $what:$c in
        ssh:soft)        r=10; f=600 ;;
        ssh:normal)      r=5;  f=600 ;;
        ssh:strict)      r=3;  f=3600 ;;
        portscan:soft)   r=40; f=600 ;;
        portscan:normal) r=20; f=600 ;;
        portscan:strict) r=10; f=600 ;;
        *:custom)
            r=$(ui_input "Строгость · $title" "Попыток до бана (от 1 до $maxr):" "$cur_r") || return
            r=${r//[[:space:]]/}
            [[ $r =~ ^[0-9]+$ ]] && (( r >= 1 && r <= maxr )) || { ui_msg "Ошибка" "Некорректное число попыток: «$r»"; return; }
            f=$(ui_input "Строгость · $title" "Попыток:  $r

Окно в минутах (от 1 до 1440):" "$(( cur_f / 60 ))") || return
            f=${f//[[:space:]]/}
            [[ $f =~ ^[0-9]+$ ]] && (( f >= 1 && f <= 1440 )) || { ui_msg "Ошибка" "Некорректное число минут: «$f»"; return; }
            f=$(( f * 60 )) ;;
    esac
    [[ $r == "$cur_r" && $f == "$cur_f" ]] && { ui_msg "Строгость" "Уже установлено."; return; }
    if [[ $what == portscan ]]; then F2B_PS_MAXRETRY=$r; F2B_PS_FINDTIME=$f; else F2B_MAXRETRY=$r; F2B_FINDTIME=$f; fi
    f2b_save_apply "Защита:     $title
Строгость:  $r $(ru_plural "$r" попытка попытки попыток) за $(f2b_time_ru "$f")"
}

# Статистика банов защиты: "2 сейчас, 15 всего" или "-"
f2b_jail_stats() {
    if systemctl is-active --quiet fail2ban && [[ " $(f2b_jails_active) " == *" $1 "* ]]; then
        echo "$(f2b_jail_field "$1" "Currently banned") сейчас · $(f2b_jail_field "$1" "Total banned") всего"
    else
        echo "—"
    fi
}

f2b_ssh_menu() {
    local c
    while :; do
        c=$(ui_choose "Подбор паролей SSH" "Состояние:   $([[ $F2B_SSH == 1 ]] && echo включена || echo выключена)
Порт SSH:    $(ssh_ports | sed 's/ /, /g')
Строгость:   $F2B_MAXRETRY $(ru_plural "$F2B_MAXRETRY" попытка попытки попыток) за $(f2b_time_ru "$F2B_FINDTIME")
Время бана:  $(f2b_time_ru "$F2B_BANTIME")
Забанено:    $(f2b_jail_stats sshd)
Атаки:       $(f2b_ssh_attacks)

ℹ Блокирует IP, которые подбирают пароль или перебирают логины по SSH" \
            toggle "$([[ $F2B_SSH == 1 ]] && echo "Выключить защиту" || echo "Включить защиту")" \
            strict "Строгость: попытки и окно") || return
        case $c in
            toggle)
                if [[ $F2B_SSH == 1 ]]; then
                    if [[ $(sshd_eff passwordauthentication) == yes ]]; then
                        ui_yesno "Выключение защиты SSH" "Вход по паролю:  разрешён
Атаки:           $(f2b_ssh_attacks)

! Боты смогут без ограничений подбирать пароль к серверу

Всё равно выключить?" no || continue
                    else
                        ui_yesno "Выключение защиты SSH" "Вход по паролю:  запрещён, только ключи
Атаки:           $(f2b_ssh_attacks)

ℹ Подобрать пароль нельзя, но боты продолжат засорять журнал

Выключить защиту?" || continue
                    fi
                fi
                F2B_SSH=$(( 1 - F2B_SSH ))
                f2b_save_apply "Подбор паролей SSH:  $([[ $F2B_SSH == 1 ]] && echo включена || echo выключена)" ;;
            strict) f2b_strict_menu ssh ;;
        esac
    done
}

f2b_portscan_menu() {
    local c ufw_st knocks
    while :; do
        if ! ufw_active; then ufw_st="выключен"
        elif ufwc status verbose 2>/dev/null | grep -q '^Logging: off'; then ufw_st="включён, логи выключены"
        else ufw_st="включён, логи есть"; fi
        knocks=$(journalctl -k --since '1 hour ago' -q --no-pager 2>/dev/null | grep -c 'UFW BLOCK')
        c=$(ui_choose "Сканирование открытых портов" "Состояние:                $([[ $F2B_PORTSCAN == 1 ]] && echo включена || echo выключена)
Строгость:                $F2B_PS_MAXRETRY $(ru_plural "$F2B_PS_MAXRETRY" попытка попытки попыток) за $(f2b_time_ru "$F2B_PS_FINDTIME")
Время бана:               $(f2b_time_ru "$F2B_BANTIME")
Забанено:                 $(f2b_jail_stats skipit-portscan)
UFW:                      $ufw_st
Стуков в закрытые порты:  $knocks за час

Блокирует IP, которые перебирают порты сервера в поиске открытых сервисов.
VPN-клиенты подключаются только к открытым портам — их это не затрагивает." \
            toggle "$([[ $F2B_PORTSCAN == 1 ]] && echo "Выключить защиту" || echo "Включить защиту")" \
            strict "Строгость: попытки и окно") || return
        case $c in
            toggle)
                if [[ $F2B_PORTSCAN == 0 ]]; then
                    if [[ $ufw_st != "включён, логи есть" ]]; then
                        ui_msg "Сканирование портов" "UFW:  $ufw_st

Эта защита читает логи UFW. Включите UFW и его логи: ufw logging low"
                        continue
                    fi
                    ui_yesno "Сканирование портов" "Сканеры и внешние мониторинги, которые стучатся в закрытые порты, будут заблокированы.
VPN-клиентов это не затронет.

Включить защиту?" || continue
                fi
                F2B_PORTSCAN=$(( 1 - F2B_PORTSCAN ))
                f2b_save_apply "Сканирование портов:  $([[ $F2B_PORTSCAN == 1 ]] && echo включена || echo выключена)" ;;
            strict) f2b_strict_menu portscan ;;
        esac
    done
}

f2b_recidive_menu() {
    local c
    while :; do
        c=$(ui_choose "Повторные нарушители" "Состояние:  $([[ $F2B_RECIDIVE == 1 ]] && echo включена || echo выключена)
Правило:    попался 3 раза за сутки — бан на неделю
Забанено:   $(f2b_jail_stats recidive)

ℹ Боты, которые возвращаются после бана, уйдут надолго" \
            toggle "$([[ $F2B_RECIDIVE == 1 ]] && echo "Выключить защиту" || echo "Включить защиту")") || return
        if [[ $c == toggle ]]; then
            F2B_RECIDIVE=$(( 1 - F2B_RECIDIVE ))
            f2b_save_apply "Повторные нарушители:  $([[ $F2B_RECIDIVE == 1 ]] && echo включена || echo выключена)"
        fi
    done
}

f2b_whitelist_menu() {
    local c text ip items=() nl=$'\n' tab=$'\t'
    while :; do
        text="── Автоматически${nl}IP${tab}Почему${nl}$(f2b_auto_ignore)${nl}${nl}── Добавлены вручную"
        if [[ -n $F2B_IGNORE ]]; then
            text+="${nl}IP${tab}Почему"
            for ip in $F2B_IGNORE; do text+="${nl}${ip}${tab}добавлен вручную"; done
        else
            text+="${nl}Пока нет."
        fi
        text+="${nl}${nl}IP из белого списка никогда не блокируются."
        items=(add "Добавить IP или подсеть")
        [[ -n $F2B_IGNORE ]] && items+=(del "Удалить IP из списка")
        c=$(ui_choose "Белый список" "$text" "${items[@]}") || return
        case $c in
            add)
                ip=$(ui_input "Белый список" "Пример:  203.0.113.5 или 10.0.0.0/8

IP или подсеть:") || continue
                ip=${ip//[[:space:]]/}
                valid_ip_spec "$ip" || { ui_msg "Ошибка" "Некорректный IP: «$ip»"; continue; }
                [[ " $F2B_IGNORE " == *" $ip "* ]] && { ui_msg "Белый список" "$ip уже в списке."; continue; }
                F2B_IGNORE=$(xargs <<< "$F2B_IGNORE $ip")
                f2b_save_apply "Добавлен:  $ip" ;;
            del)
                local del_items=()
                for ip in $F2B_IGNORE; do del_items+=("$ip" "$ip"); done
                ip=$(ui_choose "Удалить из белого списка" "Какой IP удалить?" "${del_items[@]}") || continue
                F2B_IGNORE=$(tr ' ' '\n' <<< "$F2B_IGNORE" | grep -vxF -- "$ip" | xargs)
                f2b_save_apply "Удалён:  $ip" ;;
        esac
    done
}

f2b_log_screen() {
    [[ -r $F2B_LOG ]] || { ui_msg "Последние баны" "Журнал $F2B_LOG пока пуст."; return; }
    local re='^[0-9]{4}-([0-9]{2})-([0-9]{2}) ([0-9]{2}:[0-9]{2}):[0-9]{2}.*\[([^]]+)\] (Ban|Unban) ([^ ]+)'
    local line out="Время"$'\t'"Событие"$'\t'"IP"$'\t'"Защита" n=0
    while IFS= read -r line; do
        [[ $line =~ $re ]] || continue
        out+=$'\n'"${BASH_REMATCH[2]}.${BASH_REMATCH[1]} ${BASH_REMATCH[3]}"$'\t'"$([[ ${BASH_REMATCH[5]} == Ban ]] && echo бан || echo разбан)"$'\t'"${BASH_REMATCH[6]}"$'\t'"$(f2b_jail_ru "${BASH_REMATCH[4]}")"
        n=$((n + 1))
    done < <(grep -E '\] (Ban|Unban) ' "$F2B_LOG" | tail -n 30 | tac)
    (( n )) || out="Банов пока не было."
    ui_text "Последние баны" "Показано:  $n (новые сверху)

$out"
}

f2b_live() {
    [[ -r $F2B_LOG ]] || { ui_msg "Журнал fail2ban" "Журнал $F2B_LOG пока пуст."; return; }
    ui_head "Журнал fail2ban"
    printf '  %sпоследние 30 строк, дальше новые в реальном времени%s\n  %s\n\n' "$C_NOTE" "$C_RESET" "$(ui_keys "Ctrl+C — остановить просмотр")" >"$TTY"
    tail -n 30 -F "$F2B_LOG" 2>/dev/null
    pause
}

f2b_toggle() {
    local err
    if systemctl is-active --quiet fail2ban; then
        ui_yesno "Остановить fail2ban" "Защита SSH перестанет работать, заблокированные IP будут разблокированы.

Остановить fail2ban?" no || return
        systemctl disable --now fail2ban >/dev/null 2>&1
        log "fail2ban stop"
        ui_msg "Готово" "fail2ban:  остановлен"
    else
        ui_loading "Запускаю fail2ban…"
        if ! err=$(f2b_apply); then ui_msg "Ошибка" "$err"; return; fi
        log "fail2ban start"
        ui_msg "Готово" "fail2ban:  работает"
    fi
}

f2b_remove() {
    ui_yesno "Удалить настройки SkipIt" "Файлы:  $F2B_JAIL, $F2B_FILTER
fail2ban будет остановлен и выключен, сам пакет останется.

Удалить настройки?" no || return
    systemctl disable --now fail2ban >/dev/null 2>&1
    rm -f "$F2B_JAIL" "$F2B_FILTER" "$F2B_STATE"
    log "fail2ban remove skipit config"
    ui_msg "Готово" "Настройки SkipIt удалены, fail2ban остановлен."
}

menu_fail2ban() {
    local c hdr
    while :; do
        if ! command -v fail2ban-client >/dev/null 2>&1; then
            c=$(ui_menu "fail2ban" "Состояние:     не установлен
Атаки на SSH:  $(f2b_ssh_attacks)

fail2ban следит за журналами и блокирует IP атакующих:
подбор паролей SSH и сканирование портов." \
                ""      "Установка" \
                install "Установить и включить защиту SSH") || return
            [[ $c == install ]] && f2b_install
            continue
        fi
        f2b_state_load
        hdr="Состояние:     $(f2b_state_ru)
Время бана:    $(f2b_time_ru "$F2B_BANTIME")
Атаки на SSH:  $(f2b_ssh_attacks)"
        [[ -f $F2B_JAIL ]] || hdr+=$'\n\n'"Настройки SkipIt не записаны — выберите «Применить настройки SkipIt заново»."
        systemctl is-active --quiet fail2ban && hdr+=$'\n\n'"$(f2b_jails_table)"
        c=$(ui_menu "fail2ban" "$hdr" \
            ""        "Защиты" \
            ssh       "Подбор паролей SSH" \
            recidive  "Повторные нарушители" \
            portscan  "Сканирование открытых портов" \
            ""        "Баны" \
            banned    "Заблокированные IP" \
            unban     "Разблокировать IP" \
            ban       "Заблокировать IP вручную" \
            ""        "Общие настройки" \
            bantime   "Время бана" \
            whitelist "Белый список" \
            apply     "Применить настройки SkipIt заново" \
            ""        "Журнал" \
            log       "Последние баны" \
            live      "Журнал в реальном времени" \
            ""        "Управление" \
            toggle    "$(systemctl is-active --quiet fail2ban && echo "Остановить fail2ban" || echo "Запустить fail2ban")" \
            remove    "Удалить настройки SkipIt") || return
        case $c in
            ssh)       f2b_ssh_menu ;;
            portscan)  f2b_portscan_menu ;;
            banned)    f2b_banned_screen ;;
            unban)     f2b_unban ;;
            ban)       f2b_ban_manual ;;
            bantime)   f2b_bantime_menu ;;
            recidive)  f2b_recidive_menu ;;
            whitelist) f2b_whitelist_menu ;;
            apply)     f2b_save_apply "Настройки SkipIt применены." ;;
            log)       f2b_log_screen ;;
            live)      f2b_live ;;
            toggle)    f2b_toggle ;;
            remove)    f2b_remove ;;
        esac
    done
}

# Байты -> "160 МБ", "1,2 ГБ"
hsize() {
    awk -v b="${1:-0}" 'BEGIN {
        split("Б КБ МБ ГБ ТБ", u, " "); i = 1
        if (b < 0) b = 0
        while (b >= 1024 && i < 5) { b /= 1024; i++ }
        s = (i <= 2 || b >= 10) ? sprintf("%d %s", b, u[i]) : sprintf("%.1f %s", b, u[i])
        gsub(/\./, ",", s); print s
    }'
}

# "занято 2,8 ГБ из 60 ГБ (5%)" для корневого раздела
disk_usage_ru() {
    local size used
    read -r size used < <(df -B1 --output=size,used / 2>/dev/null | tail -n 1)
    echo "занято $(hsize "$used") из $(hsize "$size") ($(( used * 100 / (size > 0 ? size : 1) ))%)"
}

# ---- Сервис: тест скорости канала - официальный Speedtest CLI от Ookla ----
SPEEDTEST_BIN="/var/cache/skipit/speedtest"
SPEEDTEST_VER="1.2.0"

speedtest_fetch() {
    [[ -x $SPEEDTEST_BIN ]] && return 0
    local arch tmp
    case $(uname -m) in
        x86_64)        arch=x86_64 ;;
        aarch64|arm64) arch=aarch64 ;;
        armv7*|armv8l) arch=armhf ;;
        i?86)          arch=i386 ;;
        *)             return 1 ;;
    esac
    tmp=$(mktemp -d) || return 1
    if curl -fsSL --max-time 60 "https://install.speedtest.net/app/cli/ookla-speedtest-${SPEEDTEST_VER}-linux-${arch}.tgz" -o "$tmp/st.tgz" &&
       tar -xzf "$tmp/st.tgz" -C "$tmp" speedtest 2>/dev/null; then
        mkdir -p "${SPEEDTEST_BIN%/*}" && install -m 0755 "$tmp/speedtest" "$SPEEDTEST_BIN"
    fi
    rm -rf "$tmp"
    [[ -x $SPEEDTEST_BIN ]]
}

# Условия Ookla принимает сам пользователь, один раз. Без согласия тест не запускается.
SPEEDTEST_ACCEPT="${SKIPIT_ETC}/speedtest-license-accepted"
speedtest_consent() {
    [[ -f $SPEEDTEST_ACCEPT ]] && return 0
    ui_yesno "Условия Speedtest" "Программа:  Speedtest CLI от Ookla
Условия:    бесплатно для личного некоммерческого использования

ℹ Лицензия: https://www.speedtest.net/about/eula
ℹ Конфиденциальность: https://www.speedtest.net/about/privacy
ℹ Во время теста Ookla получает IP сервера и результаты замера

Принимаете условия Ookla?" no || return 1
    mkdir -p "$SKIPIT_ETC" && date '+%F %T' > "$SPEEDTEST_ACCEPT"
    log "speedtest: license accepted"
}

# байт/с -> целые Мбит/с
st_mbps() { awk -v b="${1:-0}" 'BEGIN { printf "%d", b * 8 / 1000000 + 0.5 }'; }

sys_speedtest() {
    local out down up ping jitter loss srv isp url verdict
    ui_yesno "Тест скорости канала" "Сервер теста:  ближайший к этому VPS
Займёт:        около 30 секунд

! Тест прокачивает много трафика — до 1 ГБ на быстром канале

ℹ Используется официальный Speedtest CLI от Ookla, скачивается при первом запуске

Запустить тест?" || return
    speedtest_consent || return
    ensure_pkg jq jq || return
    ui_loading "Скачиваю Speedtest CLI…"
    speedtest_fetch || { ui_msg "Ошибка" "Не удалось скачать Speedtest CLI для архитектуры $(uname -m)."; return; }
    ui_loading "Проверяю скорость — около 30 секунд…"
    # Флаги только передают CLI ответ, который пользователь уже дал в speedtest_consent
    out=$("$SPEEDTEST_BIN" --accept-license --accept-gdpr -f json -p no 2>&1)
    if ! jq -e '.download.bandwidth' >/dev/null 2>&1 <<< "$out"; then
        log "speedtest: FAIL $(tail -n 1 <<< "$out")"
        ui_msg "Ошибка" "Тест скорости не удался.

$(tail -n 3 <<< "$out")"
        return
    fi
    down=$(st_mbps "$(jq -r '.download.bandwidth' <<< "$out")")
    up=$(st_mbps "$(jq -r '.upload.bandwidth' <<< "$out")")
    ping=$(jq -r '.ping.latency * 10 | round / 10' <<< "$out" | tr . ,)
    jitter=$(jq -r '.ping.jitter * 10 | round / 10' <<< "$out" | tr . ,)
    loss=$(jq -r 'if .packetLoss == null then "" else (.packetLoss * 10 | round / 10 | tostring) end' <<< "$out" | tr . ,)
    srv=$(jq -r '"\(.server.name), \(.server.location)"' <<< "$out")
    isp=$(jq -r '.isp // "—"' <<< "$out")
    url=$(jq -r '.result.url // ""' <<< "$out")
    if (( down >= 500 && up >= 500 )); then verdict="отлично"
    elif (( down >= 100 && up >= 100 )); then verdict="хорошо"
    else verdict="слабо — клиенты упрутся в скорость"; fi
    [[ -n $loss ]] && loss+="%" || loss="нет данных"
    log "speedtest: down=$down up=$up ping=$ping server=$srv"
    ui_msg "Тест скорости канала" "Скачивание:  $down Мбит/с
Отдача:      $up Мбит/с
Пинг:        $ping мс, джиттер $jitter мс
Потери:      $loss
Сервер:      $srv
Провайдер:   $isp
Для ноды:    $verdict${url:+

ℹ Результат на сайте Speedtest: $url}"
}

# ---- Сервис: очистка диска - только кэши и старые логи, данные не трогаем ----
CLEAN_JOURNAL_KEEP=$((100 * 1024 * 1024))

# Размер в байтах, который можно освободить: apt | journal | docker | logs | cache | tmp
clean_size() {
    local b=0 j
    case $1 in
        apt)
            if [[ $PM == apt ]]; then
                b=$(find /var/cache/apt/archives -type f -name '*.deb' -printf '%s\n' 2>/dev/null | awk '{s+=$1} END {print s+0}')
            else
                b=$(du -sb /var/cache/dnf /var/cache/yum 2>/dev/null | awk '{s+=$1} END {print s+0}')
            fi ;;
        journal)
            j=$(du -sb /var/log/journal 2>/dev/null | cut -f1)
            (( ${j:-0} > CLEAN_JOURNAL_KEEP )) && b=$(( j - CLEAN_JOURNAL_KEEP )) ;;
        docker)
            command -v docker >/dev/null 2>&1 &&
            b=$(docker system df --format '{{.Type}}|{{.Reclaimable}}' 2>/dev/null | awk -F'|' '
                $1 == "Images" || $1 == "Build Cache" {
                    v = $2; sub(/ .*/, "", v)
                    n = v + 0; unit = v; gsub(/[0-9.]/, "", unit)
                    m = 1
                    if (unit ~ /^k/) m = 1e3; else if (unit ~ /^M/) m = 1e6
                    else if (unit ~ /^G/) m = 1e9; else if (unit ~ /^T/) m = 1e12
                    s += n * m
                } END { printf "%d", s }') ;;
        logs)
            b=$(find /var/log -type f \( -name '*.gz' -o -name '*.[0-9]' -o -name '*.old' \) -printf '%s\n' 2>/dev/null | awk '{s+=$1} END {print s+0}') ;;
        cache)
            b=$(du -sb /var/cache/skipit 2>/dev/null | cut -f1) ;;
        tmp)
            b=$(find /tmp -xdev -mindepth 1 -type f -mtime +7 -printf '%s\n' 2>/dev/null | awk '{s+=$1} END {print s+0}') ;;
    esac
    echo "${b:-0}"
}

clean_label() {
    case $1 in
        apt)     echo "Кэш скачанных пакетов" ;;
        journal) echo "Журнал systemd (оставить 100 МБ)" ;;
        docker)  echo "Неиспользуемые образы Docker" ;;
        logs)    echo "Старые архивы логов" ;;
        cache)   echo "Кэш SkipIt (шаблоны, Speedtest)" ;;
        tmp)     echo "Файлы в /tmp старше 7 дней" ;;
    esac
}

sys_disk_clean() {
    local t sel before after freed out="" items=() sz
    ui_loading "Считаю, что можно почистить…"
    for t in apt journal docker logs cache tmp; do
        sz=$(clean_size "$t")
        (( sz >= 1048576 )) && items+=("$t" "$(pad "$(clean_label "$t")" 34) $(hsize "$sz")" OFF)
    done
    if (( ${#items[@]} == 0 )); then
        ui_msg "Очистка диска" "Диск:  $(disk_usage_ru)

ℹ Чистить нечего — кэши и старые логи уже пустые"
        return
    fi
    sel=$(ui_checklist "Очистка диска" "Диск:  $(disk_usage_ru)

ℹ Настройки, сайт и данные ноды не трогаются" "${items[@]}") || return
    [[ -z $sel ]] && return
    before=$(df -B1 --output=avail / 2>/dev/null | tail -n 1)
    for t in $sel; do
        sz=$(clean_size "$t")
        ui_loading "Чищу: $(clean_label "$t")…"
        case $t in
            apt)     if [[ $PM == apt ]]; then apt-get clean >/dev/null 2>&1; else "$PM" clean all >/dev/null 2>&1; fi ;;
            journal) journalctl --vacuum-size=100M >/dev/null 2>&1 ;;
            docker)  docker image prune -af >/dev/null 2>&1; docker builder prune -af >/dev/null 2>&1 ;;
            logs)    find /var/log -type f \( -name '*.gz' -o -name '*.[0-9]' -o -name '*.old' \) -delete 2>/dev/null ;;
            cache)   rm -rf /var/cache/skipit/* 2>/dev/null ;;
            tmp)     find /tmp -xdev -mindepth 1 -type f -mtime +7 -delete 2>/dev/null ;;
        esac
        out+="✓ $(pad "$(clean_label "$t")" 34) $(hsize "$sz")"$'\n'
    done
    after=$(df -B1 --output=avail / 2>/dev/null | tail -n 1)
    freed=$(( after - before ))
    log "disk clean: $(xargs <<< "$sel") freed=$freed"
    ui_msg "Очистка диска" "Освобождено:  $(hsize "$freed")
Диск:         $(disk_usage_ru)

${out%$'\n'}"
}

# ---- Сервер: монитор ресурсов - btop из репозитория, на весь терминал ----
sys_btop() {
    local out
    if ! command -v btop >/dev/null 2>&1; then
        ui_yesno "Монитор ресурсов" "Монитор:    btop — процессор, память, диск, сеть, процессы
Установка:  пакет btop из репозитория системы

ℹ Графики заполняются в течение минуты после запуска
ℹ Выход из монитора — клавиша q

Установить и открыть?" || return
        ui_loading "Устанавливаю btop…"
        if ! out=$(pkg_install btop 2>&1) || ! command -v btop >/dev/null 2>&1; then
            log "pkg install btop: FAIL"
            ui_msg "Ошибка" "Не удалось установить btop — в репозитории этой системы его может не быть.

$(tail -n 4 <<< "$out" | sed 's/^/    /')"
            return
        fi
        log "pkg install btop"
    fi
    # Настоящий терминал сессии (/dev/pts/N), а не /dev/tty: имя "/dev/tty..." btop
    # принимает за консоль Linux и включает упрощённый режим - без 24-битного цвета и фона
    local term
    term=$(ps -o tty= -p $$ 2>/dev/null | tr -d ' ')
    if [[ -n $term && $term != "?" && -c /dev/$term ]]; then term="/dev/$term"; else term=$TTY; fi
    clear >"$TTY"
    btop <"$term" >"$term" 2>&1
    clear >"$TTY"
}

# Проверка IP по регионам: сторонний скрипт ipregion (github.com/vernette/ipregion)
region_check() {
    local grp tmp ipv flags=() v6check=0
    if ! ip -6 route show default 2>/dev/null | grep -q . || ipv6_prefer_v4; then
        flags+=(--ipv4); ipv="только IPv4"
    else
        ipv="IPv4 и IPv6, если IPv6 работает"; v6check=1
    fi
    grp=$(ui_choose "Проверка IP по регионам" "Сервер:    $SERVER_IP
Протокол:  $ipv
Скрипт:    ipregion (github.com/vernette/ipregion)

Показывает, какой страной сервисы и GeoIP-базы считают IP сервера.
Скрипт скачивается при каждом запуске и на сервере ничего не меняет.

Что проверить?" \
        all     "Всё: сервисы и GeoIP-базы" \
        custom  "Сервисы: YouTube, Netflix, ChatGPT, Spotify…" \
        primary "GeoIP-базы: MaxMind, ipinfo, Cloudflare…") || return
    if (( v6check )); then
        ui_loading "Проверяю IPv6…"
        ipv6_broken && flags+=(--ipv4)
    fi
    ensure_pkg jq jq || return
    if ! command -v column >/dev/null 2>&1; then
        ensure_pkg column "$([[ $PM == apt ]] && echo bsdextrautils || echo util-linux)" || return
    fi
    ui_loading "Скачиваю ipregion…"
    tmp=$(mktemp) || return
    if ! { curl -fsSL --max-time 30 https://ipregion.vrnt.xyz -o "$tmp" ||
           curl -fsSL --max-time 30 https://ipregion.mirror.vrnt.xyz -o "$tmp"; } ||
       [[ $(head -c 2 "$tmp") != '#!' ]]; then
        rm -f "$tmp"
        ui_msg "Ошибка" "Не удалось скачать ipregion.

Адрес:    https://ipregion.vrnt.xyz
Зеркало:  https://ipregion.mirror.vrnt.xyz"
        return
    fi
    [[ $grp != all ]] && flags+=(--group "$grp")
    ui_head "Проверка IP по регионам"
    printf '  %s\n\n' "$(ui_keys "Ctrl+C — прервать")" >"$TTY"
    bash "$tmp" "${flags[@]}" <"$TTY" >"$TTY" 2>&1
    rm -f "$tmp"
    log "region check: group=$grp ${flags[*]}"
    printf '\n  %s ' "$(ui_keys "Enter — вернуться в меню")" >"$TTY"
    ui_readline _
}

# ---- Обновление SkipIt с GitHub ----
SKIPIT_UPDATE_URL="https://raw.githubusercontent.com/FrI3nd7/skipit-vps-node/main/skipit.sh"
SKIPIT_UPDATE_CONF="${SKIPIT_ETC}/update.conf"

update_token() { sed -n 's/^SKIPIT_UPDATE_TOKEN=//p' "$SKIPIT_UPDATE_CONF" 2>/dev/null | head -n 1; }

update_token_save() { # токен
    mkdir -p "$SKIPIT_ETC"
    ( umask 077; printf 'SKIPIT_UPDATE_TOKEN=%s\n' "$1" > "$SKIPIT_UPDATE_CONF" )
    chmod 600 "$SKIPIT_UPDATE_CONF"
    log "update: token saved"
}

# Скачать свежий skipit.sh в файл.
# 0 - готово, 1 - нет связи, 2 - нет доступа (приватный репозиторий или неверный токен), 3 - это не SkipIt
update_fetch() { # файл
    local dst=$1 token code
    local -a hdr=()
    token=$(update_token)
    [[ -n $token ]] && hdr=(-H "Authorization: Bearer $token")
    code=$(curl -sSL --max-time 60 "${hdr[@]}" -o "$dst" -w '%{http_code}' "$SKIPIT_UPDATE_URL" 2>/dev/null) || code=000
    case $code in
        200) ;;
        401|403|404) return 2 ;;
        *) return 1 ;;
    esac
    head -n 1 "$dst" | grep -q '^#!.*bash' && grep -q '^SKIPIT_VERSION="' "$dst" && bash -n "$dst" 2>/dev/null || return 3
}

update_version_of() { sed -n 's/^SKIPIT_VERSION="\(.*\)"$/\1/p' "$1" 2>/dev/null | head -n 1; }

# 0, если версия $1 новее $2
version_newer() { [[ $1 != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1) == "$1" ]]; }

# Бэкап текущей версии и замена. Новый файл кладём рядом и переименовываем:
# уже запущенный SkipIt продолжает читать старый файл и не ломается на ходу. Печатает путь бэкапа.
update_apply() { # файл
    local bak="$SKIPIT_BACKUPS/skipit-v${SKIPIT_VERSION}.$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$SKIPIT_BACKUPS"
    [[ -f $SKIPIT_BIN ]] && cp -a "$SKIPIT_BIN" "$bak"
    install -m 0755 "$1" "$SKIPIT_BIN.new" && mv -f "$SKIPIT_BIN.new" "$SKIPIT_BIN" || { rm -f "$SKIPIT_BIN.new"; return 1; }
    log "update: v$SKIPIT_VERSION -> v$(update_version_of "$SKIPIT_BIN")"
    echo "$bak"
}

# Главное меню: SkipIt -> Обновить SkipIt
menu_update() {
    local tmp rc new tok bak
    tmp=$(mktemp) || return
    while :; do
        ui_loading "Проверяю обновления…"
        update_fetch "$tmp"; rc=$?
        (( rc == 2 )) || break
        tok=$(ui_pass "Доступ к репозиторию" "Репозиторий:   FrI3nd7/skipit-vps-node
Ответ GitHub:  нет доступа

ℹ Пока репозиторий приватный, нужен токен GitHub только на чтение
ℹ Токен сохранится на этом сервере, прочитать его сможет только root

Токен GitHub (начинается с github_pat_):") || { rm -f "$tmp"; return; }
        tok=${tok//[[:space:]]/}
        [[ -n $tok ]] || { rm -f "$tmp"; return; }
        update_token_save "$tok"
    done
    case $rc in
        1)  rm -f "$tmp"
            ui_msg "Ошибка" "Не удалось скачать обновление: нет связи с GitHub.

ℹ Проверьте интернет на сервере и попробуйте ещё раз"
            return ;;
        3)  rm -f "$tmp"
            ui_msg "Ошибка" "Скачанный файл не похож на SkipIt или повреждён, обновление отменено.

ℹ Установленная версия не тронута"
            return ;;
    esac
    new=$(update_version_of "$tmp")
    if [[ $new == "$SKIPIT_VERSION" ]]; then
        rm -f "$tmp"
        ui_msg "Обновление SkipIt" "Установлена:  $SKIPIT_VERSION
Доступна:     $new

ℹ У вас последняя версия"
        return
    fi
    if version_newer "$new" "$SKIPIT_VERSION"; then
        ui_yesno "Обновление SkipIt" "Установлена:  $SKIPIT_VERSION
Доступна:     $new

ℹ Настройки SkipIt и ноды не пропадут, старая версия сохранится в бэкап

Обновить SkipIt?" || { rm -f "$tmp"; return; }
    else
        ui_yesno "Обновление SkipIt" "Установлена:    $SKIPIT_VERSION
В репозитории:  $new

! В репозитории версия старее установленной

Всё равно установить $new?" no || { rm -f "$tmp"; return; }
    fi
    if ! bak=$(update_apply "$tmp"); then
        rm -f "$tmp"
        ui_msg "Ошибка" "Не удалось записать $SKIPIT_BIN, установленная версия не тронута."
        return
    fi
    rm -f "$tmp"
    ui_msg "SkipIt обновлён" "Версия:  $new
Бэкап:   $bak

ℹ SkipIt перезапустится с новой версией"
    clear >"$TTY"
    exec "$SKIPIT_BIN"
}

# skipit update [--yes] - текстом, без экранов меню. С --yes работает и без терминала (ssh host 'skipit update --yes')
skipit_update_cli() {
    local yes=0 tmp rc new bak tok a tty=0
    [[ ${1:-} == --yes || ${1:-} == -y ]] && yes=1
    { : >/dev/tty; } 2>/dev/null && tty=1
    (( yes || tty )) || die "Нет терминала. Для обновления без вопросов: ${SKIPIT_CMD} update --yes"
    tmp=$(mktemp) || exit 1
    say "Проверяю обновления..."
    update_fetch "$tmp"; rc=$?
    if (( rc == 2 && ! yes && tty )); then
        printf '\n  Нет доступа к репозиторию FrI3nd7/skipit-vps-node.\n  Токен GitHub только на чтение (ввод скрыт, пусто - отмена): ' >/dev/tty
        read -r -s tok </dev/tty; echo >/dev/tty
        tok=${tok//[[:space:]]/}
        if [[ -n $tok ]]; then update_token_save "$tok"; update_fetch "$tmp"; rc=$?; fi
    fi
    case $rc in
        0) ;;
        2) rm -f "$tmp"; die "Нет доступа к репозиторию. Сохраните токен: ${SKIPIT_CMD} update (без --yes)" ;;
        3) rm -f "$tmp"; die "Скачанный файл не похож на SkipIt, обновление отменено." ;;
        *) rm -f "$tmp"; die "Не удалось скачать обновление: нет связи с GitHub." ;;
    esac
    new=$(update_version_of "$tmp")
    if [[ $new == "$SKIPIT_VERSION" ]]; then
        rm -f "$tmp"; say "Установлена последняя версия: v$new"; return 0
    fi
    if ! version_newer "$new" "$SKIPIT_VERSION"; then
        rm -f "$tmp"; say "В репозитории v$new, это старее установленной v$SKIPIT_VERSION. Ничего не меняю."; return 0
    fi
    if (( ! yes )); then
        printf '\n  Установлена:  v%s\n  Доступна:     v%s\n\n  Обновить? [Y/n] ' "$SKIPIT_VERSION" "$new" >/dev/tty
        read -r a </dev/tty; a=${a,,}; a=${a//[[:space:]]/}
        [[ -z $a || $a == y || $a == yes || $a == д || $a == да ]] || { rm -f "$tmp"; say "Отменено."; return 0; }
    fi
    bak=$(update_apply "$tmp") || { rm -f "$tmp"; die "Не удалось записать $SKIPIT_BIN, установленная версия не тронута."; }
    rm -f "$tmp"
    say "SkipIt обновлён: v$SKIPIT_VERSION -> v$new (бэкап: $bak)"
}

menu_about() {
    ui_dims
    { clear; ui_banner; echo; } >"$TTY"
    ui_body "── Где SkipIt
Команда:  ${SKIPIT_CMD}
Скрипт:   ${SKIPIT_BIN}
Лог:      ${SKIPIT_LOG}
Бэкапы:   ${SKIPIT_BACKUPS}

── Файлы, которые меняет SkipIt
SSH:      ${SSHD_DROPIN}
sysctl:   ${SYSCTL_FILE}
IPv6:     ${IPV6_SYSCTL}
fail2ban: ${F2B_JAIL}
Нода:     ${NODE_DIR}
Сайт:     ${NODE_WEBROOT}
Настройки ноды:  ${NODE_STATE}

── Что использует SkipIt
Нода:            Remnawave Node — github.com/remnawave
Веб-сервер:      nginx (${NODE_NGINX_IMAGE})
Docker:          установщик get.docker.com
Сертификаты:     Let's Encrypt, certbot и плагин Cloudflare
Шаблоны сайтов:  Mrvibecodic (GitHub), Manual32 (manual32.online)
Проверка IP:     ipregion — github.com/vernette/ipregion
Тест скорости:   Speedtest CLI от Ookla
Монитор:         btop
Внешний IP:      api.ipify.org, ifconfig.me
Защита:          UFW, fail2ban"
    printf '\n  %s ' "$(ui_keys "Enter — назад")" >"$TTY"
    ui_readline _
}

main_menu() {
    local c rc ufw_st
    while :; do
        if ! command -v ufw >/dev/null 2>&1; then ufw_st="не установлен"
        elif ufw_active; then ufw_st="включён"; else ufw_st="выключен"; fi
        UI_CANCEL="Выход"; UI_BANNER=1
        UI_FOOTER=$'\n'"  ${C_HINT}запуск в любой момент: ${C_ACC}${SKIPIT_CMD}${C_RESET}"
        c=$(ui_menu "" "сервер     $(hostname) · $SERVER_IP
система    $OS_NAME · $VIRT
статус     SSH $(ssh_ports) · UFW $ufw_st · fail2ban $(f2b_state_ru) · TCP $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
сеть       IPv6 $(ipv6_state_ru)

процессор  $(sys_cpu_line)
память     $(sys_mem_line)
диск       $(sys_disk_line)
нагрузка   $(sys_load_line)" \
            ""      "Remnawave" \
            node    "$(node_menu_label)" \
            ""      "Защита" \
            users   "SSH и пользователи" \
            ufw     "Фаервол UFW" \
            f2b     "fail2ban" \
            ""      "Сервер" \
            kernel  "Ядро Linux — sysctl, BBR" \
            ipv6    "IPv6 — включить, выключить, основной протокол" \
            upgrade "Обновление сервера — пакеты системы" \
            monitor "Монитор ресурсов (btop)" \
            ""      "Сервис" \
            regions "Проверка IP по регионам (ipregion)" \
            speed   "Тест скорости канала" \
            clean   "Очистка диска" \
            ""      "SkipIt" \
            update  "Обновить SkipIt" \
            about   "О программе")
        rc=$?
        UI_CANCEL="Назад"; UI_FOOTER=""; UI_BANNER=0
        (( rc != 0 )) && return
        case $c in
            node)   menu_node ;;
            users)  menu_users ;;
            ufw)    menu_ufw ;;
            f2b)    menu_fail2ban ;;
            kernel) menu_kernel ;;
            ipv6)   menu_ipv6 ;;
            upgrade) menu_sys_upgrade ;;
            monitor) sys_btop ;;
            regions) region_check ;;
            speed)   sys_speedtest ;;
            clean)   sys_disk_clean ;;
            update) menu_update ;;
            about)  menu_about ;;
        esac
    done
}

# Один SkipIt на сервер. Если он уже открыт в другом окне - закрываем тот
# (вместе с его дочерними процессами: они держат тот же lock-файл) и занимаем место.
lock_holders() {
    local f pid
    for f in /proc/[0-9]*/fd/*; do
        [[ $(readlink "$f" 2>/dev/null) == "$SKIPIT_LOCK" ]] || continue
        pid=${f#/proc/}; pid=${pid%%/*}
        [[ $pid == "$$" ]] || printf '%s\n' "$pid"
    done | sort -u
}

lock_take() {
    exec 9>>"$SKIPIT_LOCK"
    flock -n 9 && return 0
    exec 9>&-   # чтобы наши подпроцессы не попали в список держателей
    say "SkipIt уже открыт в другом окне — закрываю его..."
    local pids; pids=$(lock_holders)
    [[ -n $pids ]] && kill -TERM $pids 2>/dev/null
    exec 9>>"$SKIPIT_LOCK"
    if ! flock -w 5 9; then
        exec 9>&-
        pids=$(lock_holders)
        [[ -n $pids ]] && kill -KILL $pids 2>/dev/null
        exec 9>>"$SKIPIT_LOCK"
        flock -w 3 9 || die "Не удалось закрыть SkipIt в другом окне. Закройте его вручную: kill $(echo $pids)"
    fi
    sleep 0.3
}

main() {
    case ${1:-} in
        version|-v|--version) echo "SkipIt v${SKIPIT_VERSION}"; exit 0 ;;
        help|-h|--help)       usage; exit 0 ;;
        install|uninstall|update|menu|"") ;;
        *) usage; exit 1 ;;
    esac
    require_root "$@"
    setup_env
    detect_pm
    # Команда skipit ещё не установлена - это первый запуск на сервере
    [[ -x $SKIPIT_BIN || ${1:-} == uninstall ]] || sys_upgrade first

    case ${1:-} in
        install)
            bootstrap_deps; self_install
            say "Готово! Запускайте панель командой: ${C_ACC}${SKIPIT_CMD}${C_RESET}"
            exit 0 ;;
        uninstall)
            self_uninstall; exit 0 ;;
        update)
            bootstrap_deps
            skipit_update_cli "${2:-}"; exit $? ;;
    esac

    bootstrap_deps
    # Первый запуск из файла - сразу ставим команду skipit
    if [[ ! -x $SKIPIT_BIN ]]; then
        self_install && say "Команда ${SKIPIT_CMD} установлена — дальше запускайте просто: ${SKIPIT_CMD}"
        sleep 1
    fi

    { : >"$TTY"; } 2>/dev/null || die "Нужен интерактивный терминал (SSH-сессия)."
    lock_take
    trap 'tx_end; stty echo <"$TTY" 2>/dev/null' EXIT
    trap 'printf "\n\n  %sSkipIt%s закрыт: его открыли в другом окне.\n\n" "$C_BRAND" "$C_RESET" >"$TTY" 2>/dev/null; exit 143' TERM HUP
    trap ':' INT   # Ctrl+C отменяет текущее действие, а не закрывает панель

    say "Собираю сведения о сервере..."
    server_info_init
    # Ноды, установленные старыми версиями: обновить хуки certbot (перезапуск после перевыпуска)
    if [[ -f $NODE_STATE && ( -f $ACME_DEPLOY_OLD || ! -f $ACME_DEPLOY ) ]]; then
        cert_write_hooks 2>/dev/null && log "certbot hooks updated"
    fi
    main_menu
    clear
}

[[ ${BASH_SOURCE[0]} == "$0" ]] && main "$@"
