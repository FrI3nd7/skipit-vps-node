#!/usr/bin/env bash
# SkipIt Tool - VPS Control Center (текстовое меню)
#
# Разделы: нода Remnawave (установка и управление), пользователи и SSH,
#         фаервол UFW, ядро Linux (sysctl, BBR)
#
# Установка:  bash skipit.sh install     -> команда: skipit
# Удаление:   skipit uninstall

SKIPIT_VERSION="1.1.3a"
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
TZ_STATE="${SKIPIT_ETC}/timezone.conf"
NODE_WEBROOT="/var/www/html"
# Сокет «Xray → заглушка»: своя папка ноды, смонтированная в оба контейнера как /skipit
NODE_SOCK_DIR="/skipit"                       # путь внутри контейнеров
NODE_SOCK="${NODE_SOCK_DIR}/decoy.sock"       # target в REALITY и listen в nginx
NODE_SOCK_HOST="${NODE_DIR}/run/decoy.sock"   # тот же сокет, если смотреть с хоста
NODE_IMAGE="remnawave/node:latest"
NODE_NGINX_IMAGE="nginx:1.30-alpine"
NODE_DECOY="remnawave-nginx"                  # контейнер nginx (имя из документации Remnawave)
NODE_XHTTP_PORT=2096          # XHTTP REALITY - Xray
NODE_WS_PORT=2098             # WS - Xray, только 127.0.0.1
NODE_WS_PUBLIC=8443           # WS - публичный TLS-листенер nginx
CF_CREDS="${SKIPIT_ETC}/cloudflare.ini"
ACME_OPEN="/etc/letsencrypt/renewal-hooks/pre/skipit-open80.sh"
ACME_CLOSE="/etc/letsencrypt/renewal-hooks/post/skipit-close80.sh"
F2B_JAIL="/etc/fail2ban/jail.d/skipit.local"
F2B_FILTER="/etc/fail2ban/filter.d/skipit-portscan.conf"
F2B_LOG="/var/log/fail2ban.log"
ACME_DEPLOY="/etc/letsencrypt/renewal-hooks/deploy/skipit-reload-nginx.sh"
ACME_DEPLOY_OLD="/etc/letsencrypt/renewal-hooks/deploy/skipit-reload-decoy.sh"

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

# ==== Общие утилиты ====
# Знак логотипа: шеврон и полоса. Обе однокелейные, ширину строк не ломают.
SKIPIT_MARK="❯▌"
say()  { printf '\n  %s%s SkipIt Tool%s %s›%s %b\n' "${C_BRAND:-$'\e[1;34m'}" "$SKIPIT_MARK" $'\e[0m' "${C_ACC:-}" $'\e[0m' "$*"; }
die()  { printf '\n  %s%s SkipIt Tool%s %s✗%s %b\n' "${C_BRAND:-$'\e[1;34m'}" "$SKIPIT_MARK" $'\e[0m' "${C_ERR:-$'\e[1;31m'}" $'\e[0m' "$*" >&2; exit 1; }
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
    # 700 на каталоги и 600 на лог - второй рубеж: закроют содержимое, даже если
    # у отдельного файла внутри права окажутся выставлены неверно
    chmod 700 "$SKIPIT_BACKUPS" "$SKIPIT_ETC" 2>/dev/null
    [[ -e $SKIPIT_LOG ]] || : >"$SKIPIT_LOG" 2>/dev/null
    chmod 600 "$SKIPIT_LOG" 2>/dev/null
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
apt_upgrade_run() {
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get update -o DPkg::Lock::Timeout=180 &&
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get upgrade -y -o DPkg::Lock::Timeout=180 \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold
}

# 0, если grub-pc установлен, но не донастроен (упал postinst)
grub_pc_broken() {
    case $(dpkg-query -W -f='${db:Status-Status}' grub-pc 2>/dev/null) in
        unpacked|half-configured) return 0 ;;
        *) return 1 ;;
    esac
}

# ---- Починка GRUB (BIOS, пакет grub-pc) ----
# Ошибка «You must correct your GRUB install devices»: у VPS сменился диск, а в debconf
# остался старый. В неинтерактивном режиме grub-pc не настраивается, apt падает с кодом 100.
# Всё ниже работает без вопросов; подробный вывод dpkg - в $SKIPIT_LOG.

# Постоянное имя диска для debconf: /dev/disk/by-id/..., если есть
grub_dev_name() { # sda
    local link
    for link in /dev/disk/by-id/*; do
        [[ -L $link && $link != *-part* ]] || continue
        [[ $(readlink -f "$link") == "/dev/$1" ]] && { printf '%s\n' "$link"; return; }
    done
    printf '/dev/%s\n' "$1"
}

# Все физические диски, доступные на запись (без zram, loop и т. п.)
grub_all_disks() {
    lsblk -dnro NAME,TYPE,RO 2>/dev/null |
        awk '$2=="disk" && $3=="0" && $1 !~ /^(zram|loop|ram|nbd|fd|sr)/ {print $1}'
}

# Диски, в первом секторе которых уже стоит GRUB, - с них сервер и загружается
grub_mbr_disks() {
    local d
    for d in $(grub_all_disks); do
        [[ -b /dev/$d ]] || continue
        LC_ALL=C grep -aq GRUB < <(timeout 5 head -c 512 "/dev/$d" 2>/dev/null) && printf '%s\n' "$d"
    done
}

# Физические диски под файловой системой /boot (через разделы, LVM, RAID)
grub_boot_disks() {
    local src
    src=$(findmnt -no SOURCE -T /boot 2>/dev/null | head -n 1)
    src=${src%%\[*}                                   # btrfs: /dev/sda1[/@]
    [[ -b $src ]] || return 0
    lsblk -nsro NAME,TYPE "$src" 2>/dev/null | awk '$2=="disk"{print $1}' | sort -u
}

# 0, если новый grub-pc той же версии GRUB, что уже стоит в загрузочном секторе
# (отличается только ревизия Debian). Тогда пропустить запись в сектор безопасно:
# старый загрузчик и старые модули в /boot/grub остаются согласованными.
grub_same_upstream() {
    local new old
    new=$(dpkg-query -W -f='${Version}' grub-pc 2>/dev/null)
    old=$(dpkg-query -W -f='${Config-Version}' grub-pc 2>/dev/null)
    [[ -n $new && -n $old ]] || return 1
    new=${new#*:}; new=${new%-*}
    old=${old#*:}; old=${old%-*}
    [[ $new == "$old" ]]
}

# Прописать диски (sda vdb ...) и донастроить пакеты. Без аргументов - не писать в сектор.
grub_try() {
    local list="" d
    for d in "$@"; do list+="$(grub_dev_name "$d"), "; done
    list=${list%, }
    if [[ -n $list ]]; then
        printf 'grub-pc grub-pc/install_devices multiselect %s\ngrub-pc grub-pc/install_devices_empty boolean false\n' "$list"
    else
        printf 'grub-pc grub-pc/install_devices multiselect\ngrub-pc grub-pc/install_devices_empty boolean true\n'
    fi | debconf-set-selections >>"$SKIPIT_LOG" 2>&1 || return 1
    log "grub fix: try install_devices='${list:-<none>}'"
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a dpkg --configure -a >>"$SKIPIT_LOG" 2>&1
    grub_pc_broken && return 1
    log "grub fix: ok (${list:-<none>})"
    return 0
}

# Автоматическая починка. 0 - grub-pc настроен.
grub_fix_devices() {
    [[ $PM == apt ]] && grub_pc_broken || return 1
    local set tried="|" d singles
    say "Загрузчик GRUB не настроен (похоже, у сервера сменился диск). Исправляю автоматически..."

    # UEFI: загрузочный сектор BIOS не используется, запись в него не нужна
    if [[ -d /sys/firmware/efi ]]; then
        grub_try && { say "Загрузчик GRUB настроен (UEFI)."; return 0; }
    else
        # 1) диски, где GRUB уже стоит; 2) диски под /boot; 3) единственный диск в системе
        for set in "$(grub_mbr_disks)" "$(grub_boot_disks)" \
                   "$( [[ $(grub_all_disks | wc -l) -eq 1 ]] && grub_all_disks )"; do
            set=$(echo $set)
            [[ -n $set && $tried != *"|$set|"* ]] || continue
            tried+="$set|"
            say "Пробую установить GRUB на: $set"
            grub_try $set && { say "Загрузчик GRUB установлен на: $set"; return 0; }
        done
        # Несколько дисков (RAID) и один из них не принимает загрузчик - ставим по одному
        singles=$( { grub_mbr_disks; grub_boot_disks; } | sort -u)
        if [[ $(wc -w <<<"$singles") -gt 1 ]]; then
            for d in $singles; do
                grub_try "$d" && { say "Загрузчик GRUB установлен на: $d"; return 0; }
            done
        fi
        # Запасной вариант: версия GRUB та же - оставляем прежний загрузчик в секторе
        if grub_same_upstream; then
            say "Установить не удалось — оставляю прежний загрузчик, он той же версии и загрузит сервер как раньше."
            grub_try && { log "grub fix: skipped MBR install (same upstream)"; return 0; }
        fi
    fi
    log "grub fix: failed"
    return 1
}

# Обновить систему (apt update && apt upgrade). Ошибка не останавливает SkipIt Tool.
# first - первый запуск SkipIt Tool на сервере (только меняет текст сообщения)
sys_upgrade() {
    local rc=0 pre=""
    [[ ${1:-} == first ]] && pre="Первый запуск: "
    case $PM in
        apt)
            say "${pre}Обновляю пакеты системы..."
            apt_upgrade_run || rc=$?
            if (( rc != 0 )) && grub_pc_broken && grub_fix_devices; then
                say "Повторяю обновление пакетов..."
                rc=0
                apt_upgrade_run || rc=$?
            fi ;;
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
        if [[ $PM == apt ]] && grub_pc_broken; then
            say "Причина — загрузчик GRUB. Автоматически исправить без риска для загрузки сервера не удалось
  (подробности: $SKIPIT_LOG). Не перезагружайте сервер. Исправить вручную — отметьте пробелом системный диск:
    DEBIAN_FRONTEND=dialog dpkg --configure grub-pc"
        fi
    fi
    [[ -f /var/run/reboot-required ]] && say "Обновилось ядро или системные библиотеки — после настройки перезагрузите сервер: reboot"
    return 0
}

# Главное меню -> Сервер -> Обновление сервера
# ---- Автообновления безопасности (unattended-upgrades) ----
# Ставятся только security-обновления: обычные пакеты остаются на «Обновление сервера»,
# чтобы ничего не менялось на сервере без ведома хозяина.
# Наш файл идёт после 50unattended-upgrades (apt читает каталог по алфавиту) и
# перекрывает его. Списки в apt.conf при повторном объявлении дополняются,
# поэтому перед каждым - #clear.
AUTOUPD_CONF="/etc/apt/apt.conf.d/52skipit-unattended"
AUTOUPD_PERIODIC="/etc/apt/apt.conf.d/20auto-upgrades"
AUTOUPD_LOGDIR="/var/log/unattended-upgrades"
AUTOUPD_REBOOT_TIME="05:30"

autoupd_supported() { [[ $PM == apt ]]; }
autoupd_installed() { command -v unattended-upgrade >/dev/null 2>&1; }
autoupd_on() {
    [[ -f $AUTOUPD_CONF ]] || return 1
    grep -Eq '^[[:space:]]*APT::Periodic::Unattended-Upgrade[[:space:]]+"1"' "$AUTOUPD_PERIODIC" 2>/dev/null
}
autoupd_reboot_on()   { grep -Eq '^[[:space:]]*Unattended-Upgrade::Automatic-Reboot[[:space:]]+"true"' "$AUTOUPD_CONF" 2>/dev/null; }
autoupd_reboot_time() { sed -n 's/^[[:space:]]*Unattended-Upgrade::Automatic-Reboot-Time[[:space:]]*"\([^"]*\)".*/\1/p' "$AUTOUPD_CONF" 2>/dev/null | head -n 1; }
autoupd_timers_on()   { systemctl is-enabled apt-daily-upgrade.timer >/dev/null 2>&1; }
reboot_required()     { [[ -f /var/run/reboot-required ]]; }

# Что обновилось в последний раз - из журнала unattended-upgrades
autoupd_last_run() {
    local f="$AUTOUPD_LOGDIR/unattended-upgrades.log" d
    [[ -f $f ]] || { echo "—"; return; }
    d=$(grep -E 'Starting unattended upgrades script' "$f" 2>/dev/null | tail -n 1 | awk '{print $1, $2}')
    [[ -n $d ]] && date -d "$d" '+%d.%m.%Y %H:%M' 2>/dev/null || echo "—"
}
autoupd_last_packages() {
    local f="$AUTOUPD_LOGDIR/unattended-upgrades.log"
    [[ -f $f ]] || return 0
    grep -E 'Packages that will be upgraded:' "$f" 2>/dev/null | tail -n 1 |
        sed 's/.*Packages that will be upgraded: //' | tr ' ' '\n' | grep -v '^$' | head -n 12
}

autoupd_write() { # reboot(0|1)
    local reboot=${1:-0} f
    mkdir -p "$(dirname "$AUTOUPD_CONF")"
    for f in "$AUTOUPD_CONF" "$AUTOUPD_PERIODIC"; do [[ -f $f ]] && backup_file "$f" >/dev/null; done
    cat > "$AUTOUPD_CONF" <<'EOF'
// SkipIt Tool · автообновления безопасности
// Файл пересоздаётся SkipIt Tool (Обновление сервера → Автообновления), ручные правки уйдут в бэкап.
// Идёт после 50unattended-upgrades и перекрывает его настройки.

// Только security-ветка. Две строки - чтобы файл подошёл и Debian, и Ubuntu:
// несовпавшая просто не сработает.
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
    "origin=Ubuntu,archive=${distro_codename}-security";
};

// Docker обновляем только вручную: перезапуск демона роняет контейнеры,
// а с ними и клиентов VPN - такое не должно случаться само по себе.
#clear Unattended-Upgrade::Package-Blacklist;
Unattended-Upgrade::Package-Blacklist {
    "docker-ce";
    "docker-ce-cli";
    "docker-ce-rootless-extras";
    "docker-buildx-plugin";
    "docker-compose-plugin";
    "containerd.io";
};

// Ставить по одному пакету: если что-то оборвётся, система не останется на полпути
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
EOF
    if (( reboot )); then
        printf 'Unattended-Upgrade::Automatic-Reboot "true";\nUnattended-Upgrade::Automatic-Reboot-WithUsers "true";\nUnattended-Upgrade::Automatic-Reboot-Time "%s";\n' \
            "$AUTOUPD_REBOOT_TIME" >> "$AUTOUPD_CONF"
    else
        printf 'Unattended-Upgrade::Automatic-Reboot "false";\n' >> "$AUTOUPD_CONF"
    fi
    chmod 644 "$AUTOUPD_CONF"
    cat > "$AUTOUPD_PERIODIC" <<'EOF'
// SkipIt Tool · расписание автообновлений
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
    chmod 644 "$AUTOUPD_PERIODIC"
}

autoupd_enable() {
    autoupd_installed || {
        clear >"$TTY"; say "Устанавливаю unattended-upgrades..."
        pkg_install unattended-upgrades >/dev/null 2>&1 || {
            ui_msg "Ошибка" "Не удалось установить пакет unattended-upgrades."; return 1; }
    }
    autoupd_write "$( autoupd_reboot_on && echo 1 || echo 0 )"
    systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1
    apt-config dump Unattended-Upgrade::Origins-Pattern >/dev/null 2>&1 || {
        ui_msg "Ошибка в конфиге" "apt не принял настройки — файл $AUTOUPD_CONF сохранён, проверьте его вручную."; return 1; }
    log "autoupdates: on"
    return 0
}

autoupd_disable() {
    [[ -f $AUTOUPD_PERIODIC ]] && backup_file "$AUTOUPD_PERIODIC" >/dev/null
    [[ -f $AUTOUPD_CONF ]] && { backup_file "$AUTOUPD_CONF" >/dev/null; rm -f "$AUTOUPD_CONF"; }
    cat > "$AUTOUPD_PERIODIC" <<'EOF'
// SkipIt Tool · автообновления выключены
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
EOF
    chmod 644 "$AUTOUPD_PERIODIC"
    log "autoupdates: off"
}

autoupd_check_now() {
    if ! autoupd_installed; then
        ui_msg "Проверка автообновлений" "Пакет unattended-upgrades ещё не установлен — проверять нечем.

Включите автообновления, и он поставится сам."
        return
    fi
    ui_head "Проверка автообновлений"
    n_say "Смотрю, что поставилось бы сейчас. Ничего не устанавливается."
    echo
    unattended-upgrade --dry-run --debug 2>&1 | sed -n '/Checking/,$p' | head -n 60 | ui_indent
    pause
}

autoupd_log_screen() {
    local f="$AUTOUPD_LOGDIR/unattended-upgrades.log"
    [[ -f $f ]] || { ui_msg "Журнал" "Файл $f ещё не создан — автообновления пока не запускались."; return; }
    ui_textfile "Журнал автообновлений" "$f"
}

menu_autoupd() {
    local c hdr tab=$'\t' pkgs
    if ! autoupd_supported; then
        ui_msg "Автообновления" "Автообновления безопасности SkipIt Tool умеет настраивать только на Debian и Ubuntu (apt)."
        return
    fi
    while :; do
        pkgs=$(autoupd_last_packages | paste -sd', ' - 2>/dev/null)
        hdr="Компонент${tab}Состояние
Автообновления${tab}$(autoupd_on && echo "включены" || echo "выключены")
Что ставится${tab}только обновления безопасности
Docker${tab}не трогаем — обновляется вручную
Перезагрузка${tab}$(autoupd_reboot_on && echo "сама, в $(autoupd_reboot_time)" || echo "не делается, только пометка")
Таймер apt${tab}$(autoupd_timers_on && echo "включён" || echo "выключен")
Последний раз${tab}$(autoupd_last_run)"
        reboot_required && hdr+=$'\n'"Сервер${tab}ждёт перезагрузки"
        [[ -n $pkgs ]] && hdr+=$'\n\n'"Последними ставились: $pkgs"
        hdr+=$'\n\n'"ℹ Обычные обновления остаются на вас: «Обновление сервера»"

        c=$(ui_menu "Автообновления безопасности" "$hdr" \
            ""       "Управление" \
            toggle   "$(autoupd_on && echo "Выключить автообновления" || echo "Включить автообновления")" \
            reboot   "$(autoupd_reboot_on && echo "Перезагрузку выключить" || echo "Перезагружать сервер при необходимости")" \
            ""       "Проверка" \
            check    "Проверить сейчас — что поставилось бы" \
            logs     "Журнал автообновлений") || return
        case $c in
            toggle)
                if autoupd_on; then
                    ui_yesno "Выключить автообновления" "Патчи безопасности перестанут ставиться сами.

Обновлять сервер придётся вручную: «Обновление сервера».

Выключить?" no && { autoupd_disable; ui_msg "Готово" "Автообновления выключены."; }
                else
                    ui_yesno "Включить автообновления" "── Что будет
Ставится:      только security-обновления Debian/Ubuntu
Не трогаем:    Docker — чтобы клиенты VPN не отваливались сами по себе
Расписание:    системный таймер apt, примерно раз в сутки
Перезагрузка:  не делается, появится пометка «сервер ждёт перезагрузки»

── Файлы
Настройки:     $AUTOUPD_CONF
Расписание:    $AUTOUPD_PERIODIC
Журнал:        $AUTOUPD_LOGDIR

ℹ Обычные обновления по-прежнему за вами: «Обновление сервера»

Включить автообновления безопасности?" && {
                        autoupd_enable && ui_msg "Готово" "Автообновления безопасности включены.

Проверить, что именно будет ставиться, можно пунктом «Проверить сейчас»."
                    }
                fi ;;
            reboot)
                if autoupd_reboot_on; then
                    autoupd_write 0
                    ui_msg "Готово" "Сервер больше не будет перезагружаться сам.

После обновления ядра появится пометка «сервер ждёт перезагрузки» — момент выбираете вы."
                else
                    ui_yesno "Перезагрузка по необходимости" "После обновления ядра или системных библиотек сервер будет
перезагружаться сам, в $AUTOUPD_REBOOT_TIME по времени сервера.

! Клиенты VPN потеряют связь примерно на минуту, без предупреждения

Включить автоперезагрузку?" no && { autoupd_write 1; ui_msg "Готово" "Сервер будет перезагружаться при необходимости в $AUTOUPD_REBOOT_TIME."; }
                fi ;;
            check) autoupd_check_now ;;
            logs)  autoupd_log_screen ;;
        esac
    done
}

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

# ==== Часовой пояс сервера ====
# По времени сервера пишутся журналы, ночная перезагрузка автообновлений и бэкапы
# панели по расписанию. В чужом поясе всё это читается неудобно, поэтому пояс
# спрашиваем один раз - при установке команды, дальше меняется из меню.
# Контейнеры Remnawave живут в UTC (TZ=UTC в docker-compose) и пояса хоста не видят.

# Пара "пояс" "город" - что предлагаем на первом экране, без поиска
TZ_POPULAR=(
    Europe/Moscow      "Москва"
    UTC                "всемирное время"
    Europe/Minsk       "Минск"
    Asia/Almaty        "Алматы"
    Asia/Yekaterinburg "Екатеринбург"
    Europe/Berlin      "Берлин, Амстердам, Париж"
    Europe/Warsaw      "Варшава"
    Europe/London      "Лондон"
)

# Действующий пояс: сначала systemd, потом файлы - в контейнерах timedatectl нет
tz_current() {
    local tz l
    tz=$(timedatectl show -p Timezone --value 2>/dev/null)
    [[ -n $tz ]] || tz=$(cat /etc/timezone 2>/dev/null)
    if [[ -z $tz ]]; then
        l=$(readlink -f /etc/localtime 2>/dev/null)
        [[ $l == */zoneinfo/* ]] && tz=${l#*/zoneinfo/}
    fi
    echo "${tz:-UTC}"
}

tz_time()  { TZ="$1" date '+%H:%M' 2>/dev/null; }          # 14:32 в этом поясе
tz_off()   { # +0330 → UTC+3:30
    local s=${1:0:1} h m
    [[ $1 =~ ^[+-][0-9]{4}$ ]] || { printf 'UTC'; return; }
    h=$((10#${1:1:2})); m=$((10#${1:3:2}))
    (( h == 0 && m == 0 )) && { printf 'UTC'; return; }
    if (( m )); then printf 'UTC%s%d:%02d' "$s" "$h" "$m"; else printf 'UTC%s%d' "$s" "$h"; fi
}
tz_label() { printf '%s · %s' "$(tz_time "$1")" "$(tz_off "$(TZ="$1" date '+%z' 2>/dev/null)")"; }

# Пояс существует? Имя идёт в путь /usr/share/zoneinfo, поэтому ".." отсекаем
# отдельно: точка сама по себе в именах поясов допустима.
tz_valid() {
    local tz=$1
    [[ -n $tz && $tz != *..* ]] || return 1
    [[ $tz =~ ^[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)*$ ]] || return 1
    [[ -f /usr/share/zoneinfo/$tz ]]
}

tz_list() {
    local out
    out=$(timedatectl list-timezones 2>/dev/null)
    [[ -n $out ]] || out=$( { echo UTC; awk '$0 !~ /^#/ && NF >= 3 { print $3 }' /usr/share/zoneinfo/zone.tab 2>/dev/null; } | sort -u)
    printf '%s\n' "$out"
}

# База поясов: без неё выбирать не из чего. Ставим молча - вопрос и так задан.
tz_ensure_data() {
    [[ -d /usr/share/zoneinfo ]] && return 0
    [[ -n $PM ]] || return 1
    pkg_install tzdata >/dev/null 2>&1
    [[ -d /usr/share/zoneinfo ]]
}

# Пояс по IP сервера: две площадки, обе без ключа и с коротким таймаутом.
# Это только подсказка в меню - пояс всё равно выбирает человек.
tz_by_ip() {
    local u tz
    for u in https://ipapi.co/timezone 'http://ip-api.com/line/?fields=timezone'; do
        tz=$(curl -4 -fsS --max-time 4 "$u" 2>/dev/null)
        tz=${tz//[[:space:]]/}
        tz_valid "$tz" && { printf '%s' "$tz"; return 0; }
    done
    return 1
}

# Состояние: спрашивали пояс или нет. Пустой аргумент - установка прошла без
# терминала, вопрос переносим на первый запуск меню.
tz_state_save() { # [пояс]
    if [[ -n ${1:-} ]]; then
        printf '# SkipIt Tool — часовой пояс\nTZ_ASKED=1\nTZ_SET=%s\n' "$1" > "$TZ_STATE" 2>/dev/null
    else
        printf '# SkipIt Tool — часовой пояс\nTZ_ASKED=0\n' > "$TZ_STATE" 2>/dev/null
    fi
    chmod 600 "$TZ_STATE" 2>/dev/null
}

tz_apply() { # пояс
    local tz=$1
    tz_valid "$tz" || return 1
    command -v timedatectl >/dev/null 2>&1 && timedatectl set-timezone "$tz" 2>/dev/null
    if [[ $(tz_current) != "$tz" ]]; then
        # Контейнеры и системы без systemd: те же два файла, только руками
        [[ -f /etc/localtime || -L /etc/localtime ]] && backup_file /etc/localtime >/dev/null 2>&1
        ln -sfn "/usr/share/zoneinfo/$tz" /etc/localtime 2>/dev/null
        [[ -f /etc/timezone || $PM == apt ]] && echo "$tz" > /etc/timezone 2>/dev/null
    fi
    [[ $(tz_current) == "$tz" ]] || return 1
    log "timezone: $tz"
    return 0
}

# Поиск по названию города: принимает и "Madrid", и "Europe/Madrid"
tz_search() { # → stdout: пояс
    local q hits=() args=() tz err=""
    while :; do
        q=$(ui_input "Поиск часового пояса" "Название города латиницей — Madrid, New York, Belgrade.
Можно сразу пояс целиком: Europe/Madrid.${err:+

✗ $err}

Город (латиницей):") || return 1
        q=${q#"${q%%[![:space:]]*}"}; q=${q%"${q##*[![:space:]]}"}; q=${q//[[:space:]]/_}
        [[ -n $q ]] || return 1
        mapfile -t hits < <(tz_list | grep -iF -- "$q")
        if (( ${#hits[@]} == 0 )); then err="ничего не нашлось: «${q//_/ }»"; continue; fi
        if (( ${#hits[@]} == 1 )); then printf '%s' "${hits[0]}"; return 0; fi
        if (( ${#hits[@]} > 30 )); then err="нашлось ${#hits[@]} поясов — уточните запрос"; continue; fi
        args=()
        for tz in "${hits[@]}"; do args+=("$tz" "$tz · $(tz_time "$tz")"); done
        tz=$(ui_choose "Часовой пояс" "Нашлось ${#hits[@]} — выберите нужный:" "${args[@]}") || { err=""; continue; }
        printf '%s' "$tz"
        return 0
    done
}

tz_pick() { # заголовок текст → stdout: выбранный пояс
    local title=$1 text=$2 cur geo tz name i items old_cancel=$UI_CANCEL
    cur=$(tz_current)
    ui_loading "Определяю часовой пояс по IP сервера…"
    geo=$(tz_by_ip) || geo=""
    [[ $geo == "$cur" ]] && geo=""
    while :; do
        items=("" "Часто выбирают")
        [[ -n $geo ]] && items+=("$geo" "$geo — по IP сервера · $(tz_time "$geo")")
        for ((i = 0; i < ${#TZ_POPULAR[@]}; i += 2)); do
            tz=${TZ_POPULAR[i]}; name=${TZ_POPULAR[i + 1]}
            [[ $tz == "$cur" || $tz == "$geo" ]] && continue
            items+=("$tz" "$name — $tz · $(tz_time "$tz")")
        done
        items+=("" "Другой город" search "Найти по названию — например Madrid или New York")
        UI_CANCEL="Оставить как есть"
        tz=$(ui_menu "$title" "$text" "${items[@]}")
        UI_CANCEL=$old_cancel
        [[ -n $tz ]] || return 1
        if [[ $tz == search ]]; then
            tz=$(tz_search) || continue
        fi
        printf '%s' "$tz"
        return 0
    done
}

# Смена пояса из меню
tz_change() {
    local cur tz
    tz_ensure_data || { ui_msg "Часовой пояс" "На сервере нет базы часовых поясов (tzdata), и установить её не вышло."; return; }
    cur=$(tz_current)
    tz=$(tz_pick "Часовой пояс" "Сейчас на сервере: $cur · $(tz_label "$cur")

Какой часовой пояс поставить?") || return
    if [[ $tz == "$cur" ]]; then
        ui_msg "Часовой пояс" "На сервере уже $cur — ничего не меняю."
        return
    fi
    if tz_apply "$tz"; then
        tz_state_save "$tz"
        ui_msg "Готово" "Пояс:    $tz
Время:   $(date '+%H:%M · %d.%m.%Y')

ℹ Новое время сразу увидят journalctl, cron и новые записи в журнале SkipIt Tool.
   Программы, которые уже запущены, возьмут пояс после перезапуска.
   Контейнеры Remnawave специально живут в UTC — у них время не меняется."
    else
        ui_msg "Не получилось" "Не удалось поставить пояс $tz — на сервере остался $cur.

Попробуйте вручную: timedatectl set-timezone $tz"
    fi
}

# Вопрос про пояс - один раз, при установке команды.
#   tz_first_run          - ставим команду прямо сейчас
#   tz_first_run pending  - обычный запуск: спрашиваем, только если при установке
#                           не было терминала (curl | bash из другого скрипта).
# Серверы, где SkipIt Tool стоял до этой версии, файла состояния не имеют и
# вопроса не увидят: пояс там меняется из меню «Часовой пояс».
tz_first_run() { # [pending]
    if [[ -f $TZ_STATE ]]; then
        grep -q '^TZ_ASKED=0' "$TZ_STATE" 2>/dev/null || return 0
    elif [[ ${1:-} == pending ]]; then
        return 0
    fi
    { : >"$TTY"; } 2>/dev/null || { tz_state_save; return 0; }
    tz_ensure_data || return 0
    local cur tz
    cur=$(tz_current)
    tz=$(tz_pick "Часовой пояс сервера" "Сейчас на сервере: $cur · $(tz_label "$cur")

По времени сервера пишутся журналы, ночные автообновления и бэкапы панели.
Удобнее, когда оно совпадает с вашим — поменять можно потом в меню «Часовой пояс».

Какой часовой пояс поставить?") || { tz_state_save "$cur"; return 0; }
    if [[ $tz == "$cur" ]] || tz_apply "$tz"; then
        tz_state_save "$tz"
        clear >"$TTY"
        say "Часовой пояс сервера: ${C_OK}${tz}${C_RESET} · $(tz_label "$tz")"
    else
        tz_state_save "$cur"
        clear >"$TTY"
        say "Не удалось поставить пояс $tz — оставил $cur. Поменять можно в меню «Часовой пояс»."
    fi
}

menu_timezone() {
    local c cur ntp items tab=$'\t'
    while :; do
        cur=$(tz_current)
        items=(set "Сменить часовой пояс")
        case $(timedatectl show -p NTPSynchronized --value 2>/dev/null) in
            yes) ntp="время синхронизировано" ;;
            no)  ntp="время НЕ синхронизировано — ломается TLS и REALITY"
                 items+=(ntp "Включить синхронизацию времени") ;;
            *)   ntp="проверить не удалось" ;;
        esac
        c=$(ui_menu "Часовой пояс" "Компонент${tab}Состояние
Пояс${tab}$cur
Время сервера${tab}$(date '+%H:%M · %d.%m.%Y')
Смещение${tab}$(tz_off "$(date '+%z')")
Синхронизация${tab}$ntp

ℹ По времени сервера пишутся журналы, ночные автообновления и бэкапы панели.
   Контейнеры Remnawave живут в UTC — их время от пояса сервера не зависит." \
            "${items[@]}") || return
        case $c in
            set) tz_change ;;
            ntp)
                if timedatectl set-ntp true 2>/dev/null; then
                    ui_msg "Готово" "Синхронизация времени включена — сервер подтянет точное время сам за минуту."
                else
                    ui_msg "Не получилось" "Не удалось включить синхронизацию: на сервере нет systemd-timesyncd или chrony.

Поставьте вручную: apt install systemd-timesyncd"
                fi ;;
        esac
    done
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
SkipIt Tool v${SKIPIT_VERSION} — VPS Control Center

  ${SKIPIT_CMD}              открыть меню
  ${SKIPIT_CMD} install      установить команду ${SKIPIT_CMD} (${SKIPIT_BIN})
  ${SKIPIT_CMD} uninstall    удалить команду
  ${SKIPIT_CMD} update       обновить SkipIt Tool с GitHub (--yes: без вопросов)
  ${SKIPIT_CMD} version      версия
EOF
}

# ---- Конфиг SkipIt Tool и бэкапы ----
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
# Без временного каталога транзакции нет: копии ушли бы в корень ФС ("/0", "/1"),
# tx_end их не убрал бы, а следующий откат спутал бы их с текущими файлами
tx_begin() { tx_end; TX_DIR=$(mktemp -d) || die "Не удалось создать временный каталог — проверьте место на диске и /tmp."; TX_FILES=(); }
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

# Интерфейс SkipIt Tool: текстовое меню с номерами
# Всё выводится в /dev/tty, в stdout - только результат выбора/ввода.
C_RESET=$'\e[0m'
if (( $(tput colors 2>/dev/null || echo 8) >= 256 )) || [[ ${COLORTERM:-} == *color* || ${TERM:-} == *256* ]]; then
    C_BRAND=$'\e[1;38;5;33m'  # SkipIt Tool - синий логотипа (#0087ff)
    C_ACC=$'\e[1;38;5;74m'    # номера, приглашение
    C_KEY=$'\e[1;38;5;79m'    # клавиши в подсказках - мятный, в тон значениям
    C_TXT=$'\e[38;5;252m'     # основной текст
    C_OK=$'\e[1;38;5;72m'     # значения
    C_ERR=$'\e[1;38;5;167m'
    C_WARN=$'\e[1;38;5;179m'
    C_LABEL=$'\e[38;5;103m'   # подписи "ключ - значение"
    C_NOTE=$'\e[38;5;110m'    # пояснения
    C_BADGE=$'\e[1;38;5;234;48;5;179m' # плашка «i» у пояснений
    C_SECTION=$'\e[1;38;5;255;48;5;60m' # плашка названия раздела
    C_HINT=$'\e[38;5;250m'    # подсказки внизу экрана
    C_DIM=$'\e[38;5;60m'      # линии и разделители
    C_SEP=$'\e[38;5;242m'     # точки-разделители в подсказках
    C_QST=$'\e[1;38;5;255m'   # строка вопроса «▸ …» - белым, синий на тёмном фоне не читается
else
    C_BRAND=$'\e[1;34m'; C_ACC=$'\e[1;36m'; C_KEY=$'\e[1;92m'; C_TXT=$'\e[97m'; C_QST=$'\e[1;97m'
    C_OK=$'\e[1;32m'; C_ERR=$'\e[1;31m'; C_WARN=$'\e[1;33m'; C_LABEL=$'\e[37m'; C_NOTE=$'\e[96m'
    C_HINT=$'\e[37m'; C_DIM=$'\e[90m'; C_SEP=$'\e[90m'; C_BADGE=$'\e[1;30;43m'; C_SECTION=$'\e[1;97;44m'
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
    # Ширина рамки считается по этой же строке без цветов - знак логотипа
    # обязан входить в неё, иначе рамка разъедется
    local plain="${SKIPIT_MARK}  SkipIt Tool  ·  VPS Control Center  ·  v${SKIPIT_VERSION}" line
    line=$(printf '─%.0s' $(seq 1 $(( ${#plain} + 4 ))))
    printf '  %s╭%s╮%s\n' "$C_BRAND" "$line" "$C_RESET"
    printf '  %s│%s  %s%s  SkipIt Tool%s  %s·  VPS Control Center  ·  v%s%s  %s│%s\n' \
        "$C_BRAND" "$C_RESET" "$C_BRAND" "$SKIPIT_MARK" "$C_RESET" "$C_HINT" "$SKIPIT_VERSION" "$C_RESET" "$C_BRAND" "$C_RESET"
    printf '  %s╰%s╯%s\n' "$C_BRAND" "$line" "$C_RESET"
}

# Шапка окна: чистый экран, "SkipIt Tool › Заголовок", линия
ui_head() {
    G_STEP=0; G_NOTE_OPEN=0
    ui_dims
    {
        clear
        printf '\n  %s%s SkipIt Tool%s %s›%s %s%s%s\n' "$C_BRAND" "$SKIPIT_MARK" "$C_RESET" "$C_ACC" "$C_RESET" "$C_TXT" "$1" "$C_RESET"
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
        if [[ $tl == 'ℹ '* ]]; then g_note "${tl#ℹ }"; continue; fi
        # Продолжение пояснения: строка с отступом сразу после ℹ. Без этого она
        # печаталась бы обычным текстом, не по колонке пояснения и мимо блока.
        if (( G_NOTE_OPEN )) && [[ $line == '  '* && -n ${tl//[[:space:]]/} ]]; then
            printf '  %s │ %s %s%s%s\n' "$C_DIM" "$C_RESET" "$C_NOTE" "$tl" "$C_RESET" >"$TTY"
            continue
        fi
        if [[ $line == '    '* && $tl != [✓✗!]' '* ]]; then
            g_flush; printf '  %s%s%s\n' "$color" "$line" "$C_RESET" >"$TTY"; continue
        fi
        if [[ $line == *$'\t'* ]]; then
            (( ${#G_ROWS[@]} )) && { local _t=("${T_ROWS[@]}"); T_ROWS=(); g_flush; T_ROWS=("${_t[@]}"); }
            G_NOTE_OPEN=0; T_ROWS+=("$line"); continue
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
        sep="$C_SEP · $C_RESET"
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
        printf '  %s▸%s %s%s%s\n' "$C_ACC" "$C_RESET" "$C_QST" "$last" "$C_RESET" >"$TTY"
    elif [[ $last == *: ]]; then
        field=${last%:}
        if [[ $field =~ ^(.+)[[:space:]]\((.+)\)$ ]]; then field=${BASH_REMATCH[1]}; note=${BASH_REMATCH[2]}; fi
        [[ -n $body ]] && { ui_body "$body"; echo >"$TTY"; }
        printf '  %s▸%s %s%s%s\n' "$C_ACC" "$C_RESET" "$C_QST" "$field" "$C_RESET" >"$TTY"
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
            printf '\n  %s%s SkipIt Tool%s %s›%s %s%s%s\n' "$C_BRAND" "$SKIPIT_MARK" "$C_RESET" "$C_ACC" "$C_RESET" "$C_TXT" "$title" "$C_RESET"
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

# Порты SSH берутся из трёх источников, и они расходятся: директива Port,
# ListenAddress с явно указанным портом (он сильнее Port) и то, что демон
# слушает прямо сейчас. Раньше читалась только Port - и при строке вида
# «ListenAddress 0.0.0.0:22» скрипт считал 22 закрытым, хотя sshd продолжал его
# слушать: в меню значился новый порт, правило UFW для 22 удалялось, а зайти по
# 22 по-прежнему было можно.

# Ubuntu 22.10+ принимает SSH через ssh.socket: порт там задаётся в ListenStream=,
# а Port в sshd_config не работает вовсе. Без своего drop-in смена порта на таких
# системах молча не срабатывала - скрипт показывал новый порт, сервер продолжал
# слушать старый, и по нему спокойно пускало.
SSH_SOCKET_DROPIN="/etc/systemd/system/ssh.socket.d/00-skipit.conf"

ssh_socket_used() {
    [[ -d /run/systemd/system ]] || return 1
    systemctl is-enabled --quiet ssh.socket 2>/dev/null
}

# Порты, которые слушает сам сокет
ssh_socket_ports() {
    ssh_socket_used || return 0
    systemctl show ssh.socket -p Listen --value 2>/dev/null |
        awk '{ for (i = 1; i <= NF; i++) if ($i ~ /:[0-9]+$/) { n = split($i, a, ":"); print a[n] } }' |
        sort -un | xargs
}

# Свой drop-in для ssh.socket; без аргументов - убрать его.
# Пишется внутри транзакции: при откате конфига файл вернётся или исчезнет.
ssh_socket_write() { # [порт ...]
    local p
    tx_add "$SSH_SOCKET_DROPIN"
    if (( $# == 0 )); then
        rm -f "$SSH_SOCKET_DROPIN"
        rmdir "${SSH_SOCKET_DROPIN%/*}" 2>/dev/null
    else
        mkdir -p "${SSH_SOCKET_DROPIN%/*}"
        { printf '# Управляется SkipIt Tool\n[Socket]\nListenStream=\n'
          for p in "$@"; do printf 'ListenStream=%s\n' "$p"; done; } > "$SSH_SOCKET_DROPIN"
    fi
    systemctl daemon-reload 2>/dev/null
    return 0
}

# Порты, прибитые строками ListenAddress (только те, где порт указан явно).
# Формы: 1.2.3.4:22, [::]:22, [2a0d::1]:22 - и без порта: 1.2.3.4, ::1
ssh_la_awk() { # разбор строк listenaddress из дампа sshd -T
    awk '$1 == "listenaddress" {
            $1 = ""; sub(/^ /, ""); sub(/ rdomain .*/, "")
            if (match($0, /:[0-9]+$/)) {
                p = substr($0, RSTART + 1); r = substr($0, 1, RSTART - 1)
                if (r ~ /^\[.*\]$/ || r !~ /:/) { print p; next }
            }
            print "-"          # ListenAddress без порта: на нём работает Port
        }'
}

ssh_la_ports() { # [дамп sshd -T]
    { [[ -n ${1:-} ]] && printf '%s\n' "$1" || sshd_dump; } |
        ssh_la_awk | grep -E '^[0-9]+$' | sort -un | xargs
}

# То же, но по самим файлам конфига. sshd -T печатает listenaddress всегда, даже
# когда своих строк нет (это его развёрнутые умолчания), - спрашивать по нему
# «убрать ваши ListenAddress?» значило бы спрашивать про несуществующее.
ssh_la_conf_ports() {
    cat "$SSHD_MAIN" "$SSHD_DROPIN_DIR"/*.conf 2>/dev/null |
        awk 'tolower($1)=="listenaddress"{ print "listenaddress", $2 }' |
        ssh_la_awk | grep -E '^[0-9]+$' | sort -un | xargs
}

# Порты по конфигу. ListenAddress с портом перебивает Port; сама Port действует,
# только если такой строки нет или есть ListenAddress без порта.
ssh_cfg_ports() {
    local dump la la_port port plain=0 sp
    # Сокет-активация: порт задан в ssh.socket, sshd_config тут ни при чём
    sp=$(ssh_socket_ports)
    [[ -n $sp ]] && { echo "$sp"; return; }
    dump=$(sshd_dump)
    if [[ -z $dump ]]; then
        # sshd -T не отработал - читаем файлы, как раньше
        port=$(cat "$SSHD_MAIN" "$SSHD_DROPIN_DIR"/*.conf 2>/dev/null |
            awk 'tolower($1)=="port"{print $2}' | sort -un | xargs)
        echo "${port:-22}"; return
    fi
    la=$(ssh_la_awk <<< "$dump")
    la_port=$(grep -E '^[0-9]+$' <<< "$la" | sort -un | xargs)
    grep -q '^-$' <<< "$la" && plain=1
    port=$(awk '$1=="port"{print $2}' <<< "$dump" | sort -un | xargs)
    { [[ -z $la_port ]] || (( plain )); } && printf '%s ' $port
    printf '%s' "$la_port"
    echo
}

# Порты, которые sshd слушает прямо сейчас
ssh_live_ports() {
    ss -Htlnp 2>/dev/null |
        awk '/"sshd"/ { n = split($4, a, ":"); if (a[n] ~ /^[0-9]+$/) print a[n] }' |
        sort -un | xargs
}

# Всё, по чему до SSH реально можно достучаться: конфиг плюс живые сокеты.
# Правила UFW открываются именно по этому списку - чтобы расхождение конфига с
# демоном не оставило сервер без входа.
ssh_ports() {
    local p
    p=$({ ssh_cfg_ports; ssh_live_ports; } | tr ' ' '\n' |
        grep -E '^[0-9]{1,5}$' | sort -un | xargs)
    echo "${p:-22}"
}

# Порты SSH для экранов: у порта, который демон держит, но UFW наружу не пускает,
# так и написано. Иначе строка «SSH-порт: 22, 57833» после закрытия 22 в UFW
# выглядит как «правило не сработало», хотя снаружи порт уже закрыт.
ssh_ports_ru() {
    local p out="" allowed on=0
    ufw_active && { on=1; allowed=$(ufw_allowed); }
    for p in $(ssh_ports); do
        if (( on )) && [[ $(ufw_port_scope "$p" tcp "$allowed") == "закрыт в UFW" ]]; then
            out+=", $p (закрыт в UFW)"
        else
            out+=", $p"
        fi
    done
    printf '%s' "${out#, }"
}

# Лишние порты: демон слушает, а по конфигу их быть не должно
ssh_port_check_live() { # порт, который должен остаться → лишние
    local want=$1 p out=""
    for p in $(ssh_live_ports); do [[ $p == "$want" ]] || out+=" $p"; done
    printf '%s' "${out# }"
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
        [[ -f $SSHD_DROPIN ]] || echo "# Управляется SkipIt Tool. Этот файл читается первым — его значения приоритетны." > "$SSHD_DROPIN"
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

# Закомментировать директиву вне блоков Match (и вне блока SkipIt Tool)
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
    local cur new p busy hint
    cur=$(ssh_ports)
    hint=""
    (( $(wc -w <<< "$cur") > 1 )) && hint=$'\n\n! Сейчас sshd слушает несколько портов — прошлая смена не завершена.\n  Введите тот, который нужно оставить: остальные закроются.'
    new=$(ui_input "Порт SSH" "Сейчас:  $(ssh_ports_ru)
UFW:     $(ufw_active && echo "новый порт откроется автоматически" || echo "не включён")

── Занятые порты
$(ports_used_table)

Старый порт закроется только после того, как вы проверите вход через новый.${hint}

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

    # ListenAddress с портом сильнее директивы Port: пока такие строки есть,
    # sshd останется на своих портах, а скрипт и UFW будут считать порт сменённым
    local la fix_la=0
    la=$(ssh_la_conf_ports)
    if [[ -n $la ]]; then
        ui_yesno "В конфиге есть ListenAddress" "Строки ListenAddress задают порт напрямую:  ${la// /, }

Пока они там, директива Port не действует: sshd продолжит слушать эти порты,
а SkipIt Tool и UFW будут считать, что порт уже сменился — по старому порту
по-прежнему можно будет зайти.

Закомментировать их (sshd будет слушать все адреса на порту $new)?" || return
        fix_la=1
    fi

    # Уже слушаем этот порт среди нескольких -> оставить только его
    if [[ " $cur " == *" $new "* ]]; then
        [[ $cur == "$new" ]] && { ui_msg "Порт SSH" "SSH уже работает на порту $new."; return; }
        ui_yesno "Порт SSH" "Сейчас:    $cur
Оставить:  $new

Убедитесь, что подключение через порт $new работает!

Закрыть остальные порты?" no || return
        tx_begin; sshd_comment_everywhere port
        (( fix_la )) && sshd_comment_everywhere listenaddress
        ssh_socket_used && ssh_socket_write "$new"
        sshd_write Port "$new"
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
    (( fix_la )) && sshd_comment_everywhere listenaddress
    # shellcheck disable=SC2086
    ssh_socket_used && ssh_socket_write $cur "$new"
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
        tx_begin; sshd_comment_everywhere port
        (( fix_la )) && sshd_comment_everywhere listenaddress
        ssh_socket_used && ssh_socket_write "$new"
        sshd_write Port "$new"
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
    local p msg still skipped="" del=""
    # Конфиг мы переписали, но верить ему нельзя: проверяем, что демон и правда
    # отпустил старые порты. Правило UFW для порта, который всё ещё слушается,
    # не трогаем - иначе закроем единственный работающий вход.
    still=$(ssh_port_check_live "$2")
    if [[ -n $still ]]; then
        msg="! sshd всё ещё слушает:  ${still// /, }

В конфиге остался только порт $2, но демон занял и другие. Обычно это строки
ListenAddress с портом или сокет-активация systemd (ssh.socket).
Посмотреть:  ss -tlnp | grep sshd"
    else
        msg="SSH теперь работает только на порту $2."
    fi
    if ufw_active && ui_yesno "UFW" "Удалить правила UFW для старых портов SSH ($1)?"; then
        for p in $1; do
            [[ $p == "$2" ]] && continue
            [[ " $still " == *" $p "* ]] && { skipped+=" $p"; continue; }
            ufwc --force delete allow "$p/tcp" >/dev/null 2>&1
            ufwc --force delete allow "$p/tcp" comment 'SSH (SkipIt)' >/dev/null 2>&1
            ufwc --force delete allow "$p" >/dev/null 2>&1
            [[ $p == 22 ]] && ufwc --force delete allow OpenSSH >/dev/null 2>&1
            del+=" $p"
        done
        [[ -n $del ]]     && msg+=$'\n\n'"Правила UFW удалены:  ${del# }"
        [[ -n $skipped ]] && msg+=$'\n'"Оставлены (sshd их слушает):  ${skipped# }"
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
Слушает сейчас:     $(ssh_live_ports | sed 's/ /, /g')

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

── Файл SkipIt Tool"
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
    ui_yesno "Сброс настроек SSH" "Удалятся:    все настройки SSH, сделанные SkipIt Tool
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
    [[ -f $SSH_SOCKET_DROPIN ]] && ssh_socket_write
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
    local c ports live root pass hint
    while :; do
        ports=$(ssh_cfg_ports); live=$(ssh_live_ports)
        root=$(norm_sshd_val "$(sshd_eff permitrootlogin)")
        pass=$(sshd_eff passwordauthentication)
        # Несколько портов - это незавершённая смена: старый ещё слушается.
        # Правило UFW его закрывает снаружи, но в списках он остаётся - объясняем.
        hint=""
        (( $(wc -w <<< "${live:-$ports}") > 1 )) && hint=$'\n\n! Портов несколько — смена порта не завершена: старый ещё слушается.\n  Закрыть его: «Сменить порт SSH» → ввести тот, который нужно оставить.\n  Правило UFW закрывает порт только снаружи, sshd продолжает его держать.'
        c=$(ui_menu "SSH-сервер" "Порт SSH:        $(ssh_ports_ru)$(
            [[ -n $live && $live != "$ports" ]] && printf '\nСлушает сейчас:  %s  ← расходится с конфигом' "${live// /, }" )
Вход root:       $(ru_root "$root")
Вход по паролю:  $(yn_ru "$pass")${hint}

Изменения проверяются через sshd -t, при ошибке откатываются.
Текущие подключения не разрываются." \
            ""    "Настройки" \
            port  "Сменить порт SSH" \
            root  "Вход root" \
            pass  "Вход по паролю" \
            ""    "Обзор и сброс" \
            show  "Показать итоговые настройки" \
            reset "Сбросить настройки SkipIt Tool") || return
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
SSH-порт:     $(ssh_ports_ru)
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

# Что UFW думает про порт: открыт всем, открыт только с определённого адреса
# или не открыт вовсе. Порт может слушаться и при этом быть закрытым снаружи -
# в таблице занятых портов «все адреса» на такой порт вводило в заблуждение.
# Список правил можно передать третьим аргументом, чтобы не звать ufw на каждый порт.
ufw_port_scope() { # порт [протокол] [готовый вывод ufw_allowed]
    local port=$1 proto=${2:-tcp} list=${3-} lport lproto lsrc item a b src="" any=0
    local -a items
    ufw_active || { echo "все адреса"; return; }
    [[ -n $list ]] || list=$(ufw_allowed)
    while IFS=$'\t' read -r lport lproto lsrc; do
        [[ -n $lport ]] || continue
        [[ -z $lproto || $lproto == "$proto" ]] || continue
        IFS=, read -ra items <<< "$lport"
        for item in "${items[@]}"; do
            if [[ $item == *:* ]]; then
                a=${item%%:*}; b=${item##*:}
                (( port >= a && port <= b )) || continue
            elif [[ $item != "$port" ]]; then
                continue
            fi
            [[ -z $lsrc ]] && any=1 || src=$lsrc
        done
    done <<< "$list"
    if (( any )); then echo "все адреса"
    elif [[ -n $src ]]; then echo "только с $src"
    else echo "закрыт в UFW"; fi
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
    local ssh_hit="" close_sshd=0 only_ssh=0
    local -a ports keep=() drop=()
    mapfile -t rules < <(ufw_rules)
    if (( ${#rules[@]} == 0 )); then ui_msg "Закрыть порт" "ℹ Правил пока нет"; return; fi
    for i in "${!rules[@]}"; do
        items+=("$((i + 1))" "$(ufw_rule_ru "${rules[$i]}")" OFF)
    done
    sel=$(ui_checklist "Закрыть порт" "ℹ Правила SkipIt Tool для SSH и панели лучше не удалять" "${items[@]}") || return
    [[ -z $sel ]] && return

    for i in $sel; do
        rule=${rules[$((i - 1))]}
        list+="    $(ufw_rule_ru "$rule")"$'\n'
        ufw_rule_parse "$rule"
        IFS=, read -ra ports <<< "$R_PORT"
        for p in $(ssh_ports); do
            for item in "${ports[@]}"; do
                [[ $item == "$p" ]] && { warn_ssh=1; [[ " $ssh_hit " == *" $p "* ]] || ssh_hit+=" $p"; }
            done
        done
        [[ $R_COMMENT == SSH* || $rule == *OpenSSH* ]] && warn_ssh=1
        [[ $R_COMMENT == *"Remnawave panel"* ]] && warn_panel=1
    done
    # Закрыть порт SSH в фаерволе и оставить его открытым у демона - полумера:
    # снаружи не пускает, но порт живёт, светится в списках и ждёт, пока правило
    # вернут. Поэтому закрываем и в sshd - но только если остаётся другой порт,
    # иначе закрытие правила отрезало бы доступ к серверу совсем.
    if [[ -n $ssh_hit ]]; then
        for p in $(ssh_ports); do
            if [[ " $ssh_hit " == *" $p "* ]]; then drop+=("$p"); else keep+=("$p"); fi
        done
        if (( ${#drop[@]} && ${#keep[@]} )); then close_sshd=1; else only_ssh=1; fi
    fi
    if (( close_sshd )) || { (( warn_ssh || warn_panel )) && ufw_active; }; then
        local text="Удалятся:"$'\n'"${list%$'\n'}"$'\n'
        (( close_sshd ))  && text+=$'\n'"! Порт SSH ${drop[*]} закроется и в sshd — останется только ${keep[*]}"
        (( only_ssh ))    && text+=$'\n'"! Это единственный порт SSH — в sshd он останется, иначе доступ к серверу пропадёт"
        (( warn_ssh ))    && text+=$'\n'"! Удаляется правило SSH — можно потерять доступ к серверу"
        (( warn_panel ))  && text+=$'\n'"! Удаляется правило панели — нода потеряет связь с Remnawave"
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

    # Тот же порт - и у демона
    if (( close_sshd )); then
        tx_begin
        sshd_comment_everywhere port
        ssh_socket_used && ssh_socket_write "${keep[@]}"
        sshd_write Port "${keep[@]}"
        if sshd_commit; then
            log "ssh port: closed ${drop[*]} together with ufw, left ${keep[*]}"
            out+=$'\n'"✓ SSH больше не слушает ${drop[*]} — остался ${keep[*]}"
        else
            out+=$'\n'"✗ SSH: закрыть ${drop[*]} не вышло, конфиг откачен"
        fi
    elif (( only_ssh )); then
        out+=$'\n'"ℹ В sshd порт ${ssh_hit# } оставлен: он единственный, иначе доступ к серверу пропал бы"
    fi
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
SSH-порт:   $(ssh_ports_ru)
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

# Подкачка - страховка от OOM-killer. Панель держит три процесса Node, рядом база;
# на 2-4 ГБ всплеск трафика или бэкап базы упираются в потолок RAM, и без swap
# ядро в такой момент просто убивает процесс. vm.swappiness=10 из раздела
# «Ядро Linux» держит систему в RAM, пока она есть, и трогает swap лишь на пике.
# Установку никогда не валим: swap - приятное дополнение, а не требование.
SWAP_FILE="/swapfile"
swap_active_mb() { awk 'NR>1 {s+=$3} END {print int(s/1024)+0}' /proc/swaps 2>/dev/null; }
swap_target_mb() {
    local ram; ram=$(sysctl_ram_mb); [[ $ram =~ ^[0-9]+$ ]] || ram=2048
    (( ram <= 4096 )) && { echo 2048; return; }
    echo 4096
}
swap_ensure() {
    local have want free_mb fstype
    have=$(swap_active_mb); [[ $have =~ ^[0-9]+$ ]] || have=0
    (( have >= 512 )) && { n_say "Подкачка уже есть: ${have} МБ — не трогаю"; return 0; }
    # На Btrfs и ZFS файл подкачки требует особой подготовки - туда не лезем
    fstype=$(stat -f -c %T / 2>/dev/null)
    case $fstype in
        btrfs|zfs) n_say "Подкачка: файловая система $fstype — swap создайте вручную"; return 0 ;;
    esac
    [[ -e $SWAP_FILE ]] && { n_say "Подкачка: $SWAP_FILE уже существует, но выключен — не трогаю"; return 0; }
    want=$(swap_target_mb)
    free_mb=$(df -Pm / 2>/dev/null | awk 'NR==2 {print $4}')
    if [[ $free_mb =~ ^[0-9]+$ ]] && (( free_mb < want + 2048 )); then
        n_say "Подкачка: на диске свободно ${free_mb} МБ — мало, пропускаю"
        return 0
    fi
    n_say "Создаю файл подкачки ${want} МБ…"
    if ! fallocate -l "${want}M" "$SWAP_FILE" 2>/dev/null; then
        dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$want" status=none 2>/dev/null || {
            rm -f "$SWAP_FILE"; n_say "Подкачка: не удалось создать файл — пропускаю"; return 0; }
    fi
    chmod 600 "$SWAP_FILE"
    if ! mkswap "$SWAP_FILE" >/dev/null 2>&1 || ! swapon "$SWAP_FILE" 2>/dev/null; then
        swapoff "$SWAP_FILE" 2>/dev/null
        rm -f "$SWAP_FILE"; n_say "Подкачка: не удалось включить — пропускаю"; return 0
    fi
    grep -q "^${SWAP_FILE}[[:space:]]" /etc/fstab 2>/dev/null ||
        printf '%s none swap sw 0 0\n' "$SWAP_FILE" >> /etc/fstab
    log "swap: created $SWAP_FILE ${want}M"
    n_say "Подкачка включена: ${want} МБ ($SWAP_FILE), прописана в /etc/fstab"
    return 0
}

# Основной сетевой интерфейс и его очередь
sysctl_iface()  { ip -o route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<NF;i++) if ($i=="dev") {print $(i+1); exit}}'; }
qdisc_now()     { tc qdisc show dev "$1" root 2>/dev/null | awk '{print $2; exit}'; }
sysctl_profile_ru() { case $1 in fq) echo "fq + BBR" ;; cake) echo "CAKE + BBR" ;; *) echo "${1:-не записан}" ;; esac; }
sysctl_file_profile() { [[ -f $SYSCTL_FILE ]] && sysctl_file_value net.core.default_qdisc; }

sysctl_template() { # fq|cake
    local q=${1:-fq} ct; ct=$(sysctl_ct_max)
    cat <<EOF
# Оптимизация ядра для xray-ноды (100+ пользователей). Файл записан SkipIt Tool.
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
Профиль SkipIt Tool:  $(sysctl_profile_ru "$(sysctl_file_profile)")
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
        ui_msg "Сброс" "Настройки ядра SkipIt Tool не записаны."; return
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
Профиль SkipIt Tool:  $(sysctl_profile_ru "$(sysctl_file_profile)")"
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
# Схема: клиент -> 443 Xray (remnanode, REALITY). Чужой трафик Xray отдаёт в
#        unix-сокет $NODE_SOCK (PROXY v2) -> nginx ($NODE_DECOY) -> сайт-заглушка
NODE_DOMAIN=""; NODE_PANEL_IP=""; NODE_PORT=2222; NODE_CERT_METHOD=""; NODE_CERT_NAME=""
NODE_TEMPLATE=""; NODE_PRIV=""; NODE_PUB=""; NODE_SID=""
NODE_LAYOUT="steal"; NODE_WS_PATH=""; NODE_XHTTP_PATH=""
# Связка: nginx ноды обслуживает ещё и панель со страницей подписки. 443 при этом
# держит Xray, а панель живёт за тем же unix-сокетом, что и сайт-заглушка.
NODE_SHARED=0
NODE_KEYS=(NODE_DOMAIN NODE_PANEL_IP NODE_PORT NODE_CERT_METHOD NODE_CERT_NAME NODE_TEMPLATE NODE_PRIV NODE_PUB NODE_SID
           NODE_LAYOUT NODE_WS_PATH NODE_XHTTP_PATH NODE_SHARED)

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
    chmod 600 "$NODE_KEYS_FILE" 2>/dev/null
    # Пути WS/XHTTP в лог не пишем: они прячут инбаунды от сканирования, а лог читают все
    log "node keys: $(basename "$NODE_KEYS_FILE")"
}

# Путь WS, который реально стоит в nginx.conf ноды (пусто - файла или WS-блока нет)
node_nginx_ws_path() {
    sed -n 's/^[[:space:]]*location[[:space:]]\+\(=[[:space:]]\+\)\{0,1\}\(\/ws-[^[:space:]]*\)[[:space:]]*{.*/\2/p' "$NODE_NGINX" 2>/dev/null | head -n 1
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

# Домен из формы: спрашиваем, пока не введут корректный. Пустой ответ - отмена.
ask_domain() { # заголовок текст [значение] → stdout: домен
    local d
    while :; do
        d=$(ui_input "$1" "$2" "${3:-}") || return 1
        d=${d//[[:space:]]/}; d=${d,,}; d=${d%.}
        valid_domain "$d" && { printf '%s' "$d"; return 0; }
        ui_msg "Ошибка" "Некорректный домен: «$d»"
    done
}

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

# Кто занял порт - человеческим языком вместо сырого вывода ss.
# Для компонентов SkipIt Tool называем компонент, а не просто имя процесса: «nginx»
# ни о чём не говорит, а «nginx панели (panel.example.com)» - говорит.
# Имя печатается в stdout, а «чей порт» - кодом возврата: функцию вызывают через
# $(...), то есть в подоболочке, и присваивание переменной наружу бы не вышло.
#   1 - порт свободен, 2 - порт держит компонент SkipIt Tool, 0 - чужой процесс
port_owner() { # порт
    local line name
    line=$(port_listeners "$1" | head -n 1)
    [[ -n $line ]] || return 1
    [[ $line =~ users:\(\(\"([^\"]+)\" ]] && name=${BASH_REMATCH[1]} || name=""
    case $name in
        nginx)
            if panel_installed 2>/dev/null && [[ $(ctr_status "$PANEL_NGINX_CTR") == running ]]; then
                echo "nginx панели ($PANEL_DOMAIN)"; return 2
            elif sub_installed 2>/dev/null && [[ $(ctr_status "$SUB_NGINX_CTR") == running ]]; then
                echo "nginx страницы подписки ($SUB_DOMAIN)"; return 2
            elif node_installed 2>/dev/null && [[ $(ctr_status "$NODE_DECOY") == running ]]; then
                if (( ${NODE_SHARED:-0} )); then
                    echo "nginx ноды ($NODE_DOMAIN) — он же фронт панели"; return 2
                fi
                echo "nginx-заглушка ноды ($NODE_DOMAIN)"; return 2
            fi
            echo "nginx" ;;
        xray|rw-core) echo "Xray ноды";        return 2 ;;
        rw-node|node) echo "нода Remnawave";   return 2 ;;
        sshd)         echo "SSH" ;;
        docker-proxy) echo "проброшенный порт Docker" ;;
        "")           echo "неизвестный процесс" ;;
        *)            echo "$name" ;;
    esac
    return 0
}

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

# Порт закреплён за нодой SkipIt Tool по схеме -> причина (или пусто)
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
    local line addr port host name who allowed
    local -A by_name by_scope
    allowed=$(ufw_allowed)
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
            # Слушается на всех адресах - но снаружи пускает только UFW
            by_scope[$port]=$(ufw_port_scope "$port" tcp "$allowed")
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

SkipIt Tool может это исправить — сервер будет подключаться сначала по IPv4, а IPv6 оставит запасным.

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
    printf '%s\n' "# SkipIt Tool: IPv6 выключен (включить: ${SKIPIT_CMD} → IPv6)" \
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
        ui_msg "IPv6" "IPv6 выключен в ядре (параметр загрузки ipv6.disable=1) — из SkipIt Tool его не включить."
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
    G_NOTE_OPEN=0
    printf '\n  %s[%s]%s %s%s%s\n' "$C_ACC" "${1%% *}" "$C_RESET" "$C_TXT" "${1#*  }" "$C_RESET"
}
n_say()     { G_NOTE_OPEN=0; printf '       %s%s%s\n' "$C_NOTE" "$*" "$C_RESET"; }
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
# SkipIt Tool: открыть 80/tcp на время проверки HTTP-01 (аргумент force - при первом выпуске)
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
# SkipIt Tool: закрыть 80/tcp, если его открыл хук skipit-open80.sh
[ -f /run/skipit-acme80 ] || exit 0
ufw --force delete allow 80/tcp >/dev/null 2>&1
rm -f /run/skipit-acme80
exit 0
EOF
    cat > "$ACME_DEPLOY" <<'EOF'
#!/bin/sh
# SkipIt Tool: сертификат продлён - nginx (заглушка ноды, панель, сабпейдж) перечитывает его.
# Xray (REALITY) сертификат не использует, поэтому remnanode не трогаем и VPN не рвётся.
command -v docker >/dev/null 2>&1 || exit 0
# certbot передаёт RENEWED_LINEAGE - действуем, только если продлился сертификат,
# который использует нода, панель или сабпейдж SkipIt Tool
if [ -n "$RENEWED_LINEAGE" ]; then
    lineage=${RENEWED_LINEAGE##*/}
    match=0
    for f in /etc/skipit/node.conf /etc/skipit/panel.conf /etc/skipit/subpage.conf; do
        [ -f "$f" ] || continue
        for name in $(sed -n 's/^[A-Z_]*CERT_NAME=//p' "$f"); do
            [ "$lineage" = "$name" ] && match=1
        done
    done
    [ "$match" = 1 ] || exit 0
fi
for c in remnawave-nginx remnawave-panel-nginx remnasub-nginx; do
    docker inspect "$c" >/dev/null 2>&1 || continue
    if docker exec "$c" nginx -s reload >/dev/null 2>&1; then r=reload
    elif docker restart "$c" >/dev/null 2>&1; then r=restart
    else r=FAIL; fi
    echo "$(date '+%F %T')  cert renew: $c $r" >> /var/log/skipit.log
done
exit 0
EOF
    chmod 755 "$ACME_OPEN" "$ACME_CLOSE" "$ACME_DEPLOY"
    rm -f "$ACME_DEPLOY_OLD" "${ACME_DEPLOY%/*}/skipit-restart-node.sh" "${ACME_DEPLOY%/*}/skipit-nginx-reload.sh"
}

# Настоящая причина отказа certbot. В версии 2.1 из Debian ошибка ACME по пути
# наверх затирается «AttributeError: can't set attribute» из josepy, и на экране
# остаётся бесполезный текст - а причина (лимит, DNS, недоступный 80) лежит в логе.
cert_last_error() { # → текст ошибки ACME или пусто
    local log=/var/log/letsencrypt/letsencrypt.log line
    [[ -r $log ]] || return 1
    line=$(grep -a 'acme\.messages\.Error:' "$log" 2>/dev/null | tail -n 1)
    [[ -n $line ]] || return 1
    printf '%s' "${line#*acme.messages.Error: }"
}

# Причина человеческим языком. Лимит Let's Encrypt выносим отдельно: это самая
# частая причина, по которой «всё правильно, а сертификат не выпускается».
cert_fail_reason() { # → многострочный текст или пусто
    local err when
    err=$(cert_last_error) || return 1
    case $err in
        *rateLimited*|*"too many certificates"*)
            when=$(sed -n 's/.*retry after \([0-9-]* [0-9:]*\) UTC.*/\1/p' <<< "$err")
            printf 'Лимит Let'"'"'s Encrypt: на этот набор доменов за последнюю неделю\nуже выпущено 5 сертификатов.'
            [[ -n $when ]] && printf '\nПовторить можно после %s UTC.' "$when"
            printf '\n\nЧто можно сделать:\n  · дождаться снятия лимита\n  · выпустить сертификат на ДРУГОЙ набор имён — счётчик у каждого набора свой\n  · выпустить через Cloudflare DNS на зону и *.зону'
            ;;
        *urn:ietf:params:acme:error:*)
            printf '%s' "$err" ;;
        *) printf '%s' "$err" ;;
    esac
}

cert_issue_http() { # email домен... (все домены - в один сертификат, имя по первому)
    local rc em=(--register-unsafely-without-email) email=$1 d
    local -a args=()
    shift
    [[ -n $email ]] && em=(-m "$email")
    for d; do args+=(-d "$d"); done
    "$ACME_OPEN" force
    certbot certonly --standalone --non-interactive --agree-tos "${em[@]}" \
        --cert-name "$1" "${args[@]}" --key-type ecdsa
    rc=$?
    "$ACME_CLOSE"
    return $rc
}

cert_issue_cf() { # email базовый-домен... (зона и *.зона для каждой, имя по первой)
    local em=(--register-unsafely-without-email) email=$1 z
    local -a args=()
    shift
    [[ -n $email ]] && em=(-m "$email")
    for z; do args+=(-d "$z" -d "*.$z"); done
    certbot certonly --dns-cloudflare --dns-cloudflare-credentials "$CF_CREDS" \
        --dns-cloudflare-propagation-seconds 30 --non-interactive --agree-tos "${em[@]}" \
        --cert-name "$1" "${args[@]}" --key-type ecdsa
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
    # Токен - через stdin (-K -), а не аргументом: /proc/PID/cmdline читают все локальные пользователи.
    # cf_clean_token оставляет только [A-Za-z0-9_-], поэтому кавычки в конфиг curl не попадут.
    r=$(printf 'header = "Authorization: Bearer %s"\n' "$1" |
        curl -sS --max-time 20 -K - \
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
# Сайт-заглушка: шаблоны learning-zone/website-templates - ~170 обычных сайтов (HTML5/Bootstrap).
# Репозиторий ~190 МБ, поэтому целиком не качаем: список файлов закреплённого коммита берём
# один раз из GitHub API, а файлы выбранного шаблона - поштучно с raw.githubusercontent.com.
WT_REPO="learning-zone/website-templates"
WT_SHA="7bf31e9646a6b5f51c2e55b2557787310436989f"
WT_LIST="/var/cache/skipit/website-templates-${WT_SHA:0:7}.list"

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
    if [[ $1 == wt:* ]]; then
        echo "$(wt_name "${1#wt:}") — шаблон website-templates"
        return
    fi
    t=$(site_field "$1" 2) && echo "$t — шаблон Mrvibecodic" || echo "$1"
}

# Список файлов website-templates (закреплённый коммит) в кеш: строка = путь файла
wt_fetch_list() {
    [[ -s $WT_LIST ]] && return 0
    mkdir -p "$(dirname "$WT_LIST")" || return 1
    if curl -fsSL --retry 2 --connect-timeout 15 --max-time 120 -o "$WT_LIST.json" \
            "https://api.github.com/repos/$WT_REPO/git/trees/$WT_SHA?recursive=1" &&
        grep -q '"truncated": *false' "$WT_LIST.json"; then
        # top-level assets/ - превью для README, не шаблон
        awk -F'"' '$2=="path"{p=$4} $2=="type"&&$4=="blob"&&p~/\//&&p!~/^assets\//{print p}' \
            "$WT_LIST.json" > "$WT_LIST.part"
        if grep -q '^[^/]*/index\.html$' "$WT_LIST.part"; then
            mv "$WT_LIST.part" "$WT_LIST"; rm -f "$WT_LIST.json"
            return 0
        fi
    fi
    rm -f "$WT_LIST.json" "$WT_LIST.part"
    return 1
}

wt_types() { sed -n 's#^\([^/]*\)/index\.html$#\1#p' "$WT_LIST" 2>/dev/null; }

wt_name() { # каталог → читаемое название без «free-bootstrap-responsive-template»
    local n
    n=$(tr '-' '\n' <<< "$1" | grep -viE '^(free|bootstrap|html5?|responsive|template|templates|theme|web|website|websites|css3|[0-9.]+)$' | paste -sd' ')
    echo "${n:-$1}"
}

# Скачать файлы шаблона в каталог (README и служебные файлы git не берём)
wt_download() { # каталог-шаблона куда
    local tpl=$1 dst=$2 p rel rc n=0
    local -a args=()
    wt_fetch_list || return 1
    wt_types | grep -qxF -- "$tpl" || return 1
    # Имена файлов приходят из чужого репозитория, поэтому не конфиг curl (-K), где кавычка
    # в имени сломала бы разбор и подсунула бы произвольные опции, а обычные аргументы.
    while IFS= read -r p; do
        [[ $p == "$tpl"/* ]] || continue
        rel=${p#"$tpl"/}
        case ${rel##*/} in [Rr][Ee][Aa][Dd][Mm][Ee]*|.git*) continue ;; esac
        # За пределы $dst не выпускаем
        [[ $rel == /* || $rel == ../* || $rel == */../* || $rel == */.. || $rel == .. ]] && continue
        args+=(--url "https://raw.githubusercontent.com/${WT_REPO}/${WT_SHA}/${p// /%20}"
               --output "$dst/$rel")
        n=$((n + 1))
    done < "$WT_LIST"
    (( n )) || return 1
    curl -fsS -g --parallel --parallel-max 16 --create-dirs --retry 2 \
        --connect-timeout 15 --max-time 600 "${args[@]}" 2>/dev/null
    rc=$?
    (( rc == 0 )) && [[ -f $dst/index.html ]]
}

site_external() { # тег → «С внешних сайтов: …» или пусто
    local x; x=$(site_field "$1" 5)
    [[ -n $x ]] && echo "С внешних сайтов грузит: $x"
}

site_choose() { # [keep] [домен] → тег
    local mode=${1:-} domain=${2:-$NODE_DOMAIN} t x items tags=()
    items=(wtrandom "Случайный шаблон от website-templates" random "Случайный шаблон от Mrvibecodic" pick "Выбрать шаблон")
    [[ $mode == keep ]] && items+=("" "" keep "Оставить текущий сайт в $NODE_WEBROOT")
    t=$(ui_choose "Сайт-заглушка" "website-templates:  github.com/$WT_REPO
Mrvibecodic:        github.com/$SITE_REPO

ℹ Эту страницу увидит любой, кто откроет домен ноды в браузере." "${items[@]}") || return 1
    case $t in
        random)
            mapfile -t tags < <(site_tags)
            t=${tags[RANDOM % ${#tags[@]}]} ;;
        wtrandom)
            ui_loading "Получаю список шаблонов website-templates…"
            if ! wt_fetch_list; then
                ui_msg "Ошибка" "Не удалось получить список шаблонов с GitHub (api.github.com).
Проверьте доступ сервера к GitHub и попробуйте снова."
                return 1
            fi
            mapfile -t tags < <(wt_types)
            t="wt:${tags[RANDOM % ${#tags[@]}]}" ;;
        pick)
            items=("" "Mrvibecodic")
            while IFS= read -r x; do
                items+=("$x" "$(site_field "$x" 2) · $(site_field "$x" 3) · $(site_field "$x" 4)")
            done < <(site_tags)
            t=$(ui_choose "Выбрать шаблон" "Для Mrvibecodic указаны название · язык · размер." "${items[@]}") || return 1 ;;
    esac
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
    local tpl=$1 domain=${2:-$NODE_DOMAIN} tmp src rc
    SITE_BAK=""
    [[ $tpl == keep ]] && return 0
    tmp=$(mktemp -d) || return 1
    if [[ $tpl == wt:* ]]; then
        src="$tmp/site"
        wt_download "${tpl#wt:}" "$src" || { rm -rf "$tmp"; return 1; }
        [[ -f $src/robots.txt ]] || printf 'User-agent: *\nDisallow: /\n' > "$src/robots.txt"
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
    # Сайт, поставленный не SkipIt Tool, - в архив перед заменой
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
# nginx ноды: сайт-заглушка за Xray, в балансире ещё и TLS-вход для WS.
# TLS - профиль «intermediate» из Mozilla SSL Configuration Generator (ssl-config.mozilla.org),
# но без DHE: ssl_dhparam не задан, и nginx эти шифры всё равно не предложит.
# Нет resolver/ssl_trusted_certificate: они нужны только для OCSP stapling,
# а Let's Encrypt OCSP больше не выдаёт.
node_nginx_conf() { # домен имя-сертификата схема
    local cert="/etc/letsencrypt/live/$2"
    # В связке за этим же nginx стоит панель: её блоки слушают тот же сокет,
    # поэтому с proxy_protocol, а настоящий IP клиента лежит только в PROXY-заголовке.
    local sh_maps="" sh_blocks=""
    if (( ${NODE_SHARED:-0} )); then
        local p_dom p_cert p_path p_cookie p_api s_dom="" s_cert=""
        # состояние панели читаем в подоболочке: наружу её переменные не нужны
        eval "$(
            panel_state_load 2>/dev/null || exit 0
            [[ -n $PANEL_DOMAIN && -n $PANEL_CERT_NAME ]] || exit 0
            sub_state_load 2>/dev/null
            printf 'p_dom=%q; p_cert=%q; p_path=%q; p_cookie=%q; p_api=%q\n' \
                "$PANEL_DOMAIN" "$PANEL_CERT_NAME" "$PANEL_PATH" \
                "$(panel_env_get SKIPIT_PANEL_COOKIE)" "$(panel_env_get SKIPIT_PANEL_API_KEY)"
            [[ -n ${PANEL_SUB_CERT:-} && -n ${SUB_DOMAIN:-} ]] &&
                printf 's_dom=%q; s_cert=%q\n' "$SUB_DOMAIN" "$PANEL_SUB_CERT"
            true
        )"
        if [[ -n ${p_dom:-} ]]; then
            sh_maps=$(panel_nginx_maps "$p_cookie" "$p_api")
            sh_blocks=$(panel_server_blocks "    listen unix:${NODE_SOCK} ssl proxy_protocol;" \
                        '$proxy_protocol_addr' "$p_dom" "$p_cert" "$p_path" "$p_cookie" "$s_dom" "$s_cert")
        fi
    fi
cat <<EOF
# SkipIt Tool · нода $1 · $(node_layout_ru "$3")${sh_blocks:+ · панель на этом же сервере}
# Файл пересоздаётся SkipIt Tool (Нода Remnawave → nginx.conf), ручные правки уйдут в бэкап.

server_tokens off;

# Запас под длинные и дополнительные домены: при стандартном размере корзины (обычно 64)
# nginx не стартует с «could not build server_names_hash» на имени длиннее ~60 символов
server_names_hash_bucket_size 128;

$(nginx_gzip_conf)

# Connection для проксирования: upgrade для WebSocket, close для обычных запросов.
# Общий для всех server - пригодится и панели на этом же сервере.
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ""      close;
}
${sh_maps:+
$sh_maps
}
ssl_certificate     $cert/fullchain.pem;
ssl_certificate_key $cert/privkey.pem;
ssl_protocols       TLSv1.2 TLSv1.3;
ssl_ecdh_curve      X25519:prime256v1:secp384r1;
ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
ssl_prefer_server_ciphers off;
ssl_session_cache   shared:skipit_tls:10m;
ssl_session_timeout 4h;
ssl_session_tickets off;

# ── Сайт-заглушка
# Сюда Xray отдаёт всё, что не прошло REALITY: браузеры и сканеры, открывшие
# https://$1. Адрес клиента приходит PROXY-заголовком (xver 2 в профиле).
server {
    listen unix:${NODE_SOCK} ssl proxy_protocol;
    http2 on;
    server_name $1;

    root ${NODE_WEBROOT};
    index index.html;
    access_log off;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
${sh_blocks:+
$sh_blocks
}
# ── Любое другое имя в SNI: рукопожатие обрывается, сертификат не показывается
server {
    listen unix:${NODE_SOCK} ssl proxy_protocol default_server;
    ssl_reject_handshake on;
}
EOF
[[ $3 == balancer ]] || return 0
cat <<EOF

# ── WS балансира
# Клиент подключается к nginx напрямую по TLS на ${NODE_WS_PUBLIC} (без Xray перед ним,
# поэтому без proxy_protocol), nginx открывает WebSocket к Xray на 127.0.0.1:${NODE_WS_PORT}.
server {
    listen ${NODE_WS_PUBLIC} ssl;
EOF
# [::] только если в системе есть IPv6, иначе nginx не запустится
[[ -f /proc/net/if_inet6 ]] && echo "    listen [::]:${NODE_WS_PUBLIC} ssl;"
cat <<EOF
    http2 on;
    server_name $1;

    root ${NODE_WEBROOT};
    index index.html;
    access_log off;

    # Ровно path WS-инбаунда. Запрос без Upgrade: websocket получает обычный 404,
    # как любая несуществующая страница сайта, - путь ничем себя не выдаёт.
    location = ${NODE_WS_PATH} {
        if (\$http_upgrade !~* ^websocket\$) {
            return 404;
        }
        proxy_pass http://127.0.0.1:${NODE_WS_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_buffering off;
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
}

# docker-compose ноды: remnanode (официальный образ Remnawave) и nginx-заглушка.
# Общая у контейнеров только папка ./run с сокетом - не весь /dev/shm хоста.
node_compose() {
# Сертификаты: только нужный набор, а не весь /etc/letsencrypt - иначе заглушка,
# которая смотрит в интернет, видит приватные ключи всех сертификатов хоста.
# Симлинки live/<имя>/*.pem -> ../../archive/<имя>/*.pem разрешаются, потому что
# обе папки смонтированы по родным путям. Имени нет (старая нода) - монтируем целиком.
local cert_mounts
if [[ -n ${NODE_CERT_NAME:-} ]]; then
    cert_mounts="      - /etc/letsencrypt/live/${NODE_CERT_NAME}:/etc/letsencrypt/live/${NODE_CERT_NAME}:ro
      - /etc/letsencrypt/archive/${NODE_CERT_NAME}:/etc/letsencrypt/archive/${NODE_CERT_NAME}:ro"
else
    cert_mounts="      - /etc/letsencrypt/live:/etc/letsencrypt/live:ro
      - /etc/letsencrypt/archive:/etc/letsencrypt/archive:ro"
fi
# В связке этот же nginx отдаёт панель и страницу подписки - их сертификат
# (у панели со страницей он общий) тоже надо занести внутрь контейнера.
# Сертификат ноды остаётся отдельным: класть домены панели в SAN заглушки нельзя.
if (( ${NODE_SHARED:-0} )) && [[ -n ${NODE_CERT_NAME:-} ]]; then
    local p_cert
    p_cert=$( panel_state_load 2>/dev/null && printf '%s' "${PANEL_CERT_NAME:-}" )
    if [[ -n $p_cert && $p_cert != "$NODE_CERT_NAME" ]]; then
        cert_mounts+="
      - /etc/letsencrypt/live/${p_cert}:/etc/letsencrypt/live/${p_cert}:ro
      - /etc/letsencrypt/archive/${p_cert}:/etc/letsencrypt/archive/${p_cert}:ro"
    fi
fi
cat <<EOF
# SkipIt Tool · нода Remnawave. SECRET_KEY и NODE_PORT - в .env рядом.

x-defaults: &defaults
  restart: unless-stopped
  network_mode: host
  # запрет повышения прав внутри контейнера через setuid-бинарники
  security_opt:
    - no-new-privileges:true
  logging:
    driver: json-file
    options:
      max-size: 10m
      max-file: "3"

services:
  remnanode:
    <<: *defaults
    image: ${NODE_IMAGE}
    container_name: remnanode
    hostname: remnanode
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile: 262144
    env_file: .env
    volumes:
      - ./run:${NODE_SOCK_DIR}

  remnawave-nginx:
    <<: *defaults
    image: ${NODE_NGINX_IMAGE}
    container_name: ${NODE_DECOY}
    hostname: ${NODE_DECOY}
    mem_limit: 128m
    # сокет от прошлого запуска (сбой, перезагрузка) не даст nginx занять адрес
    entrypoint: ["/bin/sh", "-c", "rm -f ${NODE_SOCK}; exec nginx -g 'daemon off;'"]
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ./run:${NODE_SOCK_DIR}
      - ${NODE_WEBROOT}:${NODE_WEBROOT}:ro
${cert_mounts}
EOF
}

node_compose_run() { ( cd "$NODE_DIR" && docker compose "$@" ); }

# Связка не поднялась - вернуть панели её собственный nginx на 443, иначе она
# останется вообще без фронта. Ноду при этом гасим: 443 ей уже не достанется.
# Xray занимает 443 не при старте контейнера, а когда панель отдаст ему конфиг.
# Поэтому после переключения ждём порт, а не считаем связку удавшейся сразу.
node_wait_443() { # секунд
    local i=0 n=${1:-90}
    while (( i < n )); do
        [[ -n $(port_listeners 443) ]] && return 0
        sleep 3; i=$((i + 3))
        ui_loading "Жду, пока Xray займёт 443… ${i} с из ${n}"
    done
    return 1
}

node_bundle_rollback() {
    n_say "Возвращаю панели её nginx…"
    node_compose_run down >/dev/null 2>&1
    NODE_SHARED=0
    node_state_save 2>/dev/null
    PANEL_NGINX_MODE=own
    panel_state_save 2>/dev/null
    panel_compose > "$PANEL_COMPOSE"
    panel_nginx_write
    panel_compose_run up -d --remove-orphans >/dev/null 2>&1
    sleep 3
    local rerr
    if rerr=$(panel_nginx_ok); then
        n_say "Панель снова на своём nginx: $(panel_url)"
    else
        n_say "ВНИМАНИЕ: nginx панели не поднялся — $rerr"
        n_say "Поднимите вручную: cd $PANEL_DIR && docker compose up -d"
    fi
}

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
    [[ $(ctr_status "$NODE_DECOY") == running ]] || { echo "контейнер $NODE_DECOY не работает"; return 1; }
    out=$(docker exec "$NODE_DECOY" nginx -t 2>&1) || { echo "$out"; return 1; }
    [[ -S $NODE_SOCK_HOST ]] || { echo "нет сокета $NODE_SOCK_HOST"; return 1; }
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
          "target": "$NODE_SOCK",
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
      }
    ],
    "domainStrategy": "IPIfNonMatch"
  }
}
EOF
}

# Строки экранов-инструкций: текст белый, подписи светло-сиреневые, значения зелёные
g_line() { g_flush; printf '  %s%s%s\n' "$C_TXT" "$1" "$C_RESET" >"$TTY"; }
# Пояснения подряд - это один блок: плашка печатается у первой строки,
# остальные подхватываются вертикальной линией. Признак блока сбрасывает любой
# другой вывод (g_flush, g_kv, новый экран), поэтому считаем его ДО g_flush.
G_NOTE_OPEN=0
# Перенос по словам. fold считает байты, а не символы, и на кириллице рвёт
# строку вдвое раньше нужного, поэтому меряем сами: ${#s} в UTF-8 даёт символы.
ui_wrap() { # текст ширина
    local w=$2 line="" word
    for word in $1; do
        if [[ -z $line ]]; then line=$word
        elif (( ${#line} + 1 + ${#word} <= w )); then line+=" $word"
        else printf '%s\n' "$line"; line=$word; fi
    done
    [[ -n $line ]] && printf '%s\n' "$line"
    return 0
}

g_note() {
    local first=$(( ! G_NOTE_OPEN )) w line
    g_flush
    w=$(( ${UI_W:-78} - 6 )); (( w > 66 )) && w=66; (( w < 30 )) && w=30
    while IFS= read -r line; do
        if (( first )); then
            printf '  %s i %s %s%s%s\n' "$C_BADGE" "$C_RESET" "$C_NOTE" "$line" "$C_RESET" >"$TTY"
            first=0
        else
            printf '  %s │ %s %s%s%s\n' "$C_DIM" "$C_RESET" "$C_NOTE" "$line" "$C_RESET" >"$TTY"
        fi
    done < <(ui_wrap "$1" "$w")
    G_NOTE_OPEN=1
}
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
        s=${s//«/$C_QST«}; s=${s//»/»$C_RESET$C_TXT}
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
        if [[ -n $rest ]]; then out+="$C_KEY$part$C_RESET $C_SEP›$C_RESET "
        else out+="$C_QST$part$C_RESET"; fi
    done
    g_flush; printf '  %s▸%s %s\n' "$C_ACC" "$C_RESET" "$out" >"$TTY"
}
# Строки "ключ - значение" копятся и выводятся рамкой-таблицей перед следующим выводом
G_ROWS=()
g_kv()   { G_NOTE_OPEN=0; G_ROWS+=("$1"$'\t'"$2"); }
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
    G_NOTE_OPEN=0
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
# Тот же блок, но для пар «подпись → значение»: подпись приглушена, значение -
# цветом значений, как в таблицах выше. В одноцветном g_code «логин:» сливался
# с самим логином, и строку приходилось разбирать глазами.
g_code_kv() { # подпись значение [подпись значение ...]
    g_flush
    local -a p=("$@")
    local i kw=0
    for ((i = 0; i < ${#p[@]}; i += 2)); do (( ${#p[i]} > kw )) && kw=${#p[i]}; done
    {
        ui_rule
        for ((i = 0; i < ${#p[@]}; i += 2)); do
            printf '    %s%s%s  %s%s%s\n' \
                "$C_LABEL" "$(pad "${p[i]}:" $(( kw + 1 )))" "$C_RESET" \
                "$C_OK" "${p[i+1]}" "$C_RESET"
        done
        ui_rule
    } >"$TTY"
}
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
  "policy": {
    "levels": {
      "0": { "connIdle": 60, "handshake": 4, "uplinkOnly": 1, "downlinkOnly": 1 }
    }
  },
  "routing": {
    "rules": [
      { "type": "field", "inboundTag": ["dns-in"], "balancerTag": "PROXY" },
      { "port": 53, "type": "field", "outboundTag": "dns-out" },
      { "type": "field", "protocol": ["bittorrent"], "outboundTag": "block" },
      { "ip": ["::/0"], "type": "field", "outboundTag": "block" },
      { "port": "443", "type": "field", "network": "udp", "outboundTag": "block" },
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
          "domain:ru", "domain:su", "domain:xn--p1ai",
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
          "domain:yamal.ru", "domain:zdrav10.ru", "domain:1c-bitrix.ru", "domain:1c.ru",
          "domain:1cfresh.com", "domain:1cloud.ru", "domain:1internet.tv", "domain:2gis.ae",
          "domain:2gis.am", "domain:2gis.az", "domain:2gis.by", "domain:2gis.com", "domain:2gis.com.cy",
          "domain:2gis.cz", "domain:2gis.ge", "domain:2gis.kg", "domain:2gis.kz", "domain:2gis.ru",
          "domain:2gis.tj", "domain:2gis.ua", "domain:2gis.uz", "domain:47news.ru", "domain:4meeting.me",
          "domain:5ka.ru", "domain:5post.market", "domain:abr.ru", "domain:aclub.ru", "domain:adfox.ru",
          "domain:admetrica.ru", "domain:aeroflot.ru", "domain:alfa-bank.com", "domain:alfa-bank.ru",
          "domain:alfa-finance.com", "domain:alfa-fx.com", "domain:alfa-pc.com", "domain:alfa-usa.com",
          "domain:alfabank.com", "domain:alfabank.ru", "domain:alfafinance.biz", "domain:alfafinance.ru",
          "domain:alfafuture.com", "domain:alfafuture.ru", "domain:alfafx.com", "domain:alfaleasing.ru",
          "domain:alfaprivate.com", "domain:alformacap.com", "domain:alformacapital.com",
          "domain:auth-nsdi.ru", "domain:auto.ru", "domain:av.ru", "domain:avito.ru", "domain:avito.st",
          "domain:baltbank.ru", "domain:banka-ui.dev", "domain:banki.ru", "domain:bankline.ru",
          "domain:beeline.ru", "domain:beta-bank.com", "domain:bitrix24.ru", "domain:bronevik.com",
          "domain:cdn-tinkoff.ru", "domain:cdn-vk.ru", "domain:chizhik.club", "domain:citydrive.ru",
          "domain:clstorage.net", "domain:credistory.ru", "domain:csat.ru", "domain:cscampus.ru",
          "domain:dbo-dengi.online", "domain:dellin.ru", "domain:dixy.ru", "domain:dnevnik.ru",
          "domain:dns-shop.ru", "domain:dodopizza.ru", "domain:dom.ru", "domain:domclick.ru",
          "domain:donationalerts.com", "domain:drweb.ru", "domain:dzen.ru", "domain:dzeninfra.ru",
          "domain:e5.ru", "domain:edadeal.io", "domain:edadeal.ru", "domain:fastvps.ru",
          "domain:finuslugi.ru", "domain:fivepost.ru", "domain:fix-price.com", "domain:gazeta.ru",
          "domain:gazprombank.ru", "domain:gazprombank.tech", "domain:gazprompay.ru", "domain:gorodpay.ru",
          "domain:gpb.ru", "domain:gpmdi.ru", "domain:hh.ru", "domain:idx5.ru", "domain:imgsmail.ru",
          "domain:investalfabank.com", "domain:iz.ru", "domain:jivo.ru", "domain:jivochat.com",
          "domain:jivosite.com", "domain:jx5.ru", "domain:kaspersky.com", "domain:kaspersky.ru",
          "domain:kazanexpress.ru", "domain:kinopoisk-ru.clstorage.net", "domain:kinopoisk.ru",
          "domain:kommersant.ru", "domain:kp.ru", "domain:krasyar.ru", "domain:krd.ru", "domain:kuper.ru",
          "domain:lead-pro2023.online", "domain:lemanapro.ru", "domain:lenta.com", "domain:lenta.ru",
          "domain:lmru.tech", "domain:magnit.ru", "domain:mail.ru", "domain:max.ru", "domain:megafon.ru",
          "domain:megamarket.ru", "domain:megamarket.tech", "domain:memealerts.com",
          "domain:mirpayonline.ru", "domain:miya-news.online", "domain:mm.ru", "domain:mnogolososya.ru",
          "domain:moex.com", "domain:mradx.net", "domain:mts.ru", "domain:mtsdengi.ru", "domain:mvk.com",
          "domain:myapelsin.ru", "domain:mycdn.me", "domain:mymts.ru", "domain:naydex.net",
          "domain:nbki.ru", "domain:netmonet.co", "domain:nspk.ru", "domain:ok.ru", "domain:okcdn.ru",
          "domain:okko.sport", "domain:okko.tv", "domain:okolo.app", "domain:oneme.ru", "domain:ozon.ru",
          "domain:ozone.ru", "domain:ozonusercontent.com", "domain:perekrestok.ru", "domain:pochta.ru",
          "domain:psbank.ru", "domain:psblog.ru", "domain:qms.ru", "domain:rambler.ru", "domain:rbc.ru",
          "domain:res-nsdi.ru", "domain:rostaxi.org", "domain:rostelecom.ru", "domain:rshb.ru",
          "domain:rt.ru", "domain:rtbcdn.ru", "domain:russiacalling.com", "domain:rutube.ru",
          "domain:rutubelist.ru", "domain:rzd-bonus.ru", "domain:rzd.ru", "domain:sbermarket.ru",
          "domain:sbermegamarket.ru", "domain:sbpgpb.ru", "domain:sistema-capital.com", "domain:spvb.ru",
          "domain:static-storage.net", "domain:svoy.academy", "domain:t2.ru", "domain:tamtam.chat",
          "domain:taximaxim.ru", "domain:taxsee.com", "domain:tbank-online.com", "domain:tele2.ru",
          "domain:timeweb.cloud", "domain:timeweb.com", "domain:tips.tips", "domain:tnt-online.ru",
          "domain:tochka-tech.com", "domain:tochka.com", "domain:topdelivery.ru", "domain:trbcdn.net",
          "domain:tsx.x5static.net", "domain:tu-tu.ru", "domain:turbopages.org", "domain:tutu.ru",
          "domain:usedesk.ru", "domain:userapi.com", "domain:uxfeedback.ru", "domain:vgtrk.ru",
          "domain:victoria-group.ru", "domain:vk-analytics.ru", "domain:vk-apps.com", "domain:vk-apps.ru",
          "domain:vk-cdn.me", "domain:vk-cdn.net", "domain:vk-portal.net", "domain:vk.cc", "domain:vk.com",
          "domain:vk.company", "domain:vk.design", "domain:vk.link", "domain:vk.me", "domain:vk.ru",
          "domain:vk.team", "domain:vkcache.com", "domain:vkcloud-static.ru", "domain:vkgo.app",
          "domain:vklive.app", "domain:vkmessenger.app", "domain:vkmessenger.com", "domain:vkontakte.ru",
          "domain:vkuser.net", "domain:vkuseraudio.com", "domain:vkuseraudio.net", "domain:vkuseraudio.ru",
          "domain:vkusercdn.ru", "domain:vkuserlive.net", "domain:vkuserphoto.ru", "domain:vkuservideo.com",
          "domain:vkuservideo.net", "domain:vkuservideo.ru", "domain:vkusnoitochka.ru", "domain:vkusvill.ru",
          "domain:vkvideo.ru", "domain:vtb-liga.fut.ru", "domain:vtb-russia.com", "domain:vtb.bank.in",
          "domain:vtb.com", "domain:vtb.corp.ru", "domain:vtb.digital", "domain:vtb.fut.ru",
          "domain:vtb.promo", "domain:vtb.ru", "domain:vtb24.com", "domain:vtb24.ru", "domain:vtbcareer.com",
          "domain:vtbfamily.ru", "domain:vtbindia.com", "domain:vtbkep.site", "domain:vtbpartners.com",
          "domain:vtbrussia.com", "domain:vtbrussia.ru", "domain:vtbstrana.ru", "domain:wb.ru",
          "domain:webvisor.com", "domain:webvisor.org", "domain:whoosh.bike", "domain:wildberries.ru",
          "domain:wink.ru", "domain:x5.ru", "domain:x5.tech", "domain:x5club.ru", "domain:x5id.ru",
          "domain:x5l.ru", "domain:x5paket.ru", "domain:x5q.ru", "domain:xn----7sb7akeedqd.xn--p1ai",
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
        "outboundTag": "proxy"
      },
      {
        "ip": [
          "91.108.4.0/22", "91.108.8.0/22", "91.108.12.0/22", "91.108.16.0/22",
          "91.108.56.0/22", "149.154.160.0/20", "185.76.151.0/24"
        ],
        "type": "field",
        "outboundTag": "proxy"
      },
      { "type": "field", "network": "tcp,udp", "balancerTag": "PROXY" }
    ],
    "balancers": [
      {
        "tag": "PROXY",
        "selector": ["proxy"],
        "strategy": { "type": "leastPing" },
        "fallbackTag": "proxy"
      }
    ],
    "domainMatcher": "hybrid",
    "domainStrategy": "IPIfNonMatch"
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
    { "tag": "block", "protocol": "blackhole" },
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "dns-out", "protocol": "dns" }
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
      "timeout": "3s",
      "interval": "1m",
      "sampling": 2,
      "destination": "http://www.gstatic.com/generate_204"
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
                "В меню слева выберите «Профиль» и нажмите «+» справа вверху" \
                "В поле «Название профиля» впишите ⟦$name⟧ и нажмите «Создать»" \
                "Откройте профиль ⟦$name⟧, удалите весь текст конфига и вставьте вместо него этот:"
        g_gap
        node_profile_json "$domain" "$layout" | g_code
        g_gap
        g_steps "Сохраните профиль"
        g_gap
        g_note "Ключи REALITY, shortId и пути созданы SkipIt Tool, сохранены и не меняются при переустановке."
        g_next || { rc=1; break; }

        ui_head "Панель · шаг 2 из $total · Нода"
        # Xray слушает 443 только после того, как панель подключилась и передала профиль
        if [[ $mode != wizard && -n $(port_listeners 443) ]]; then
            printf '  %s✓ Нода уже подключена к панели%s\n' "$C_OK" "$C_RESET" >"$TTY"
            g_gap
            g_line "Этот шаг пропустите — нода уже создана в панели и работает."
            g_gap
            g_note "Пересоздали ноду в панели? Смените SECRET_KEY: SkipIt Tool → Нода Remnawave → Сменить SECRET_KEY"
            g_next "Enter — пропустить шаг · Ctrl+C — выйти" || { rc=1; break; }
        else
        g_steps "В меню слева нажмите «Ноды» → «Управление», затем «+» справа вверху"
        g_gap
        g_line "Первый экран «Создать ноду» — заполните поля:"
        g_kv "Внутреннее название" "$name"
        g_kv "Домен или IP" "$domain"
        g_kv "Node Port" "$port"
        g_gap
        g_steps "Нажмите «Далее»"
        g_gap
        g_line "Следующий экран — выберите:"
        g_kv "Профиль" "$name (создан на шаге 1)"
        g_kv "Inbounds" "$inb"
        g_gap
        g_steps "Сохраните ноду" \
                "Откроется окно подключения. Если там «CONNECTING…», «Устанавливаем mTLS-соединение…» или «Подключиться не удалось» — не ждите, сразу нажмите «Закрыть»"
        g_gap
        if [[ $mode == wizard ]]; then
            g_note "Ошибка подключения на этом шаге — это нормально: нода на сервере запустится после шагов с хостами. SECRET_KEY SkipIt Tool попросит в конце."
        elif [[ -n $(port_listeners 443) ]]; then
            g_note "Нода уже подключена к панели."
        else
            g_note "SECRET_KEY уже записан — панель переподключится к ноде сама. Проверить: SkipIt Tool → Нода Remnawave → Диагностика."
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
                g_steps "Не закрывая шаблон, откройте панель Remnawave в новой вкладке браузера, в меню слева выберите «Хосты», откройте хост ⟦$(node_tag "$domain" steal)⟧ и скопируйте его UUID" \
                        "В шаблоне, в блоке «values», сотрите текст-заглушку ⟦UUID хоста $(node_tag "$domain" steal)⟧ и вставьте скопированный UUID (кавычки оставьте)" \
                        "Так же скопируйте UUID хоста ⟦$(node_tag "$domain" xhttp)⟧ и вставьте его вместо заглушки ⟦UUID хоста $(node_tag "$domain" xhttp)⟧" \
                        "Сохраните шаблон"
                # Копия JSON в папке ноды. Мастер показывает этот шаг до установки - папки может ещё не быть
                { mkdir -p "$NODE_DIR" && node_client_template_json "$name" > "$NODE_DIR/client-template.json"; } 2>/dev/null
                g_gap
                g_note "Балансир PROXY выбирает по пингу между хостами $(node_tag "$domain" steal) и $(node_tag "$domain" xhttp)."
                g_next || { rc=1; break; }
                continue
            fi
            ui_head "Панель · шаг $((n + 2)) из $total · Хост $(node_tag "$domain" "${h,,}")"
            g_steps "В меню слева выберите «Хосты» и нажмите «+» справа вверху"
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
                    # XHTTP ходит поверх HTTP/2, и без ALPN клиент договаривается
                    # на http/1.1 - инбаунд тогда не отвечает
                    g_kv "ALPN" "h2,http/1.1"
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
                g_note "Трафик идёт через $(node_tag "$domain" steal) и $(node_tag "$domain" xhttp) — PROXY выбирает по пингу."
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
    g_path "SkipIt Tool → Нода Remnawave → Что создать в панели"
    g_gap
    g_line "2. Проверить связь с панелью:"
    g_path "SkipIt Tool → Нода Remnawave → Диагностика"
    g_gap
    g_note "Xray начинает слушать 443, когда панель подключится к ноде и передаст профиль."
    local a
    printf '\n  %s ' "$(ui_keys "Enter — в меню · d — запустить диагностику")" >"$TTY"
    ui_readline a || return 0
    a=${a,,}; a=${a//[[:space:]]/}
    [[ $a == d || $a == в ]] && node_diag
    return 0
}

# ==== Мастер «всё на один сервер» ====
# Панель, страница подписки и нода ставятся одним заходом: мастер задаёт все вопросы
# заранее и складывает ответы сюда, а _panel_install и _node_install берут готовое и
# ничего не переспрашивают. WZ_ON=0 - обычная установка по одному компоненту, как была.
WZ_ON=0
WZ_PANEL_DOMAIN=""; WZ_SUB_DOMAIN=""; WZ_PROX_DOMS=""
WZ_NODE_DOMAIN=""; WZ_NODE_PORT=""; WZ_NODE_TPL=""

wz_asked() { (( WZ_ON )); }   # «вопрос уже задан мастером» - использовать как: wz_asked || ui_yesno ...
wz_reset() {
    WZ_ON=0
    WZ_PANEL_DOMAIN=""; WZ_SUB_DOMAIN=""; WZ_PROX_DOMS=""
    WZ_NODE_DOMAIN=""; WZ_NODE_PORT=""; WZ_NODE_TPL=""
}

# ---- Вопросы про ноду: спрашиваем отдельно от установки, чтобы мастер мог
# задать их заранее, а _node_install - взять готовые ответы ----

# Домен ноды: за прокси Cloudflare не работают ни REALITY, ни HTTP-01
node_dns_ask() { # домен
    node_check_dns "$1"
    case $? in
        0) ;;
        2) ui_yesno "DNS: прокси Cloudflare" "$DNS_MSG

REALITY через прокси Cloudflare не работает, сертификат HTTP-01 тоже не выпустится.
Переключите запись в режим «DNS only» (серое облако).

Продолжить всё равно?" no || return 1 ;;
        *) ui_yesno "DNS не совпадает" "$DNS_MSG

Если запись только что создана — подождите пару минут.
Без правильной A-записи сертификат HTTP-01 не выпустится.

Продолжить всё равно?" no || return 1 ;;
    esac
    return 0
}

node_port_ask() { # схема [значение] → stdout: порт
    local layout=$1 port busy
    while :; do
        port=$(ui_input "Порт ноды" "Этот же порт укажите в панели (NODE_PORT).

Порт, на который панель подключается к ноде:" "${2:-}") || return 1
        port=${port//[[:space:]]/}
        if [[ ! $port =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 || port == 80 || port == 443 )) ||
           [[ $layout == balancer && ( $port == "$NODE_XHTTP_PORT" || $port == "$NODE_WS_PORT" || $port == "$NODE_WS_PUBLIC" ) ]]; then
            ui_msg "Ошибка" "Некорректный порт: «$port» (80, 443$([[ $layout == balancer ]] && echo ", $NODE_XHTTP_PORT, $NODE_WS_PORT, $NODE_WS_PUBLIC") заняты схемой ноды)."; continue
        fi
        busy=$(port_foreign "$port")
        [[ -n $busy ]] && { ui_msg "Порт занят" "Порт $port уже занят:

$busy"; continue; }
        if port_in_ephemeral "$port"; then
            ui_yesno "Порт ноды" "$(port_ephemeral_warning "$port" "нода")" no || continue
        fi
        break
    done
    printf '%s' "$port"
}

# Сертификат ноды: только спрашиваем, ничего не ставим и не выпускаем. Ответы - в NCERT_*
NCERT_METHOD=""; NCERT_NAME=""; NCERT_BASE=""; NCERT_TOKEN=""; NCERT_EMAIL=""
ncert_choice_ru() {
    case $NCERT_METHOD in
        reuse) echo "готовый ($NCERT_NAME)" ;;
        http)  echo "HTTP-01" ;;
        cf)    echo "Cloudflare DNS: $NCERT_BASE и *.$NCERT_BASE" ;;
    esac
}

# Строка про сертификат ноды в сводке мастера. Wildcard на общую зону покрывает и
# домен ноды - выпуск там физически один, и делать вид, что их два, нечестно.
wz_ncert_ru() {
    if [[ $NCERT_METHOD == cf && $NCERT_BASE == "$CERT_NAME" ]]; then
        echo "тот же wildcard *.$NCERT_BASE — он покрывает и домен ноды"
    else
        echo "$(ncert_choice_ru) — отдельный выпуск"
    fi
}
# Сертификат ноды по ответам, которые уже дали для панели: способ, токен и email
# общие, выпуск — отдельный. Спрашиваем только то, чего в ответах нет: зону, если
# домен ноды лежит в другой, и токен, если старый эту зону не открывает.
# 0 - ответы готовы, 1 - отмена, 2 - так не выйдет, нужен обычный опрос.
node_cert_from_panel() { # домен ноды
    local d=$1 z
    NCERT_METHOD=""; NCERT_NAME=""; NCERT_BASE=""; NCERT_TOKEN=""; NCERT_EMAIL=""
    case $CERT_METHOD in
        http)
            NCERT_METHOD=http; NCERT_NAME=$d; NCERT_EMAIL=$CERT_EMAIL ;;
        cf)
            NCERT_METHOD=cf; NCERT_TOKEN=$CERT_TOKEN; NCERT_EMAIL=$CERT_EMAIL
            for z in "${CERT_ZONES[@]}"; do
                cert_in_zone "$d" "$z" && { NCERT_BASE=$z; break; }
            done
            if [[ -z $NCERT_BASE ]]; then
                while :; do
                    NCERT_BASE=$(ui_input "Зона Cloudflare для ноды" "Домены панели и подписки в других зонах ($(cert_list_ru "${CERT_ZONES[@]}")),
поэтому для $d нужна ещё одна.

Зона Cloudflare (должна быть в вашем аккаунте):" "$(base_domain "$d")") || return 1
                    NCERT_BASE=${NCERT_BASE//[[:space:]]/}; NCERT_BASE=${NCERT_BASE,,}
                    valid_domain "$NCERT_BASE" && cert_in_zone "$d" "$NCERT_BASE" && break
                    ui_msg "Ошибка" "«$NCERT_BASE» не подходит: $d должен быть этой зоной или её поддоменом."
                done
                # Тот же токен может не открывать новую зону - тогда спросим отдельный
                while ! cf_zone_check "$NCERT_TOKEN" "$NCERT_BASE"; do
                    ui_yesno "Токен не открывает зону $NCERT_BASE" "Токен: $(cf_mask "$NCERT_TOKEN")

$CF_ERR

y — ввести другой токен для этой зоны
n — оставить прежний и выпускать как есть

Ввести другой токен?" || break
                    NCERT_TOKEN=$(ui_input "Cloudflare API-токен для $NCERT_BASE" "Zone Resources:  зона $NCERT_BASE

API-токен Cloudflare:") || return 1
                    NCERT_TOKEN=$(cf_clean_token "$NCERT_TOKEN")
                done
            fi
            NCERT_NAME=$NCERT_BASE ;;
        *) return 2 ;;   # готовый сертификат панели ноде не отдаём - спросим обычным порядком
    esac
    return 0
}

node_cert_ask() { # домен [подпись в сводке]
    local domain=$1 label=${2:-Сертификат} d name busy
    NCERT_METHOD=""; NCERT_NAME=""; NCERT_BASE=""; NCERT_TOKEN=""; NCERT_EMAIL=""

    # Уже есть подходящий сертификат - предложить его
    for d in /etc/letsencrypt/live/*/; do
        name=$(basename "$d")
        [[ -f $(cert_file "$name") ]] && cert_covers "$name" "$domain" || continue
        (( $(cert_days_left "$name") >= 30 )) || continue
        if ui_yesno "Сертификат уже есть" "Найден действующий сертификат для $domain:
  $name — $(cert_domains "$name")
  осталось $(cert_days_left "$name") дн., способ: $(cert_method_ru "$name")

Использовать его?"; then
            NCERT_METHOD=reuse; NCERT_NAME=$name
        fi
        break
    done

    if [[ -z $NCERT_METHOD ]]; then
        NCERT_METHOD=$(ui_choose "SSL-сертификат" "Как выпустить сертификат Let's Encrypt для $domain?" \
            http "HTTP-01 — просто, без токенов (80 порт откроется на время проверки)" \
            cf   "Cloudflare DNS — wildcard *.домен (нужен API-токен)") || return 1
    fi
    case $NCERT_METHOD in
        reuse) ui_ctx_add "$label" "существующий ($NCERT_NAME)" ;;
        http)  ui_ctx_add "$label" "HTTP-01" ;;
        cf)    ui_ctx_add "$label" "Cloudflare DNS" ;;
    esac
    if [[ $NCERT_METHOD == http ]]; then
        busy=$(port_listeners 80)
        if [[ -n $busy ]]; then
            ui_msg "Порт 80 занят" "HTTP-01 не сработает — порт 80 занят:

$busy

Освободите порт или выберите способ Cloudflare DNS."
            return 1
        fi
    fi
    if [[ $NCERT_METHOD == cf ]]; then
        while :; do
            NCERT_BASE=$(ui_input "Зона Cloudflare" "Сертификат будет выпущен на домен и *.домен.

Зона Cloudflare (должна быть в вашем аккаунте):" "$(base_domain "$domain")") || return 1
            NCERT_BASE=${NCERT_BASE//[[:space:]]/}; NCERT_BASE=${NCERT_BASE,,}
            if valid_domain "$NCERT_BASE" && [[ $domain == "$NCERT_BASE" || $domain == *".$NCERT_BASE" ]]; then break; fi
            ui_msg "Ошибка" "«$NCERT_BASE» не подходит: $domain должен быть этим доменом или его поддоменом."
        done
        ui_ctx_add "Зона CF" "$NCERT_BASE (*.$NCERT_BASE)"
        if [[ $domain != "$NCERT_BASE" && $domain == *.*".$NCERT_BASE" ]]; then
            ui_yesno "Внимание" "Wildcard *.$NCERT_BASE не покрывает $domain (поддомен второго уровня).

Продолжить всё равно?" no || return 1
        fi
        while :; do
            NCERT_TOKEN=$(ui_input "Cloudflare API-токен" "▸ Cloudflare → My Profile → API Tokens → Create Token
Шаблон:          «Edit zone DNS»
Zone Resources:  зона $NCERT_BASE
Вставить:        правая кнопка мыши или Ctrl+Shift+V

API-токен Cloudflare:") || return 1
            NCERT_TOKEN=$(cf_clean_token "$NCERT_TOKEN")
            if (( ${#NCERT_TOKEN} < 20 )); then
                ui_msg "Ошибка" "Токен не вставился или слишком короткий: $(cf_mask "$NCERT_TOKEN").
API-токен Cloudflare — строка примерно из 40 символов."
                continue
            fi
            cf_zone_check "$NCERT_TOKEN" "$NCERT_BASE" && break
            ui_yesno "Проверка токена не прошла" "Токен: $(cf_mask "$NCERT_TOKEN")

$CF_ERR

n — ввести токен заново.

Продолжить с этим токеном без проверки?" no && break
        done
        ui_ctx_add "Токен CF" "$(cf_mask "$NCERT_TOKEN")"
    fi
    if [[ $NCERT_METHOD != reuse ]]; then
        while :; do
            NCERT_EMAIL=$(ui_input "Email для Let's Encrypt" "На него придёт предупреждение, если сертификат не продлится.

Email (можно оставить пустым):") || return 1
            NCERT_EMAIL=${NCERT_EMAIL//[[:space:]]/}
            [[ -z $NCERT_EMAIL || $NCERT_EMAIL =~ ^[^@]+@[^@]+\.[^@]+$ ]] && break
            ui_msg "Ошибка" "Некорректный email: «$NCERT_EMAIL»"
        done
        ui_ctx_add "Email" "${NCERT_EMAIL:-не указан}"
    fi
    return 0
}

# ---- Установка ----
node_install() { UI_CTX=""; _node_install; local rc=$?; UI_CTX=""; return $rc; }

_node_install() {
    local domain panel_ip port secret method="" base="" token="" email="" tpl cert_name="" name d busy
    local old_ip="" old_port="" had_state=0 warn=""
    if node_state_load; then
        had_state=1; old_ip=$NODE_PANEL_IP; old_port=$NODE_PORT
        wz_asked || ui_yesno "Переустановка" "Нода уже установлена: $NODE_DOMAIN

docker-compose.yml, .env и nginx.conf будут перезаписаны (старые — в бэкап).
Ключи REALITY сохранятся — профиль в панели менять не придётся.

Продолжить?" no || return
    else
        NODE_PORT=2222
    fi
    wz_asked || ui_yesno "Установка ноды Remnawave" "── Что понадобится
Домен:       A-запись на IP этого сервера ($SERVER_IP)
IP панели:   сервер с панелью Remnawave
SECRET_KEY:  ключ ноды из панели

ℹ Если домен в Cloudflare — только режим «DNS only» (серое облако).

── Что будет сделано
Программы:   Docker, certbot, сертификат Let's Encrypt
ℹ Docker ставится официальным установщиком get.docker.com — это сторонний скрипт,
  он скачивается и выполняется с правами root. Если так не хотите, поставьте Docker
  сами (пакет docker-ce из репозитория Docker), SkipIt Tool возьмёт уже установленный.
Контейнеры:  remnanode (Xray) и nginx в $NODE_DIR
Трафик:      Xray :443 → unix-сокет → nginx с сайтом-заглушкой
UFW:         порты схемы для всех, порт ноды только для IP панели

Начать?" || return
    wz_asked || ipv6_check_wizard || return

    # Панель на этом же сервере - ставим связку: 443 забирает Xray, а панель со
    # страницей подписки уезжают за его unix-сокет, туда же, где сайт-заглушка.
    # Схема только шаблонная: балансиру нужны ещё два публичных порта.
    local bundle=0
    if panel_installed 2>/dev/null; then
        wz_asked || ui_yesno "Панель на этом сервере" "── Сейчас
Панель:       $PANEL_DOMAIN$( sub_installed 2>/dev/null && printf '\nПодписка:     %s' "$SUB_DOMAIN" )
Порт 443:     держит nginx панели

── Станет
Порт 443:     держит Xray ноды
Заглушка:     на unix-сокете Xray
Панель:       там же, выбор по имени домена
Схема ноды:   только шаблонная

ℹ Снаружи адреса не меняются: свой nginx панели больше не нужен,
  его работу берёт на себя nginx ноды.

ℹ Сертификат ноды будет отдельным от сертификата панели: иначе домен
  панели попал бы в сертификат заглушки и связь стала бы видна снаружи.

ℹ Пока переключаемся, панель недоступна несколько секунд.

Поставить ноду в связке с панелью?" || return
        bundle=1
        ui_ctx_add "Режим" "связка с панелью $PANEL_DOMAIN"
    fi

    local layout
    if (( bundle )); then
        layout=steal
    else
        layout=$(ui_choose "Схема ноды" "Схема"$'\t'"Порты"$'\t'"Как работает
Шаблонная"$'\t'"443"$'\t'"selfsteal TCP: Xray на 443, сайт-заглушка через nginx
Балансир"$'\t'"443, $NODE_XHTTP_PORT, $NODE_WS_PUBLIC"$'\t'"selfsteal TCP + XHTTP + WS через nginx, балансир по пингу

Какую схему установить?" \
            steal    "Шаблонная" \
            balancer "Балансир") || return
    fi
    ui_ctx_add "Схема" "$(node_layout_ru "$layout")"

    if wz_asked; then domain=$WZ_NODE_DOMAIN
    else
        domain=$(ask_domain "Домен ноды" "Он же SNI для REALITY.
Пример:  node1.example.com

Домен, на который подключаются клиенты:" "$NODE_DOMAIN") || return
        node_dns_ask "$domain" || return
    fi
    ui_ctx_add "Домен" "$domain"

    if (( bundle )); then
        # Панель рядом, но в своей bridge-сети: до ноды она идёт с адреса этой
        # подсети, а не с 127.0.0.1. Открываем порт ноды ровно для неё.
        panel_ip=$(panel_docker_subnet) || panel_ip=""
        if [[ -z $panel_ip ]]; then
            ui_msg "Не вижу сеть панели" "Не удалось определить подсеть docker-сети remnawave-network.

Без неё правило фаервола получится неверным, и панель не достучится до ноды.
Проверьте, что панель запущена: Компоненты Remnawave → Панель."
            return
        fi
        ui_ctx_add "Сеть панели" "$panel_ip (панель на этом же сервере)"
    else
    while :; do
        panel_ip=$(ui_input "IP панели" "Порт ноды в UFW будет открыт только для него.

IP-адрес сервера с панелью Remnawave:" "$NODE_PANEL_IP") || return
        panel_ip=${panel_ip//[[:space:]]/}
        valid_host_ip "$panel_ip" && break
        ui_msg "Ошибка" "Некорректный IP: «$panel_ip»"
    done
    if [[ $panel_ip == "$SERVER_IP" ]]; then
        ui_yesno "Внимание" "IP панели совпадает с IP этого сервера.

Если панель стоит здесь же — сначала поставьте её (Компоненты Remnawave → Панель),
и установка ноды сама предложит связку: 443 заберёт Xray, панель уедет за его сокет.

Продолжить всё равно?" no || return
    fi

    ui_ctx_add "IP панели" "$panel_ip"
    fi

    if wz_asked; then port=$WZ_NODE_PORT
    else port=$(node_port_ask "$layout" "$NODE_PORT") || return; fi
    ui_ctx_add "Порт ноды" "$port"

    node_keys_ensure || { ui_msg "Ошибка" "Не удалось сгенерировать ключи REALITY (нужен openssl 1.1.1+)."; return; }

    # В связке ноду в панели заводит сам мастер - на шаге установки, после
    # подтверждения. Здесь только помечаем это в сводке: писать что-то в панель
    # до того, как человек согласился, неправильно - отменит, а мусор останется.
    local mk_node=0
    if (( bundle )) && ! panel_has_node; then
        mk_node=1
        ui_ctx_add "Нода в панели" "заведу сам"
    fi

    # Панель живёт в контейнере: 127.0.0.1 для неё - это она сама, а не хост.
    # С таким адресом она никогда не достучится до ноды, конфига не отдаст, и
    # Xray не займёт 443. Ловим это до того, как трогать nginx панели.
    if (( bundle )) && (( ! mk_node )); then
        local addrs
        addrs=$(panel_node_addrs 2>/dev/null)
        if [[ -n $addrs ]] && ! grep -qv -e '^127\.' -e '^localhost$' -e '^::1$' <<< "$addrs"; then
            ui_msg "Неверный адрес ноды в панели" "── Сейчас в панели
Адрес ноды:   $(head -n1 <<< "$addrs")

Панель работает в контейнере, и 127.0.0.1 для неё — она сама, а не этот сервер.
С таким адресом она не достучится до ноды и не отдаст ей конфиг, а без конфига
Xray не займёт 443.

── Что поправить
В панели:     «Ноды» → откройте ноду → «Домен или IP» → $domain

ℹ Порт оставьте прежним: $port

Поправьте адрес и запустите установку снова."
            return
        fi
    fi

    # В связке ключ достаём сами: /api/keygen локальной панели отдаёт тот самый
    # SECRET_KEY. Не вышло - спросим руками, как обычно.
    if (( bundle )); then
        secret=$(panel_node_secret) || secret=""
        if [[ -n $secret ]] && valid_secret "$secret"; then
            ui_ctx_add "SECRET_KEY" "$(cf_mask "$secret") — забран из панели"
        else
            secret=""
            ui_msg "SECRET_KEY" "Не удалось забрать ключ из панели автоматически.
Спрошу его обычным способом — он лежит в панели: «Ноды» → «Управление»."
        fi
    fi

    local have
    if [[ -z ${secret:-} ]]; then
    have=$(ui_choose "Нода в панели" "SECRET_KEY выдаёт панель, когда вы создаёте в ней ноду.
Для ноды нужен профиль с ключами REALITY — SkipIt Tool их уже сгенерировал." \
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
    fi

    # Вопросы про сертификат вынесены в node_cert_ask: мастер «всё на один сервер»
    # задаёт их заранее и кладёт ответы в те же NCERT_*
    wz_asked || node_cert_ask "$domain" || return
    method=$NCERT_METHOD; cert_name=$NCERT_NAME; base=$NCERT_BASE
    token=$NCERT_TOKEN; email=$NCERT_EMAIL

    if wz_asked; then tpl=$WZ_NODE_TPL
    elif [[ -f $NODE_WEBROOT/index.html ]]; then tpl=$(site_choose keep "$domain") || return
    else tpl=$(site_choose "" "$domain") || return; fi
    if [[ $tpl == wt:* ]]; then
        if ! wt_fetch_list; then
            ui_msg "Ошибка" "Не удалось получить список шаблонов website-templates (api.github.com).
Проверьте доступ сервера к GitHub и запустите установку снова."
            return
        fi
    elif [[ $tpl != keep ]] && ! site_fetch; then
        ui_msg "Ошибка" "Не удалось скачать шаблоны с GitHub (codeload.github.com).
Проверьте доступ сервера к GitHub и запустите установку снова."
        return
    fi

    local p
    for p in 443 $([[ $layout == balancer ]] && echo "$NODE_XHTTP_PORT $NODE_WS_PORT $NODE_WS_PUBLIC"); do
        # В связке 443 сейчас держит nginx панели - он уедет сам, это не конфликт
        (( bundle )) && [[ $p == 443 ]] && continue
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
    wz_asked || ui_yesno "Подтверждение" "Установить ноду?

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
            cert_issue_cf "$email" "$base" || { node_fail "Certbot не смог выпустить сертификат.

$(cert_fail_reason || echo "Подробности выше и в /var/log/letsencrypt/letsencrypt.log")"; return; }
        else
            cert_name=$domain
            cert_issue_http "$email" "$domain" || { node_fail "Certbot не смог выпустить сертификат.

$(cert_fail_reason || echo "Проверьте A-запись и доступность 80 порта, подробности в /var/log/letsencrypt/letsencrypt.log")"; return; }
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
    # До node_compose и node_nginx_conf: оба смотрят на этот признак и в связке
    # добавляют сертификаты панели и её server-блоки
    NODE_SHARED=$bundle
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

    # Ноду в панели заводим ДО того, как трогать 443: без неё панель не отдаст
    # Xray конфиг, Xray не поднимется, и порт останется ничьим.
    if (( bundle )) && (( mk_node )); then
        n_say "Завожу профиль и ноду в панели…"
        if panel_create_node "$domain" "$port" "$layout"; then
            n_say "Профиль и нода созданы, ключи REALITY уже внутри профиля"
            if [[ -n $PANEL_HOST_ERR ]]; then
                n_say "Хост $(node_tag "$domain" steal): $PANEL_HOST_ERR"
            else
                n_say "Хост $(node_tag "$domain" steal) создан, инбаунд добавлен в сквод"
            fi
            log "panel node created: $PANEL_NODE_UUID ($domain:$port)"
        else
            node_fail "Не удалось завести ноду в панели: $PANEL_NODE_ERR

Панель не тронута и работает как раньше. Заведите ноду вручную
(Нода Remnawave → мастер покажет, что создать) и запустите установку снова."
            return
        fi
    fi

    # Связка: 443 должен освободиться ДО старта Xray, иначе он не займёт порт.
    # Панель остаётся жить, уходит только её nginx - его работу забирает nginx ноды.
    if (( bundle )); then
        n_say "Панель переезжает за сокет Xray, её nginx останавливается…"
        backup_file "$PANEL_COMPOSE" >/dev/null
        PANEL_NGINX_MODE=socket
        panel_state_save
        panel_compose > "$PANEL_COMPOSE"
        panel_compose_run up -d --remove-orphans >/dev/null 2>&1
    fi

    node_compose_run up -d --force-recreate --remove-orphans || {
        (( bundle )) && node_bundle_rollback
        node_fail "docker compose up завершился с ошибкой."; return; }
    sleep 4
    local err
    if ! err=$(node_nginx_ok); then
        (( bundle )) && node_bundle_rollback
        node_fail "nginx не запустился: $err"; return
    fi
    # Связка: 443 сейчас не держит никто, кроме будущего Xray. Пока он не занял
    # порт, панель недоступна - поэтому ждём и при неудаче возвращаем всё назад.
    if (( bundle )); then
        if ! node_wait_443 90; then
            node_bundle_rollback
            node_fail "Xray так и не занял 443 за 90 секунд.

Скорее всего панель не отдала ноде конфиг: проверьте, что нода в панели создана,
её адрес 127.0.0.1, порт $port, и SECRET_KEY совпадает.
Панель возвращена на свой nginx и снова работает."
            return
        fi
        n_say "Xray занял 443 — панель снова отвечает через nginx ноды"
    fi
    log "node install: ok$( (( bundle )) && echo " (связка с панелью)" )"

    # В мастере «всё на один сервер» итоговый экран общий, его показывает мастер
    wz_asked || node_done_screen "$domain"
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

# Что в профиле панели не совпадает с настройками SkipIt Tool -> "ключ REALITY, путь WS" (пусто - всё совпадает)
# Код 2 - проверить не удалось (Xray не запущен, нет python3)
node_profile_diff() {
    local cfg
    command -v python3 >/dev/null 2>&1 || return 2
    cfg=$(node_live_config) || return 2
    # Значения - через окружение, а не аргументами: приватный ключ REALITY в argv был бы
    # виден в ps любому локальному пользователю (/proc/PID/environ читает только владелец и root)
    SKIPIT_WS=$NODE_WS_PATH SKIPIT_XH=$NODE_XHTTP_PATH SKIPIT_SID=$NODE_SID \
    SKIPIT_PRIV=$NODE_PRIV SKIPIT_SOCK=$NODE_SOCK \
    python3 -c '
import json, os, sys
ws, xh, sid, priv, sock = (os.environ[k] for k in
    ("SKIPIT_WS", "SKIPIT_XH", "SKIPIT_SID", "SKIPIT_PRIV", "SKIPIT_SOCK"))
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
        if r.get("target", r.get("dest")) != sock: add("сокет заглушки (target)")
    if s.get("network") == "xhttp" and (s.get("xhttpSettings") or {}).get("path") != xh: add("путь XHTTP")
    if s.get("network") == "ws" and (s.get("wsSettings") or {}).get("path") != ws: add("путь WS")
print(", ".join(bad))
' <<< "$cfg" 2>/dev/null || return 2
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

# Проверки самого сервера - общие для всех компонентов, ни к одному не привязаны.
# Наполняют DIAG, но не сбрасывают и не показывают его: вызываются и сами по себе,
# и первым разделом в отчёте ноды.
server_diag_collect() { # [installed]
    local v
    diag_head "Сервер"
    v=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
    case $v in
        yes) diag_ok "Время синхронизировано (важно для сертификатов и REALITY)" ;;
        no)  diag_bad "Время НЕ синхронизировано — ломается TLS и REALITY. Включите: timedatectl set-ntp true" ;;
        *)   diag_warn "Не удалось проверить синхронизацию времени" ;;
    esac
    if ipv6_off || ! ipv6_supported; then
        diag_ok "IPv6 выключен"
    elif ipv6_prefer_v4; then
        diag_ok "IPv4 приоритетнее IPv6 ($GAI_CONF)"
    elif ipv6_broken; then
        diag_bad "IPv6 не работает, а программы пробуют его первым — certbot может зависать.
      Исправление: мастер установки предложит его, или добавьте в $GAI_CONF строку «$GAI_LINE»"
    elif ip -6 route show default 2>/dev/null | grep -q .; then
        diag_ok "IPv6 работает"
    fi
    v=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    [[ $v == bbr ]] && diag_ok "TCP: BBR" || diag_warn "TCP: $v — BBR можно включить в разделе «Ядро Linux»"
    if ! command -v ufw >/dev/null 2>&1; then diag_warn "UFW не установлен"; DIAG_FIX_UFW=${1:-0}
    elif ufw_active; then diag_ok "UFW включён"
    else diag_warn "UFW выключен — порты не ограничены"; DIAG_FIX_UFW=${1:-0}; fi

    diag_head "Docker"
    if ! command -v docker >/dev/null 2>&1; then
        diag_warn "Docker не установлен — SkipIt Tool поставит его сам при установке компонента"
    elif ! docker info >/dev/null 2>&1; then
        diag_bad "Docker установлен, но служба не работает: systemctl start docker"
    else
        diag_ok "Docker $(docker version -f '{{.Server.Version}}' 2>/dev/null) работает"
    fi
}

# Отчёт по серверу, когда компонентов ещё нет: готов ли он что-то принять
server_diag() {
    local v rc
    DIAG=""; DIAG_OK=0; DIAG_WARN=0; DIAG_BAD=0; DIAG_PROBLEMS=""; DIAG_FIX_UFW=0
    server_diag_collect

    diag_head "Порты"
    v=$(port_owner 443); rc=$?
    case $rc in
        1) diag_ok "443 свободен — нужен панели, ноде и странице подписки" ;;
        2) diag_ok "443 занят: $v — это компонент SkipIt Tool" ;;
        *) diag_warn "443 занят: $v — порт нужен любому компоненту Remnawave" ;;
    esac
    v=$(port_owner 80); rc=$?
    case $rc in
        1) diag_ok "80 свободен (нужен для проверки HTTP-01)" ;;
        *) diag_warn "80 занят: $v — HTTP-01 не сработает, выпускайте сертификат через Cloudflare DNS" ;;
    esac
    v=$(ssh_ports)
    diag_ok "SSH слушает порт ${v// /, }"

    diag_show "Диагностика сервера" "Компоненты Remnawave ещё не установлены."
}

node_diag() {
    local v d code restarts rc installed=0
    DIAG=""; DIAG_OK=0; DIAG_WARN=0; DIAG_BAD=0; DIAG_PROBLEMS=""; DIAG_FIX_UFW=0
    # Установку запускает меню компонентов, поэтому сюда попадаем с готовой нодой.
    # Ноды нет - показываем отчёт по серверу, а не пустой отчёт в терминах ноды.
    node_installed || { server_diag; return; }
    installed=1
    server_diag_collect 1

    diag_head "Контейнеры"
    for v in remnanode "$NODE_DECOY"; do
        case $(ctr_status "$v") in
            running)
                restarts=$(docker inspect -f '{{.RestartCount}}' "$v" 2>/dev/null)
                if (( ${restarts:-0} > 3 )); then diag_warn "$v работает, но перезапускался $restarts раз — смотрите логи"
                else diag_ok "$v работает"; fi ;;
            "") diag_bad "$v не создан — перезапустите контейнеры" ;;
            *)  diag_bad "$v: $(ctr_state_ru "$v") — смотрите логи" ;;
        esac
    done
    if v=$(node_nginx_ok); then diag_ok "nginx: конфигурация верна, сокет $NODE_SOCK_HOST есть"
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
            diag_bad "https://$NODE_DOMAIN через 443 не отвечает (код ${code:-нет}) — проверьте target ($NODE_SOCK) и xver в профиле"
    else
        diag_bad "Порт 443 не слушается — Xray не получил конфиг от панели.
      Проверьте: нода создана в панели ($SERVER_IP:$NODE_PORT), SECRET_KEY совпадает,
      ноде назначен профиль с inbound на порт 443."
    fi
    local pdiff
    if pdiff=$(node_profile_diff); then
        if [[ -z $pdiff ]]; then
            diag_ok "Профиль в панели совпадает с настройками SkipIt Tool"
        else
            diag_bad "Профиль в панели устарел — не совпадает: $pdiff. Клиенты не подключатся.
      Вставьте профиль заново: SkipIt Tool → Нода Remnawave → Что создать в панели → шаг 1"
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
      Исправить: SkipIt Tool → Нода Remnawave → Перезапустить контейнеры"
        fi
        if port_listeners "$NODE_XHTTP_PORT" | grep -qE '"(rw-core|xray)"'; then
            diag_warn "Xray слушает :$NODE_XHTTP_PORT, хотя схема шаблонная — в профиле панели остались inbound балансира.
      Исправить: Панель → Профили конфигурации → профиль ноды (SkipIt Tool → Нода Remnawave → Что создать в панели)"
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
    for v in remnanode "$NODE_DECOY"; do
        r=$(docker inspect -f '{{.RestartCount}}' "$v" 2>/dev/null)
        hdr+=$'\n'"$v"$'\t'"$(ctr_state_ru "$v")"$'\t'"${r:-—}"
    done
    c=$(ui_choose "Логи" "$hdr" \
        remnanode     "remnanode — Xray и связь с панелью" \
        "$NODE_DECOY" "nginx — сайт-заглушка и WS балансира") || return
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
    before=$(docker inspect -f '{{.Image}}' remnanode "$NODE_DECOY" 2>/dev/null)
    node_compose_run pull || { node_fail "Не удалось скачать образы."; return; }
    node_compose_run up -d --remove-orphans || { node_fail "docker compose up завершился с ошибкой."; return; }
    after=$(docker inspect -f '{{.Image}}' remnanode "$NODE_DECOY" 2>/dev/null)
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

Mrvibecodic:        проверьте доступ сервера к codeload.github.com
website-templates:  проверьте доступ к api.github.com и raw.githubusercontent.com"
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
Продление:   $(cert_renew_scheduled && echo "автоматически (certbot), затем nginx перечитывает сертификат" || echo "НЕ НАСТРОЕНО")"
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
    # nginx перечитывает сертификат в хуке $ACME_DEPLOY - certbot запускает его сам после перевыпуска
    log "node cert $c rc=$rc"
    echo
    if (( rc != 0 )); then printf '%s✗ certbot завершился с ошибкой (код %s)%s\n' "$C_ERR" "$rc" "$C_RESET"
    elif [[ $c == renew ]]; then say "Готово. Сертификат перевыпущен, nginx его перечитал."
    else say "Готово."; fi
    pause
}

node_nginx_menu() {
    local c bak err
    c=$(ui_choose "nginx.conf" "Файл:   $NODE_NGINX
Схема:  $(node_layout_ru "$NODE_LAYOUT")
nginx:  $(ctr_state_ru "$NODE_DECOY")" \
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
    if [[ $(ctr_status "$NODE_DECOY") != running ]]; then
        log "node nginx $c (backup: $bak)"
        ui_msg "Сохранено" "Файл сохранён, но контейнер nginx не работает — проверить нельзя.
Бэкап: $bak"
        return
    fi
    if ! err=$(docker exec "$NODE_DECOY" nginx -t 2>&1); then
        cat "$bak" > "$NODE_NGINX"
        ui_msg "Ошибка в nginx.conf" "Проверка nginx -t не пройдена — файл возвращён к прежней версии:

$err"
        return
    fi
    docker exec "$NODE_DECOY" nginx -s reload >/dev/null 2>&1
    log "node nginx $c (backup: $bak)"
    ui_msg "Готово" "nginx.conf проверен и применён. Бэкап: $bak"
}

# Пересоздать nginx.conf и docker-compose.yml по шаблону SkipIt Tool (можно сменить схему).
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
    ui_yesno "$( (( changed )) && echo "Смена схемы" || echo "Пересоздание файлов")" "Схема:           $(node_layout_ru "$layout")
Пересоздадутся:  контейнеры remnanode и $NODE_DECOY
Если сбой:       файлы и контейнеры вернутся к прежним

! Клиенты VPN отключатся на 5–10 секунд

Продолжить?" || return

    bak_n=$(backup_file "$NODE_NGINX"); bak_c=$(backup_file "$NODE_COMPOSE")
    node_gen_paths
    node_compose > "$NODE_COMPOSE"
    node_nginx_conf "$NODE_DOMAIN" "$NODE_CERT_NAME" "$layout" > "$NODE_NGINX"
    clear; say "Пересоздаю контейнеры ноды..."
    # --remove-orphans: убрать контейнеры сервисов, которых в новом compose уже нет
    node_compose_run up -d --force-recreate --remove-orphans
    sleep 4
    if ! err=$(node_nginx_ok); then
        [[ -n $bak_n ]] && cat "$bak_n" > "$NODE_NGINX"
        [[ -n $bak_c ]] && cat "$bak_c" > "$NODE_COMPOSE"
        say "Откатываю..."
        node_compose_run up -d --force-recreate --remove-orphans
        log "node regen: FAIL layout=$layout, rolled back"
        ui_msg "nginx не запустился" "Файлы и контейнеры возвращены к прежним.

$err

Смотрите логи:
▸ SkipIt Tool → Нода Remnawave → Логи → nginx"
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
        local pdiff=""
        sleep 2; pdiff=$(node_profile_diff)
        ui_msg "Готово" "nginx.conf и docker-compose.yml пересозданы, nginx работает.
Бэкапы:
  $bak_n
  $bak_c${pdiff:+

! В профиле панели не совпадает: $pdiff
  Обновите профиль — инструкция откроется на следующем экране.}"
        [[ -n $pdiff ]] && node_guide "$NODE_DOMAIN" "$NODE_PORT" "$layout"
    fi
}

node_remove() {
    local del_cert=0 del_site=0 del_443=0 del_bal=0 bak
    ui_yesno "Удаление ноды" "── Будет удалено
Контейнеры:  remnanode и $NODE_DECOY
Папка:       $NODE_DIR — перед удалением уйдёт в архив
Фаервол:     правило $NODE_PORT/tcp с $NODE_PANEL_IP

── Останется
Бэкапы:      $SKIPIT_BACKUPS — архивы и копии конфигов
$( (( ${NODE_SHARED:-0} )) && printf '\n── Связка с панелью\nПанель:      вернётся на свой nginx и снова займёт 443 сама\nПерерыв:     панель недоступна несколько секунд, пока nginx поднимается\n' )
Удалить ноду $NODE_DOMAIN?" no || return
    ask_del_cert "$NODE_CERT_NAME" node && del_cert=1
    ui_yesno "Сайт-заглушка" "Удалить файлы сайта из $NODE_WEBROOT?" no && del_site=1
    # 443 закрываем только через ask_close_443: он один знает, нужен ли порт ещё
    # кому-то (панели, странице подписки). Закрыть его вслепую - значит оставить
    # оставшееся без входа с улицы: nginx слушает, а снаружи таймаут.
    ask_close_443 node && del_443=1
    # Порты балансира ничей больше не занимает - про них спрашиваем отдельно
    if [[ $NODE_LAYOUT == balancer ]]; then
        ui_yesno "Порты балансира" "Закрыть в UFW порты $NODE_XHTTP_PORT, $NODE_WS_PUBLIC/tcp?

Их слушала только нода." no && del_bal=1
    fi

    clear; say "Удаляю ноду $NODE_DOMAIN..."
    # В связке фронтом панели был nginx ноды. Сначала возвращаем панели её
    # собственный nginx, иначе после сноса она останется без входа с улицы.
    local was_shared=${NODE_SHARED:-0}
    [[ -f $NODE_COMPOSE ]] && node_compose_run down --remove-orphans
    if (( was_shared )) && panel_installed 2>/dev/null; then
        say "Возвращаю панели её nginx на 443..."
        NODE_SHARED=0
        PANEL_NGINX_MODE=own
        panel_state_save
        backup_file "$PANEL_COMPOSE" >/dev/null
        panel_compose > "$PANEL_COMPOSE"
        panel_nginx_write
        panel_compose_run up -d --remove-orphans >/dev/null 2>&1
        local perr
        if perr=$(panel_nginx_ok); then
            say "Панель снова отдаётся своим nginx: $(panel_url)"
        else
            say "Внимание: nginx панели не поднялся — $perr"
        fi
    fi
    bak="${SKIPIT_BACKUPS}/remnanode-$(date +%Y%m%d-%H%M%S).tar.gz"
    tar -czf "$bak" -C "$(dirname "$NODE_DIR")" "$(basename "$NODE_DIR")" 2>/dev/null && chmod 600 "$bak"
    rm -rf "$NODE_DIR"
    node_ufw_remove "$NODE_PANEL_IP" "$NODE_PORT"
    if command -v ufw >/dev/null 2>&1; then
        (( del_443 )) && ufwc --force delete allow 443/tcp >/dev/null 2>&1
        (( del_bal )) && node_ufw_close_balancer
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
        # Установку запускает меню компонентов; сюда попадаем только с готовой нодой.
        # Ноду могли удалить прямо отсюда - тогда возвращаемся к списку компонентов.
        node_installed || return
        local tab=$'\t'
        hdr="Схема:      $(node_layout_ru "$NODE_LAYOUT")
Домен:      $NODE_DOMAIN
IP панели:  $NODE_PANEL_IP
Порт ноды:  $NODE_PORT

Компонент${tab}Состояние
remnanode${tab}$(ctr_state_ru remnanode)
nginx${tab}$(ctr_state_ru "$NODE_DECOY")
Сертификат${tab}$(node_cert_state)
UFW${tab}$(if ! command -v ufw >/dev/null 2>&1; then echo "не установлен"; elif ufw_active; then echo "включён"; else echo "выключен"; fi)"
        c=$(ui_menu "Нода Remnawave" "$hdr" \
            ""        "Панель" \
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

# ==== Панель Remnawave ====
# Стек панели: backend + PostgreSQL + Valkey в bridge-сети remnawave-network.
# Наружу панель не смотрит: backend публикует порты только на 127.0.0.1, а в интернет
# её выдаёт отдельный nginx в host-сети - так на него действуют правила UFW
# (у контейнеров с проброшенными портами -p правила UFW не работают).
#
# Вход в панель закрыт cookie: по секретному пути cookie ставится и дальше запросы
# идут как есть. Пути не переписываются, поэтому SPA и /api работают без правок.
# Исключение - /api/sub/: по нему клиенты забирают подписку, cookie у них нет.
PANEL_DIR="/opt/remnawave"
PANEL_COMPOSE="${PANEL_DIR}/docker-compose.yml"
PANEL_ENV="${PANEL_DIR}/.env"
PANEL_NGINX="${PANEL_DIR}/nginx.conf"
PANEL_STATE="${SKIPIT_ETC}/panel.conf"
PANEL_NGINX_CTR="remnawave-panel-nginx"
PANEL_BACKEND_IMAGE="remnawave/backend:3"
PANEL_DB_IMAGE="postgres:18.4"          # мажор менять только через pg_upgrade/дамп - не в «Обновить»
PANEL_REDIS_IMAGE="valkey/valkey:9-alpine"
PANEL_APP_PORT=3000
PANEL_METRICS_PORT=3001
PANEL_BACKUP_KEEP=14
PANEL_BACKUP_CRON="/etc/cron.d/skipit-panel-backup"

# Потолки памяти. В образах панели и страницы подписки зашито
# NODE_OPTIONS=--max-old-space-size=16384: V8 считает, что у него 16 ГБ, и не
# видит смысла собирать мусор всерьёз. На сервере с 2-4 ГБ это значит, что
# раньше сборки мусора приедет OOM-killer ядра и снесёт процесс, а то и базу
# рядом. Считаем потолки от объёма RAM и отдаём их через env_file: значения из
# него перекрывают ENV образа.
panel_node_heap_mb() {
    local ram; ram=$(sysctl_ram_mb); [[ $ram =~ ^[0-9]+$ ]] || ram=2048
    if   (( ram <= 2048 )); then echo 256
    elif (( ram <= 4096 )); then echo 384
    elif (( ram <= 8192 )); then echo 768
    else echo 1024; fi
}
sub_node_heap_mb() {
    local ram; ram=$(sysctl_ram_mb); [[ $ram =~ ^[0-9]+$ ]] || ram=2048
    if   (( ram <= 2048 )); then echo 192
    elif (( ram <= 4096 )); then echo 256
    else echo 512; fi
}
# Панель держит три процесса Node (api, jobs, scheduler) - потолок кучи на каждый
# плюс запас на код, буферы и нативную память
panel_mem_limit_mb() { echo $(( $(panel_node_heap_mb) * 3 + 384 )); }
sub_mem_limit_mb()   { echo $(( $(sub_node_heap_mb) + 256 )); }
# База: четверть RAM, но не меньше 512 МБ и не больше 2 ГБ. Внутрь лимита входит
# и shm_size, поэтому ниже 512 опускаться нельзя
panel_db_mem_limit_mb() {
    local ram v; ram=$(sysctl_ram_mb); [[ $ram =~ ^[0-9]+$ ]] || ram=2048
    v=$(( ram / 4 )); (( v < 512 )) && v=512; (( v > 2048 )) && v=2048; echo "$v"
}

PANEL_DOMAIN=""; PANEL_CERT_METHOD=""; PANEL_CERT_NAME=""; PANEL_PATH=""; PANEL_SUB_DOMAIN=""
PANEL_SUB_CERT=""
# own - свой контейнер nginx на 443 (обычная установка);
# socket - блоки панели уехали в nginx ноды на unix-сокет, 443 держит Xray.
# Значение по умолчанию own, поэтому состояние от прошлых версий читается как есть.
PANEL_NGINX_MODE="own"
PANEL_KEYS=(PANEL_DOMAIN PANEL_CERT_METHOD PANEL_CERT_NAME PANEL_PATH PANEL_SUB_DOMAIN PANEL_SUB_CERT
            PANEL_NGINX_MODE)

panel_state_load() {
    local k v
    [[ -f $PANEL_STATE ]] || return 1
    while IFS='=' read -r k v; do
        [[ " ${PANEL_KEYS[*]} " == *" $k "* ]] && printf -v "$k" '%s' "$v"
    done < "$PANEL_STATE"
    [[ -n $PANEL_DOMAIN ]]
}

panel_state_save() {
    local k
    mkdir -p "$SKIPIT_ETC"
    ( umask 077; for k in "${PANEL_KEYS[@]}"; do printf '%s=%s\n' "$k" "${!k}"; done > "$PANEL_STATE" )
    chmod 600 "$PANEL_STATE"
}

panel_installed() { panel_state_load && [[ -f $PANEL_COMPOSE ]]; }
panel_env_get() { sed -n "s/^$1=//p" "$PANEL_ENV" 2>/dev/null | head -n 1; }
panel_compose_run() { ( cd "$PANEL_DIR" && docker compose "$@" ); }

# В связке фронт панели - это nginx ноды: и контейнер, и файл конфига другие.
# Всё, что перезагружает или проверяет nginx панели, ходит через эти две функции.
panel_bundled()   { [[ ${PANEL_NGINX_MODE:-own} == socket ]]; }

# Подсеть bridge-сети панели. В связке нода слушает свой порт на хосте, а панель
# живёт в контейнере: 127.0.0.1 для неё - это она сама, и до ноды пакет уходит
# с адреса вида 172.18.0.5. Правило UFW должно пускать именно эту подсеть, иначе
# панель молча упрётся в таймаут и не отдаст ноде конфиг - а без конфига Xray
# не поднимет 443.
panel_docker_subnet() {
    local net
    net=$(docker network inspect remnawave-network \
        --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null)
    [[ $net == */* ]] || return 1
    printf '%s' "$net"
}
panel_nginx_ctr() { panel_bundled && echo "$NODE_DECOY" || echo "$PANEL_NGINX_CTR"; }
panel_nginx_file(){ panel_bundled && echo "$NODE_NGINX"  || echo "$PANEL_NGINX"; }

# Перегенерировать конфиг nginx панели там, где он сейчас живёт. В связке это
# конфиг ноды целиком: её сайт-заглушка и блоки панели лежат в одном файле,
# и собрать его можно только генератором ноды.
panel_nginx_write() {
    local cookie api_key
    cookie=$(panel_env_get SKIPIT_PANEL_COOKIE); api_key=$(panel_env_get SKIPIT_PANEL_API_KEY)
    if panel_bundled; then
        node_state_load 2>/dev/null || return 1
        node_nginx_conf "$NODE_DOMAIN" "$NODE_CERT_NAME" "$NODE_LAYOUT" > "$NODE_NGINX"
    else
        panel_nginx_conf "$PANEL_DOMAIN" "$PANEL_CERT_NAME" "$PANEL_PATH" "$cookie" "$api_key" \
            ${PANEL_SUB_CERT:+"$PANEL_SUB_DOMAIN" "$PANEL_SUB_CERT"} > "$PANEL_NGINX"
    fi
}

panel_nginx_reload() { docker exec "$(panel_nginx_ctr)" nginx -s reload >/dev/null 2>&1; }

# Секрет для .env: 32 байта энтропии в base64url
panel_gen_secret() { head -c 32 /dev/urandom | base64 -w0 | tr '+/' '-_' | tr -d '='; }
# Секретный путь входа: /p-<12 hex>
panel_gen_path() { printf '/p-%s' "$(openssl rand -hex 6)"; }
# Значение cookie, по которому nginx пускает в панель
panel_gen_cookie() { openssl rand -hex 16; }

panel_url() { printf 'https://%s%s' "$PANEL_DOMAIN" "$PANEL_PATH"; }

# .env панели. Пароль БД, APP_SECRET и прочее генерируются один раз и переживают обновления.
panel_write_env() { # домен sub_public_domain
    local app_secret pg_pass metrics_pass webhook_secret cookie api_key
    app_secret=$(panel_env_get APP_SECRET);            [[ -n $app_secret ]]      || app_secret=$(panel_gen_secret)
    pg_pass=$(panel_env_get POSTGRES_PASSWORD);        [[ -n $pg_pass ]]         || pg_pass=$(panel_gen_secret)
    metrics_pass=$(panel_env_get METRICS_PASS);        [[ -n $metrics_pass ]]    || metrics_pass=$(panel_gen_secret)
    webhook_secret=$(panel_env_get WEBHOOK_SECRET_HEADER); [[ -n $webhook_secret ]] || webhook_secret=$(panel_gen_secret)
    cookie=$(panel_env_get SKIPIT_PANEL_COOKIE);       [[ -n $cookie ]]          || cookie=$(panel_gen_cookie)
    api_key=$(panel_env_get SKIPIT_PANEL_API_KEY);     [[ -n $api_key ]]         || api_key=$(panel_gen_cookie)
    mkdir -p "$PANEL_DIR"
    ( umask 077; cat > "$PANEL_ENV" <<EOF
# SkipIt Tool · панель Remnawave. Файл с секретами, права 600.
# APP_SECRET и пароль БД создаются один раз и при обновлении не меняются.

APP_PORT=${PANEL_APP_PORT}
METRICS_PORT=${PANEL_METRICS_PORT}
API_INSTANCES=1

# Потолок кучи V8 на процесс, считается от RAM сервера. Перекрывает зашитые
# в образ 16 ГБ - иначе V8 не поджимается и сервер уходит в OOM.
NODE_OPTIONS=--max-old-space-size=$(panel_node_heap_mb)

DATABASE_URL="postgresql://postgres:${pg_pass}@remnawave-db:5432/postgres"
POSTGRES_USER=postgres
POSTGRES_PASSWORD=${pg_pass}
POSTGRES_DB=postgres
REDIS_SOCKET=/var/run/valkey/valkey.sock

APP_SECRET=${app_secret}
PANEL_DOMAIN=${1}
FRONT_END_DOMAIN=${1}
SUB_PUBLIC_DOMAIN=${2}

METRICS_USER=metrics
METRICS_PASS=${metrics_pass}

IS_TELEGRAM_NOTIFICATIONS_ENABLED=false
WEBHOOK_ENABLED=false
WEBHOOK_SECRET_HEADER=${webhook_secret}

SHORT_UUID_METHOD=nanoid
SHORT_UUID_LENGTH=16

# Читают только SkipIt Tool и nginx-конфиг рядом:
# COOKIE - по нему nginx пускает в панель из браузера,
# API_KEY - заголовок X-Api-Key, по нему в /api/ проходит сабпейдж с другого сервера
SKIPIT_PANEL_COOKIE=${cookie}
SKIPIT_PANEL_API_KEY=${api_key}
EOF
    )
    chmod 600 "$PANEL_ENV"
}

panel_compose() {
local cert_mounts sub_service="" ngx_service=""
if [[ -n ${PANEL_CERT_NAME:-} ]]; then
    cert_mounts="      - /etc/letsencrypt/live/${PANEL_CERT_NAME}:/etc/letsencrypt/live/${PANEL_CERT_NAME}:ro
      - /etc/letsencrypt/archive/${PANEL_CERT_NAME}:/etc/letsencrypt/archive/${PANEL_CERT_NAME}:ro"
    # у страницы подписки свой домен и свой сертификат - монтируем и его
    if [[ -n ${PANEL_SUB_CERT:-} && $PANEL_SUB_CERT != "$PANEL_CERT_NAME" ]]; then
        cert_mounts+="
      - /etc/letsencrypt/live/${PANEL_SUB_CERT}:/etc/letsencrypt/live/${PANEL_SUB_CERT}:ro
      - /etc/letsencrypt/archive/${PANEL_SUB_CERT}:/etc/letsencrypt/archive/${PANEL_SUB_CERT}:ro"
    fi
else
    cert_mounts="      - /etc/letsencrypt/live:/etc/letsencrypt/live:ro
      - /etc/letsencrypt/archive:/etc/letsencrypt/archive:ro"
fi
# Страница подписки рядом с панелью: ходит в неё по внутренней сети, минуя nginx,
# поэтому cookie-гейт ей не мешает и X-Api-Key не нужен
if [[ -n ${PANEL_SUB_CERT:-} ]]; then
    sub_service="
  ${SUB_CTR}:
    <<: *common
    image: ${SUB_IMAGE}
    container_name: ${SUB_CTR}
    hostname: ${SUB_CTR}
    mem_limit: $(sub_mem_limit_mb)m
    env_file: sub.env
    networks: [remnawave-network]
    ports:
      - 127.0.0.1:${SUB_APP_PORT}:${SUB_APP_PORT}
    depends_on:
      remnawave:
        condition: service_healthy
"
fi
# В связке фронт панели - nginx ноды: он уже держит unix-сокет за Xray на 443.
# Второй nginx тут не нужен и всё равно не смог бы занять 443.
if ! panel_bundled; then
    ngx_service="  # nginx в host-сети: так на 443 действуют правила UFW
  ${PANEL_NGINX_CTR}:
    <<: *common
    image: ${NODE_NGINX_IMAGE}
    container_name: ${PANEL_NGINX_CTR}
    hostname: ${PANEL_NGINX_CTR}
    mem_limit: 128m
    network_mode: host
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
${cert_mounts}
"
fi
cat <<EOF
# SkipIt Tool · панель Remnawave. Секреты - в .env рядом.
# Версия Postgres закреплена намеренно: смена мажора требует pg_upgrade,
# иначе кластер не стартует. Пункт «Обновить панель» её не трогает.

x-common: &common
  restart: unless-stopped
  security_opt:
    - no-new-privileges:true
  logging:
    driver: json-file
    options:
      max-size: 10m
      max-file: "3"

services:
  remnawave:
    <<: *common
    image: ${PANEL_BACKEND_IMAGE}
    container_name: remnawave
    hostname: remnawave
    mem_limit: $(panel_mem_limit_mb)m
    env_file: .env
    networks: [remnawave-network]
    ulimits:
      nofile: 1048576
    volumes:
      - valkey-socket:/var/run/valkey
    ports:
      - 127.0.0.1:${PANEL_APP_PORT}:${PANEL_APP_PORT}
      - 127.0.0.1:${PANEL_METRICS_PORT}:${PANEL_METRICS_PORT}
    healthcheck:
      test: ['CMD-SHELL', 'curl -f http://localhost:${PANEL_METRICS_PORT}/health']
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
    depends_on:
      remnawave-db:
        condition: service_healthy
      remnawave-redis:
        condition: service_healthy

  remnawave-db:
    <<: *common
    image: ${PANEL_DB_IMAGE}
    container_name: remnawave-db
    hostname: remnawave-db
    mem_limit: $(panel_db_mem_limit_mb)m
    shm_size: 512mb
    env_file: .env
    networks: [remnawave-network]
    environment:
      - POSTGRES_USER=\${POSTGRES_USER}
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      - POSTGRES_DB=\${POSTGRES_DB}
      - TZ=UTC
    volumes:
      - remnawave-db-data:/var/lib/postgresql
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U \$\${POSTGRES_USER} -d \$\${POSTGRES_DB}']
      interval: 3s
      timeout: 10s
      retries: 3

  remnawave-redis:
    <<: *common
    image: ${PANEL_REDIS_IMAGE}
    container_name: remnawave-redis
    hostname: remnawave-redis
    mem_limit: 256m
    networks: [remnawave-network]
    volumes:
      - valkey-socket:/var/run/valkey
    command: >
      valkey-server
      --save ""
      --appendonly no
      --maxmemory-policy noeviction
      --loglevel warning
      --unixsocket /var/run/valkey/valkey.sock
      --unixsocketperm 777
      --port 0
    healthcheck:
      test: ['CMD', 'valkey-cli', '-s', '/var/run/valkey/valkey.sock', 'ping']
      interval: 3s
      timeout: 3s
      retries: 3

${sub_service}
${ngx_service}
networks:
  remnawave-network:
    name: remnawave-network
    driver: bridge

volumes:
  remnawave-db-data:
    name: remnawave-db-data
  valkey-socket:
    name: valkey-socket
EOF
}

# nginx панели: 443 напрямую (Xray на этом сервере нет).
# TLS - профиль «intermediate» Mozilla, как и у ноды.
# Cookie-гейт панели: три map. Нужны и своему nginx панели, и nginx ноды, когда
# панель стоит за ним. Вынесены отдельно и существуют в одном экземпляре:
# гейт закрывает /api/auth/login от перебора, двум копиям расходиться нельзя.
panel_nginx_maps() { # cookie api-ключ
cat <<EOF
# Вход в панель разрешён только с cookie, которую ставит секретный путь ниже
map \$http_cookie \$skipit_panel_ok {
    default 0;
    "~*(^|;[[:space:]]*)skipit_panel=$1(;|\$)" 1;
}

# Страница подписки на ДРУГОМ сервере ходит в /api/ по заголовку X-Api-Key
map \$http_x_api_key \$skipit_api_key_ok {
    default 0;
    "$2" 1;
}

# В /api/ пускаем, если есть cookie ИЛИ верный X-Api-Key
map "\$skipit_panel_ok\$skipit_api_key_ok" \$skipit_api_ok {
    default 0;
    "~1" 1;
}
EOF
}

# Строки listen для своего nginx панели: 443 напрямую, [::] только при IPv6
panel_listen_own() { # [суффикс]
    printf '    listen 443 ssl%s;\n' "${1:+ $1}"
    [[ -f /proc/net/if_inet6 ]] && printf '    listen [::]:443 ssl%s;\n' "${1:+ $1}"
    return 0
}

# server-блоки панели и (если задана) страницы подписки. Общие для обоих
# генераторов: свой nginx панели слушает 443, nginx ноды - unix-сокет за Xray.
#   $1  строка listen целиком (может быть многострочной)
#   $2  откуда брать адрес клиента: \$remote_addr или \$proxy_protocol_addr.
#       За Xray соединение приходит по сокету, и настоящий IP лежит только
#       в PROXY-заголовке - \$remote_addr там пустой.
panel_server_blocks() { # listen realip домен серт путь cookie [домен-подписки серт-подписки]
    local listen=$1 realip=$2 cert="/etc/letsencrypt/live/$4" xff
    # X-Forwarded-For: за Xray цепочку строить не из чего, берём адрес из PROXY
    if [[ $realip == '$proxy_protocol_addr' ]]; then xff='$proxy_protocol_addr'
    else xff='$proxy_add_x_forwarded_for'; fi
cat <<EOF
# ── Панель
server {
$listen
    http2 on;
    server_name $3;

    # сертификат внутри server: у панели и страницы подписки они разные
    ssl_certificate     $cert/fullchain.pem;
    ssl_certificate_key $cert/privkey.pem;

    client_max_body_size 32m;
    access_log off;

    # Секретный вход: ставит cookie на 30 дней и уводит на корень панели
    location = $5 {
        add_header Set-Cookie "skipit_panel=$6; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=2592000" always;
        return 302 https://\$host/;
    }

    # Подписки клиентов: cookie у них нет и быть не может.
    # Правило длиннее, чем /api/ ниже, поэтому nginx выберет именно его.
    location /api/sub/ {
        proxy_pass http://127.0.0.1:${PANEL_APP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP $realip;
        proxy_set_header X-Forwarded-For $xff;
        proxy_set_header X-Forwarded-Proto https;
    }

    # API панели: браузер с cookie или страница подписки с X-Api-Key. Остальным - 404,
    # чтобы /api/auth/login нельзя было брутить снаружи.
    location /api/ {
        if (\$skipit_api_ok = 0) {
            return 404;
        }
        proxy_pass http://127.0.0.1:${PANEL_APP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP $realip;
        proxy_set_header X-Forwarded-For $xff;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 5m;
    }

    # Всё остальное - только с cookie. Без неё домен выглядит пустым сайтом.
    location / {
        if (\$skipit_panel_ok = 0) {
            return 404;
        }
        proxy_pass http://127.0.0.1:${PANEL_APP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP $realip;
        proxy_set_header X-Forwarded-For $xff;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
    }
}
EOF
    # ── Страница подписки на этом же сервере: свой домен, свой сертификат, без гейта
    [[ -n ${7:-} ]] || return 0
    local scert="/etc/letsencrypt/live/$8"
cat <<EOF

# ── Страница подписки
server {
$listen
    http2 on;
    server_name $7;

    ssl_certificate     $scert/fullchain.pem;
    ssl_certificate_key $scert/privkey.pem;

    access_log off;

    location / {
        proxy_pass http://127.0.0.1:${SUB_APP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP $realip;
        proxy_set_header X-Forwarded-For $xff;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 1m;
    }
}
EOF
}

# Сжатие. Фронтенд панели тянет WASM-модуль и бандлы на десятки мегабайт: без gzip
# они едут по сети как есть, и страница профилей открывается минутами. Ответы идут
# через proxy_pass, поэтому обязателен gzip_proxied - по умолчанию nginx их не жмёт.
# text/html сжимается всегда, его в списке типов не указывают.
nginx_gzip_conf() {
cat <<'EOF'
gzip            on;
gzip_vary       on;
gzip_proxied    any;
gzip_comp_level 5;
gzip_min_length 1024;
gzip_types      application/wasm application/javascript text/javascript application/json
                text/css text/plain text/xml image/svg+xml application/manifest+json
                font/woff font/woff2;
EOF
}

panel_nginx_conf() { # домен серт путь cookie api-ключ [домен-подписки серт-подписки]
cat <<EOF
# SkipIt Tool · панель $1${6:+ + страница подписки $6}
# Файл пересоздаётся SkipIt Tool (Панель → nginx.conf), ручные правки уйдут в бэкап.

server_tokens off;
server_names_hash_bucket_size 128;

$(nginx_gzip_conf)

map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ""      close;
}

$(panel_nginx_maps "$4" "$5")

ssl_protocols       TLSv1.2 TLSv1.3;
ssl_ecdh_curve      X25519:prime256v1:secp384r1;
ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
ssl_prefer_server_ciphers off;
ssl_session_cache   shared:skipit_tls:10m;
ssl_session_timeout 4h;
ssl_session_tickets off;

$(panel_server_blocks "$(panel_listen_own)" '$remote_addr' "$1" "$2" "$3" "$4" "${6:-}" "${7:-}")

# Любое другое имя в SNI: рукопожатие обрывается, сертификат не показывается
server {
$(panel_listen_own default_server)
    ssl_reject_handshake on;
}
EOF
}

panel_nginx_ok() { # → текст ошибки
    local out
    local c; c=$(panel_nginx_ctr)
    [[ $(ctr_status "$c") == running ]] || { echo "контейнер $c не работает"; return 1; }
    out=$(docker exec "$c" nginx -t 2>&1) || { echo "$out"; return 1; }
}

# Панель отвечает на /health в контейнере метрик
panel_healthy() {
    curl -fsS -o /dev/null --max-time 5 "http://127.0.0.1:${PANEL_METRICS_PORT}/health" 2>/dev/null
}

panel_wait_healthy() { # секунд
    local i=0 n=${1:-90}
    while (( i < n )); do
        panel_healthy && return 0
        [[ $(ctr_status remnawave) == exited ]] && return 1
        sleep 3; i=$((i + 3))
        ui_loading "Жду запуска панели… ${i} с из ${n}"
    done
    return 1
}

# Контейнер healthy по порту метрик, но REST-часть на 3000 поднимается позже:
# без этого ожидания регистрация админа стучится в ещё не готовый API.
panel_wait_api() { # секунд
    local i=0 n=${1:-90} rc
    while (( i < n )); do
        panel_register_open; rc=$?
        (( rc != 1 )) && return 0
        sleep 3; i=$((i + 3))
        ui_loading "Жду API панели… ${i} с из ${n}"
    done
    return 1
}

# ---- Первый администратор и API-токен ----
# На свежей панели SkipIt Tool заводит супер-админа и сразу выпускает API-токен
# для страницы подписки. После создания админа register закрывается, поэтому
# на уже настроенной панели это не сработает - там токен вводится руками.
# Пароль по требованиям бэкенда: >=24 символов, заглавная + строчная + цифра.
# Логин админа тоже случайный: угадать пару «логин + пароль» труднее, чем один пароль.
# Формат ограничений панели не документирован, поэтому при отказе откатываемся на admin.
panel_gen_admin_user() { printf 'admin_%s' "$(openssl rand -hex 4)"; }

panel_gen_admin_password() {
    local p
    while :; do
        p=$(head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 28)
        [[ ${#p} -eq 28 && $p == *[A-Z]* && $p == *[a-z]* && $p == *[0-9]* ]] && { printf '%s' "$p"; return; }
    done
}

panel_api() { printf 'http://127.0.0.1:%s/api' "$PANEL_APP_PORT"; }
# Remnawave (ProxyCheckMiddleware) отвечает только на запросы «из-за реверс-прокси с HTTPS»:
# без этих заголовков обращение напрямую в 127.0.0.1:3000 обрывается без ответа.
# Нужны оба - и схема, и X-Forwarded-For; Host не обязателен.
PANEL_PROXY_HDR=(-H "X-Forwarded-Proto: https" -H "X-Forwarded-For: 127.0.0.1")
# Завести в панели профиль конфигурации и ноду под него - без похода в браузер.
# В связке все данные у нас уже есть: профиль Xray генерирует node_profile_json,
# адрес и порт известны, токен выпущен при установке панели. Гонять человека в UI
# ради этого незачем.
# uuid созданной ноды - в PANEL_NODE_UUID, текст проблемы - в PANEL_NODE_ERR.
# Через stdout ничего не возвращаем: вызов из $( ) уносил бы обе переменные в
# подоболочку, и на экране вместо причины оставалась пустота.
PANEL_NODE_ERR=""; PANEL_NODE_UUID=""
panel_create_node() { # домен порт схема
    local domain=$1 port=$2 layout=$3
    local name=${domain%%.*} tok body out prof inb steal
    PANEL_NODE_ERR=""; PANEL_NODE_UUID=""

    tok=$(panel_api_token) || { PANEL_NODE_ERR="у SkipIt Tool нет API-токена панели"; return 1; }
    # Ставим молча: это середина установки, вопрос «поставить jq?» здесь не к месту
    command -v jq >/dev/null 2>&1 || pkg_install jq >/dev/null 2>&1
    command -v jq >/dev/null 2>&1 || { PANEL_NODE_ERR="не установлен пакет jq"; return 1; }
    # Имя ноды в панели - минимум 3 символа, иначе панель отклонит запрос
    (( ${#name} >= 3 )) || name="node-$name"

    # 1. Профиль: {"name": ..., "config": <тот же JSON, что показывает подсказка>}
    body=$(printf '{"name":%s,"config":%s}' \
        "$(jq -Rn --arg v "$name" '$v')" "$(node_profile_json "$domain" "$layout")")
    out=$(panel_api_post "/config-profiles" "$body") || {
        PANEL_NODE_ERR="панель не приняла профиль: $PANEL_API_ERR"; return 1; }
    prof=$(jq -r '.response.uuid // empty' <<< "$out")
    [[ -n $prof ]] || { PANEL_NODE_ERR="панель не вернула uuid профиля"; return 1; }

    # 2. Инбаунды профиля: в связке он один - steal-<имя>
    inb=$(jq -r '[.response.inbounds[]?.uuid] | map(select(. != null)) | @json' <<< "$out")
    [[ -n $inb && $inb != "[]" ]] || {
        PANEL_NODE_ERR="в созданном профиле нет инбаундов"; return 1; }
    # Отдельно - steal-инбаунд: под него заводится хост Self-steal (TCP)
    steal=$(jq -r --arg t "$(node_tag "$domain" steal)" \
        '.response.inbounds[]? | select(.tag == $t) | .uuid' <<< "$out" 2>/dev/null | head -n 1)

    # 3. Нода под этот профиль. Адрес - домен ноды: панель живёт в контейнере,
    #    и петлевой адрес привёл бы её саму к себе, а не к ноде на хосте.
    body=$(printf '{"name":%s,"address":%s,"port":%s,"configProfile":{"activeConfigProfileUuid":%s,"activeInbounds":%s}}' \
        "$(jq -Rn --arg v "$name" '$v')" "$(jq -Rn --arg v "$domain" '$v')" "$port" \
        "$(jq -Rn --arg v "$prof" '$v')" "$inb")
    out=$(panel_api_post "/nodes" "$body") || {
        PANEL_NODE_ERR="панель не приняла ноду: $PANEL_API_ERR"; return 1; }
    PANEL_NODE_UUID=$(jq -r '.response.uuid // empty' <<< "$out")

    # 4. Хост под Self-steal (TCP) и его инбаунд в сквод. Не вышло - не беда:
    #    нода уже создана и работает, текст проблемы остаётся в PANEL_HOST_ERR.
    panel_create_steal_host "$prof" "$steal" "$domain" || true
    return 0
}

# Запрос в API панели. Тело - третьим аргументом, ошибка - в PANEL_API_ERR.
# Тело идёт через stdin: шаблон Xray JSON - это десятки килобайт, аргументом
# командной строки такое передавать незачем.
PANEL_API_ERR=""
panel_api_req() { # метод путь [тело]
    local tok code out tmp
    PANEL_API_ERR=""
    tok=$(panel_api_token) || { PANEL_API_ERR="нет токена"; return 1; }
    tmp=$(mktemp) || return 1
    if [[ -n ${3:-} ]]; then
        code=$(printf '%s' "$3" | curl -sS -o "$tmp" -w '%{http_code}' --max-time 25 \
            -X "$1" "${PANEL_PROXY_HDR[@]}" -H "Authorization: Bearer $tok" \
            -H "Content-Type: application/json" --data-binary @- \
            "$(panel_api)$2" 2>/dev/null) || code=000
    else
        code=$(curl -sS -o "$tmp" -w '%{http_code}' --max-time 25 \
            -X "$1" "${PANEL_PROXY_HDR[@]}" -H "Authorization: Bearer $tok" \
            "$(panel_api)$2" 2>/dev/null) || code=000
    fi
    out=$(cat "$tmp"); rm -f "$tmp"
    case $code in
        200|201) printf '%s' "$out"; return 0 ;;
        000) PANEL_API_ERR="панель не ответила" ;;
        *)   PANEL_API_ERR="код $code$(jq -r 'if .errors then " — " + ([.errors[].message] | join("; ")) elif .message then " — " + (.message|tostring) else "" end' <<< "$out" 2>/dev/null)" ;;
    esac
    return 1
}
panel_api_post() { panel_api_req POST "$1" "${2:-}"; }
panel_api_get()  { panel_api_req GET "$1"; }

# Хост под Self-steal (TCP) - тот самый, который раньше человек заводил руками по
# подсказке мастера. Всё нужное уже есть: профиль, его inbound, домен и 443.
# Ошибка сюда установку не роняет: нода работает и без хоста, текст - в PANEL_HOST_ERR.
PANEL_HOST_ERR=""
panel_create_steal_host() { # uuid-профиля uuid-инбаунда домен
    local prof=$1 inb=$2 domain=$3 remark body
    PANEL_HOST_ERR=""
    [[ -n $inb ]] || { PANEL_HOST_ERR="в профиле не нашёлся инбаунд $(node_tag "$domain" steal)"; return 1; }
    remark=$(node_tag "$domain" steal)
    # Поля - ровно те, что мастер просил заполнить в UI: примечание, адрес, порт,
    # SNI и отпечаток. Остальное панель проставит по умолчанию.
    body=$(jq -cn --arg p "$prof" --arg i "$inb" --arg r "$remark" --arg d "$domain" \
        '{inbound:{configProfileUuid:$p,configProfileInboundUuid:$i},remark:$r,
          address:$d,port:443,sni:$d,fingerprint:"firefox",
          securityLayer:"DEFAULT",isDisabled:false}') || {
        PANEL_HOST_ERR="не удалось собрать запрос (jq)"; return 1; }
    panel_api_post "/hosts" "$body" >/dev/null || {
        PANEL_HOST_ERR="панель не приняла хост: $PANEL_API_ERR"; return 1; }
    log "panel host created: $remark"
    panel_squad_add_inbound "$inb" || return 1
    return 0
}

# Инбаунд - в сквод. Без этого хост в панели есть, а в подписку не попадает:
# Remnawave отдаёт клиенту только те хосты, чей inbound лежит в его скводе.
# Трогаем Default-Squad свежей панели (или единственный, если он один): PATCH
# перезаписывает список целиком, поэтому шлём прежние инбаунды плюс новый.
panel_squad_add_inbound() { # uuid-инбаунда
    local inb=$1 out squad list body
    out=$(panel_api_get "/internal-squads") || {
        PANEL_HOST_ERR="хост создан, но список скводов не получен: $PANEL_API_ERR"; return 1; }
    squad=$(jq -r '(.response.internalSquads // []) as $s
        | (($s | map(select(.name == "Default-Squad"))) + (if ($s | length) == 1 then $s else [] end))
        | .[0].uuid // empty' <<< "$out" 2>/dev/null)
    [[ -n $squad ]] || {
        PANEL_HOST_ERR="хост создан, но сквод Default-Squad не нашёлся — добавьте инбаунд в сквод сами"; return 1; }
    list=$(jq -c --arg s "$squad" --arg i "$inb" \
        '[(.response.internalSquads[]? | select(.uuid == $s) | .inbounds[]?.uuid), $i] | unique' <<< "$out" 2>/dev/null)
    body=$(jq -cn --arg s "$squad" --argjson l "$list" '{uuid:$s,inbounds:$l}') || {
        PANEL_HOST_ERR="хост создан, но не удалось собрать запрос к скводу"; return 1; }
    panel_api_req PATCH "/internal-squads" "$body" >/dev/null || {
        PANEL_HOST_ERR="хост создан, но инбаунд в сквод не добавился: $PANEL_API_ERR"; return 1; }
    log "panel squad: inbound $inb added to $squad"
    return 0
}

# ==== Шаблон Xray JSON «RU-Routing» ====
# Клиентский конфиг с раздельным роутингом: .ru, .su, .рф, госсайты, банки и
# российские сервисы идут напрямую, Telegram - через прокси, IPv6 и QUIC на 443
# закрыты. Панель отдаёт его клиентам Xray JSON вместо шаблона по умолчанию,
# но только если шаблон выбран у хоста - сам по себе он ничего не меняет.
# Заводится при установке панели и пересоздаётся пунктом меню.
PANEL_RU_TPL="RU-Routing"
PANEL_TPL_ERR=""; PANEL_RU_TPL_OK=0
panel_ru_template_ensure() {
    local out uuid body
    PANEL_TPL_ERR=""
    panel_api_token >/dev/null 2>&1 || {
        PANEL_TPL_ERR="у SkipIt Tool нет API-токена панели"; return 1; }
    command -v jq >/dev/null 2>&1 || pkg_install jq >/dev/null 2>&1
    command -v jq >/dev/null 2>&1 || { PANEL_TPL_ERR="не установлен пакет jq"; return 1; }

    out=$(panel_api_get "/subscription-templates") || {
        PANEL_TPL_ERR="панель не отдала список шаблонов: $PANEL_API_ERR"; return 1; }
    uuid=$(jq -r --arg n "$PANEL_RU_TPL" \
        '.response.templates[]? | select(.templateType == "XRAY_JSON" and .name == $n) | .uuid' <<< "$out" 2>/dev/null | head -n 1)
    if [[ -z $uuid ]]; then
        # Создание принимает только имя и тип, содержимое приезжает вторым запросом
        out=$(panel_api_post "/subscription-templates" \
            "$(jq -cn --arg n "$PANEL_RU_TPL" '{name:$n,templateType:"XRAY_JSON"}')") || {
            PANEL_TPL_ERR="панель не приняла шаблон: $PANEL_API_ERR"; return 1; }
        uuid=$(jq -r '.response.uuid // empty' <<< "$out" 2>/dev/null)
        [[ -n $uuid ]] || { PANEL_TPL_ERR="панель не вернула uuid шаблона"; return 1; }
    fi
    body=$(panel_ru_routing_json | jq -c --arg u "$uuid" '{uuid:$u,templateJson:.}' 2>/dev/null) || body=""
    [[ -n $body ]] || { PANEL_TPL_ERR="не удалось собрать шаблон (jq)"; return 1; }
    panel_api_req PATCH "/subscription-templates" "$body" >/dev/null || {
        PANEL_TPL_ERR="панель не сохранила содержимое шаблона: $PANEL_API_ERR"; return 1; }
    log "panel template: $PANEL_RU_TPL ok ($uuid)"
    return 0
}

panel_ru_routing_json() {
cat <<'SKIPIT_RU_ROUTING_EOF'
{
  "dns": {
    "servers": [
      "1.1.1.1",
      "8.8.8.8"
    ],
    "queryStrategy": "UseIPv4"
  },
  "routing": {
    "rules": [
      {
        "port": 53,
        "type": "field",
        "outboundTag": "dns-out"
      },
      {
        "type": "field",
        "protocol": [
          "bittorrent"
        ],
        "outboundTag": "block"
      },
      {
        "ip": [
          "::/0"
        ],
        "type": "field",
        "outboundTag": "block"
      },
      {
        "port": "443",
        "type": "field",
        "network": "udp",
        "outboundTag": "block"
      },
      {
        "ip": [
          "10.0.0.0/8",
          "100.64.0.0/10",
          "127.0.0.0/8",
          "169.254.0.0/16",
          "172.16.0.0/12",
          "192.168.0.0/16",
          "::1/128",
          "fc00::/7",
          "fe80::/10"
        ],
        "type": "field",
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "domain": [
          "regexp:[.]ru$",
          "regexp:[.]su$",
          "regexp:[.]xn--p1ai$",
          "domain:ipify.org",
          "domain:checkip.amazonaws.com",
          "domain:ifconfig.me",
          "domain:ipapi.is",
          "domain:iplocate.io",
          "domain:ip.sb",
          "domain:2ip.ru",
          "domain:mangalib.me",
          "domain:animego.me",
          "domain:showip.net",
          "domain:avtoto.ru",
          "domain:tilda.cc",
          "domain:kinescope.io",
          "domain:kinescopecdn.net",
          "domain:redheadsound.studio",
          "domain:vtbglobalperspectives.com",
          "domain:vtb-direct.com",
          "domain:sber.world",
          "domain:sber.ws",
          "domain:sbercoin.com",
          "domain:ssb.msk.ru",
          "domain:vlb100.ru",
          "domain:slavbank.ru",
          "domain:prvbank.ru",
          "domain:pvubank.com",
          "domain:vtb-grants.fut.ru",
          "domain:selkombank.ru",
          "domain:ankb.ru",
          "domain:bank-arzamas.ru",
          "domain:bankermak.ru",
          "domain:alefbank.com",
          "domain:forshtadt.ru",
          "domain:bfa.ru",
          "domain:rkbank.ru",
          "domain:mvs-bank.ru",
          "domain:bank-credit-suisse-moscow.ru",
          "domain:ziraatbank.ru",
          "domain:jpmorgan.ru",
          "domain:noosferabank.ru",
          "domain:westernunion.ru",
          "domain:tagbank.ru",
          "domain:korona.com",
          "domain:credit-zenit.ru",
          "domain:zenit-card.ru",
          "domain:autobahn.db.com",
          "domain:commerzbank.ru",
          "domain:mizuhogroup.com",
          "domain:ibamoscow.ru",
          "domain:ubs.com",
          "domain:smbcr-bank.ru",
          "domain:yoobusiness.ru",
          "domain:ru.ccb.com",
          "domain:bank131.com",
          "domain:asia-pay.ru",
          "domain:rncoluminis.ru",
          "domain:government.ru",
          "domain:gov.ru",
          "domain:gosuslugi.ru",
          "domain:gu-st.ru",
          "domain:emias.info",
          "domain:mgfoms.ru",
          "domain:edu.ru",
          "domain:cbr.ru",
          "domain:cikrf.ru",
          "domain:ebs.ru",
          "domain:goskey.ru",
          "domain:grfc.ru",
          "domain:izbirkom.ru",
          "domain:kremlin.ru",
          "domain:mil.ru",
          "domain:nalog.ru",
          "domain:xn--80ajghhoc2aj1c8b.xn--p1ai",
          "domain:mos.ru",
          "domain:mosreg.ru",
          "domain:spb.ru",
          "domain:sevastopol.ru",
          "domain:sev.ru",
          "domain:adygeya.ru",
          "domain:bashkiria.ru",
          "domain:buryatia.ru",
          "domain:chuvashia.ru",
          "domain:crimea.ru",
          "domain:dagestan.ru",
          "domain:grozny.ru",
          "domain:i-ola.ru",
          "domain:izhevsk.ru",
          "domain:kalmykia.ru",
          "domain:karelia.ru",
          "domain:kazan.ru",
          "domain:kchr.ru",
          "domain:khakassia.ru",
          "domain:mari-el.ru",
          "domain:mari.ru",
          "domain:mordovia.ru",
          "domain:nalchik.ru",
          "domain:ptz.ru",
          "domain:rkomi.ru",
          "domain:tatarstan.ru",
          "domain:tuva.ru",
          "domain:udm.ru",
          "domain:udmurtia.ru",
          "domain:ulan-ude.ru",
          "domain:vladikavkaz.ru",
          "domain:yakutia.ru",
          "domain:altai.ru",
          "domain:chita.ru",
          "domain:kamchatka.ru",
          "domain:khabarovsk.ru",
          "domain:khv.ru",
          "domain:krasnodar.su",
          "domain:krasnoyarsk.ru",
          "domain:kuban.ru",
          "domain:marine.ru",
          "domain:perm.ru",
          "domain:stavropol.ru",
          "domain:stv.ru",
          "domain:vl.ru",
          "domain:vladivostok.ru",
          "domain:amur.ru",
          "domain:arkhangelsk.ru",
          "domain:astrakhan.ru",
          "domain:belgorod.ru",
          "domain:bir.ru",
          "domain:bryansk.ru",
          "domain:cbg.ru",
          "domain:chel.ru",
          "domain:chelyabinsk.ru",
          "domain:ekburg.ru",
          "domain:xn--80acgfbsl1azdqr.xn--p1ai",
          "domain:irk.ru",
          "domain:irkutsk.ru",
          "domain:ivanovo.ru",
          "domain:jar.ru",
          "domain:kaluga.ru",
          "domain:kemerovo.ru",
          "domain:kirov.ru",
          "domain:koenig.ru",
          "domain:kostroma.ru",
          "domain:kurgan.ru",
          "domain:kursk.ru",
          "domain:lipetsk.ru",
          "domain:magadan.ru",
          "domain:murmansk.ru",
          "domain:nn.ru",
          "domain:nov.ru",
          "domain:novosibirsk.ru",
          "domain:nsk.ru",
          "domain:omsk.ru",
          "domain:orb.ru",
          "domain:oryol.ru",
          "domain:penza.ru",
          "domain:psk",
          "domain:psk.ru",
          "domain:pskov.ru",
          "domain:rnd.ru",
          "domain:ryazan.ru",
          "domain:sakhalin.ru",
          "domain:samara.ru",
          "domain:saratov.ru",
          "domain:simbirsk.ru",
          "domain:smolensk.ru",
          "domain:tambov.ru",
          "domain:tom.ru",
          "domain:tomsk.ru",
          "domain:tsaritsyn.ru",
          "domain:tsk.ru",
          "domain:tula.ru",
          "domain:tver.ru",
          "domain:tyumen.ru",
          "domain:vladimir.ru",
          "domain:vlg.ru",
          "domain:volgograd.ru",
          "domain:vologda.ru",
          "domain:voronezh.ru",
          "domain:vrn.ru",
          "domain:vyatka.ru",
          "domain:yaroslavl.ru",
          "domain:yuzhno-sakhalinsk.ru",
          "domain:chukotka.ru",
          "domain:jamal.ru",
          "domain:surgut.ru",
          "domain:yamal.ru",
          "domain:zdrav10.ru",
          "domain:1c-bitrix.ru",
          "domain:1c.ru",
          "domain:1cfresh.com",
          "domain:1cloud.ru",
          "domain:1internet.tv",
          "domain:2gis.ae",
          "domain:2gis.am",
          "domain:2gis.az",
          "domain:2gis.by",
          "domain:2gis.com",
          "domain:2gis.com.cy",
          "domain:2gis.cz",
          "domain:2gis.ge",
          "domain:2gis.kg",
          "domain:2gis.kz",
          "domain:2gis.ru",
          "domain:2gis.tj",
          "domain:2gis.ua",
          "domain:2gis.uz",
          "domain:47news.ru",
          "domain:4meeting.me",
          "domain:5ka.ru",
          "domain:5post.market",
          "domain:abr.ru",
          "domain:aclub.ru",
          "domain:adfox.ru",
          "domain:admetrica.ru",
          "domain:aeroflot.ru",
          "domain:alfa-bank.com",
          "domain:alfa-bank.ru",
          "domain:alfa-finance.com",
          "domain:alfa-fx.com",
          "domain:alfa-pc.com",
          "domain:alfa-usa.com",
          "domain:alfabank.com",
          "domain:alfabank.ru",
          "domain:alfafinance.biz",
          "domain:alfafinance.ru",
          "domain:alfafuture.com",
          "domain:alfafuture.ru",
          "domain:alfafx.com",
          "domain:alfaleasing.ru",
          "domain:alfaprivate.com",
          "domain:alformacap.com",
          "domain:alformacapital.com",
          "domain:auth-nsdi.ru",
          "domain:auto.ru",
          "domain:av.ru",
          "domain:avito.ru",
          "domain:avito.st",
          "domain:baltbank.ru",
          "domain:banka-ui.dev",
          "domain:banki.ru",
          "domain:bankline.ru",
          "domain:beeline.ru",
          "domain:beta-bank.com",
          "domain:bitrix24.ru",
          "domain:bronevik.com",
          "domain:cdn-tinkoff.ru",
          "domain:cdn-vk.ru",
          "domain:chizhik.club",
          "domain:citydrive.ru",
          "domain:clstorage.net",
          "domain:credistory.ru",
          "domain:csat.ru",
          "domain:cscampus.ru",
          "domain:dbo-dengi.online",
          "domain:dellin.ru",
          "domain:dixy.ru",
          "domain:dnevnik.ru",
          "domain:dns-shop.ru",
          "domain:dodopizza.ru",
          "domain:dom.ru",
          "domain:domclick.ru",
          "domain:donationalerts.com",
          "domain:drweb.ru",
          "domain:dzen.ru",
          "domain:dzeninfra.ru",
          "domain:e5.ru",
          "domain:edadeal.io",
          "domain:edadeal.ru",
          "domain:fastvps.ru",
          "domain:finuslugi.ru",
          "domain:fivepost.ru",
          "domain:fix-price.com",
          "domain:gazeta.ru",
          "domain:gazprombank.ru",
          "domain:gazprombank.tech",
          "domain:gazprompay.ru",
          "domain:gorodpay.ru",
          "domain:gpb.ru",
          "domain:gpmdi.ru",
          "domain:hh.ru",
          "domain:idx5.ru",
          "domain:imgsmail.ru",
          "domain:investalfabank.com",
          "domain:iz.ru",
          "domain:jivo.ru",
          "domain:jivochat.com",
          "domain:jivosite.com",
          "domain:jx5.ru",
          "domain:kaspersky.com",
          "domain:kaspersky.ru",
          "domain:kazanexpress.ru",
          "domain:kinopoisk-ru.clstorage.net",
          "domain:kinopoisk.ru",
          "domain:kommersant.ru",
          "domain:kp.ru",
          "domain:krasyar.ru",
          "domain:krd.ru",
          "domain:kuper.ru",
          "domain:lead-pro2023.online",
          "domain:lemanapro.ru",
          "domain:lenta.com",
          "domain:lenta.ru",
          "domain:lmru.tech",
          "domain:magnit.ru",
          "domain:mail.ru",
          "domain:max.ru",
          "domain:megafon.ru",
          "domain:megamarket.ru",
          "domain:megamarket.tech",
          "domain:memealerts.com",
          "domain:mirpayonline.ru",
          "domain:miya-news.online",
          "domain:mm.ru",
          "domain:mnogolososya.ru",
          "domain:moex.com",
          "domain:mradx.net",
          "domain:mts.ru",
          "domain:mtsdengi.ru",
          "domain:mvk.com",
          "domain:myapelsin.ru",
          "domain:mycdn.me",
          "domain:mymts.ru",
          "domain:naydex.net",
          "domain:nbki.ru",
          "domain:netmonet.co",
          "domain:nspk.ru",
          "domain:ok.ru",
          "domain:okcdn.ru",
          "domain:okko.sport",
          "domain:okko.tv",
          "domain:okolo.app",
          "domain:oneme.ru",
          "domain:ozon.ru",
          "domain:ozone.ru",
          "domain:ozonusercontent.com",
          "domain:perekrestok.ru",
          "domain:pochta.ru",
          "domain:psbank.ru",
          "domain:psblog.ru",
          "domain:qms.ru",
          "domain:rambler.ru",
          "domain:rbc.ru",
          "domain:res-nsdi.ru",
          "domain:rostaxi.org",
          "domain:rostelecom.ru",
          "domain:rshb.ru",
          "domain:rt.ru",
          "domain:rtbcdn.ru",
          "domain:russiacalling.com",
          "domain:rutube.ru",
          "domain:rutubelist.ru",
          "domain:rzd-bonus.ru",
          "domain:rzd.ru",
          "domain:sbermarket.ru",
          "domain:sbermegamarket.ru",
          "domain:sbpgpb.ru",
          "domain:sistema-capital.com",
          "domain:spvb.ru",
          "domain:static-storage.net",
          "domain:svoy.academy",
          "domain:t2.ru",
          "domain:tamtam.chat",
          "domain:taximaxim.ru",
          "domain:taxsee.com",
          "domain:tbank-online.com",
          "domain:tele2.ru",
          "domain:timeweb.cloud",
          "domain:timeweb.com",
          "domain:tips.tips",
          "domain:tnt-online.ru",
          "domain:tochka-tech.com",
          "domain:tochka.com",
          "domain:topdelivery.ru",
          "domain:trbcdn.net",
          "domain:tsx.x5static.net",
          "domain:tu-tu.ru",
          "domain:turbopages.org",
          "domain:tutu.ru",
          "domain:usedesk.ru",
          "domain:userapi.com",
          "domain:uxfeedback.ru",
          "domain:vgtrk.ru",
          "domain:victoria-group.ru",
          "domain:vk-analytics.ru",
          "domain:vk-apps.com",
          "domain:vk-apps.ru",
          "domain:vk-cdn.me",
          "domain:vk-cdn.net",
          "domain:vk-portal.net",
          "domain:vk.cc",
          "domain:vk.com",
          "domain:vk.company",
          "domain:vk.design",
          "domain:vk.link",
          "domain:vk.me",
          "domain:vk.ru",
          "domain:vk.team",
          "domain:vkcache.com",
          "domain:vkcloud-static.ru",
          "domain:vkgo.app",
          "domain:vklive.app",
          "domain:vkmessenger.app",
          "domain:vkmessenger.com",
          "domain:vkontakte.ru",
          "domain:vkuser.net",
          "domain:vkuseraudio.com",
          "domain:vkuseraudio.net",
          "domain:vkuseraudio.ru",
          "domain:vkusercdn.ru",
          "domain:vkuserlive.net",
          "domain:vkuserphoto.ru",
          "domain:vkuservideo.com",
          "domain:vkuservideo.net",
          "domain:vkuservideo.ru",
          "domain:vkusnoitochka.ru",
          "domain:vkusvill.ru",
          "domain:vkvideo.ru",
          "domain:vtb-liga.fut.ru",
          "domain:vtb-russia.com",
          "domain:vtb.bank.in",
          "domain:vtb.com",
          "domain:vtb.corp.ru",
          "domain:vtb.digital",
          "domain:vtb.fut.ru",
          "domain:vtb.promo",
          "domain:vtb.ru",
          "domain:vtb24.com",
          "domain:vtb24.ru",
          "domain:vtbcareer.com",
          "domain:vtbfamily.ru",
          "domain:vtbindia.com",
          "domain:vtbkep.site",
          "domain:vtbpartners.com",
          "domain:vtbrussia.com",
          "domain:vtbrussia.ru",
          "domain:vtbstrana.ru",
          "domain:wb.ru",
          "domain:webvisor.com",
          "domain:webvisor.org",
          "domain:whoosh.bike",
          "domain:wildberries.ru",
          "domain:wink.ru",
          "domain:x5.ru",
          "domain:x5.tech",
          "domain:x5club.ru",
          "domain:x5id.ru",
          "domain:x5l.ru",
          "domain:x5paket.ru",
          "domain:x5q.ru",
          "domain:xn----7sb7akeedqd.xn--p1ai",
          "domain:xn--80aacoonefzg3am8b1fsb.xn--p1ai",
          "domain:xn--90ab2c.xn--p1ai",
          "domain:xn--90aifd0aza.site",
          "domain:xn--b1aew.xn--p1ai",
          "domain:xn--d1acpjx3f.xn--p1ai",
          "domain:ya.ru",
          "domain:yads.tech",
          "domain:yandex",
          "domain:yandex-bank.net",
          "domain:yandex-images.clstorage.net",
          "domain:yandex-team.ru",
          "domain:yandex.aero",
          "domain:yandex.az",
          "domain:yandex.by",
          "domain:yandex.cloud",
          "domain:yandex.co.il",
          "domain:yandex.com",
          "domain:yandex.com.am",
          "domain:yandex.com.ge",
          "domain:yandex.com.ru",
          "domain:yandex.com.tr",
          "domain:yandex.com.ua",
          "domain:yandex.de",
          "domain:yandex.ee",
          "domain:yandex.eu",
          "domain:yandex.fi",
          "domain:yandex.fr",
          "domain:yandex.jobs",
          "domain:yandex.kg",
          "domain:yandex.kz",
          "domain:yandex.lt",
          "domain:yandex.lv",
          "domain:yandex.md",
          "domain:yandex.net",
          "domain:yandex.org",
          "domain:yandex.pl",
          "domain:yandex.ru",
          "domain:yandex.st",
          "domain:yandex.sx",
          "domain:yandex.tj",
          "domain:yandex.tm",
          "domain:yandex.tr",
          "domain:yandex.ua",
          "domain:yandex.uz",
          "domain:yandexadexchange.net",
          "domain:yandexcloud.net",
          "domain:yandexcom.net",
          "domain:yandexmetrica.com",
          "domain:yandexwebcache.net",
          "domain:yandexwebcache.org",
          "domain:yastat.net",
          "domain:yastatic-net.ru",
          "domain:yastatic.net",
          "domain:yota.ru",
          "domain:youla-web-static.mrgcdn.ru",
          "domain:youla.io",
          "domain:youla.ru",
          "domain:zentotem.net",
          "domain:hematonix.ru",
          "domain:medtrum.ru",
          "domain:medtrum.eu",
          "domain:anytimeru.com",
          "domain:lumiflex.ru",
          "domain:ican-sinocare.ru",
          "domain:freestylediabetes.ru",
          "domain:rsscenter.cloud",
          "domain:dbankcloud.ru"
        ],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "domain": [
          "domain:telegram.org",
          "domain:t.me",
          "domain:telegram.me",
          "domain:tdesktop.com",
          "domain:telesco.pe",
          "domain:telegram.dog"
        ],
        "outboundTag": "proxy"
      },
      {
        "ip": [
          "91.108.4.0/22",
          "91.108.8.0/22",
          "91.108.12.0/22",
          "91.108.16.0/22",
          "91.108.56.0/22",
          "149.154.160.0/20",
          "185.76.151.0/24"
        ],
        "type": "field",
        "outboundTag": "proxy"
      },
      {
        "type": "field",
        "network": "tcp,udp",
        "balancerTag": "PROXY"
      }
    ],
    "balancers": [
      {
        "tag": "PROXY",
        "selector": [
          "proxy"
        ],
        "strategy": {
          "type": "leastPing"
        },
        "fallbackTag": "proxy"
      }
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
      "settings": {
        "udp": true,
        "auth": "noauth"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "tag": "dns-out",
      "protocol": "dns"
    },
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ],
  "burstObservatory": {
    "pingConfig": {
      "timeout": "2s",
      "interval": "10s",
      "sampling": 2,
      "destination": "http://www.gstatic.com/generate_204"
    },
    "subjectSelector": [
      "proxy"
    ]
  }
}
SKIPIT_RU_ROUTING_EOF
}


# Заведена ли в панели хоть одна нода. Критично для связки: remnanode держит
# Xray выключенным, пока панель не отдаст ему конфиг. Нет ноды в панели - нет
# конфига, Xray не займёт 443, и связка оставит сервер вообще без фронта.
panel_has_node() {
    local tok out
    tok=$(panel_api_token) || return 1
    out=$(curl -sS --max-time 15 "${PANEL_PROXY_HDR[@]}" -H "Authorization: Bearer $tok" \
        "$(panel_api)/nodes" 2>/dev/null) || return 1
    grep -q '"uuid"' <<< "$out"
}

# Токен API панели. Свежий из установки, иначе тот, что выпущен для страницы
# подписки. Состояние страницы подгружаем сами: без него SUB_ENV смотрит на путь
# отдельной установки, и в связке токена там не окажется.
panel_api_token() {
    local t=${PANEL_API_TOKEN:-}
    if [[ -z $t ]]; then
        sub_state_load 2>/dev/null
        t=$(sub_env_get REMNAWAVE_API_TOKEN 2>/dev/null)
    fi
    [[ -n $t ]] || return 1
    printf '%s' "$t"
}

# Адреса нод, заведённых в панели - по одному в строке.
panel_node_addrs() {
    local tok out
    tok=$(panel_api_token) || return 1
    out=$(curl -sS --max-time 15 "${PANEL_PROXY_HDR[@]}" -H "Authorization: Bearer $tok" \
        "$(panel_api)/nodes" 2>/dev/null) || return 1
    grep -o '"address"[[:space:]]*:[[:space:]]*"[^"]*"' <<< "$out" | sed 's/.*"\([^"]*\)"$/\1/'
}

# SECRET_KEY для ноды из панели на этом же сервере. /api/keygen отдаёт ключ,
# общий для всей панели (а не отдельный на каждую ноду) - именно его ждёт
# node_write_env. Токен берём тот, что уже выпущен для страницы подписки.
panel_node_secret() { # → SECRET_KEY или пусто
    local tok out
    tok=$(panel_api_token) || return 1
    out=$(curl -sS --max-time 15 "${PANEL_PROXY_HDR[@]}" -H "Authorization: Bearer $tok" \
        "$(panel_api)/keygen" 2>/dev/null) || return 1
    out=$(sed -n 's/.*"secretKey"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<< "$out" | head -n 1)
    [[ -n $out ]] || return 1
    printf '%s' "$out"
}
panel_proxy_hdr_cfg() { printf 'header = "X-Forwarded-Proto: https"\nheader = "X-Forwarded-For: 127.0.0.1"\n'; }

# Открыт ли ещё выпуск первого админа: 0 - да, 1 - нет связи, 2 - админ уже есть
panel_register_open() {
    local st
    st=$(curl -fsS --max-time 10 "${PANEL_PROXY_HDR[@]}" "$(panel_api)/auth/status" 2>/dev/null) || return 1
    grep -Eq '"isRegisterAllowed"[[:space:]]*:[[:space:]]*true' <<< "$st" && return 0
    return 2
}

# Завести админа и выпустить токен. Результат в PANEL_ADMIN_USER/PASS и PANEL_API_TOKEN.
# Пароль и JWT уходят через файл конфига curl, не через argv: /proc/PID/cmdline читают все.
PANEL_ADMIN_USER=""; PANEL_ADMIN_PASS=""; PANEL_API_TOKEN=""; PANEL_BOOTSTRAP_ERR=""
panel_bootstrap_admin() { # [логин] [notoken - только админ, токен не выпускать]
    local cfg jwt out
    PANEL_ADMIN_USER=""; PANEL_ADMIN_PASS=""; PANEL_API_TOKEN=""; PANEL_BOOTSTRAP_ERR=""
    command -v jq >/dev/null 2>&1 || pkg_install jq >/dev/null 2>&1
    command -v jq >/dev/null 2>&1 || { PANEL_BOOTSTRAP_ERR="Не установлен jq — без него не разобрать ответ панели."; return 1; }

    case $(panel_register_open; echo $?) in
        1) PANEL_BOOTSTRAP_ERR="Панель не отвечает на $(panel_api)/auth/status."; return 1 ;;
        2) PANEL_BOOTSTRAP_ERR="В панели уже есть администратор — автоматическая регистрация закрыта."; return 2 ;;
    esac

    # Сначала случайный логин; если панель его не примет (свои правила формата) -
    # вторая попытка под admin. Повтор только пока регистрация открыта: если админ
    # всё-таки создался, второй заход создал бы путаницу вместо понятной ошибки.
    local -a users=("${1:-$(panel_gen_admin_user)}") u
    [[ -z ${1:-} ]] && users+=(admin)
    for u in "${users[@]}"; do
        PANEL_ADMIN_USER=$u
        PANEL_ADMIN_PASS=$(panel_gen_admin_password)
        cfg=$(mktemp) || return 1
        ( umask 077; { panel_proxy_hdr_cfg
            printf 'header = "Content-Type: application/json"\ndata = "{\\"username\\":\\"%s\\",\\"password\\":\\"%s\\"}"\n' \
                "$PANEL_ADMIN_USER" "$PANEL_ADMIN_PASS"; } > "$cfg" )
        out=$(curl -sS --max-time 25 -K "$cfg" "$(panel_api)/auth/register" 2>&1)
        rm -f "$cfg"
        jwt=$(jq -r '.response.accessToken // empty' <<< "$out" 2>/dev/null)
        [[ -n $jwt ]] && break
        panel_register_open || break
    done
    if [[ -z $jwt ]]; then
        PANEL_ADMIN_USER=""; PANEL_ADMIN_PASS=""
        PANEL_BOOTSTRAP_ERR="Панель не создала администратора: $(jq -r '.message // .errorCode // empty' <<< "$out" 2>/dev/null || echo "$out" | head -c 200)"
        return 1
    fi

    # API-токены в панели не привязаны к администратору (таблица api_tokens живёт
    # отдельно), поэтому при сбросе админа выпускать новый незачем - старый работает
    [[ ${2:-} == notoken ]] && { log "panel bootstrap: admin created (token not requested)"; return 0; }

    cfg=$(mktemp) || return 1
    # x-remnawave-client-type: browser - иначе панель отвечает «For API requests you must
    # create own API-token in the admin dashboard»: по JWT она пускает только браузер
    ( umask 077; { panel_proxy_hdr_cfg
        printf 'header = "Content-Type: application/json"\nheader = "x-remnawave-client-type: browser"\nheader = "Authorization: Bearer %s"\ndata = "{\\"name\\":\\"skipit-subpage\\",\\"expiresInDays\\":3650,\\"scopes\\":[\\"*\\"]}"\n' \
            "$jwt"; } > "$cfg" )
    out=$(curl -sS --max-time 25 -K "$cfg" "$(panel_api)/tokens" 2>&1)
    rm -f "$cfg"
    PANEL_API_TOKEN=$(jq -r '.response.token // empty' <<< "$out" 2>/dev/null)
    if [[ -z $PANEL_API_TOKEN ]]; then
        PANEL_BOOTSTRAP_ERR="Администратор создан, но токен выпустить не удалось: $(jq -r '.message // .errorCode // empty' <<< "$out" 2>/dev/null || echo "$out" | head -c 200)"
        return 3
    fi
    log "panel bootstrap: admin created, api token issued"
    return 0
}

panel_ufw_apply() {
    command -v ufw >/dev/null 2>&1 || return 0
    ufwc allow 443/tcp comment 'Remnawave panel (SkipIt)' >/dev/null 2>&1
}

# Проверка DNS для панели и страницы подписки. В отличие от ноды, прокси Cloudflare
# (оранжевое облако) тут не мешает, а наоборот прячет реальный IP сервера: это обычный
# HTTPS, а не REALITY. Ставит CF_PROXIED=1, если прокси включён. Возврат 1 - отказ.
CF_PROXIED=0
web_check_dns_ui() { # домен заголовок
    CF_PROXIED=0
    node_check_dns "$1"
    case $? in
        0) return 0 ;;
        2) CF_PROXIED=1
           ui_msg "$2 · DNS" "$DNS_MSG

✓ Так и нужно: прокси Cloudflare прячет реальный IP сервера.

ℹ Сертификат дальше можно выпускать любым способом. Если HTTP-01 не пройдёт —
  у Cloudflare включён SSL-режим «Full», и проверка уходит на 443 мимо certbot.
  Тогда выберите «Cloudflare DNS»." ;;
        3) ui_yesno "$2 · DNS" "$DNS_MSG

Продолжить?" || return 1 ;;
        *) ui_yesno "$2 · DNS не совпадает" "$DNS_MSG

Если запись только что создана — подождите пару минут.

Продолжить всё равно?" no || return 1 ;;
    esac
    return 0
}

# ---- Сертификат для произвольного домена (панель, сабпейдж) ----
# Результат в CERT_NAME и CERT_METHOD. Возврат 1 - пользователь отменил.
# Сертификат в два шага: сначала только спрашиваем (ничего не ставим и не выпускаем),
# потом выпускаем - уже после подтверждения установки. Иначе apt и certbot печатали бы
# поверх формы, а отказ от установки тратил бы лимит выпусков Let's Encrypt.
#
# Доменов может быть несколько (панель + страница подписки): вопрос задаётся ОДИН раз
# и выпускается один общий сертификат - HTTP-01 со всеми доменами в SAN либо
# Cloudflare DNS на зону и *.зона (домены из разных зон - обе зоны в одном сертификате).
CERT_NAME=""; CERT_METHOD=""; CERT_EMAIL=""; CERT_TOKEN=""; CERT_ZONE=""
CERT_DOMS=(); CERT_ZONES=()

cert_in_zone()   { [[ $1 == "$2" || $1 == *".$2" ]]; }
cert_list_ru()   { local s; s=$(printf '%s, ' "$@"); echo "${s%, }"; }
cert_in_list() { # значение список...
    local x=$1 e; shift
    for e; do [[ $x == "$e" ]] && return 0; done
    return 1
}

cert_covers_all() { # имя домен...
    local name=$1 d; shift
    for d; do cert_covers "$name" "$d" || return 1; done
    return 0
}

cert_ask() { # "домен [домен...]" заголовок ["домен-за-прокси [домен...]"] [приписка к вопросу]
    local title=$2 note=${4:-} d z name busy list subj bad cf_head
    local -a doms rest left zones prox
    read -r -a doms <<< "$1"
    CERT_NAME=""; CERT_METHOD=""; CERT_EMAIL=""; CERT_TOKEN=""; CERT_ZONE=""
    CERT_DOMS=(); CERT_ZONES=()
    (( ${#doms[@]} )) || return 1
    CERT_DOMS=("${doms[@]}")
    list=$(cert_list_ru "${doms[@]}")

    # Уже есть подходящий (покрывающий все домены) - предложить его
    for d in /etc/letsencrypt/live/*/; do
        name=$(basename "$d")
        [[ -f $(cert_file "$name") ]] && cert_covers_all "$name" "${doms[@]}" || continue
        (( $(cert_days_left "$name") >= 30 )) || continue
        if ui_yesno "$title · сертификат" "Найден действующий сертификат для $list:
  $name — $(cert_domains "$name")
  осталось $(cert_days_left "$name") дн., способ: $(cert_method_ru "$name")

Использовать его?"; then
            CERT_METHOD=reuse; CERT_NAME=$name
            return 0
        fi
        break
    done

    subj="для $list"
    (( ${#doms[@]} > 1 )) && subj="сразу для обоих доменов ($list)"

    # Какие из доменов за оранжевым облаком - чтобы не писать «домен за прокси»,
    # когда проксирован только один из двух
    read -r -a prox <<< "${3:-}"

    if (( ${#prox[@]} )); then
        # За оранжевым облаком HTTP-01 упирается в прокси - первым предлагаем DNS-01.
        # Несколько доменов - таблицей: у панели и подписки облака бывают разного цвета
        if (( ${#doms[@]} == 1 )); then
            cf_head="Домен за прокси Cloudflare (оранжевое облако). Доступны оба способа.

ℹ HTTP-01 за прокси проходит при SSL-режиме «Flexible». При «Full» Cloudflare идёт
  к серверу на 443, мимо certbot, и проверка не проходит — тогда Cloudflare DNS."
        else
            # домены уже в таблице - в вопросе их не повторяем
            subj="сразу для $( (( ${#doms[@]} == 2 )) && echo обоих || echo всех ) доменов"
            cf_head="Домен"$'\t'"Cloudflare"$'\t'"HTTP-01"
            for d in "${doms[@]}"; do
                if cert_in_list "$d" "${prox[@]}"; then
                    cf_head+=$'\n'"$d"$'\t'"оранжевое облако"$'\t'"при SSL «Flexible»"
                else
                    cf_head+=$'\n'"$d"$'\t'"серое облако"$'\t'"пройдёт"
                fi
            done
            cf_head+="

ℹ Сертификат один на все домены — HTTP-01 должен пройти везде.
  За прокси он проходит только при SSL-режиме «Flexible».
  При «Full» Cloudflare идёт к серверу на 443, мимо certbot,
  и тогда падает весь выпуск — вместе с панелью.
  Cloudflare DNS работает при любых настройках прокси."
        fi
        CERT_METHOD=$(ui_choose "$title · сертификат" "$cf_head
${note:+
$note
}
Как выпустить сертификат Let's Encrypt $subj?" \
            cf   "Cloudflare DNS — работает при любых настройках прокси (нужен API-токен)" \
            http "HTTP-01 — через 80 порт, без токенов") || return 1
    else
        CERT_METHOD=$(ui_choose "$title · сертификат" "${note:+$note

}Как выпустить сертификат Let's Encrypt $subj?" \
            http "HTTP-01 — просто, без токенов (80 порт откроется на время проверки)" \
            cf   "Cloudflare DNS — wildcard *.домен (нужен API-токен)") || return 1
    fi

    if [[ $CERT_METHOD == http ]]; then
        busy=$(port_listeners 80)
        if [[ -n $busy ]]; then
            ui_msg "Порт 80 занят" "HTTP-01 не сработает — порт 80 занят:

$busy

Освободите порт или выберите способ Cloudflare DNS."
            return 1
        fi
        CERT_NAME=${doms[0]}
    else
        # Зоны спрашиваем, пока не покрыты все домены: одна зона на подомены общего домена,
        # вторая - только если домены из разных зон
        rest=("${doms[@]}"); zones=()
        while (( ${#rest[@]} )); do
            while :; do
                CERT_ZONE=$(ui_input "$title · зона Cloudflare" "Сертификат будет выпущен на домен и *.домен.$( (( ${#zones[@]} )) && printf '\n\nУже выбрано: %s\nОсталось покрыть: %s' "$(cert_list_ru "${zones[@]}")" "$(cert_list_ru "${rest[@]}")" )

Зона Cloudflare (должна быть в вашем аккаунте):" "$(base_domain "${rest[0]}")") || return 1
                CERT_ZONE=${CERT_ZONE//[[:space:]]/}; CERT_ZONE=${CERT_ZONE,,}
                if valid_domain "$CERT_ZONE" && cert_in_zone "${rest[0]}" "$CERT_ZONE"; then break; fi
                ui_msg "Ошибка" "«$CERT_ZONE» не подходит: ${rest[0]} должен быть этим доменом или его поддоменом."
            done
            zones+=("$CERT_ZONE")
            left=()
            for d in "${rest[@]}"; do cert_in_zone "$d" "$CERT_ZONE" || left+=("$d"); done
            rest=("${left[@]}")
        done
        CERT_ZONES=("${zones[@]}")
        CERT_ZONE=${zones[0]}
        while :; do
            CERT_TOKEN=$(ui_input "$title · Cloudflare API-токен" "▸ Cloudflare → My Profile → API Tokens → Create Token
Шаблон:          «Edit zone DNS»
Zone Resources:  $( (( ${#zones[@]} > 1 )) && echo "зоны $(cert_list_ru "${zones[@]}") (или All zones)" || echo "зона $CERT_ZONE" )

API-токен Cloudflare:") || return 1
            CERT_TOKEN=$(cf_clean_token "$CERT_TOKEN")
            if (( ${#CERT_TOKEN} < 20 )); then
                ui_msg "Ошибка" "Токен не вставился или слишком короткий: $(cf_mask "$CERT_TOKEN")."
                continue
            fi
            bad=""
            for z in "${zones[@]}"; do cf_zone_check "$CERT_TOKEN" "$z" || { bad=$z; break; }; done
            [[ -z $bad ]] && break
            ui_yesno "Проверка токена не прошла" "Токен: $(cf_mask "$CERT_TOKEN")

Зона $bad:
$CF_ERR

n — ввести токен заново.

Продолжить с этим токеном без проверки?" no && break
        done
        CERT_NAME=${zones[0]}
    fi

    while :; do
        CERT_EMAIL=$(ui_input "$title · email" "На него придёт предупреждение, если сертификат не продлится.

Email (можно оставить пустым):") || return 1
        CERT_EMAIL=${CERT_EMAIL//[[:space:]]/}
        [[ -z $CERT_EMAIL || $CERT_EMAIL =~ ^[^@]+@[^@]+\.[^@]+$ ]] && break
        ui_msg "Ошибка" "Некорректный email: «$CERT_EMAIL»"
    done
    return 0
}

# То же в одну короткую строку: для сводки мастера, где домены и так перечислены выше
cert_choice_short() {
    case $CERT_METHOD in
        reuse) echo "готовый ($CERT_NAME)" ;;
        http)  echo "HTTP-01" ;;
        cf)    echo "Cloudflare DNS: $(cert_list_ru "${CERT_ZONES[@]}")" ;;
    esac
}

# Краткое описание выбора для экрана подтверждения
cert_choice_ru() {
    local z zl=""
    case $CERT_METHOD in
        reuse) echo "готовый ($CERT_NAME)" ;;
        http)  echo "HTTP-01 для $(cert_list_ru "${CERT_DOMS[@]}") — выпустим при установке" ;;
        cf)    for z in "${CERT_ZONES[@]}"; do zl+="$z и *.$z, "; done
               echo "Cloudflare DNS: ${zl%, }" ;;
    esac
}

# Шаг 2: ставит пакеты и выпускает сертификат. apt и certbot печатают прямо в терминал,
# поэтому вызывать только после ui_head - когда экран уже переключён в «журнальный» режим.
# Без аргументов берёт домены, о которых спрашивал cert_ask.
cert_issue() { # [домен...]
    local -a doms=("$@") zones
    local d list zl=""
    (( ${#doms[@]} )) || doms=("${CERT_DOMS[@]}")
    list=$(cert_list_ru "${doms[@]}")
    if [[ $CERT_METHOD == reuse ]]; then
        cert_write_hooks; cert_ensure_renew
        n_say "Используется готовый сертификат: /etc/letsencrypt/live/$CERT_NAME"
        return 0
    fi
    if ! command -v certbot >/dev/null 2>&1; then
        n_say "Устанавливаю certbot..."
        pkg_install certbot >/dev/null 2>&1 || { node_fail "Не удалось установить certbot."; return 1; }
    fi
    cert_write_hooks
    if [[ $CERT_METHOD == cf ]]; then
        zones=("${CERT_ZONES[@]}"); (( ${#zones[@]} )) || zones=("$CERT_ZONE")
        if ! certbot plugins 2>/dev/null | grep -q dns-cloudflare; then
            n_say "Устанавливаю плагин certbot для Cloudflare..."
            pkg_install python3-certbot-dns-cloudflare >/dev/null 2>&1 ||
                { node_fail "Не удалось установить плагин certbot для Cloudflare."; return 1; }
        fi
        mkdir -p "$SKIPIT_ETC"
        ( umask 077; printf 'dns_cloudflare_api_token = %s\n' "$CERT_TOKEN" > "$CF_CREDS" )
        chmod 600 "$CF_CREDS"
        for d in "${zones[@]}"; do zl+="$d, *.$d, "; done
        n_say "Выпускаю сертификат для ${zl%, } (проверка через DNS, до минуты)..."
        cert_issue_cf "$CERT_EMAIL" "${zones[@]}" ||
            { node_fail "Certbot не смог выпустить сертификат.

$(cert_fail_reason || echo "Подробности выше и в /var/log/letsencrypt/letsencrypt.log")"; return 1; }
    else
        n_say "Выпускаю сертификат для $list (проверка по 80 порту)..."
        cert_issue_http "$CERT_EMAIL" "${doms[@]}" ||
            { node_fail "Certbot не смог выпустить сертификат.

$(cert_fail_reason || echo "Проверьте A-записи и доступность 80 порта, подробности в /var/log/letsencrypt/letsencrypt.log")"; return 1; }
    fi
    cert_ensure_renew
    for d in "${doms[@]}"; do
        cert_covers "$CERT_NAME" "$d" || { node_fail "Сертификат $CERT_NAME не подходит для $d."; return 1; }
    done
    n_say "Сертификат: /etc/letsencrypt/live/$CERT_NAME ($list) — осталось $(cert_days_left "$CERT_NAME") дн."
    return 0
}
# ---- Общие ресурсы компонентов ----
# Сертификат и порт 443 нода, панель и страница подписки могут делить: cert_ask сам
# предлагает переиспользовать подходящий lineage, а в связке панель со страницей
# всегда на одном. Поэтому перед удалением сертификата и закрытием порта смотрим,
# не нужны ли они кому-то ещё - иначе удаление одного компонента ломает соседа.
# Состояния читаются в подоболочке: *_state_load перетирает глобальные переменные.
# Свой-компонент - это те, что уезжают прямо сейчас: их считать «остающимися»
# нельзя. В связке панель уносит с собой страницу подписки, поэтому сюда
# передают сразу оба: "panel sub". Иначе мы обещаем сохранить сертификат ради
# страницы, которую сами же и удаляем.
cert_other_users() { # имя-сертификата свои-компоненты(node|panel|sub, через пробел) → «нода (dom), панель (dom)»
    local name=$1 skip=" ${2:-} " out
    [[ -n $name ]] || return 0
    out=$(
        [[ $skip != *" node "* ]] && node_state_load 2>/dev/null && [[ $NODE_CERT_NAME == "$name" ]] &&
            printf 'нода (%s), ' "$NODE_DOMAIN"
        [[ $skip != *" panel "* ]] && panel_state_load 2>/dev/null && [[ -f $PANEL_COMPOSE ]] &&
            [[ $PANEL_CERT_NAME == "$name" ]] && printf 'панель (%s), ' "$PANEL_DOMAIN"
        [[ $skip != *" sub "* ]] && sub_state_load 2>/dev/null && [[ -f $SUB_COMPOSE ]] &&
            [[ $SUB_CERT_NAME == "$name" ]] && printf 'страница подписки (%s), ' "$SUB_DOMAIN"
        true
    )
    echo "${out%, }"
}

port443_other_users() { # свои-компоненты(node|panel|sub, через пробел) → «нода, панель»
    local skip=" ${1:-} " out
    out=$(
        [[ $skip != *" node "* ]] && node_state_load 2>/dev/null && [[ -f $NODE_COMPOSE ]] &&
            printf 'нода, '
        [[ $skip != *" panel "* ]] && panel_state_load 2>/dev/null && [[ -f $PANEL_COMPOSE ]] &&
            printf 'панель, '
        [[ $skip != *" sub "* ]] && sub_state_load 2>/dev/null && [[ -f $SUB_COMPOSE ]] &&
            printf 'страница подписки, '
        true
    )
    echo "${out%, }"
}

# Спросить про удаление сертификата, но только если он больше никому не нужен
ask_del_cert() { # имя свой-компонент → 0 удалять / 1 нет
    local name=$1 busy
    [[ -n $name ]] || return 1
    busy=$(cert_other_users "$name" "$2")
    if [[ -n $busy ]]; then
        ui_msg "Сертификат остаётся" "Сертификат $name используется дальше: $busy

Поэтому удалять его нельзя — оставляю на месте."
        return 1
    fi
    ui_yesno "Сертификат" "Удалить и сертификат $name?

Домены: $(cert_domains "$name")
Больше им никто не пользуется." no
}

# Спросить про закрытие 443, но только если порт больше никому не нужен
ask_close_443() { # свой-компонент → 0 закрывать / 1 нет
    local busy
    busy=$(port443_other_users "$1")
    if [[ -n $busy ]]; then
        ui_msg "Порт 443 остаётся открыт" "Порт 443/tcp нужен дальше: $busy

Закрывать его нельзя — оставляю правило UFW на месте."
        return 1
    fi
    ui_yesno "Порт" "Закрыть в UFW порт 443/tcp?

Больше его никто не слушает." no
}

# ---- Бэкапы БД панели ----
# Дамп делается внутри контейнера: пароль не попадает в командную строку хоста.
# ---- Сброс администратора ----
# Повторяет «Fully reset superadmin» из Rescue CLI панели (docker exec -it remnawave cli):
# запись админа удаляется, кэш настроек в Valkey сбрасывается - и панель снова
# открывает регистрацию. Нового админа SkipIt Tool заводит сам, как при установке.
PANEL_REDIS_SOCK="/var/run/valkey/valkey.sock"

panel_sql() { # SQL → 0/1
    [[ $(ctr_status remnawave-db) == running ]] || return 1
    docker exec -i remnawave-db sh -c \
        'psql -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' <<< "$1"
}

panel_cache_drop() { # сбросить кэш настроек, как это делает CLI панели
    docker exec remnawave-redis valkey-cli -s "$PANEL_REDIS_SOCK" DEL remnawave_settings >/dev/null 2>&1 ||
    docker exec remnawave-redis redis-cli  -s "$PANEL_REDIS_SOCK" DEL remnawave_settings >/dev/null 2>&1
}

panel_reset_admin() {
    local bak rc
    panel_installed || return
    sub_state_load 2>/dev/null   # знать про связку: токен страницы придётся выпустить заново
    ui_yesno "Сброс администратора" "── Когда это нужно
Забыт пароль:   войти в панель больше нечем
Сменить учётку: старая удаляется, заводится новая

── Что будет сделано
Бэкап:      дамп базы перед изменением
Удалим:     текущего администратора панели
Заведём:    нового со случайным логином и паролем
Покажем:    логин и пароль на экране — сохраните их

── Что не тронется
Данные:     пользователи, ноды, хосты и подписки остаются
API-токены: живут отдельно от админа — страница подписки работает дальше

! Открытые сессии в браузере оборвутся

Сбросить администратора?" no || return

    # Кто заводит нового админа: скрипт или сам человек в браузере
    local who
    who=$(ui_choose "Сброс администратора · новая учётка" "Старая учётка удаляется в любом случае. Кто заведёт новую?" \
        auto "SkipIt Tool — случайный логин и пароль, покажу на экране" \
        self "Я сам — панель откроет форму регистрации, задам логин и пароль в браузере") || return
    ui_head "Сброс администратора · $PANEL_DOMAIN"

    node_step "1/4  Бэкап базы"
    bak=$(panel_backup_make) || { node_fail "Не удалось сделать дамп базы — сброс отменён."; return; }
    n_say "$bak"

    node_step "2/4  Удаляю администратора"
    if ! panel_sql 'DELETE FROM admin;'; then
        node_fail "Не удалось удалить запись администратора. База отвечает? Дамп цел: $bak"
        return
    fi
    panel_cache_drop
    n_say "Запись удалена, кэш настроек сброшен"

    node_step "3/4  Перезапуск панели"
    panel_compose_run restart remnawave >/dev/null 2>&1
    if ! panel_wait_healthy 120 || ! panel_wait_api 90; then
        node_fail "Панель не поднялась после перезапуска. Логи: Панель → Логи → remnawave
Дамп базы на месте: $bak"
        return
    fi
    n_say "Панель работает, API отвечает"

    node_step "4/4  Новый администратор"
    if [[ $who == self ]]; then
        n_say "Регистрация в панели открыта — заведите администратора сами."
        log "panel admin reset (self)"
        g_gap
        g_line "Откройте адрес входа и задайте логин с паролем:"
        g_gap
        printf '%s\n' "$(panel_url)" | g_code
        g_gap
        g_note "Форма регистрации появится сама: администратора в панели сейчас нет."
        g_gap
        g_note "Дамп базы до сброса: $bak"
        pause
        return
    fi
    panel_bootstrap_admin "" notoken; rc=$?
    if (( rc != 0 )); then
        node_fail "Не удалось завести администратора: $PANEL_BOOTSTRAP_ERR
Дамп базы на месте: $bak"
        return
    fi
    (( SUB_BUNDLED )) && n_say "API-токен страницы подписки не трогали — он продолжает работать"
    log "panel admin reset"

    g_gap
    g_line "Новый администратор панели:"
    g_gap
    g_code_kv "логин" "$PANEL_ADMIN_USER" "пароль" "$PANEL_ADMIN_PASS"
    g_gap
    g_note "Сохраните пароль — второй раз он показан не будет, в лог не пишется."
    g_note "Вход: $(panel_url)"
    g_gap
    g_note "Дамп базы до сброса: $bak"
    pause
}

panel_dump_db() { # файл-назначение → 0/1
    local dst=$1
    [[ $(ctr_status remnawave-db) == running ]] || return 1
    ( umask 077
      docker exec -i remnawave-db sh -c \
        'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists' 2>/dev/null | gzip -c > "$dst"
    ) || return 1
    chmod 600 "$dst" 2>/dev/null
    [[ -s $dst ]] && gzip -t "$dst" 2>/dev/null
}

panel_backup_name() { printf '%s/remnawave-db-%s.sql.gz' "$SKIPIT_BACKUPS" "$(date +%Y%m%d-%H%M%S)"; }
panel_backup_list() { ls -1t "${SKIPIT_BACKUPS}"/remnawave-db-*.sql.gz 2>/dev/null; }

# Свежий дамп + чистка старых. Печатает путь.
panel_backup_make() {
    local f; f=$(panel_backup_name)
    mkdir -p "$SKIPIT_BACKUPS"
    panel_dump_db "$f" || { rm -f "$f"; return 1; }
    panel_backup_list | tail -n +$((PANEL_BACKUP_KEEP + 1)) | xargs -r rm -f
    printf '%s' "$f"
}

panel_backup_now() {
    local f
    ui_loading "Делаю дамп базы данных…"
    if ! f=$(panel_backup_make); then
        ui_msg "Ошибка" "Не удалось сделать дамп. Проверьте, что контейнер remnawave-db работает:
▸ Панель → Логи"
        return
    fi
    log "panel backup: $f"
    ui_msg "Бэкап готов" "Файл:    $f
Размер:  $(hsize "$(stat -c %s "$f")")
Хранится последних:  $PANEL_BACKUP_KEEP

ℹ Бэкапы не удаляются при удалении панели"
}

panel_backup_screen() {
    local f n=0 out="Файл"$'\t'"Когда"$'\t'"Размер"
    while IFS= read -r f; do
        [[ -n $f ]] || continue
        n=$((n + 1))
        out+=$'\n'"$(basename "$f")"$'\t'"$(date -r "$f" '+%d.%m.%Y %H:%M')"$'\t'"$(hsize "$(stat -c %s "$f")")"
    done < <(panel_backup_list)
    (( n )) || out="Бэкапов пока нет."
    ui_text "Бэкапы панели" "Папка:       $SKIPIT_BACKUPS
Хранится:    последние $PANEL_BACKUP_KEEP
Авто:        $(panel_backup_cron_on && echo "ежедневно в 04:20" || echo "выключено")

$out"
}

panel_backup_cron_on() { [[ -f $PANEL_BACKUP_CRON ]]; }

panel_backup_cron_toggle() {
    if panel_backup_cron_on; then
        ui_yesno "Автобэкап" "Выключить ежедневный бэкап базы данных панели?

! Уже сделанные бэкапы останутся на месте" no || return
        rm -f "$PANEL_BACKUP_CRON"
        log "panel backup cron: off"
        ui_msg "Готово" "Автобэкап выключен. Сделанные бэкапы не тронуты."
    else
        ui_yesno "Автобэкап" "Когда:     каждый день в 04:20
Куда:      $SKIPIT_BACKUPS
Хранить:   последние $PANEL_BACKUP_KEEP, старые удаляются

Включить ежедневный бэкап базы данных?" || return
        printf '20 4 * * * root %s panel-backup >/dev/null 2>&1\n' "$SKIPIT_BIN" > "$PANEL_BACKUP_CRON"
        chmod 644 "$PANEL_BACKUP_CRON"
        log "panel backup cron: on"
        ui_msg "Готово" "Автобэкап включён: каждый день в 04:20."
    fi
}

panel_restore() {
    local items=() f sel
    while IFS= read -r f; do
        [[ -n $f ]] || continue
        items+=("$f" "$(date -r "$f" '+%d.%m.%Y %H:%M') · $(hsize "$(stat -c %s "$f")")")
    done < <(panel_backup_list)
    if (( ${#items[@]} == 0 )); then
        ui_msg "Восстановление" "Бэкапов нет в $SKIPIT_BACKUPS."
        return
    fi
    sel=$(ui_choose "Восстановить базу данных" "Текущая база будет заменена содержимым бэкапа целиком.

! Все изменения после выбранного бэкапа пропадут
! Панель будет остановлена на время восстановления

Какой бэкап восстановить?" "${items[@]}") || return
    ui_yesno "Подтверждение" "Бэкап:   $(basename "$sel")
Создан:  $(date -r "$sel" '+%d.%m.%Y %H:%M')

Текущая база данных панели будет заменена. Это необратимо.

Восстановить?" no || return

    local safety
    ui_loading "Делаю дамп текущей базы на всякий случай…"
    safety=$(panel_backup_make) || safety=""
    clear; say "Останавливаю панель..."
    panel_compose_run stop remnawave >/dev/null 2>&1
    say "Восстанавливаю базу данных..."
    if ! gzip -dc "$sel" | docker exec -i remnawave-db sh -c 'psql -q -U "$POSTGRES_USER" -d "$POSTGRES_DB"' >/dev/null 2>&1; then
        panel_compose_run start remnawave >/dev/null 2>&1
        log "panel restore FAIL: $sel"
        ui_msg "Ошибка" "Восстановление не удалось, панель запущена обратно.
${safety:+
Дамп базы до попытки: $safety}"
        return
    fi
    say "Запускаю панель..."
    panel_compose_run start remnawave >/dev/null 2>&1
    if panel_wait_healthy 90; then
        log "panel restore: $sel"
        ui_msg "Готово" "База восстановлена из $(basename "$sel"), панель работает.
${safety:+
Дамп базы до восстановления: $safety}"
    else
        ui_msg "Внимание" "База восстановлена, но панель не ответила за 90 секунд.
Смотрите логи: Панель → Логи
${safety:+
Дамп базы до восстановления: $safety}"
    fi
}

# ---- Установка панели ----
panel_install() { UI_CTX=""; _panel_install "$@"; local rc=$?; UI_CTX=""; return $rc; }

# Всё на один сервер. Отдельной копии логики не пишем: ставим панель со
# страницей подписки обычным мастером, а следом мастер ноды сам видит панель
# и предлагает связку - забрать 443 и увести панель за свой unix-сокет.
# Всё на один сервер. Сначала мастер спрашивает всё, что нужно и панели, и ноде,
# и только потом ставит: между панелью и нодой вопросов больше не будет.
bundle_all_install() {
    wz_reset
    bundle_all_ask || { wz_reset; return; }

    WZ_ON=1
    panel_install with_sub
    if ! panel_installed 2>/dev/null; then wz_reset; return; fi
    node_install
    wz_reset

    if node_installed 2>/dev/null; then
        bundle_all_done_screen
    else
        # Нода не встала, но панель работает: адрес входа и пароль администратора
        # показать обязательно - больше их взять неоткуда
        panel_sub_done_screen
    fi
}

# Все вопросы одним заходом. Ответы уходят в WZ_*, CERT_* (панель) и NCERT_* (нода) -
# оттуда их и берут _panel_install и _node_install.
bundle_all_ask() {
    local busy rc
    ui_yesno "Панель, страница подписки и нода — на один сервер" "── Что понадобится
Три домена:   панель, страница подписки, домен ноды (он же SNI для REALITY)
A-записи:     все три на IP этого сервера ($SERVER_IP)

ℹ Домены панели и подписки в Cloudflare — можно с прокси (оранжевое облако).
ℹ Домен ноды — только «DNS only» (серое): через прокси REALITY не работает.

── Как это будет работать
Порт 443:     держит Xray ноды
Не REALITY:   уходит в nginx по unix-сокету, дальше выбор по имени домена
              домен ноды → сайт-заглушка
              домен панели → панель
              домен подписки → страница подписки
Сертификаты:  два выпуска — отдельно нода, отдельно панель со страницей.
              Общий выдал бы связь между заглушкой и панелью.

── Порядок
1. Сначала вопросы — все сразу, ничего ставить не начинаем
2. Потом установка: панель со страницей подписки, следом нода
   Нода заберёт 443 и уведёт панель за свой сокет

Начать?" || return 1

    # 443 нужен и панели, и ноде: если порт чужой, дальше спрашивать незачем
    busy=$(port_owner 443); rc=$?
    if (( rc != 1 )); then
        ui_msg "Порт 443 занят" "Схеме нужен порт 443, а его занял: $busy

Освободите порт и запустите установку снова."
        return 1
    fi
    ipv6_check_wizard || return 1

    WZ_PANEL_DOMAIN=$(ask_domain "Домен панели · 1 из 3" "Пример:  panel.example.com

Домен, по которому вы будете открывать панель:" "$PANEL_DOMAIN") || return 1
    web_check_dns_ui "$WZ_PANEL_DOMAIN" "Панель" || return 1
    (( CF_PROXIED )) && WZ_PROX_DOMS=$WZ_PANEL_DOMAIN
    ui_ctx_add "Домен панели" "$WZ_PANEL_DOMAIN"

    while :; do
        WZ_SUB_DOMAIN=$(ask_domain "Домен страницы подписки · 2 из 3" "Отдельный домен, A-запись на этот же сервер ($SERVER_IP).
Пример:  sub.example.com

Домен, по которому клиенты будут открывать подписку:" "$SUB_DOMAIN") || return 1
        [[ $WZ_SUB_DOMAIN != "$WZ_PANEL_DOMAIN" ]] && break
        ui_msg "Ошибка" "Домен подписки должен отличаться от домена панели ($WZ_PANEL_DOMAIN)."
    done
    web_check_dns_ui "$WZ_SUB_DOMAIN" "Страница подписки" || return 1
    (( CF_PROXIED )) && WZ_PROX_DOMS="${WZ_PROX_DOMS:+$WZ_PROX_DOMS }$WZ_SUB_DOMAIN"
    ui_ctx_add "Домен подписки" "$WZ_SUB_DOMAIN"

    while :; do
        WZ_NODE_DOMAIN=$(ask_domain "Домен ноды · 3 из 3" "Он же SNI для REALITY, в Cloudflare — только «DNS only» (серое облако).
Пример:  node1.example.com

Домен, на который подключаются клиенты:" "$NODE_DOMAIN") || return 1
        [[ $WZ_NODE_DOMAIN != "$WZ_PANEL_DOMAIN" && $WZ_NODE_DOMAIN != "$WZ_SUB_DOMAIN" ]] && break
        ui_msg "Ошибка" "Домен ноды должен отличаться от доменов панели и страницы подписки."
    done
    node_dns_ask "$WZ_NODE_DOMAIN" || return 1
    ui_ctx_add "Домен ноды" "$WZ_NODE_DOMAIN"

    WZ_NODE_PORT=$(node_port_ask steal "${NODE_PORT:-2222}") || return 1
    ui_ctx_add "Порт ноды" "$WZ_NODE_PORT"

    # Про сертификаты спрашиваем один раз на все три домена: способ, зона, токен и
    # email общие. Выпусков при этом два - панель со страницей подписки отдельно,
    # нода отдельно: общий сертификат выдал бы связь заглушки с панелью.
    cert_ask "$WZ_PANEL_DOMAIN $WZ_SUB_DOMAIN" "Панель, подписка и нода" "$WZ_PROX_DOMS" \
"ℹ Это вопрос заодно и про ноду: $WZ_NODE_DOMAIN получит свой сертификат —
  тем же способом, с тем же токеном и email, спрашивать второй раз не буду.
  Отдельный он потому, что общий выдал бы связь заглушки с панелью." || return 1
    ui_ctx_add "Сертификаты" "$(cert_choice_ru)"
    node_cert_from_panel "$WZ_NODE_DOMAIN"; rc=$?
    case $rc in
        0) ;;
        2) node_cert_ask "$WZ_NODE_DOMAIN" "Сертификат ноды" || return 1 ;;
        *) return 1 ;;
    esac

    if [[ -f $NODE_WEBROOT/index.html ]]; then WZ_NODE_TPL=$(site_choose keep "$WZ_NODE_DOMAIN") || return 1
    else WZ_NODE_TPL=$(site_choose "" "$WZ_NODE_DOMAIN") || return 1; fi

    UI_CTX=""
    ui_yesno "Подтверждение" "Поставить панель, страницу подписки и ноду?

  Домен панели:       $WZ_PANEL_DOMAIN
  Домен подписки:     $WZ_SUB_DOMAIN
  Домен ноды:         $WZ_NODE_DOMAIN
  Порт ноды:          $WZ_NODE_PORT
  Сертификат панели:  $(cert_choice_short)
  Сертификат ноды:    $(wz_ncert_ru)
  Заглушка:           $(site_title "$WZ_NODE_TPL")
  Папки:              $PANEL_DIR, $NODE_DIR
  Порт 443:           займёт Xray ноды, панель уйдёт за его сокет

ℹ Больше вопросов не будет: дальше всё ставится и настраивается само.
ℹ Ноду в панели, её профиль и API-токен страницы подписки мастер заведёт сам.

Начать установку?" || return 1
    return 0
}

bundle_all_done_screen() {
    UI_CTX=""
    ui_head "Панель, страница подписки и нода установлены"
    g_kv "Панель" "https://$PANEL_DOMAIN"
    g_kv "Ссылки клиентов" "https://$SUB_DOMAIN/…"
    g_kv "Нода" "$NODE_DOMAIN — сайт-заглушка на https://$NODE_DOMAIN"
    g_kv "Папки" "$PANEL_DIR, $NODE_DIR"
    g_kv "Автобэкап" "ежедневно в 04:20"
    g_gap
    g_line "Адрес входа в панель — откройте его один раз в браузере:"
    g_gap
    printf '%s\n' "$(panel_url)" | g_code
    if [[ -n $PANEL_ADMIN_PASS ]]; then
        g_gap
        g_line "Администратор панели создан, войдите этими данными:"
        g_gap
        g_code_kv "логин" "$PANEL_ADMIN_USER" "пароль" "$PANEL_ADMIN_PASS"
        g_gap
        g_note "Сохраните пароль — больше он показан не будет, в лог не пишется."
        g_note "Сменить его можно в самой панели после входа."
        if [[ -n $PANEL_API_TOKEN ]]; then
            g_note "API-токен для страницы подписки уже выпущен и вставлен — делать ничего не нужно."
        else
            g_note "А вот API-токен выпустить не удалось: $PANEL_BOOTSTRAP_ERR"
            g_note "Сделайте руками: Настройки → API Tokens → создайте токен,"
            g_note "затем Страница подписки → Сменить API-токен."
        fi
    else
        g_gap
        g_note "Администратора создайте сами при первом входе."
        g_note "Потом: Настройки → API Tokens → создайте токен."
        g_note "И вставьте его: Страница подписки → Сменить API-токен."
    fi
    g_gap
    g_line "Что осталось:"
    g_gap
    g_line "1. Ничего обязательного: профиль, нода и хост $(node_tag "$NODE_DOMAIN" steal) уже созданы."
    g_line "   Остальные хосты, если понадобятся:"
    g_path "SkipIt Tool → Нода Remnawave → Что создать в панели"
    g_gap
    (( PANEL_RU_TPL_OK )) && g_note "Шаблон Xray JSON «$PANEL_RU_TPL» создан — выберите его у хоста, если нужен раздельный роутинг."
    g_note "Порт 443 держит Xray ноды: панель и страница подписки работают через её nginx."
    g_note "Без cookie домен панели отвечает 404 — боты её не найдут."
    local a
    printf '\n  %s ' "$(ui_keys "Enter — в меню · d — запустить диагностику")" >"$TTY"
    ui_readline a || return 0
    a=${a,,}; a=${a//[[:space:]]/}
    [[ $a == d || $a == в ]] && { panel_diag; sub_diag; node_diag; }
    return 0
}

_panel_install() {
    local domain sub_domain path cookie api_key busy reinstall=0
    local with_sub=0 sub_dom="" sub_cert=""
    # Сертификат спрашивается один раз на оба домена (см. cert_ask) и выпускается
    # одним общим: панель и страница подписки живут на одном lineage
    [[ ${1:-} == with_sub ]] && with_sub=1
    if panel_state_load && [[ -f $PANEL_COMPOSE ]]; then
        reinstall=1
        wz_asked || ui_yesno "Переустановка панели" "── Что уже установлено
Домен:   $PANEL_DOMAIN
Папка:   $PANEL_DIR

── Что будет перезаписано
Файлы:   docker-compose.yml, .env, nginx.conf
Бэкап:   старые версии уйдут в $SKIPIT_BACKUPS

── Что не тронется
База:    пользователи, ноды и секреты панели

Переустановить панель?" no || return
    fi
    wz_asked || ui_yesno "$( (( with_sub )) && echo "Установка панели и страницы подписки" || echo "Установка панели Remnawave" )" "── Что понадобится
$( if (( with_sub )); then echo "Домен панели:    A-запись на IP этого сервера ($SERVER_IP)
Домен подписки:  отдельный домен, тоже на этот сервер"
else echo "Домен:  A-запись на IP этого сервера ($SERVER_IP)"; fi )

ℹ Домен в Cloudflare — включайте прокси, он спрячет IP сервера.
ℹ Нужно «оранжевое облако» — серое обязательно только для ноды.

── Что будет сделано
Контейнеры:  панель, база, кэш$( (( with_sub )) && echo ", страница подписки" ) и nginx
Папка:       $PANEL_DIR
Порты:       443 наружу, 80 — только на время выпуска сертификата
Вход:        в панель по секретному адресу, чужие его не подберут$( (( with_sub )) && echo "
Токен:       выпустится сам, вставлять вручную не придётся" )
Бэкапы:      $SKIPIT_BACKUPS, ежедневно (можно выключить)

ℹ Docker ставится официальным установщиком get.docker.com — сторонний скрипт с правами root

Начать?" || return
    wz_asked || ipv6_check_wizard || return

    local prox_doms=""
    if wz_asked; then domain=$WZ_PANEL_DOMAIN; prox_doms=$WZ_PROX_DOMS
    else
        domain=$(ask_domain "Домен панели" "Пример:  panel.example.com

Домен, по которому вы будете открывать панель:" "$PANEL_DOMAIN") || return
        web_check_dns_ui "$domain" "Панель" || return
        (( CF_PROXIED )) && prox_doms="$domain"
    fi
    ui_ctx_add "$( (( with_sub )) && echo "Домен панели" || echo "Домен" )" "$domain"

    if (( with_sub )); then
        if wz_asked; then sub_dom=$WZ_SUB_DOMAIN
        else
        while :; do
            sub_dom=$(ask_domain "Домен страницы подписки" "Отдельный домен, A-запись на этот же сервер ($SERVER_IP).
Пример:  sub.example.com

Домен, по которому клиенты будут открывать подписку:" "$SUB_DOMAIN") || return
            [[ $sub_dom != "$domain" ]] && break
            ui_msg "Ошибка" "Домен подписки должен отличаться от домена панели ($domain)."
        done
        web_check_dns_ui "$sub_dom" "Страница подписки" || return
        (( CF_PROXIED )) && prox_doms="${prox_doms:+$prox_doms }$sub_dom"
        fi
        ui_ctx_add "Домен подписки" "$sub_dom"
    fi
    if [[ -n $prox_doms ]]; then
        if [[ $prox_doms == "$domain${sub_dom:+ $sub_dom}" ]]; then
            ui_ctx_add "Cloudflare" "прокси включён, IP скрыт"
        else
            ui_ctx_add "Cloudflare" "прокси только на $prox_doms"
        fi
    fi

    local bundle=0
    if (( ! reinstall )); then
        busy=$(port_owner 443)
        case $? in
            1) ;;
            2) if node_installed 2>/dev/null; then
                   # 443 держит Xray нашей ноды - панели свой nginx не нужен,
                   # она въедет в nginx ноды на тот же unix-сокет
                   ui_yesno "Нода на этом сервере" "── Сейчас
Нода:         $NODE_DOMAIN
Порт 443:     держит Xray ноды

── Станет
Панель:       на том же unix-сокете, своего nginx не будет
Выбор:        по имени домена — ноде заглушка, панели панель
Порт 443:     остаётся за Xray, как и был

ℹ Сертификат панели выпустим отдельный, сертификат ноды не трогаем:
  общий выдал бы связь между заглушкой и панелью.

ℹ Нода перезагрузит свой nginx — клиенты этого не заметят.

Поставить панель в связке с нодой?" || return
                   bundle=1
                   ui_ctx_add "Режим" "связка с нодой $NODE_DOMAIN"
               else
                   ui_msg "Порт 443 занят" "Панели нужен порт 443, а его занял: $busy"
                   return
               fi ;;
            *) ui_msg "Порт 443 занят" "Панели нужен порт 443, а его занял: $busy"
               return ;;
        esac
    fi

    # Секретный адрес входа
    path=${PANEL_PATH:-$(panel_gen_path)}
    ui_ctx_add "Вход" "по секретному адресу"

    # Сертификат спрашиваем один раз - сразу на оба домена, один общий выпуск.
    # Только спрашиваем; сам выпуск - после подтверждения, шагом 2/5
    local cert_ru
    if ! wz_asked && ! cert_ask "$domain${sub_dom:+ $sub_dom}" "$( (( with_sub )) && echo "Панель и страница подписки" || echo "Панель" )" \
                  "$prox_doms"; then return; fi
    PANEL_CERT_METHOD=$CERT_METHOD; PANEL_CERT_NAME=$CERT_NAME
    sub_cert=$CERT_NAME
    cert_ru=$(cert_choice_ru)
    ui_ctx_add "Сертификат" "$cert_ru"

    # Подписки: без отдельной страницы их отдаёт сама панель по /api/sub
    if (( with_sub )); then sub_domain="$sub_dom"; else sub_domain="${domain}/api/sub"; fi
    UI_CTX=""
    local confirm
    if (( with_sub )); then
        confirm="Установить панель и страницу подписки?

  Домен панели:     $domain
  Домен подписки:   $sub_dom
  Сертификат:       $cert_ru
  Ссылки клиентов:  https://$sub_domain/…
  Папка:            $PANEL_DIR
  Порт:             443/tcp

ℹ Сертификат один на оба домена — выпустится за один раз"
    else
        confirm="Установить панель?

  Домен:            $domain
  Сертификат:       $cert_ru
  Ссылки клиентов:  https://$sub_domain/…
  Папка:            $PANEL_DIR
  Порт:             443/tcp"
    fi
    wz_asked || ui_yesno "Подтверждение" "$confirm

ℹ Секретный адрес входа покажу в конце — сохраните его" || return

    ui_head "Установка панели · $domain"
    log "panel install: domain=$domain cert=$PANEL_CERT_METHOD"

    node_step "1/5  Docker и подкачка"
    node_ensure_docker || { node_fail "Не удалось установить или запустить Docker."; return; }
    swap_ensure

    node_step "2/5  SSL-сертификат"
    # Один выпуск на все домены, о которых спрашивал cert_ask
    cert_issue || return
    sub_cert=$CERT_NAME

    node_step "3/5  Файлы панели"
    mkdir -p "$PANEL_DIR" || { node_fail "Не удалось создать $PANEL_DIR"; return; }
    local f
    for f in "$PANEL_COMPOSE" "$PANEL_ENV" "$PANEL_NGINX"; do [[ -f $f ]] && backup_file "$f" >/dev/null; done
    PANEL_DOMAIN=$domain; PANEL_PATH=$path; PANEL_SUB_DOMAIN=$sub_domain
    PANEL_SUB_CERT=$sub_cert
    panel_write_env "$domain" "$sub_domain"
    cookie=$(panel_env_get SKIPIT_PANEL_COOKIE)
    api_key=$(panel_env_get SKIPIT_PANEL_API_KEY)
    if (( with_sub )); then
        # Страница подписки живёт в compose панели: своё окружение в sub.env рядом
        SUB_DIR=$PANEL_DIR; SUB_ENV="${PANEL_DIR}/sub.env"
        SUB_COMPOSE=$PANEL_COMPOSE; SUB_NGINX=$PANEL_NGINX
        SUB_NGINX_CTR=$(panel_nginx_ctr)
        SUB_DOMAIN=$sub_dom; SUB_CERT_NAME=$sub_cert; SUB_CERT_METHOD=$PANEL_CERT_METHOD
        SUB_PANEL_URL="http://remnawave:${PANEL_APP_PORT}"; SUB_PREFIX=""; SUB_BUNDLED=1
        # токен появится после регистрации админа, пока пусто
        sub_write_env "$SUB_PANEL_URL" "" "" ""
        panel_nginx_conf "$domain" "$PANEL_CERT_NAME" "$path" "$cookie" "$api_key" \
                         "$sub_dom" "$sub_cert" > "$PANEL_NGINX"
    else
        panel_nginx_conf "$domain" "$PANEL_CERT_NAME" "$path" "$cookie" "$api_key" > "$PANEL_NGINX"
    fi
    # В связке фронтом будет nginx ноды: свой nginx в compose не появится,
    # а собственный nginx.conf панели остаётся лежать как есть - он не читается
    (( bundle )) && PANEL_NGINX_MODE=socket
    panel_compose > "$PANEL_COMPOSE"
    panel_state_save
    n_say "$PANEL_COMPOSE, $PANEL_ENV$( panel_bundled || printf ', %s' "$PANEL_NGINX" )"

    node_step "4/5  UFW"
    if ! node_ufw_ensure; then
        n_say "Не удалось установить UFW — порты не ограничены."
    else
        panel_ufw_apply
        ufw_active || ufwc --force enable >/dev/null 2>&1
        n_say "Открыто: SSH $(ssh_ports | sed 's/ /, /g')/tcp, 443/tcp"
    fi

    node_step "5/5  Запуск контейнеров"
    panel_compose_run pull || { node_fail "Не удалось скачать образы. Проверьте доступ к Docker Hub."; return; }
    panel_compose_run up -d --remove-orphans || { node_fail "docker compose up завершился с ошибкой."; return; }
    if ! panel_wait_healthy 180; then
        node_fail "Панель не запустилась за 3 минуты. Смотрите логи: Панель → Логи → remnawave"
        return
    fi
    # Связка: блоки панели уезжают в конфиг ноды, её nginx пересоздаётся с
    # сертификатом панели внутри. Проверяем конфиг до применения.
    if (( bundle )); then
        n_say "Переношу панель в nginx ноды…"
        node_state_load 2>/dev/null
        backup_file "$NODE_NGINX" >/dev/null; backup_file "$NODE_COMPOSE" >/dev/null
        NODE_SHARED=1
        node_state_save
        node_compose > "$NODE_COMPOSE"
        panel_nginx_write
        node_compose_run up -d --remove-orphans >/dev/null 2>&1
        sleep 3
    fi

    local err
    if ! err=$(panel_nginx_ok); then node_fail "nginx не запустился: $err"; return; fi

    panel_backup_cron_on || { printf '20 4 * * * root %s panel-backup >/dev/null 2>&1\n' "$SKIPIT_BIN" > "$PANEL_BACKUP_CRON"; chmod 644 "$PANEL_BACKUP_CRON"; }

    if (( with_sub )); then
        node_step "Готово  Администратор и токен"
        panel_wait_api 90 || n_say "API панели ещё не отвечает — попробую всё равно."
        n_say "Создаю администратора панели и выпускаю API-токен для страницы..."
        panel_bootstrap_admin; local brc=$?
        if (( brc == 0 )); then
            sub_write_env "$SUB_PANEL_URL" "$PANEL_API_TOKEN" "" ""
            n_say "Токен выпущен и записан в $SUB_ENV"
            # Шаблон Xray JSON «RU-Routing» - пока токен свежий и панель под рукой
            if panel_ru_template_ensure; then
                PANEL_RU_TPL_OK=1
                n_say "Шаблон Xray JSON «$PANEL_RU_TPL» создан"
            else
                n_say "Шаблон «$PANEL_RU_TPL» создать не удалось: $PANEL_TPL_ERR"
                n_say "Повторить: SkipIt Tool → Панель → Шаблон Xray JSON «$PANEL_RU_TPL»"
            fi
        else
            n_say "Автоматически не получилось: $PANEL_BOOTSTRAP_ERR"
            # rc=3 - админ уже создан, пароль знаем только мы: его обязательно
            # показать на итоговом экране, иначе в панель будет не войти
            (( brc == 3 )) && n_say "Администратор создан — логин и пароль ниже, на итоговом экране."
            n_say "Токен можно будет вставить руками: Страница подписки → Сменить API-токен"
        fi
        n_say "Запускаю страницу подписки..."
        panel_compose_run up -d "$SUB_CTR" >/dev/null 2>&1
        sub_state_save
    fi
    log "panel install: ok with_sub=$with_sub"
    if wz_asked; then :
    elif (( with_sub )); then panel_sub_done_screen
    else panel_done_screen; fi
}

panel_sub_done_screen() {
    UI_CTX=""
    ui_head "Панель и страница подписки установлены"
    g_kv "Панель" "https://$PANEL_DOMAIN"
    g_kv "Ссылки клиентов" "https://$SUB_DOMAIN/…"
    g_kv "Папка" "$PANEL_DIR"
    g_kv "Автобэкап" "ежедневно в 04:20"
    g_gap
    g_line "Адрес входа в панель — откройте его один раз в браузере:"
    g_gap
    printf '%s\n' "$(panel_url)" | g_code
    if [[ -n $PANEL_ADMIN_PASS ]]; then
        g_gap
        g_line "Администратор панели создан, войдите этими данными:"
        g_gap
        g_code_kv "логин" "$PANEL_ADMIN_USER" "пароль" "$PANEL_ADMIN_PASS"
        g_gap
        g_note "Сохраните пароль — больше он показан не будет, в лог не пишется."
        g_note "Сменить его можно в самой панели после входа."
        if [[ -n $PANEL_API_TOKEN ]]; then
            g_note "API-токен для страницы подписки уже выпущен и вставлен — делать ничего не нужно."
            (( PANEL_RU_TPL_OK )) && g_note "Шаблон Xray JSON «$PANEL_RU_TPL» создан — выберите его у хоста, если нужен раздельный роутинг."
        else
            g_note "А вот API-токен выпустить не удалось: $PANEL_BOOTSTRAP_ERR"
            g_note "Сделайте руками: Настройки → API Tokens → создайте токен,"
            g_note "затем Страница подписки → Сменить API-токен."
        fi
    else
        g_gap
        g_note "Администратора создайте сами при первом входе."
        g_note "Потом: Настройки → API Tokens → создайте токен."
        g_note "И вставьте его: Страница подписки → Сменить API-токен."
    fi
    g_gap
    g_note "Без cookie домен панели отвечает 404 — боты её не найдут."
    g_note "Страница подписки публичная, по ней клиенты забирают конфиги."
    local a
    printf '\n  %s ' "$(ui_keys "Enter — в меню · d — запустить диагностику")" >"$TTY"
    ui_readline a || return 0
    a=${a,,}; a=${a//[[:space:]]/}
    [[ $a == d || $a == в ]] && { panel_diag; sub_diag; }
    return 0
}

panel_done_screen() {
    UI_CTX=""
    ui_head "Панель установлена"
    g_kv "Домен" "$PANEL_DOMAIN"
    g_kv "Ссылки клиентов" "https://$PANEL_SUB_DOMAIN/…"
    g_kv "Папка" "$PANEL_DIR"
    g_kv "Автобэкап" "ежедневно в 04:20"
    g_gap
    g_note "«Ссылки клиентов» — то, что вы выдаёте пользователям VPN."
    g_note "Панель даёт каждому свою ссылку, с личным кодом на конце."
    g_note "Её вставляют в v2rayTun, Hiddify и подобные приложения."
    g_note "Отдельную страницу подписки можно поставить позже, в «Компонентах»."
    g_gap
    g_line "Адрес входа в панель — откройте его один раз в браузере:"
    g_gap
    printf '%s\n' "$(panel_url)" | g_code
    g_gap
    g_note "По этому адресу браузер получит cookie и дальше панель будет открываться по https://$PANEL_DOMAIN"
    g_note "Без cookie домен отвечает 404 — боты и сканеры панель не найдут."
    g_note "Адрес всегда можно посмотреть заново: SkipIt Tool → Панель → Адрес входа."
    g_gap
    g_line "При первом входе панель попросит создать администратора."
    g_gap
    g_note "Шаблон Xray JSON «$PANEL_RU_TPL» — в меню: SkipIt Tool → Панель → Шаблон Xray JSON."
    g_note "Ему нужен API-токен панели: выпустите его в «Настройки → API Tokens»."
    local a
    printf '\n  %s ' "$(ui_keys "Enter — в меню · d — запустить диагностику")" >"$TTY"
    ui_readline a || return 0
    a=${a,,}; a=${a//[[:space:]]/}
    [[ $a == d || $a == в ]] && panel_diag
    return 0
}

# ---- Обновление панели ----
# Панель прогоняет миграции БД при каждом старте (prisma migrate deploy) и падает,
# если они не прошли. Обратных миграций у Prisma нет, поэтому откат «вернуть старый
# образ» не работает: старый бэкенд встретит уже мигрированную схему. Настоящий
# откат - только восстановление дампа, поэтому дамп делается ДО обновления и без него
# обновление не начинается.
PANEL_OVERRIDE="${PANEL_DIR}/docker-compose.override.yml"

panel_image_ref() { docker inspect -f '{{index .RepoDigests 0}}' remnawave 2>/dev/null; }
panel_image_id()  { docker inspect -f '{{.Image}}' remnawave 2>/dev/null; }
panel_version()   { docker exec remnawave sh -c 'cat package.json 2>/dev/null' 2>/dev/null | sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' | head -n 1; }

panel_update() {
    local before after bak pinned old_ref
    ui_yesno "Обновление панели" "Проверит:   образ Remnawave (${PANEL_BACKEND_IMAGE})
Сделает:    дамп базы данных перед обновлением
Затем:      скачает образ и перезапустит панель

ℹ Страница подписки, база и Valkey не трогаются — только сама панель и её nginx

! Панель будет недоступна 1–2 минуты
! Postgres и Valkey не обновляются: смена мажора Postgres требует отдельной процедуры

ℹ Если панель не поднимется, SkipIt Tool предложит вернуть прежний образ и базу

Обновить панель?" || return

    clear; say "Делаю дамп базы данных..."
    if ! bak=$(panel_backup_make); then
        ui_msg "Обновление отменено" "Не удалось сделать дамп базы данных — без него обновлять опасно.

Проверьте контейнер remnawave-db: Панель → Логи"
        return
    fi
    say "Дамп: $bak"
    old_ref=$(panel_image_ref); before=$(panel_image_id)

    # В связке в этом же compose лежит страница подписки: без явного списка сервисов
    # обновилась бы и она, хотя обещали обновить только панель
    local -a svc=(remnawave)
    panel_bundled || svc+=("$PANEL_NGINX_CTR")
    say "Скачиваю образы..."
    if ! panel_compose_run pull "${svc[@]}"; then
        ui_msg "Ошибка" "Не удалось скачать образы. Панель не тронута.
Дамп: $bak"
        return
    fi
    say "Перезапускаю панель..."
    panel_compose_run up -d "${svc[@]}"
    if panel_wait_healthy 180; then
        after=$(panel_image_id)
        docker image prune -f >/dev/null 2>&1
        log "panel update: ok${old_ref:+ (was $old_ref)}"
        if [[ $before == "$after" ]]; then
            ui_msg "Обновление панели" "Обновлений нет — образ не изменился.

Версия:  $(panel_version)
Дамп:    $bak"
        else
            ui_msg "Панель обновлена" "Версия:  $(panel_version)
Дамп до обновления:  $bak

ℹ Ноды рекомендуется обновлять после панели"
        fi
        return
    fi

    # Не поднялась: показать причину и предложить откат
    local logs
    logs=$(docker logs --tail 25 remnawave 2>&1 | tail -n 15)
    if ! ui_yesno "Панель не запустилась" "Панель не ответила за 3 минуты. Последние строки лога:

$logs

Откатить: вернуть прежний образ и восстановить базу из дампа?" ; then
        ui_msg "Оставлено как есть" "Панель не работает, откат не делался.

Дамп до обновления:  $bak
Логи:                Панель → Логи → remnawave"
        return
    fi
    if [[ -z $old_ref ]]; then
        ui_msg "Откат невозможен" "SkipIt Tool не запомнил прежний образ панели (контейнера уже не было).

Восстановите базу вручную: Панель → Бэкапы → Восстановить ($bak)"
        return
    fi
    clear; say "Откатываю на $old_ref..."
    printf '# SkipIt Tool: откат на прежний образ после неудачного обновления.\n# Удалите этот файл, когда обновитесь успешно.\nservices:\n  remnawave:\n    image: %s\n' "$old_ref" > "$PANEL_OVERRIDE"
    panel_compose_run stop remnawave >/dev/null 2>&1
    say "Восстанавливаю базу данных..."
    gzip -dc "$bak" | docker exec -i remnawave-db sh -c 'psql -q -U "$POSTGRES_USER" -d "$POSTGRES_DB"' >/dev/null 2>&1
    panel_compose_run up -d remnawave >/dev/null 2>&1
    if panel_wait_healthy 120; then
        log "panel update: rolled back to $old_ref"
        ui_msg "Откат выполнен" "Панель работает на прежнем образе.

Образ:  $old_ref
База:   восстановлена из $bak
Файл:   $PANEL_OVERRIDE — удалите его, когда решите обновиться снова

ℹ Причину смотрите в логах и в changelog Remnawave"
    else
        ui_msg "Откат не помог" "Панель не поднялась и на прежнем образе.

Дамп:  $bak
Логи:  docker logs remnawave"
    fi
}

# ---- Управление панелью ----
panel_logs() {
    local c hdr v r
    hdr="Контейнер"$'\t'"Состояние"$'\t'"Перезапусков"
    for v in remnawave remnawave-db remnawave-redis "$(panel_nginx_ctr)"; do
        r=$(docker inspect -f '{{.RestartCount}}' "$v" 2>/dev/null)
        hdr+=$'\n'"$v"$'\t'"$(ctr_state_ru "$v")"$'\t'"${r:-—}"
    done
    c=$(ui_choose "Логи панели" "$hdr" \
        remnawave         "remnawave — панель, миграции БД" \
        remnawave-db      "PostgreSQL" \
        remnawave-redis   "Valkey" \
        "$(panel_nginx_ctr)" "nginx — вход с улицы$(panel_bundled && echo " (общий с нодой)")") || return
    ui_head "Логи: $c"
    printf '  %sпоследние 200 строк, дальше новые в реальном времени%s\n  %s\n\n' \
        "$C_NOTE" "$C_RESET" "$(ui_keys "Ctrl+C — остановить просмотр")" >"$TTY"
    docker logs --tail 200 -f "$c" 2>&1
    pause
}

panel_restart() {
    sub_state_load 2>/dev/null
    ui_yesno "Перезапуск панели" "Перезапустятся:  панель, база данных и nginx$( (( SUB_BUNDLED )) && echo ", а также страница подписки — она в этом же compose" )
Займёт:          около минуты

! Панель будет недоступна, подписки клиентов тоже

Перезапустить?" || return
    clear; say "Перезапускаю панель..."
    panel_compose_run up -d --remove-orphans && panel_compose_run restart
    panel_wait_healthy 120 && say "Панель работает." || say "Панель не ответила за 2 минуты — смотрите логи."
    log "panel restart"
    pause
}

panel_show_url() {
    UI_CTX=""
    ui_head "Адрес входа в панель"
    g_line "Откройте этот адрес в браузере — он выдаст cookie:"
    g_gap
    printf '%s\n' "$(panel_url)" | g_code
    g_gap
    g_note "Дальше панель открывается просто по https://$PANEL_DOMAIN"
    g_note "Без cookie домен отвечает 404 — сканеры панель не находят."
    g_note "Кто знает этот адрес, попадёт на страницу входа. Не публикуйте его."
    g_note "Сменить адрес: Панель → Сменить адрес входа."
    printf '\n  %s ' "$(ui_keys "Enter — назад")" >"$TTY"
    ui_readline _
}

panel_show_api_key() {
    ui_msg "Ключ для сабпейджа" "Панель закрыта: без cookie её /api/ отвечает 404. Чтобы страница подписки
с ДРУГОГО сервера могла ходить в API панели, ей нужен этот ключ.

  $(panel_env_get SKIPIT_PANEL_API_KEY)

Куда вставить:  мастер установки страницы подписки спросит его сам,
                когда упрётся в 404 от панели.

! Это пропуск в /api/ панели — не публикуйте его.

ℹ Страница подписки на этом же сервере подставит ключ сама.
ℹ Сменить ключ можно, пересоздав .env панели (переустановка сохраняет базу)."
}

panel_change_path() {
    local new cookie api_key bak err
    ui_yesno "Смена адреса входа" "Сейчас:  $(panel_url)

Будет создан новый секретный адрес, старый перестанет работать.
Всем, кто уже вошёл, придётся открыть новый адрес заново.

Сменить?" no || return
    new=$(panel_gen_path)
    cookie=$(panel_gen_cookie)
    api_key=$(panel_env_get SKIPIT_PANEL_API_KEY)
    local ngx old_path=$PANEL_PATH old_cookie
    ngx=$(panel_nginx_file)
    old_cookie=$(panel_env_get SKIPIT_PANEL_COOKIE)
    bak=$(backup_file "$ngx")
    # Новый путь и cookie нужны генератору ДО записи: в связке конфиг собирает
    # нода и берёт их из состояния панели и её .env, а не из аргументов.
    # Поэтому старые значения запоминаем заранее - откатывать будет чем.
    PANEL_PATH=$new
    sed -i "s|^SKIPIT_PANEL_COOKIE=.*|SKIPIT_PANEL_COOKIE=${cookie}|" "$PANEL_ENV"
    panel_nginx_write
    # Проверяем конфиг до применения: иначе при ошибке мы бы отрапортовали новый
    # адрес, а панель осталась бы на старом - или вообще без nginx
    if ! err=$(docker exec "$(panel_nginx_ctr)" nginx -t 2>&1); then
        PANEL_PATH=$old_path
        sed -i "s|^SKIPIT_PANEL_COOKIE=.*|SKIPIT_PANEL_COOKIE=${old_cookie}|" "$PANEL_ENV"
        [[ -n $bak ]] && cat "$bak" > "$ngx"
        ui_msg "Адрес не изменён" "nginx не принял новый конфиг, всё возвращено как было:

$err"
        return
    fi
    panel_state_save
    panel_nginx_reload
    log "panel path changed"

    UI_CTX=""
    ui_head "Адрес входа изменён"
    g_line "Новый адрес — откройте его в браузере:"
    g_gap
    printf '%s\n' "$(panel_url)" | g_code
    g_gap
    g_note "Старый адрес больше не работает."
    g_note "Кто уже сидел в панели — пусть откроет новый адрес заново."
    g_note "Посмотреть его снова: Панель → Адрес входа."
    printf '\n  %s ' "$(ui_keys "Enter — назад")" >"$TTY"
    ui_readline _
}

# ---- Диагностика панели ----
panel_diag() {
    local v code
    DIAG=""; DIAG_OK=0; DIAG_WARN=0; DIAG_BAD=0; DIAG_PROBLEMS=""; DIAG_FIX_UFW=0

    diag_head "Контейнеры"
    panel_bundled && diag_ok "Связка: 443 держит Xray ноды, панель отдаётся через её nginx ($NODE_DECOY)"
    for v in remnawave remnawave-db remnawave-redis "$(panel_nginx_ctr)"; do
        case $(ctr_status "$v") in
            running) diag_ok "$v работает" ;;
            "")      diag_bad "$v не создан — перезапустите панель" ;;
            *)       diag_bad "$v: $(ctr_state_ru "$v") — смотрите логи" ;;
        esac
    done
    if panel_healthy; then diag_ok "Панель отвечает на /health"
    else diag_bad "Панель не отвечает на 127.0.0.1:${PANEL_METRICS_PORT}/health — смотрите логи remnawave (там же видны ошибки миграций БД)"; fi
    if v=$(panel_nginx_ok); then diag_ok "nginx: конфигурация верна"; else diag_bad "nginx: $v"; fi

    diag_head "Домен и сертификат"
    node_check_dns "$PANEL_DOMAIN"
    case $? in
        0) diag_ok "DNS: $DNS_MSG" ;;
        2) diag_ok "DNS: $DNS_MSG Для панели это нормально — IP сервера скрыт" ;;
        3) diag_warn "DNS: $DNS_MSG" ;;
        *) diag_bad "DNS: $DNS_MSG" ;;
    esac
    if v=$(cert_days_left "$PANEL_CERT_NAME"); then
        if ! cert_covers "$PANEL_CERT_NAME" "$PANEL_DOMAIN"; then diag_bad "Сертификат $PANEL_CERT_NAME не подходит для $PANEL_DOMAIN"
        elif (( v < 7 ));  then diag_bad "Сертификат истекает через $v дн. — перевыпустите"
        elif (( v < 20 )); then diag_warn "Сертификат: осталось $v дн."
        else diag_ok "Сертификат: осталось $v дн."; fi
    else
        diag_bad "Сертификат /etc/letsencrypt/live/$PANEL_CERT_NAME не найден"
    fi
    cert_renew_scheduled && diag_ok "Автопродление сертификата настроено" || diag_bad "Автопродление сертификата НЕ настроено"

    diag_head "Вход в панель"
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --resolve "$PANEL_DOMAIN:443:127.0.0.1" "https://$PANEL_DOMAIN/" 2>/dev/null)
    [[ $code == 404 ]] && diag_ok "Без cookie домен отвечает 404 — панель скрыта" ||
        diag_warn "Без cookie домен ответил кодом ${code:-нет}, ожидался 404 — проверьте nginx.conf"
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --resolve "$PANEL_DOMAIN:443:127.0.0.1" \
        -H "Cookie: skipit_panel=$(panel_env_get SKIPIT_PANEL_COOKIE)" "https://$PANEL_DOMAIN/" 2>/dev/null)
    [[ $code == 200 || $code == 302 ]] && diag_ok "С cookie панель открывается (код $code)" ||
        diag_bad "С cookie панель ответила кодом ${code:-нет} — панель за nginx не отвечает"

    diag_head "Бэкапы"
    v=$(panel_backup_list | head -n 1)
    if [[ -n $v ]]; then diag_ok "Последний бэкап: $(date -r "$v" '+%d.%m.%Y %H:%M') · $(hsize "$(stat -c %s "$v")")"
    else diag_warn "Бэкапов ещё нет — сделайте первый: Панель → Бэкапы"; fi
    panel_backup_cron_on && diag_ok "Автобэкап включён (ежедневно)" || diag_warn "Автобэкап выключен"

    diag_head "Фаервол"
    if ! command -v ufw >/dev/null 2>&1; then diag_warn "UFW не установлен"
    elif ! ufw_active; then diag_warn "UFW выключен — порты не ограничены"
    elif ufw_rules | grep -Eq '^allow 443(/tcp)?( |$)'; then diag_ok "UFW: 443/tcp открыт"
    else diag_bad "UFW: нет правила на 443/tcp — панель недоступна снаружи"; fi
    for v in "$PANEL_APP_PORT" "$PANEL_METRICS_PORT"; do
        if port_listeners "$v" | grep -qv '127.0.0.1'; then
            diag_bad "Порт $v слушается не только на 127.0.0.1 — панель торчит в интернет мимо nginx"
        fi
    done

    diag_show "Диагностика панели: $PANEL_DOMAIN"
}

# ---- Полное удаление панели ----
panel_remove() {
    local mode bak del_cert=0 del_443=0 with_sub=0
    # В связке страница подписки живёт в этом же compose и в этой же папке:
    # она уедет вместе с панелью, поэтому говорим об этом заранее
    sub_state_load 2>/dev/null && (( SUB_BUNDLED )) && [[ -f $SUB_COMPOSE ]] && with_sub=1
    mode=$(ui_choose "Удаление панели" "Панель:  $PANEL_DOMAIN
База:    том remnawave-db-data — пользователи, ноды, настройки$( (( with_sub )) && printf '\nСтраница подписки:  %s — стоит в связке, удалится вместе с панелью' "$SUB_DOMAIN" )

ℹ Бэкапы в $SKIPIT_BACKUPS не трогаются ни в одном из вариантов

Что делать с базой данных?" \
        keep "Оставить базу — снести только саму панель" \
        all  "Удалить всё, вместе с базой данных") || return

    if [[ $mode == keep ]]; then
        # Вместе с томом обязательно оставляем .env: в нём пароль Postgres.
        # Postgres в непустом томе игнорирует POSTGRES_PASSWORD из окружения, так что
        # переустановка со свежим .env сгенерировала бы новый пароль и не смогла войти.
        ui_yesno "Удаление панели" "── Будет удалено
Контейнеры:  remnawave, remnawave-db, remnawave-redis, nginx$( (( with_sub )) && echo " и страница подписки" )
Файлы:       docker-compose.yml и nginx.conf в $PANEL_DIR$( (( with_sub )) && printf '\nПодписка:    %s — вместе с sub.env и API-токеном' "$SUB_DOMAIN" )
Автобэкап:   ежедневный дамп выключится

── Останется
База:        том remnawave-db-data — все данные на месте
Секреты:     $PANEL_ENV — в нём пароль базы
Бэкапы:      $SKIPIT_BACKUPS

ℹ Поставите панель на этом сервере заново — она подхватит и базу, и секреты

Удалить панель $PANEL_DOMAIN, базу оставить?" no || return
    else
        ui_yesno "Удаление панели" "── Будет удалено
Контейнеры:  remnawave, remnawave-db, remnawave-redis, nginx$( (( with_sub )) && echo " и страница подписки" )
База:        том remnawave-db-data — все пользователи, ноды и настройки
Папка:       $PANEL_DIR вместе с .env и секретами$( (( with_sub )) && printf '\nПодписка:    %s — вместе с sub.env и API-токеном' "$SUB_DOMAIN" )
Автобэкап:   ежедневный дамп выключится

── Останется
Бэкапы:      $SKIPIT_BACKUPS — дампы базы не трогаем

! Это необратимо. Восстановить панель можно будет только из бэкапа.

Удалить панель $PANEL_DOMAIN вместе с базой?" no || return

        ui_yesno "Подтверждение" "Сейчас будет сделан свежий дамп базы, и панель будет удалена вместе с ней.

Точно удалить панель и её базу данных?" no || return
    fi

    # В связке страница подписки уходит вместе с панелью - значит она не в числе
    # тех, ради кого стоит беречь сертификат и правило на 443
    local goes=panel
    (( with_sub )) && goes="panel sub"
    ask_del_cert "$PANEL_CERT_NAME" "$goes" && del_cert=1
    ask_close_443 "$goes" && del_443=1

    clear; say "Делаю дамп базы данных..."
    if bak=$(panel_backup_make); then
        say "Дамп: $bak"
    else
        bak=""
        printf '\n  %s!%s %sДамп сделать не удалось (база уже не отвечает).%s\n' "$C_WARN" "$C_RESET" "$C_TXT" "$C_RESET"
        if [[ $mode == all ]]; then
            ui_yesno "Дамп не сделан" "Свежий дамп базы сделать не удалось.
Прежние бэкапы (если есть) останутся в $SKIPIT_BACKUPS.

Всё равно удалить панель вместе с базой?" no || return
            clear
        fi
    fi

    say "Удаляю панель $PANEL_DOMAIN..."
    if [[ $mode == all ]]; then
        [[ -f $PANEL_COMPOSE ]] && panel_compose_run down -v --remove-orphans
        docker volume rm remnawave-db-data valkey-socket >/dev/null 2>&1
        rm -rf "$PANEL_DIR"
    else
        # down без -v: контейнеры и сеть уходят, именованные тома остаются
        [[ -f $PANEL_COMPOSE ]] && panel_compose_run down --remove-orphans
        docker volume rm valkey-socket >/dev/null 2>&1
        rm -f "$PANEL_COMPOSE" "$PANEL_NGINX"
    fi
    # В связке блоки панели лежали в конфиге ноды - их надо убрать, иначе nginx
    # ноды не стартует: сертификат панели мы могли только что удалить.
    # Делаем до стирания состояния: генератору нужны NODE_*, а признак - PANEL_NGINX_MODE.
    if panel_bundled && node_installed 2>/dev/null; then
        say "Убираю блоки панели из nginx ноды..."
        backup_file "$NODE_NGINX" >/dev/null; backup_file "$NODE_COMPOSE" >/dev/null
        NODE_SHARED=0
        node_state_save
        PANEL_NGINX_MODE=own
        node_compose > "$NODE_COMPOSE"
        node_nginx_conf "$NODE_DOMAIN" "$NODE_CERT_NAME" "$NODE_LAYOUT" > "$NODE_NGINX"
        node_compose_run up -d --remove-orphans >/dev/null 2>&1
        local nerr
        nerr=$(node_nginx_ok) || say "Внимание: nginx ноды ругается — $nerr"
    fi
    rm -f "$PANEL_STATE" "$PANEL_BACKUP_CRON"
    # Состояние страницы подписки без панели нерабочее: её файлы лежали в $PANEL_DIR.
    # Без этого меню продолжало бы считать страницу установленной.
    (( with_sub )) && { rm -f "$SUB_STATE"; SUB_DOMAIN=""; SUB_CERT_NAME=""; SUB_BUNDLED=0; }
    # 443 в связке держит Xray ноды - закрывать его вместе с панелью нельзя
    if (( del_443 )) && ! node_installed 2>/dev/null && command -v ufw >/dev/null 2>&1; then
        ufwc --force delete allow 443/tcp >/dev/null 2>&1
    fi
    if (( del_cert )) && command -v certbot >/dev/null 2>&1; then
        certbot delete --non-interactive --cert-name "$PANEL_CERT_NAME" >/dev/null 2>&1
    fi
    log "panel remove: $PANEL_DOMAIN mode=$mode cert=$del_cert ufw443=$del_443 sub=$with_sub"
    PANEL_DOMAIN=""; PANEL_CERT_NAME=""; PANEL_PATH=""; PANEL_SUB_DOMAIN=""
    echo
    if [[ $mode == all ]]; then
        say "Панель и её база данных удалены."
    else
        say "Панель удалена. База данных и $PANEL_ENV остались на месте."
        say "Установите панель заново на этом сервере — она подхватит их сама."
    fi
    say "Бэкапы базы данных НЕ тронуты: $SKIPIT_BACKUPS"
    [[ -n $bak ]] && say "Последний дамп: $bak"
    pause
}

panel_menu_label() {
    if panel_installed; then echo "Панель Remnawave · $PANEL_DOMAIN"; else echo "Установить панель Remnawave"; fi
}

menu_panel() {
    local c hdr tab=$'\t'
    while :; do
        # Установку запускает меню компонентов; сюда попадаем только с готовой панелью
        panel_installed || return
        hdr="Домен:      $PANEL_DOMAIN
Ссылки клиентов:  https://$PANEL_SUB_DOMAIN/…
Вход:       по секретному адресу

Компонент${tab}Состояние
remnawave${tab}$(ctr_state_ru remnawave)
PostgreSQL${tab}$(ctr_state_ru remnawave-db)
Valkey${tab}$(ctr_state_ru remnawave-redis)
nginx${tab}$(ctr_state_ru "$(panel_nginx_ctr)")$(panel_bundled && echo " · общий с нодой")
Сертификат${tab}$(cert_days_left "$PANEL_CERT_NAME" >/dev/null 2>&1 && echo "действует · $(cert_days_left "$PANEL_CERT_NAME") дн." || echo НЕТ)
Бэкап${tab}$(panel_backup_list | head -n 1 | xargs -r -I{} date -r {} '+%d.%m.%Y %H:%M' || echo НЕТ)"
        c=$(ui_menu "Панель Remnawave" "$hdr" \
            ""        "Доступ" \
            url       "Адрес входа в панель" \
            apikey    "Ключ для сабпейджа на другом сервере" \
            ""        "Управление" \
            logs      "Логи" \
            restart   "Перезапустить панель" \
            update    "Обновить панель" \
            ""        "Бэкапы" \
            backups   "Список бэкапов" \
            backupnow "Сделать бэкап сейчас" \
            restore   "Восстановить из бэкапа" \
            cron      "$(panel_backup_cron_on && echo "Выключить автобэкап" || echo "Включить автобэкап")" \
            ""        "Настройки" \
            newpath   "Сменить адрес входа" \
            nginxgen  "Пересоздать nginx.conf по шаблону SkipIt Tool" \
            rutpl     "Шаблон Xray JSON «$PANEL_RU_TPL»" \
            cert      "Сертификат: статус и перевыпуск" \
            resetadm  "Сбросить администратора (забыт пароль)" \
            ""        "Опасные действия" \
            reinstall "Переустановить (файлы, база не тронется)" \
            remove    "Удалить панель") || return
        case $c in
            url)       panel_show_url ;;
            apikey)    panel_show_api_key ;;
            logs)      panel_logs ;;
            restart)   panel_restart ;;
            update)    panel_update ;;
            backups)   panel_backup_screen ;;
            backupnow) panel_backup_now ;;
            restore)   panel_restore ;;
            cron)      panel_backup_cron_toggle ;;
            resetadm)  panel_reset_admin ;;
            newpath)   panel_change_path ;;
            nginxgen)  panel_nginx_rebuild ;;
            rutpl)     panel_ru_template_menu ;;
            cert)      panel_cert ;;
            reinstall) panel_install ;;
            remove)    panel_remove ;;
        esac
    done
}

# Переписать nginx.conf по шаблону текущей версии SkipIt Tool. Так на уже
# установленную панель приезжают правки шаблона (например сжатие gzip),
# и для этого не нужно ничего переустанавливать.
panel_nginx_rebuild() {
    local ngx bak err
    ngx=$(panel_nginx_file)
    ui_yesno "Пересоздать nginx.conf" "── Что будет
Файл:      $ngx$(panel_bundled && printf '\nЭто конфиг ноды: в связке панель живёт в нём')
Заново:    соберётся по шаблону SkipIt Tool v${SKIPIT_VERSION}
Бэкап:     прежняя версия уйдёт в $SKIPIT_BACKUPS
Проверка:  nginx -t, при ошибке файл вернётся как был

ℹ Ручные правки в файле пропадут.
ℹ Домен, адрес входа и сертификат не меняются.

! nginx перечитает конфиг на ходу — клиенты этого не заметят

Пересоздать?" no || return
    bak=$(backup_file "$ngx")
    if ! panel_nginx_write; then
        ui_msg "Ошибка" "Не удалось собрать nginx.conf."
        return
    fi
    if ! err=$(docker exec "$(panel_nginx_ctr)" nginx -t 2>&1); then
        [[ -n $bak ]] && cat "$bak" > "$ngx"
        ui_msg "Ошибка в nginx.conf" "nginx не принял новый конфиг, файл возвращён как был:

$err"
        return
    fi
    panel_nginx_reload
    log "panel nginx rebuild (backup: $bak)"
    ui_msg "Готово" "nginx.conf пересоздан и применён.${bak:+

Бэкап: $bak}"
}

# Создать (или переписать) шаблон «RU-Routing» на уже установленной панели.
# Нужен API-токен: он есть, если панель ставилась вместе со страницей подписки
# или в связке. Панель без страницы токена не выпускает - об этом и сообщаем.
panel_ru_template_menu() {
    ui_yesno "Шаблон Xray JSON «$PANEL_RU_TPL»" "── Что будет
Шаблон:    $PANEL_RU_TPL, тип Xray JSON
Где:       Панель → Шаблоны → Xray JSON
Внутри:    .ru, .su, .рф, госсайты, банки и российские сервисы — напрямую
           Telegram — через прокси, IPv6 и QUIC на 443 — в блок
Если есть: содержимое перепишется по шаблону SkipIt Tool v${SKIPIT_VERSION}

ℹ Сам по себе шаблон ничего не меняет: выберите его у хоста, поле «Шаблон Xray JSON».
ℹ Клиенты без Xray JSON (обычные ссылки, Clash, Sing-box) его не видят.

Создать?" || return
    if panel_ru_template_ensure; then
        ui_msg "Готово" "Шаблон «$PANEL_RU_TPL» на месте.

Панель → Шаблоны → Xray JSON → $PANEL_RU_TPL

Чтобы он заработал, откройте нужный хост и выберите его в поле «Шаблон Xray JSON»."
    else
        ui_msg "Не получилось" "$PANEL_TPL_ERR

Токен SkipIt Tool выпускает, когда панель ставится со страницей подписки или в связке.
Панель без страницы подписки токена не имеет — выпустите его в панели
(Настройки → API Tokens) и вставьте: Страница подписки → Сменить API-токен."
    fi
}

panel_cert() {
    local d c rc
    d=$(cert_days_left "$PANEL_CERT_NAME") || d="—"
    c=$(ui_choose "Сертификат панели" "Сертификат:  /etc/letsencrypt/live/$PANEL_CERT_NAME
Домены:      $(cert_domains "$PANEL_CERT_NAME")
Способ:      $(cert_method_ru "$PANEL_CERT_NAME")
Действует:   ещё $d дн.
Продление:   $(cert_renew_scheduled && echo "автоматически (certbot)" || echo "НЕ НАСТРОЕНО")" \
        test  "Проверить автопродление (certbot renew --dry-run)" \
        renew "Перевыпустить сейчас") || return
    [[ $c == renew ]] && { ui_yesno "Перевыпуск" "Перевыпустить сертификат $PANEL_CERT_NAME?
Let's Encrypt ограничивает число выпусков (5 в неделю)." no || return; }
    command -v certbot >/dev/null 2>&1 || { ui_msg "Ошибка" "certbot не установлен."; return; }
    cert_write_hooks; cert_ensure_renew
    clear
    [[ $(cert_method_ru "$PANEL_CERT_NAME") == HTTP-01 ]] && "$ACME_OPEN" force
    if [[ $c == test ]]; then
        certbot renew --dry-run --no-random-sleep-on-renew --cert-name "$PANEL_CERT_NAME"; rc=$?
    else
        certbot renew --force-renewal --no-random-sleep-on-renew --cert-name "$PANEL_CERT_NAME"; rc=$?
    fi
    "$ACME_CLOSE"
    log "panel cert $c rc=$rc"
    echo
    (( rc == 0 )) && say "Готово." || printf '%s✗ certbot завершился с ошибкой (код %s)%s\n' "$C_ERR" "$rc" "$C_RESET"
    pause
}

# ==== Сабпейдж Remnawave (страница подписки) ====
# Один контейнер remnawave/subscription-page на 127.0.0.1:3010 плюс nginx в host-сети,
# который отдаёт его в интернет по 443 (host-сеть - чтобы действовали правила UFW).
# Страница ходит в API панели по REMNAWAVE_API_TOKEN (создаётся в самой панели).
# Если панель закрыта cookie-гейтом SkipIt Tool, страница дополнительно шлёт X-Api-Key
# (CADDY_AUTH_API_TOKEN) - иначе nginx панели ответил бы ей 404.
SUB_DIR="/opt/remnasub"
SUB_COMPOSE="${SUB_DIR}/docker-compose.yml"
SUB_ENV="${SUB_DIR}/.env"
SUB_NGINX="${SUB_DIR}/nginx.conf"
SUB_STATE="${SKIPIT_ETC}/subpage.conf"
SUB_CTR="remnawave-subscription-page"
SUB_NGINX_CTR_OWN="remnasub-nginx"    # свой nginx, когда страница стоит отдельно
SUB_NGINX_CTR="$SUB_NGINX_CTR_OWN"    # в связке с панелью подменяется на nginx панели
SUB_IMAGE="remnawave/subscription-page:latest"
SUB_APP_PORT=3010

SUB_DOMAIN=""; SUB_CERT_METHOD=""; SUB_CERT_NAME=""; SUB_PANEL_URL=""; SUB_PREFIX=""
SUB_BUNDLED=0
SUB_KEYS=(SUB_DOMAIN SUB_CERT_METHOD SUB_CERT_NAME SUB_PANEL_URL SUB_PREFIX SUB_BUNDLED)

sub_state_load() {
    local k v
    SUB_BUNDLED=0
    [[ -f $SUB_STATE ]] || return 1
    while IFS='=' read -r k v; do
        [[ " ${SUB_KEYS[*]} " == *" $k "* ]] && printf -v "$k" '%s' "$v"
    done < "$SUB_STATE"
    # В связке с панелью у страницы нет своих файлов: она живёт в compose панели,
    # её окружение - sub.env рядом, nginx общий. Пути пересчитываем здесь.
    if [[ $SUB_BUNDLED == 1 ]]; then
        SUB_DIR=$PANEL_DIR
        SUB_ENV="${PANEL_DIR}/sub.env"
        SUB_COMPOSE=$PANEL_COMPOSE
        SUB_NGINX=$PANEL_NGINX
        SUB_NGINX_CTR=$(panel_nginx_ctr)
    else
        SUB_NGINX_CTR=$SUB_NGINX_CTR_OWN
    fi
    [[ -n $SUB_DOMAIN ]]
}

sub_state_save() {
    local k
    mkdir -p "$SKIPIT_ETC"
    ( umask 077; for k in "${SUB_KEYS[@]}"; do printf '%s=%s\n' "$k" "${!k}"; done > "$SUB_STATE" )
    chmod 600 "$SUB_STATE"
}

sub_installed() { sub_state_load && [[ -f $SUB_COMPOSE ]]; }
sub_env_get() { sed -n "s/^$1=//p" "$SUB_ENV" 2>/dev/null | head -n 1; }
sub_compose_run() { ( cd "$SUB_DIR" && docker compose "$@" ); }
sub_url() { printf 'https://%s%s' "$SUB_DOMAIN" "${SUB_PREFIX:+/$SUB_PREFIX}"; }

# Токен панели: длинная строка без пробелов
sub_valid_token() { [[ ${#1} -ge 16 && $1 =~ ^[A-Za-z0-9+/=._~-]+$ ]]; }
sub_mask() { cf_mask "$1"; }

sub_write_env() { # panel_url api_token prefix skipit_key
    mkdir -p "$SUB_DIR"
    ( umask 077; cat > "$SUB_ENV" <<EOF
# SkipIt Tool · страница подписки Remnawave. Файл с токенами, права 600.

APP_PORT=${SUB_APP_PORT}
REMNAWAVE_PANEL_URL=${1}
REMNAWAVE_API_TOKEN=${2}
CUSTOM_SUB_PREFIX=${3}

# Потолок кучи V8, считается от RAM сервера. Перекрывает зашитые в образ 16 ГБ.
NODE_OPTIONS=--max-old-space-size=$(sub_node_heap_mb)

# Один реверс-прокси перед страницей - nginx SkipIt Tool
TRUST_PROXY=1

# X-Api-Key к запросам в панель: нужен, если панель закрыта cookie-гейтом SkipIt Tool
CADDY_AUTH_API_TOKEN=${4}

MARZBAN_LEGACY_LINK_ENABLED=false
EOF
    )
    chmod 600 "$SUB_ENV"
}

sub_compose() {
local cert_mounts
if [[ -n ${SUB_CERT_NAME:-} ]]; then
    cert_mounts="      - /etc/letsencrypt/live/${SUB_CERT_NAME}:/etc/letsencrypt/live/${SUB_CERT_NAME}:ro
      - /etc/letsencrypt/archive/${SUB_CERT_NAME}:/etc/letsencrypt/archive/${SUB_CERT_NAME}:ro"
else
    cert_mounts="      - /etc/letsencrypt/live:/etc/letsencrypt/live:ro
      - /etc/letsencrypt/archive:/etc/letsencrypt/archive:ro"
fi
cat <<EOF
# SkipIt Tool · страница подписки Remnawave. Токены - в .env рядом.

x-common: &common
  restart: unless-stopped
  security_opt:
    - no-new-privileges:true
  logging:
    driver: json-file
    options:
      max-size: 10m
      max-file: "3"

services:
  ${SUB_CTR}:
    <<: *common
    image: ${SUB_IMAGE}
    container_name: ${SUB_CTR}
    hostname: ${SUB_CTR}
    env_file: .env
    ports:
      - 127.0.0.1:${SUB_APP_PORT}:${SUB_APP_PORT}

  # nginx в host-сети: так на 443 действуют правила UFW
  ${SUB_NGINX_CTR}:
    <<: *common
    image: ${NODE_NGINX_IMAGE}
    container_name: ${SUB_NGINX_CTR}
    hostname: ${SUB_NGINX_CTR}
    network_mode: host
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
${cert_mounts}
EOF
}

# nginx сабпейджа: 443 напрямую. Страница публичная - её открывают клиенты по ссылке,
# поэтому cookie-гейта тут нет.
sub_nginx_conf() { # домен имя-сертификата
    local cert="/etc/letsencrypt/live/$2"
cat <<EOF
# SkipIt Tool · страница подписки $1
# Файл пересоздаётся SkipIt Tool, ручные правки уйдут в бэкап.

server_tokens off;
server_names_hash_bucket_size 128;

ssl_certificate     $cert/fullchain.pem;
ssl_certificate_key $cert/privkey.pem;
ssl_protocols       TLSv1.2 TLSv1.3;
ssl_ecdh_curve      X25519:prime256v1:secp384r1;
ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
ssl_prefer_server_ciphers off;
ssl_session_cache   shared:skipit_tls:10m;
ssl_session_timeout 4h;
ssl_session_tickets off;

server {
    listen 443 ssl;
$( [[ -f /proc/net/if_inet6 ]] && echo "    listen [::]:443 ssl;" )
    http2 on;
    server_name $1;
    access_log off;

    location / {
        proxy_pass http://127.0.0.1:${SUB_APP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 1m;
    }
}

# Любое другое имя в SNI: рукопожатие обрывается, сертификат не показывается
server {
    listen 443 ssl default_server;
$( [[ -f /proc/net/if_inet6 ]] && echo "    listen [::]:443 ssl default_server;" )
    ssl_reject_handshake on;
}
EOF
}

sub_nginx_ok() { # → текст ошибки
    local out
    [[ $(ctr_status "$SUB_NGINX_CTR") == running ]] || { echo "контейнер $SUB_NGINX_CTR не работает"; return 1; }
    out=$(docker exec "$SUB_NGINX_CTR" nginx -t 2>&1) || { echo "$out"; return 1; }
}

# Живость страницы: /internal/health и только ИЗНУТРИ контейнера.
# Корень / сабпейдж рвёт без ответа (индексного маршрута нет, это защита от сканеров),
# а /internal/health отвечает только на обращения внутри docker-сети. С хоста оба
# варианта дают «нет ответа», и проверка ругалась на живую страницу.
sub_healthy() {
    [[ $(ctr_status "$SUB_CTR") == running ]] || return 1
    docker exec "$SUB_CTR" curl -fsS -o /dev/null --max-time 5 \
        "http://127.0.0.1:${SUB_APP_PORT}/internal/health" >/dev/null 2>&1
}

sub_wait_healthy() { # секунд
    local i=0 n=${1:-60}
    while (( i < n )); do
        sub_healthy && return 0
        [[ $(ctr_status "$SUB_CTR") == exited ]] && return 1
        sleep 3; i=$((i + 3))
        ui_loading "Жду запуска страницы подписки… ${i} с из ${n}"
    done
    return 1
}

# Проверить, что панель отвечает и токен рабочий. SUB_API_ERR - текст проблемы.
# 0 - всё хорошо, 1 - не достучались, 2 - панель закрыта (нужен ключ SkipIt Tool), 3 - токен отвергнут
SUB_API_ERR=""
sub_api_check() { # panel_url api_token skipit_key
    local code hdr
    SUB_API_ERR=""
    hdr=$(printf 'header = "Authorization: Bearer %s"\n' "$2")
    [[ -n $3 ]] && hdr+=$(printf '\nheader = "X-Api-Key: %s"\n' "$3")
    # Панель по http (локальная, из compose) без этих заголовков рвёт соединение
    [[ ${1,,} == http://* ]] && hdr+=$'\n'"$(panel_proxy_hdr_cfg)"
    # В связке с панелью адрес - имя из docker-сети (http://remnawave:3000). С хоста
    # оно не резолвится, curl молча падает в 000, и проверка обвиняла живую панель.
    # Такой запрос шлём изнутри контейнера страницы - оттуда имя видно.
    local url=${1%/} host run=()
    host=${url#*://}; host=${host%%[:/]*}
    if ! getent hosts "$host" >/dev/null 2>&1; then
        if   [[ $(ctr_status "$SUB_CTR") == running ]]; then run=(docker exec -i "$SUB_CTR")
        elif [[ $(ctr_status remnawave) == running ]]; then run=(docker exec -i remnawave)
        fi
    fi
    code=$(printf '%s\n' "$hdr" | "${run[@]}" curl -sS -o /dev/null -w '%{http_code}' --max-time 15 -K - \
        "$url/api/system/stats" 2>/dev/null) || code=000
    case $code in
        200) return 0 ;;
        000) SUB_API_ERR="Сервер панели не отвечает по адресу ${1}. Проверьте адрес, DNS и что панель работает."; return 1 ;;
        404) SUB_API_ERR="Панель ответила 404 на /api/. Похоже, её API закрыт реверс-прокси.
Если панель ставил SkipIt Tool — возьмите ключ: на сервере панели «Панель → Ключ для сабпейджа»."; return 2 ;;
        401|403) SUB_API_ERR="Панель отвергла токен (код $code). Создайте новый: панель → Настройки → API Tokens."; return 3 ;;
        *) SUB_API_ERR="Панель ответила кодом $code."; return 1 ;;
    esac
}

sub_ufw_apply() {
    command -v ufw >/dev/null 2>&1 || return 0
    ufwc allow 443/tcp comment 'Remnawave subpage (SkipIt)' >/dev/null 2>&1
}

# ---- Установка сабпейджа ----
sub_install() { UI_CTX=""; _sub_install; local rc=$?; UI_CTX=""; return $rc; }

_sub_install() {
    local domain panel_url token prefix skipit_key="" busy rc reinstall=0
    sub_state_load 2>/dev/null
    # В связке файлы у страницы общие с панелью: отдельная установка перезаписала бы
    # docker-compose.yml и nginx.conf панели - и панель перестала бы существовать
    if (( SUB_BUNDLED )); then
        ui_msg "Страница подписки в связке с панелью" "Страница установлена вместе с панелью $PANEL_DOMAIN:
контейнер живёт в её docker-compose.yml, nginx у них общий.

Отдельная переустановка перезаписала бы файлы панели, поэтому она здесь закрыта.

── Что можно сделать вместо этого
Сменить домен или сертификат:  Компоненты Remnawave → Панель → Переустановить
                               (мастер спросит оба домена и поднимет связку заново)
Сменить токен панели:          Страница подписки → Сменить API-токен
Убрать только страницу:        Страница подписки → Удалить страницу подписки"
        return
    fi
    if [[ -n $SUB_DOMAIN && -f $SUB_COMPOSE ]]; then
        reinstall=1
        ui_yesno "Переустановка страницы подписки" "── Что уже установлено
Домен:   $SUB_DOMAIN
Папка:   $SUB_DIR

── Что будет перезаписано
Файлы:   docker-compose.yml, .env, nginx.conf
Бэкап:   старые версии уйдут в $SKIPIT_BACKUPS

Переустановить страницу?" no || return
    fi
    ui_yesno "Установка страницы подписки" "── Что понадобится
Домен:   A-запись на IP этого сервера ($SERVER_IP)
Панель:  адрес работающей панели Remnawave
Токен:   API-токен из панели (Настройки → API Tokens)

ℹ Домен в Cloudflare — включайте прокси, он спрячет IP сервера.
ℹ Нужно «оранжевое облако» — серое обязательно только для ноды.

── Что будет сделано
Контейнеры:  страница подписки и nginx в $SUB_DIR
Порт:        443 для страницы, 80 — только на время выпуска сертификата

ℹ Страница публичная: по её ссылке клиенты забирают свои конфиги

Начать?" || return
    wz_asked || ipv6_check_wizard || return

    while :; do
        domain=$(ui_input "Домен страницы подписки" "Пример:  sub.example.com

Домен, по которому клиенты будут открывать подписку:" "$SUB_DOMAIN") || return
        domain=${domain//[[:space:]]/}; domain=${domain,,}; domain=${domain%.}
        valid_domain "$domain" && break
        ui_msg "Ошибка" "Некорректный домен: «$domain»"
    done
    web_check_dns_ui "$domain" "Страница подписки" || return
    ui_ctx_add "Домен" "$domain"
    (( CF_PROXIED )) && ui_ctx_add "Cloudflare" "прокси включён, IP скрыт"

    if (( ! reinstall )); then
        busy=$(port_owner 443)
        case $? in
            1) ;;
            *) ui_msg "Порт 443 занят" "Странице подписки нужен порт 443, а его занял: $busy

ℹ Если это панель или нода SkipIt Tool — страница подписки рядом с ними ставится
  другим способом, он появится в следующей версии SkipIt Tool."
               return ;;
        esac
    fi

    while :; do
        panel_url=$(ui_input "Адрес панели" "Куда страница будет ходить за данными.
Пример:  https://panel.example.com

Адрес панели Remnawave:" "${SUB_PANEL_URL:-https://}") || return
        panel_url=${panel_url//[[:space:]]/}; panel_url=${panel_url%/}
        [[ $panel_url == https://* || $panel_url == http://* ]] && break
        ui_msg "Ошибка" "Адрес должен начинаться с https:// или http://"
    done
    ui_ctx_add "Панель" "$panel_url"

    # Если панель стоит на этом же сервере - ключ SkipIt Tool возьмём сами
    if panel_state_load 2>/dev/null && [[ -f $PANEL_ENV ]]; then
        skipit_key=$(panel_env_get SKIPIT_PANEL_API_KEY)
    fi

    while :; do
        token=$(ui_input "API-токен панели" "1. Откройте панель Remnawave
2. Настройки → API Tokens → создайте токен
3. Скопируйте его и вставьте сюда

API-токен панели:") || return
        token=$(cf_clean_token "$token")
        if ! sub_valid_token "$token"; then
            ui_msg "Ошибка" "Это не похоже на токен: ожидается длинная строка без пробелов."
            continue
        fi
        ui_loading "Проверяю связь с панелью…"
        sub_api_check "$panel_url" "$token" "$skipit_key"; rc=$?
        (( rc == 0 )) && { ui_ctx_add "Токен" "проверен"; break; }
        if (( rc == 2 )); then
            local key
            key=$(ui_input "Ключ панели SkipIt Tool" "$SUB_API_ERR

Ключ для сабпейджа (пусто — пропустить проверку):") || return
            key=$(cf_clean_token "$key")
            if [[ -n $key ]]; then
                skipit_key=$key
                ui_loading "Проверяю ещё раз…"
                sub_api_check "$panel_url" "$token" "$skipit_key" && { ui_ctx_add "Токен" "проверен"; break; }
            fi
        fi
        ui_yesno "Панель не подтвердила токен" "$SUB_API_ERR

n — ввести заново.

Продолжить без проверки?" no && { ui_ctx_add "Токен" "без проверки"; break; }
    done

    prefix=$(ui_input "Путь страницы" "Пусто — страница будет на https://$domain/<код>
Если указать «sub» — на https://$domain/sub/<код>

ℹ Тот же адрес нужно будет прописать в панели (SUB_PUBLIC_DOMAIN)

Путь (без слэшей, можно оставить пустым):" "$SUB_PREFIX") || return
    prefix=${prefix//[[:space:]]/}; prefix=${prefix#/}; prefix=${prefix%/}
    if [[ -n $prefix && ! $prefix =~ ^[A-Za-z0-9._-]+$ ]]; then
        ui_msg "Ошибка" "Путь может содержать только буквы, цифры, точку, дефис и подчёркивание."
        return
    fi

    # Только спрашиваем; сам выпуск - после подтверждения, шагом 2/5
    if ! cert_ask "$domain" "Страница подписки" "$( (( CF_PROXIED )) && echo "$domain" )"; then return; fi
    SUB_CERT_METHOD=$CERT_METHOD; SUB_CERT_NAME=$CERT_NAME
    local cert_ru; cert_ru=$(cert_choice_ru)
    UI_CTX=""

    ui_yesno "Подтверждение" "Установить страницу подписки?

  Домен:        $domain
  Адрес:        https://${domain}${prefix:+/$prefix}
  Панель:       $panel_url
  Сертификат:   $cert_ru
  Папка:        $SUB_DIR
  Порт:         443/tcp" || return

    ui_head "Установка страницы подписки · $domain"
    log "subpage install: domain=$domain panel=$panel_url cert=$SUB_CERT_METHOD"

    node_step "1/5  Docker и подкачка"
    node_ensure_docker || { node_fail "Не удалось установить или запустить Docker."; return; }
    swap_ensure

    node_step "2/5  SSL-сертификат"
    cert_issue "$domain" || return

    node_step "3/5  Файлы"
    mkdir -p "$SUB_DIR" || { node_fail "Не удалось создать $SUB_DIR"; return; }
    local f
    for f in "$SUB_COMPOSE" "$SUB_ENV" "$SUB_NGINX"; do [[ -f $f ]] && backup_file "$f" >/dev/null; done
    SUB_DOMAIN=$domain; SUB_PANEL_URL=$panel_url; SUB_PREFIX=$prefix
    sub_write_env "$panel_url" "$token" "$prefix" "$skipit_key"
    sub_compose > "$SUB_COMPOSE"
    sub_nginx_conf "$domain" "$SUB_CERT_NAME" > "$SUB_NGINX"
    sub_state_save
    n_say "$SUB_COMPOSE, $SUB_ENV, $SUB_NGINX"

    node_step "4/5  UFW"
    if ! node_ufw_ensure; then
        n_say "Не удалось установить UFW — порты не ограничены."
    else
        sub_ufw_apply
        ufw_active || ufwc --force enable >/dev/null 2>&1
        n_say "Открыто: SSH $(ssh_ports | sed 's/ /, /g')/tcp, 443/tcp"
    fi

    node_step "5/5  Запуск контейнеров"
    sub_compose_run pull || { node_fail "Не удалось скачать образы."; return; }
    sub_compose_run up -d --remove-orphans || { node_fail "docker compose up завершился с ошибкой."; return; }
    if ! sub_wait_healthy 90; then
        node_fail "Страница не запустилась за 90 секунд. Смотрите логи: Страница подписки → Логи"
        return
    fi
    local err
    if ! err=$(sub_nginx_ok); then node_fail "nginx не запустился: $err"; return; fi
    log "subpage install: ok"
    sub_done_screen
}

sub_done_screen() {
    UI_CTX=""
    ui_head "Страница подписки установлена"
    g_kv "Домен" "$SUB_DOMAIN"
    g_kv "Адрес" "$(sub_url)"
    g_kv "Панель" "$SUB_PANEL_URL"
    g_kv "Папка" "$SUB_DIR"
    g_gap
    g_line "Осталось прописать этот адрес в панели:"
    g_gap
    g_steps "На сервере панели откройте $PANEL_ENV" \
            "Замените значение ⟦SUB_PUBLIC_DOMAIN⟧ на ⟦${SUB_DOMAIN}${SUB_PREFIX:+/$SUB_PREFIX}⟧" \
            "Перезапустите панель"
    g_gap
    g_note "Если панель ставил SkipIt Tool на этом же сервере — правку и перезапуск он сделает сам в следующей версии."
    g_note "Ссылки подписки клиентов начнут указывать на этот домен."
    local a
    printf '\n  %s ' "$(ui_keys "Enter — в меню · d — запустить диагностику")" >"$TTY"
    ui_readline a || return 0
    a=${a,,}; a=${a//[[:space:]]/}
    [[ $a == d || $a == в ]] && sub_diag
    return 0
}

# ---- Управление сабпейджем ----
sub_update() {
    local before after
    ui_yesno "Обновление страницы подписки" "Проверит:  образ ${SUB_IMAGE}
Есть новая: скачает и перезапустит

! Страница будет недоступна около 10 секунд
ℹ Данных у неё нет — откат делается возвратом прежнего образа

Проверить обновления?" || return
    clear; say "Скачиваю образ..."
    before=$(docker inspect -f '{{.Image}}' "$SUB_CTR" 2>/dev/null)
    # В связке compose общий с панелью: без имени сервиса обновилась бы и панель с базой
    if (( SUB_BUNDLED )); then
        sub_compose_run pull "$SUB_CTR" || { node_fail "Не удалось скачать образ."; return; }
        sub_compose_run up -d "$SUB_CTR" || { node_fail "docker compose up завершился с ошибкой."; return; }
    else
        sub_compose_run pull || { node_fail "Не удалось скачать образ."; return; }
        sub_compose_run up -d --remove-orphans || { node_fail "docker compose up завершился с ошибкой."; return; }
    fi
    after=$(docker inspect -f '{{.Image}}' "$SUB_CTR" 2>/dev/null)
    docker image prune -f >/dev/null 2>&1
    echo
    if [[ $before == "$after" ]]; then say "Обновлений нет — образ не изменился."
    else say "Образ обновлён, контейнер пересоздан."; log "subpage update: image changed"; fi
    pause
}

sub_logs() {
    local c hdr v r
    hdr="Контейнер"$'\t'"Состояние"$'\t'"Перезапусков"
    for v in "$SUB_CTR" "$SUB_NGINX_CTR"; do
        r=$(docker inspect -f '{{.RestartCount}}' "$v" 2>/dev/null)
        hdr+=$'\n'"$v"$'\t'"$(ctr_state_ru "$v")"$'\t'"${r:-—}"
    done
    c=$(ui_choose "Логи страницы подписки" "$hdr" \
        "$SUB_CTR"       "страница подписки — связь с панелью" \
        "$SUB_NGINX_CTR" "nginx — вход с улицы") || return
    ui_head "Логи: $c"
    printf '  %sпоследние 200 строк, дальше новые в реальном времени%s\n  %s\n\n' \
        "$C_NOTE" "$C_RESET" "$(ui_keys "Ctrl+C — остановить просмотр")" >"$TTY"
    docker logs --tail 200 -f "$c" 2>&1
    pause
}

sub_restart() {
    ui_yesno "Перезапуск" "Перезапустятся страница подписки и nginx.

! Клиенты не смогут обновить подписку около 10 секунд$( (( SUB_BUNDLED )) && echo "
! nginx общий с панелью — панель тоже моргнёт на эти секунды" )

Перезапустить?" || return
    clear; say "Перезапускаю..."
    if (( SUB_BUNDLED )); then
        sub_compose_run up -d "$SUB_CTR" && sub_compose_run restart "$SUB_CTR" "$SUB_NGINX_CTR"
    else
        sub_compose_run up -d --remove-orphans && sub_compose_run restart
    fi
    log "subpage restart"
    pause
}

sub_change_token() {
    local token rc skipit_key
    skipit_key=$(sub_env_get CADDY_AUTH_API_TOKEN)
    while :; do
        token=$(ui_input "Новый API-токен" "1. Панель → Настройки → API Tokens
2. Создайте токен и скопируйте его

API-токен панели:") || return
        token=$(cf_clean_token "$token")
        sub_valid_token "$token" || { ui_msg "Ошибка" "Это не похоже на токен."; continue; }
        ui_loading "Проверяю связь с панелью…"
        sub_api_check "$SUB_PANEL_URL" "$token" "$skipit_key"; rc=$?
        (( rc == 0 )) && break
        ui_yesno "Панель не подтвердила токен" "$SUB_API_ERR

n — ввести заново.

Сохранить без проверки?" no && break
    done
    backup_file "$SUB_ENV" >/dev/null
    sub_write_env "$SUB_PANEL_URL" "$token" "$SUB_PREFIX" "$skipit_key"
    clear; say "Пересоздаю контейнер..."
    sub_compose_run up -d --force-recreate "$SUB_CTR"
    log "subpage token changed"
    pause
}

sub_diag() {
    local v code
    DIAG=""; DIAG_OK=0; DIAG_WARN=0; DIAG_BAD=0; DIAG_PROBLEMS=""; DIAG_FIX_UFW=0

    diag_head "Контейнеры"
    for v in "$SUB_CTR" "$SUB_NGINX_CTR"; do
        case $(ctr_status "$v") in
            running) diag_ok "$v работает" ;;
            "")      diag_bad "$v не создан — перезапустите" ;;
            *)       diag_bad "$v: $(ctr_state_ru "$v") — смотрите логи" ;;
        esac
    done
    sub_healthy && diag_ok "Страница отвечает на 127.0.0.1:${SUB_APP_PORT}" ||
        diag_bad "Страница не отвечает на 127.0.0.1:${SUB_APP_PORT} — смотрите логи"
    if v=$(sub_nginx_ok); then diag_ok "nginx: конфигурация верна"; else diag_bad "nginx: $v"; fi

    diag_head "Связь с панелью"
    sub_api_check "$SUB_PANEL_URL" "$(sub_env_get REMNAWAVE_API_TOKEN)" "$(sub_env_get CADDY_AUTH_API_TOKEN)" &&
        diag_ok "Панель $SUB_PANEL_URL отвечает, токен принят" || diag_bad "$SUB_API_ERR"

    diag_head "Домен и сертификат"
    node_check_dns "$SUB_DOMAIN"
    case $? in
        0) diag_ok "DNS: $DNS_MSG" ;;
        2) diag_ok "DNS: $DNS_MSG Для страницы подписки это нормально — IP сервера скрыт" ;;
        3) diag_warn "DNS: $DNS_MSG" ;;
        *) diag_bad "DNS: $DNS_MSG" ;;
    esac
    if v=$(cert_days_left "$SUB_CERT_NAME"); then
        if ! cert_covers "$SUB_CERT_NAME" "$SUB_DOMAIN"; then diag_bad "Сертификат $SUB_CERT_NAME не подходит для $SUB_DOMAIN"
        elif (( v < 7 ));  then diag_bad "Сертификат истекает через $v дн. — перевыпустите"
        elif (( v < 20 )); then diag_warn "Сертификат: осталось $v дн."
        else diag_ok "Сертификат: осталось $v дн."; fi
    else
        diag_bad "Сертификат /etc/letsencrypt/live/$SUB_CERT_NAME не найден"
    fi
    cert_renew_scheduled && diag_ok "Автопродление сертификата настроено" || diag_bad "Автопродление сертификата НЕ настроено"

    diag_head "Снаружи"
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --resolve "$SUB_DOMAIN:443:127.0.0.1" "$(sub_url)/" 2>/dev/null)
    # Страница открывается только по ссылке с UUID, на всё остальное рвёт соединение,
    # и nginx показывает это как 502. На корне 502 - норма, а не поломка; живость
    # страницы уже проверена выше через /internal/health.
    case $code in
        200|404) diag_ok "https://$SUB_DOMAIN отвечает через nginx (код $code)" ;;
        502)     if sub_healthy; then
                     diag_ok "https://$SUB_DOMAIN: nginx и TLS работают (502 на корне - так и задумано, страница открывается только по ссылке с UUID)"
                 else
                     diag_bad "https://$SUB_DOMAIN ответил 502, и сама страница не отвечает — смотрите логи"
                 fi ;;
        "")      diag_bad "https://$SUB_DOMAIN не ответил — проверьте nginx и сертификат" ;;
        *)       diag_bad "https://$SUB_DOMAIN ответил кодом $code" ;;
    esac
    if ! command -v ufw >/dev/null 2>&1; then diag_warn "UFW не установлен"
    elif ! ufw_active; then diag_warn "UFW выключен — порты не ограничены"
    elif ufw_rules | grep -Eq '^allow 443(/tcp)?( |$)'; then diag_ok "UFW: 443/tcp открыт"
    else diag_bad "UFW: нет правила на 443/tcp"; fi
    if port_listeners "$SUB_APP_PORT" | grep -qv '127.0.0.1'; then
        diag_bad "Порт $SUB_APP_PORT слушается не только на 127.0.0.1 — страница торчит мимо nginx"
    fi

    diag_show "Диагностика страницы подписки: $SUB_DOMAIN"
}

sub_cert() {
    local d c rc
    d=$(cert_days_left "$SUB_CERT_NAME") || d="—"
    c=$(ui_choose "Сертификат страницы подписки" "Сертификат:  /etc/letsencrypt/live/$SUB_CERT_NAME
Домены:      $(cert_domains "$SUB_CERT_NAME")
Способ:      $(cert_method_ru "$SUB_CERT_NAME")
Действует:   ещё $d дн." \
        test  "Проверить автопродление (certbot renew --dry-run)" \
        renew "Перевыпустить сейчас") || return
    [[ $c == renew ]] && { ui_yesno "Перевыпуск" "Перевыпустить сертификат $SUB_CERT_NAME?" no || return; }
    command -v certbot >/dev/null 2>&1 || { ui_msg "Ошибка" "certbot не установлен."; return; }
    cert_write_hooks; cert_ensure_renew
    clear
    [[ $(cert_method_ru "$SUB_CERT_NAME") == HTTP-01 ]] && "$ACME_OPEN" force
    if [[ $c == test ]]; then
        certbot renew --dry-run --no-random-sleep-on-renew --cert-name "$SUB_CERT_NAME"; rc=$?
    else
        certbot renew --force-renewal --no-random-sleep-on-renew --cert-name "$SUB_CERT_NAME"; rc=$?
    fi
    "$ACME_CLOSE"
    log "subpage cert $c rc=$rc"
    echo
    (( rc == 0 )) && say "Готово." || printf '%s✗ certbot завершился с ошибкой (код %s)%s\n' "$C_ERR" "$rc" "$C_RESET"
    pause
}

# ---- Полное удаление сабпейджа ----
# В связке страница живёт в compose и nginx панели: удалять надо только её сервис,
# а файлы, порт и сертификат - общие с панелью, их не трогаем.
sub_remove_bundled() {
    local bak err
    ui_yesno "Удаление страницы подписки" "── Будет удалено
Контейнер:   $SUB_CTR
Файл:        $SUB_ENV вместе с API-токеном
Из панели:   секция страницы в docker-compose.yml и nginx.conf

── Останется
Панель:      $PANEL_DOMAIN работает дальше, её nginx только перечитает конфиг
Сертификат:  $SUB_CERT_NAME общий с панелью — не трогаем
Порт 443:    нужен панели — остаётся открытым

! Клиенты перестанут получать конфиги по https://$SUB_DOMAIN

Удалить страницу подписки?" no || return

    clear; say "Удаляю страницу подписки $SUB_DOMAIN..."
    bak="${SKIPIT_BACKUPS}/remnasub-env-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$SKIPIT_BACKUPS"
    [[ -f $SUB_ENV ]] && { cp -a "$SUB_ENV" "$bak" 2>/dev/null && chmod 600 "$bak"; } || bak=""
    panel_compose_run rm -sf "$SUB_CTR" >/dev/null 2>&1
    rm -f "$SUB_ENV" "$SUB_STATE"
    # Панель без страницы: пустой PANEL_SUB_CERT убирает её из compose и nginx
    local cookie api_key
    cookie=$(panel_env_get SKIPIT_PANEL_COOKIE); api_key=$(panel_env_get SKIPIT_PANEL_API_KEY)
    PANEL_SUB_CERT=""; PANEL_SUB_DOMAIN="${PANEL_DOMAIN}/api/sub"
    backup_file "$PANEL_COMPOSE" >/dev/null; backup_file "$PANEL_NGINX" >/dev/null
    panel_compose > "$PANEL_COMPOSE"
    panel_nginx_conf "$PANEL_DOMAIN" "$PANEL_CERT_NAME" "$PANEL_PATH" "$cookie" "$api_key" > "$PANEL_NGINX"
    panel_write_env "$PANEL_DOMAIN" "$PANEL_SUB_DOMAIN"
    panel_state_save
    panel_compose_run up -d --remove-orphans >/dev/null 2>&1
    if ! err=$(panel_nginx_ok); then say "Внимание: nginx панели ругается — $err"; fi
    log "subpage remove (bundled): $SUB_DOMAIN"
    SUB_DOMAIN=""; SUB_CERT_NAME=""; SUB_PANEL_URL=""; SUB_PREFIX=""; SUB_BUNDLED=0
    echo
    say "Страница подписки удалена, панель работает: $(panel_url)"
    [[ -n $bak ]] && say "Копия sub.env с токеном: $bak"
    say "Ссылки клиентов теперь отдаёт сама панель: https://${PANEL_DOMAIN}/api/sub/…"
    pause
}

sub_remove() {
    local del_cert=0 del_443=0 bak
    (( SUB_BUNDLED )) && { sub_remove_bundled; return; }
    ui_yesno "Удаление страницы подписки" "── Будет удалено
Контейнеры:  $SUB_CTR и $SUB_NGINX_CTR
Папка:       $SUB_DIR вместе с .env и токенами

── Останется
Панель:      не тронется, удаляется только страница
Бэкапы:      $SKIPIT_BACKUPS — архив файлов страницы

! Клиенты перестанут получать конфиги по https://$SUB_DOMAIN

Удалить страницу подписки?" no || return
    ask_del_cert "$SUB_CERT_NAME" sub && del_cert=1
    ask_close_443 sub && del_443=1

    clear; say "Удаляю страницу подписки $SUB_DOMAIN..."
    bak="${SKIPIT_BACKUPS}/remnasub-$(date +%Y%m%d-%H%M%S).tar.gz"
    mkdir -p "$SKIPIT_BACKUPS"
    if [[ -d $SUB_DIR ]]; then
        tar -czf "$bak" -C "$(dirname "$SUB_DIR")" "$(basename "$SUB_DIR")" 2>/dev/null && chmod 600 "$bak" || bak=""
    else
        bak=""
    fi
    [[ -f $SUB_COMPOSE ]] && sub_compose_run down --remove-orphans
    rm -rf "$SUB_DIR"
    rm -f "$SUB_STATE"
    if (( del_443 )) && command -v ufw >/dev/null 2>&1; then
        ufwc --force delete allow 443/tcp >/dev/null 2>&1
    fi
    if (( del_cert )) && command -v certbot >/dev/null 2>&1; then
        certbot delete --non-interactive --cert-name "$SUB_CERT_NAME" >/dev/null 2>&1
    fi
    log "subpage remove: $SUB_DOMAIN cert=$del_cert ufw443=$del_443"
    SUB_DOMAIN=""; SUB_CERT_NAME=""; SUB_PANEL_URL=""; SUB_PREFIX=""
    echo
    say "Страница подписки удалена."
    say "Бэкапы НЕ тронуты: $SKIPIT_BACKUPS"
    [[ -n $bak ]] && say "Архив файлов: $bak"
    say "Не забудьте убрать домен из SUB_PUBLIC_DOMAIN в настройках панели."
    pause
}

sub_menu_label() {
    if sub_installed; then echo "Страница подписки · $SUB_DOMAIN"; else echo "Установить страницу подписки"; fi
}

menu_subpage() {
    local c hdr tab=$'\t'
    while :; do
        # Установку запускает меню компонентов; сюда попадаем только с готовой страницей
        sub_installed || return
        hdr="Домен:   $SUB_DOMAIN
Адрес:   $(sub_url)
Панель:  $SUB_PANEL_URL$( (( SUB_BUNDLED )) && printf '\nРежим:   в связке с панелью %s — compose и nginx общие' "$PANEL_DOMAIN" )

Компонент${tab}Состояние
страница${tab}$(ctr_state_ru "$SUB_CTR")
nginx${tab}$(ctr_state_ru "$SUB_NGINX_CTR")
Сертификат${tab}$(cert_days_left "$SUB_CERT_NAME" >/dev/null 2>&1 && echo "действует · $(cert_days_left "$SUB_CERT_NAME") дн." || echo НЕТ)"
        c=$(ui_menu "Страница подписки" "$hdr" \
            ""        "Управление" \
            logs      "Логи" \
            restart   "Перезапустить" \
            update    "Обновить образ" \
            ""        "Настройки" \
            token     "Сменить API-токен панели" \
            cert      "Сертификат: статус и перевыпуск" \
            ""        "Опасные действия" \
            reinstall "Переустановить" \
            remove    "Удалить страницу подписки") || return
        case $c in
            logs)      sub_logs ;;
            restart)   sub_restart ;;
            update)    sub_update ;;
            token)     sub_change_token ;;
            cert)      sub_cert ;;
            reinstall) sub_install ;;
            remove)    sub_remove ;;
        esac
    done
}

# ==== Remnawave: компоненты и общая диагностика ====
# Установка и управление собраны в одном подменю: пункт компонента запускает мастер,
# если он ещё не стоит, и открывает управление, если уже стоит.

# Список того, что уже стоит: «панель, нода» (пусто - ничего)
remna_installed_list() {
    local s=""
    panel_installed 2>/dev/null && s+="панель, "
    node_installed  2>/dev/null && s+="нода, "
    sub_installed   2>/dev/null && s+="страница подписки, "
    echo "${s%, }"
}

# Строка состояния для шапки главного меню - рядом с SSH, UFW и fail2ban
remna_hdr() {
    local have; have=$(remna_installed_list)
    [[ -n $have ]] && echo "${have//, / · }" || echo "не установлены"
}

# Строка таблицы компонентов: "Название<TAB>Состояние<TAB>Домен".
# Состояние берётся у контейнера: «нет» у docker означает, что контейнера нет,
# а компонент при этом настроен - пишем понятнее.
remna_row() { # название установлено(0|1) контейнер домен
    local st="не установлена" dom="—"
    if (( $2 )); then
        st=$(ctr_state_ru "$3"); [[ $st == нет ]] && st="не запущена"
        dom=$4
    fi
    printf '%s\t%s\t%s' "$1" "$st" "$dom"
}

menu_remnawave() {
    local c hdr p n s
    local -a items on off
    while :; do
        # состояние читаем один раз: эти вызовы заодно наполняют *_DOMAIN
        panel_installed 2>/dev/null && p=1 || p=0
        node_installed  2>/dev/null && n=1 || n=0
        sub_installed   2>/dev/null && s=1 || s=0

        # В таблице только то, что уже стоит: про остальное говорит группа
        # «Не установлено» ниже, и дублировать её строками «не установлена» незачем
        hdr=""
        if (( p || n || s )); then
            hdr="Компонент"$'\t'"Состояние"$'\t'"Домен"
            (( p )) && hdr+=$'\n'"$(remna_row "Панель"            1 remnawave  "$PANEL_DOMAIN")"
            (( n )) && hdr+=$'\n'"$(remna_row "Нода"              1 remnanode  "$NODE_DOMAIN")"
            (( s )) && hdr+=$'\n'"$(remna_row "Страница подписки" 1 "$SUB_CTR" "$SUB_DOMAIN")"
            hdr+=$'\n\n'
        fi
        hdr+="ℹ Установленный компонент откроется на управление, новый — на установку"

        # Нумерация в _ui_list сквозная: заголовок группы счётчик не увеличивает
        on=(); off=()
        if (( p )); then on+=(panel "Панель"); else off+=(panel "Панель"); fi
        if (( n )); then on+=(node "Нода"); else off+=(node "Нода"); fi
        if (( s )); then on+=(subpage "Страница подписки"); else off+=(subpage "Страница подписки"); fi
        # Связка ставится одним мастером: два домена, один nginx, токен выпускается сам
        (( p || s )) || off+=(bundle "Панель + Страница подписки — вместе")
        # Всё на одном сервере: 443 забирает Xray ноды, панель уходит за его сокет
        (( p || s || n )) || off+=(bundle_all "Панель + Страница подписки + Нода — на один сервер")
        items=()
        (( ${#on[@]}  )) && items+=("" "Установлено"    "${on[@]}")
        (( ${#off[@]} )) && items+=("" "Не установлено" "${off[@]}")

        c=$(ui_menu "Компоненты Remnawave" "$hdr" "${items[@]}") || return
        # Неустановленный компонент открываем сразу мастером: экран с одним пунктом
        # «Установить» повторял бы первый экран самого мастера
        case $c in
            bundle)     panel_install with_sub ;;
            bundle_all) bundle_all_install ;;
            panel)   if (( p )); then menu_panel;   else panel_install; fi ;;
            node)    if (( n )); then menu_node;    else node_install;  fi ;;
            subpage) if (( s )); then menu_subpage; else sub_install;   fi ;;
        esac
    done
}

# Диагностика: один компонент - сразу его отчёт, несколько - выбор,
# ничего не установлено - проверка готовности сервера (её делает node_diag)
menu_remna_diag() {
    local items=() c have p n s
    panel_installed 2>/dev/null && p=1 || p=0
    node_installed  2>/dev/null && n=1 || n=0
    sub_installed   2>/dev/null && s=1 || s=0
    have=$(remna_installed_list)

    # Ничего не установлено - выбирать не из чего, сразу проверка готовности сервера
    if [[ -z $have ]]; then server_diag; return; fi

    items=(all "Всё — сервер и установленные компоненты")
    (( p )) && items+=(panel   "Панель · $PANEL_DOMAIN")
    (( n )) && items+=(node    "Нода · $NODE_DOMAIN")
    (( s )) && items+=(subpage "Страница подписки · $SUB_DOMAIN")
    # Серверные проверки (время, BBR, UFW, IPv6, Docker) живут в отчёте ноды.
    # Ноды нет - выносим их отдельным пунктом, иначе до них было бы не добраться.
    (( n )) || items+=("" "" server "Только сервер — время, BBR, UFW, IPv6, Docker")

    c=$(ui_choose "Диагностика Remnawave" "Установлено:  $have

Что проверить?" "${items[@]}") || return
    case $c in
        all)
            # сервер проверяем всегда: отчёт ноды включает его сам, иначе - отдельно
            if (( n )); then node_diag; else server_diag; fi
            (( p )) && panel_diag
            (( s )) && sub_diag
            ;;
        server) server_diag ;;
        *)      remna_diag_one "$c" ;;
    esac
}

remna_diag_one() {
    case $1 in
        node)    node_diag ;;
        panel)   panel_diag ;;
        subpage) sub_diag ;;
    esac
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
    F2B_PORTSCAN=0; F2B_PS_FINDTIME=600; F2B_PS_MAXRETRY=20; F2B_IGNORE=""; F2B_IGNORE_SSH=0
    local k v
    [[ -f $F2B_STATE ]] || return 0
    while IFS='=' read -r k v; do
        case $k in
            F2B_SSH|F2B_BANTIME|F2B_FINDTIME|F2B_MAXRETRY|F2B_RECIDIVE|F2B_PORTSCAN|F2B_PS_FINDTIME|F2B_PS_MAXRETRY|F2B_IGNORE|F2B_IGNORE_SSH)
                printf -v "$k" '%s' "$v" ;;
        esac
    done < "$F2B_STATE"
}

f2b_state_save() {
    mkdir -p "$SKIPIT_ETC"
    printf 'F2B_SSH=%s\nF2B_BANTIME=%s\nF2B_FINDTIME=%s\nF2B_MAXRETRY=%s\nF2B_RECIDIVE=%s\nF2B_PORTSCAN=%s\nF2B_PS_FINDTIME=%s\nF2B_PS_MAXRETRY=%s\nF2B_IGNORE=%s\nF2B_IGNORE_SSH=%s\n' \
        "${F2B_SSH:-1}" "$F2B_BANTIME" "$F2B_FINDTIME" "$F2B_MAXRETRY" "$F2B_RECIDIVE" "$F2B_PORTSCAN" "$F2B_PS_FINDTIME" "$F2B_PS_MAXRETRY" "$F2B_IGNORE" "${F2B_IGNORE_SSH:-0}" > "$F2B_STATE"
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

# IP, с которого открыта текущая SSH-сессия (пусто - не из SSH, например из консоли хостера)
f2b_ssh_ip() {
    local c=${SSH_CLIENT%% *}
    [[ -z $c ]] && c=$(who -m 2>/dev/null | grep -oE '\([0-9a-fA-F:.]+\)' | tr -d '()')
    [[ -n $c ]] && printf '%s' "$c"
    return 0
}

# Белый список: "IP<TAB>почему" - добавляется всегда.
# IP текущей SSH-сессии сюда попадает, только если пользователь сам это разрешил
# (F2B_IGNORE_SSH=1): за NAT или CGNAT это открыло бы дыру всем, кто сидит за тем же адресом.
f2b_auto_ignore() {
    local c
    printf '127.0.0.1/8\tлокальный\n::1\tлокальный\n'
    [[ $SERVER_IP =~ ^[0-9]+(\.[0-9]+){3}$ ]] && printf '%s\tэтот сервер\n' "$SERVER_IP"
    if node_state_load 2>/dev/null && [[ -n $NODE_PANEL_IP ]]; then printf '%s\tпанель Remnawave\n' "$NODE_PANEL_IP"; fi
    if [[ ${F2B_IGNORE_SSH:-0} == 1 ]]; then
        c=$(f2b_ssh_ip)
        [[ -n $c ]] && printf '%s\tваше SSH-подключение\n' "$c"
    fi
    return 0
}

f2b_ignore_list() {
    { f2b_auto_ignore | cut -f1; local ip; for ip in $F2B_IGNORE; do echo "$ip"; done; } | awk 'NF && !s[$0]++' | xargs
}

f2b_render_jail() {
    cat <<EOF
# fail2ban - настройки SkipIt Tool. Файл перезаписывается из меню
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
# SkipIt Tool: сканирование портов по логам UFW ([UFW BLOCK] в журнале ядра)
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
    local auto out err c n pw ps_ok=0 knocks rec why total step=0 ip bad my_ip
    local -a extra
    f2b_state_load
    n=$(journalctl _COMM=sshd --since '24 hours ago' -q --no-pager 2>/dev/null |
        grep -cE 'Failed password|Invalid user|Connection closed by (authenticating|invalid) user|Disconnected from (authenticating|invalid) user')
    pw=$(sshd_eff passwordauthentication)
    if ufw_active && ! ufwc status verbose 2>/dev/null | grep -q '^Logging: off'; then ps_ok=1; fi
    knocks=$(journalctl -k --since '1 hour ago' -q --no-pager 2>/dev/null | grep -c 'UFW BLOCK')
    my_ip=$(f2b_ssh_ip)
    total=$(( ps_ok ? 5 : 4 ))
    [[ -n $my_ip ]] && total=$((total + 1))
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

    # 5. IP текущей SSH-сессии - в белый список или нет
    if [[ -n $my_ip ]]; then
        if [[ $pw == yes ]]; then
            rec=1; why="Вход по паролю разрешён — белый список выручит, если сами несколько раз ошибётесь паролем"
        else
            rec=0; why="Вход только по ключу — подбирать нечего, а лишний адрес в списке только ослабляет защиту"
        fi
        step=$((step + 1))
        c=$(ui_choose "fail2ban · шаг $step из $total · Ваш IP" "Ваш адрес сейчас:  $my_ip
Вход по паролю:    $([[ $pw == yes ]] && echo разрешён || echo "запрещён, только ключи")

! Домашний роутер, офис и мобильный интернет часто дают один адрес на сотни абонентов.
  Такой адрес в белом списке = fail2ban не тронет и тех, кто сидит за ним же

ℹ $why
ℹ Заблокировать себя не страшно: разбанить можно с другого устройства или из консоли
  хостера — fail2ban → Разблокировать IP" \
            0 "Не вносить$(f2b_mark 0)" \
            1 "Внести $my_ip в белый список$(f2b_mark 1)") || return
        F2B_IGNORE_SSH=$c
        ui_ctx_add "Ваш IP" "$([[ $F2B_IGNORE_SSH == 1 ]] && echo "$my_ip — в белом списке" || echo "не в белом списке")"
    else
        F2B_IGNORE_SSH=0
    fi

    # 6. Белый список
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
    local c text ip items=() nl=$'\n' tab=$'\t' my_ip
    while :; do
        my_ip=$(f2b_ssh_ip)
        text="── Автоматически${nl}IP${tab}Почему${nl}$(f2b_auto_ignore)${nl}${nl}── Добавлены вручную"
        if [[ -n $F2B_IGNORE ]]; then
            text+="${nl}IP${tab}Почему"
            for ip in $F2B_IGNORE; do text+="${nl}${ip}${tab}добавлен вручную"; done
        else
            text+="${nl}Пока нет."
        fi
        text+="${nl}${nl}IP из белого списка никогда не блокируются."
        [[ -n $my_ip ]] && text+="${nl}Ваш текущий IP ($my_ip): $([[ ${F2B_IGNORE_SSH:-0} == 1 ]] && echo "в списке" || echo "не в списке")."
        items=(add "Добавить IP или подсеть")
        [[ -n $F2B_IGNORE ]] && items+=(del "Удалить IP из списка")
        [[ -n $my_ip ]] && items+=(ssh "$([[ ${F2B_IGNORE_SSH:-0} == 1 ]] && echo "Убрать из списка ваш IP ($my_ip)" || echo "Внести в список ваш IP ($my_ip)")")
        c=$(ui_choose "Белый список" "$text" "${items[@]}") || return
        case $c in
            ssh)
                if [[ ${F2B_IGNORE_SSH:-0} == 1 ]]; then
                    F2B_IGNORE_SSH=0
                    f2b_save_apply "Ваш IP ($my_ip):  убран из белого списка"
                else
                    ui_yesno "Ваш IP в белом списке" "IP:  $my_ip

! Домашний роутер, офис и мобильный интернет часто дают один адрес на сотни абонентов.
  Такой адрес в белом списке = fail2ban не тронет и тех, кто сидит за ним же

Внести $my_ip в белый список?" no || continue
                    F2B_IGNORE_SSH=1
                    f2b_save_apply "Ваш IP ($my_ip):  внесён в белый список"
                fi ;;
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
    ui_yesno "Удалить настройки SkipIt Tool" "Файлы:  $F2B_JAIL, $F2B_FILTER
fail2ban будет остановлен и выключен, сам пакет останется.

Удалить настройки?" no || return
    systemctl disable --now fail2ban >/dev/null 2>&1
    rm -f "$F2B_JAIL" "$F2B_FILTER" "$F2B_STATE"
    log "fail2ban remove skipit config"
    ui_msg "Готово" "Настройки SkipIt Tool удалены, fail2ban остановлен."
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
        [[ -f $F2B_JAIL ]] || hdr+=$'\n\n'"Настройки SkipIt Tool не записаны — выберите «Применить настройки SkipIt Tool заново»."
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
            apply     "Применить настройки SkipIt Tool заново" \
            ""        "Журнал" \
            log       "Последние баны" \
            live      "Журнал в реальном времени" \
            ""        "Управление" \
            toggle    "$(systemctl is-active --quiet fail2ban && echo "Остановить fail2ban" || echo "Запустить fail2ban")" \
            remove    "Удалить настройки SkipIt Tool") || return
        case $c in
            ssh)       f2b_ssh_menu ;;
            portscan)  f2b_portscan_menu ;;
            banned)    f2b_banned_screen ;;
            unban)     f2b_unban ;;
            ban)       f2b_ban_manual ;;
            bantime)   f2b_bantime_menu ;;
            recidive)  f2b_recidive_menu ;;
            whitelist) f2b_whitelist_menu ;;
            apply)     f2b_save_apply "Настройки SkipIt Tool применены." ;;
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
# sha256 архивов ookla-speedtest-1.2.0-linux-<arch>.tgz. Бинарник запускается от root,
# поэтому без совпадения суммы он не устанавливается. При смене SPEEDTEST_VER обновить.
SPEEDTEST_SUM_x86_64="5690596c54ff9bed63fa3732f818a05dbc2db19ad36ed68f21ca5f64d5cfeeb7"
SPEEDTEST_SUM_aarch64="3953d231da3783e2bf8904b6dd72767c5c6e533e163d3742fd0437affa431bd3"
SPEEDTEST_SUM_armhf="e45fcdebbd8a185553535533dd032d6b10bc8c64eee4139b1147b9c09835d08d"
SPEEDTEST_SUM_i386="9ff7e18dbae7ee0e03c66108445a2fb6ceea6c86f66482e1392f55881b772fe8"

SPEEDTEST_ERR=""
speedtest_fetch() {
    [[ -x $SPEEDTEST_BIN ]] && return 0
    local arch tmp want got sumvar
    SPEEDTEST_ERR=""
    case $(uname -m) in
        x86_64)        arch=x86_64 ;;
        aarch64|arm64) arch=aarch64 ;;
        armv7*|armv8l) arch=armhf ;;
        i?86)          arch=i386 ;;
        *)             SPEEDTEST_ERR="Нет сборки Speedtest CLI для архитектуры $(uname -m)."; return 1 ;;
    esac
    sumvar="SPEEDTEST_SUM_${arch}"; want=${!sumvar}
    [[ $want =~ ^[0-9a-f]{64}$ ]] || { SPEEDTEST_ERR="В SkipIt Tool нет контрольной суммы для архитектуры $arch."; return 1; }
    tmp=$(mktemp -d) || return 1
    if ! curl -fsSL --retry 2 --connect-timeout 15 --max-time 120 \
            "https://install.speedtest.net/app/cli/ookla-speedtest-${SPEEDTEST_VER}-linux-${arch}.tgz" -o "$tmp/st.tgz"; then
        rm -rf "$tmp"
        SPEEDTEST_ERR="Не удалось скачать Speedtest CLI с install.speedtest.net."
        return 1
    fi
    got=$(sha256sum "$tmp/st.tgz" | awk '{print $1}')
    if [[ $got != "$want" ]]; then
        rm -rf "$tmp"
        log "speedtest: sha256 mismatch for $arch (got $got)"
        SPEEDTEST_ERR="Контрольная сумма Speedtest CLI не совпала — файл повреждён или подменён.
Программа НЕ установлена и не запускалась.

Ожидалось:  ${want:0:16}…
Получено:   ${got:0:16}…"
        return 1
    fi
    if tar -xzf "$tmp/st.tgz" -C "$tmp" speedtest 2>/dev/null; then
        mkdir -p "${SPEEDTEST_BIN%/*}" && install -m 0755 "$tmp/speedtest" "$SPEEDTEST_BIN"
    fi
    rm -rf "$tmp"
    [[ -x $SPEEDTEST_BIN ]] || SPEEDTEST_ERR="Не удалось распаковать Speedtest CLI."
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
    speedtest_fetch || { ui_msg "Ошибка" "${SPEEDTEST_ERR:-Не удалось получить Speedtest CLI для архитектуры $(uname -m).}"; return; }
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
        cache)   echo "Кэш SkipIt Tool (шаблоны, Speedtest)" ;;
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

# Проверка IP по регионам: сторонний скрипт ipregion (github.com/vernette/ipregion).
# Версия закреплена коммитом, файл сверяется по sha256 - он запускается с правами root,
# поэтому «скачали и выполнили» без проверки здесь недопустимо.
IPREGION_REPO="vernette/ipregion"
IPREGION_SHA="d6c230cc1fd5042931590730a5651ef87e985236"
IPREGION_SUM="f80281f79012def06cc6a7744eb78d1a4e9d9ba90b336ae01c304bea66920cd8"

region_check() {
    local grp tmp ipv flags=() v6check=0 got
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

ℹ Это сторонний скрипт, он выполняется с правами root. SkipIt Tool берёт закреплённую
  версию (коммит ${IPREGION_SHA:0:7}) и сверяет её по sha256 — подменить файл по дороге нельзя.

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
    if ! curl -fsSL --retry 2 --connect-timeout 15 --max-time 60 -o "$tmp" \
            "https://raw.githubusercontent.com/${IPREGION_REPO}/${IPREGION_SHA}/ipregion.sh"; then
        rm -f "$tmp"
        ui_msg "Ошибка" "Не удалось скачать ipregion с GitHub.

Репозиторий:  github.com/${IPREGION_REPO}
Коммит:       ${IPREGION_SHA:0:7}

ℹ Проверьте доступ сервера к raw.githubusercontent.com"
        return
    fi
    got=$(sha256sum "$tmp" | awk '{print $1}')
    if [[ $got != "$IPREGION_SUM" ]]; then
        rm -f "$tmp"
        log "region check: sha256 mismatch (got $got)"
        ui_msg "Проверка не пройдена" "Контрольная сумма ipregion не совпала — файл повреждён или подменён.
Скрипт НЕ запущен.

Ожидалось:  ${IPREGION_SUM:0:16}…
Получено:   ${got:0:16}…"
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

# ---- Обновление SkipIt Tool с GitHub ----
# Обновление берётся из последнего опубликованного релиза (черновики пропускаются,
# пре-релизы считаются), а не из ветки main. Если к релизу приложен skipit.sh -
# берём его и сверяем sha256; если нет - берём skipit.sh из тега релиза и сверяем
# git-хеш. Тег релиза должен совпадать с версией в файле.
SKIPIT_REPO="FrI3nd7/skipit-vps-node"
SKIPIT_ASSET="skipit.sh"
SKIPIT_RELEASES_API="https://api.github.com/repos/${SKIPIT_REPO}/releases?per_page=20"
SKIPIT_UPDATE_CONF="${SKIPIT_ETC}/update.conf"

# Токены GitHub - это [A-Za-z0-9_]; лишнее срезаем, чтобы кавычка не сломала конфиг curl ниже
update_token() { sed -n 's/^SKIPIT_UPDATE_TOKEN=//p' "$SKIPIT_UPDATE_CONF" 2>/dev/null | head -n 1 | tr -cd 'A-Za-z0-9_.-'; }

update_token_save() { # токен
    mkdir -p "$SKIPIT_ETC"
    ( umask 077; printf 'SKIPIT_UPDATE_TOKEN=%s\n' "$1" > "$SKIPIT_UPDATE_CONF" )
    chmod 600 "$SKIPIT_UPDATE_CONF"
    log "update: token saved"
}

# Запрос к GitHub API в файл, печатает HTTP-код
update_gh() { # url файл [Accept]
    local token
    local -a hdr=(-H "Accept: ${3:-application/vnd.github+json}" -H "X-GitHub-Api-Version: 2022-11-28")
    token=$(update_token)
    # Токен - через stdin (-K -), а не аргументом: /proc/PID/cmdline читают все локальные пользователи
    if [[ -n $token ]]; then
        printf 'header = "Authorization: Bearer %s"\n' "$token" |
            curl -sSL --max-time 60 -K - "${hdr[@]}" -o "$2" -w '%{http_code}' "$1" 2>/dev/null
    else
        curl -sSL --max-time 60 "${hdr[@]}" -o "$2" -w '%{http_code}' "$1" 2>/dev/null
    fi
}

# Разобрать HTTP-код ответа GitHub в код update_fetch (0 - всё хорошо)
update_http_rc() { # код файл-ответа
    case $1 in
        200) return 0 ;;
        401|404) return 2 ;;
        403|429)
            if grep -qi 'rate limit' "$2" 2>/dev/null; then
                UPDATE_ERR="GitHub временно ограничил число запросов с этого сервера. Попробуйте через час."
                return 4
            fi
            return 2 ;;
        *) return 1 ;;
    esac
}

# Вариант 1: skipit.sh приложен к релизу (Assets). Сверка sha256 с суммой от GitHub
# и/или с приложенным skipit.sh.sha256.
update_fetch_asset() { # файл тег id-файла digest id-суммы
    local dst=$1 tag=$2 id=$3 digest=$4 sumid=$5 sumf code want="" want2="" got
    [[ $digest == sha256:* ]] && want=${digest#sha256:}
    if [[ $sumid =~ ^[0-9]+$ ]]; then
        sumf=$(mktemp) || return 1
        code=$(update_gh "https://api.github.com/repos/${SKIPIT_REPO}/releases/assets/$sumid" "$sumf" application/octet-stream) || code=000
        update_http_rc "$code" "$sumf" || { local rc=$?; rm -f "$sumf"; return $rc; }
        want2=$(awk 'NR==1{print $1}' "$sumf")
        rm -f "$sumf"
        [[ $want2 =~ ^[0-9A-Fa-f]{64}$ ]] || { UPDATE_ERR="Файл $SKIPIT_ASSET.sha256 в релизе $tag повреждён."; return 4; }
    fi
    [[ -n $want || -n $want2 ]] || { UPDATE_ERR="Для $SKIPIT_ASSET в релизе $tag нет контрольной суммы — приложите $SKIPIT_ASSET.sha256."; return 4; }
    code=$(update_gh "https://api.github.com/repos/${SKIPIT_REPO}/releases/assets/$id" "$dst" application/octet-stream) || code=000
    update_http_rc "$code" "$dst" || return
    got=$(sha256sum "$dst" | awk '{print $1}')
    if [[ -n $want && ${want,,} != "$got" ]] || [[ -n $want2 && ${want2,,} != "$got" ]]; then
        : > "$dst"
        log "update: sha256 mismatch for $tag"
        UPDATE_ERR="Контрольная сумма $SKIPIT_ASSET из релиза $tag не совпала — файл повреждён или подменён."
        return 4
    fi
}

# Вариант 2: файла в Assets нет - берём skipit.sh из тега релиза (ровно тот код,
# что в архиве «Source code»). Сверка с git-хешем файла, который отдаёт GitHub.
update_fetch_tag() { # файл тег
    local dst=$1 tag=$2 meta code line want size got
    local url="https://api.github.com/repos/${SKIPIT_REPO}/contents/${SKIPIT_ASSET}?ref=${tag}"
    meta=$(mktemp) || return 1
    code=$(update_gh "$url" "$meta") || code=000
    if [[ $code == 404 ]]; then
        rm -f "$meta"; UPDATE_ERR="В релизе $tag нет файла $SKIPIT_ASSET."; return 4
    fi
    update_http_rc "$code" "$meta" || { local rc=$?; rm -f "$meta"; return $rc; }
    line=$(jq -r 'select(type == "object" and .type == "file") | [.sha, .size] | map(tostring) | join("|")' "$meta" 2>/dev/null)
    rm -f "$meta"
    IFS='|' read -r want size <<< "$line"
    [[ $want =~ ^[0-9a-f]{40}$ && $size =~ ^[0-9]+$ ]] || { UPDATE_ERR="GitHub не отдал сведения о $SKIPIT_ASSET в релизе $tag."; return 4; }
    code=$(update_gh "$url" "$dst" application/vnd.github.raw+json) || code=000
    update_http_rc "$code" "$dst" || return
    # git-хеш файла: sha1 от «blob <размер>\0<содержимое>»
    got=$( { printf 'blob %s\0' "$(stat -c %s "$dst")"; cat "$dst"; } | sha1sum | awk '{print $1}')
    if [[ $got != "$want" ]]; then
        : > "$dst"
        log "update: git hash mismatch for $tag"
        UPDATE_ERR="Контрольная сумма $SKIPIT_ASSET из релиза $tag не совпала — файл повреждён или подменён."
        return 4
    fi
}

# Скачать skipit.sh из последнего релиза в файл.
# 0 - готово, 1 - нет связи, 2 - нет доступа (приватный репозиторий или неверный токен),
# 3 - это не SkipIt Tool, 4 - проблема с релизом (текст в UPDATE_ERR)
UPDATE_ERR=""
update_fetch() { # файл
    local dst=$1 meta code line tag id digest sumid ver rc
    UPDATE_ERR=""
    command -v jq >/dev/null 2>&1 || { UPDATE_ERR="Не установлен пакет jq."; return 4; }
    meta=$(mktemp) || return 1
    code=$(update_gh "$SKIPIT_RELEASES_API" "$meta") || code=000
    update_http_rc "$code" "$meta" || { rc=$?; rm -f "$meta"; return $rc; }
    line=$(jq -r --arg a "$SKIPIT_ASSET" '
        [.[] | select(.draft | not)][0] // empty
        | [ .tag_name,
            ((.assets[] | select(.name == $a) | .id) // ""),
            ((.assets[] | select(.name == $a) | .digest) // ""),
            ((.assets[] | select(.name == ($a + ".sha256")) | .id) // "") ]
        | map(tostring) | join("|")' "$meta" 2>/dev/null)
    rm -f "$meta"
    [[ -n $line ]] || { UPDATE_ERR="В репозитории нет опубликованных релизов."; return 4; }
    IFS='|' read -r tag id digest sumid <<< "$line"
    [[ $tag =~ ^[A-Za-z0-9._+-]+$ ]] || { UPDATE_ERR="Некорректный тег релиза: $tag"; return 4; }
    if [[ $id =~ ^[0-9]+$ ]]; then
        update_fetch_asset "$dst" "$tag" "$id" "$digest" "$sumid" || return
    else
        update_fetch_tag "$dst" "$tag" || return
    fi
    head -n 1 "$dst" | grep -q '^#!.*bash' && grep -q '^SKIPIT_VERSION="' "$dst" && bash -n "$dst" 2>/dev/null || return 3
    ver=$(update_version_of "$dst")
    if [[ ${tag#v} != "$ver" ]]; then
        UPDATE_ERR="Тег релиза ($tag) не совпадает с версией в файле ($ver)."
        return 4
    fi
    return 0
}

update_version_of() { sed -n 's/^SKIPIT_VERSION="\(.*\)"$/\1/p' "$1" 2>/dev/null | head -n 1; }

# 0, если версия $1 новее $2
version_newer() { [[ $1 != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1) == "$1" ]]; }

# Последняя версия в репозитории - в кеше, чтобы главное меню не ходило в сеть
SKIPIT_UPDATE_LATEST="/var/cache/skipit/skipit-latest-version"

update_latest_save() { # версия
    [[ $1 =~ ^[0-9A-Za-z.+-]+$ ]] || return 0
    mkdir -p "${SKIPIT_UPDATE_LATEST%/*}" && printf '%s\n' "$1" > "$SKIPIT_UPDATE_LATEST"
}

# Версия из кеша, если она новее установленной (иначе пусто)
update_available() {
    local v; v=$(head -n 1 "$SKIPIT_UPDATE_LATEST" 2>/dev/null)
    [[ $v =~ ^[0-9A-Za-z.+-]+$ ]] && version_newer "$v" "$SKIPIT_VERSION" && printf '%s' "$v"
}

# Фоновая проверка при запуске, не чаще раза в 6 часов. Lock-дескриптор 9 закрываем,
# иначе фоновый процесс будет считаться «открытым SkipIt Tool» (см. lock_holders)
update_check_bg() {
    [[ -n $(find "$SKIPIT_UPDATE_LATEST" -mmin -360 2>/dev/null) ]] && return 0
    (
        exec 9>&-
        tmp=$(mktemp) || exit 0
        update_fetch "$tmp" && update_latest_save "$(update_version_of "$tmp")"
        rm -f "$tmp"
    ) >/dev/null 2>&1 </dev/null &
    disown 2>/dev/null
}

# Бэкап текущей версии и замена. Новый файл кладём рядом и переименовываем:
# уже запущенный SkipIt Tool продолжает читать старый файл и не ломается на ходу. Печатает путь бэкапа.
update_apply() { # файл
    local bak="$SKIPIT_BACKUPS/skipit-v${SKIPIT_VERSION}.$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$SKIPIT_BACKUPS"
    [[ -f $SKIPIT_BIN ]] && cp -a "$SKIPIT_BIN" "$bak"
    install -m 0755 "$1" "$SKIPIT_BIN.new" && mv -f "$SKIPIT_BIN.new" "$SKIPIT_BIN" || { rm -f "$SKIPIT_BIN.new"; return 1; }
    log "update: v$SKIPIT_VERSION -> v$(update_version_of "$SKIPIT_BIN")"
    echo "$bak"
}

# Главное меню: SkipIt Tool -> Обновить SkipIt Tool
menu_update() {
    local tmp rc new tok bak
    ensure_pkg jq jq || return
    tmp=$(mktemp) || return
    while :; do
        ui_loading "Проверяю обновления…"
        update_fetch "$tmp"; rc=$?
        (( rc == 2 )) || break
        tok=$(ui_pass "Доступ к репозиторию" "Репозиторий:   FrI3nd7/skipit-vps-node
Ответ GitHub:  нет доступа

ℹ Пока репозиторий приватный, нужен токен GitHub только на чтение (Contents: Read)
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
            ui_msg "Ошибка" "Скачанный файл не похож на SkipIt Tool или повреждён, обновление отменено.

ℹ Установленная версия не тронута"
            return ;;
        4)  rm -f "$tmp"
            ui_msg "Ошибка" "Обновление отменено: $UPDATE_ERR

ℹ Установленная версия не тронута"
            return ;;
    esac
    new=$(update_version_of "$tmp")
    update_latest_save "$new"
    if [[ $new == "$SKIPIT_VERSION" ]]; then
        rm -f "$tmp"
        ui_msg "Обновление SkipIt Tool" "Установлена:  $SKIPIT_VERSION
Доступна:     $new

ℹ У вас последняя версия"
        return
    fi
    # Откат на старую версию через «Обновить» не делаем - только вперёд
    if ! version_newer "$new" "$SKIPIT_VERSION"; then
        rm -f "$tmp"
        ui_msg "Обновление SkipIt Tool" "Установлена:    $SKIPIT_VERSION
В репозитории:  $new

ℹ В репозитории версия старее установленной — обновлять нечего"
        return
    fi
    ui_yesno "Обновление SkipIt Tool" "Установлена:  $SKIPIT_VERSION
Доступна:     $new

ℹ Настройки SkipIt Tool и ноды не пропадут, старая версия сохранится в бэкап

Обновить SkipIt Tool?" || { rm -f "$tmp"; return; }
    if ! bak=$(update_apply "$tmp"); then
        rm -f "$tmp"
        ui_msg "Ошибка" "Не удалось записать $SKIPIT_BIN, установленная версия не тронута."
        return
    fi
    rm -f "$tmp"
    ui_msg "SkipIt Tool обновлён" "Версия:  $new
Бэкап:   $bak

ℹ SkipIt Tool перезапустится с новой версией"
    clear >"$TTY"
    exec "$SKIPIT_BIN"
}

# skipit update [--yes] - текстом, без экранов меню. С --yes работает и без терминала (ssh host 'skipit update --yes')
skipit_update_cli() {
    local yes=0 tmp rc new bak tok a tty=0
    [[ ${1:-} == --yes || ${1:-} == -y ]] && yes=1
    { : >/dev/tty; } 2>/dev/null && tty=1
    (( yes || tty )) || die "Нет терминала. Для обновления без вопросов: ${SKIPIT_CMD} update --yes"
    if ! command -v jq >/dev/null 2>&1; then
        say "Устанавливаю jq (нужен для проверки релизов)..."
        pkg_install jq && command -v jq >/dev/null 2>&1 || die "Не удалось установить jq."
        log "pkg install jq"
    fi
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
        3) rm -f "$tmp"; die "Скачанный файл не похож на SkipIt Tool, обновление отменено." ;;
        4) rm -f "$tmp"; die "Обновление отменено: $UPDATE_ERR" ;;
        *) rm -f "$tmp"; die "Не удалось скачать обновление: нет связи с GitHub." ;;
    esac
    new=$(update_version_of "$tmp")
    update_latest_save "$new"
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
    say "SkipIt Tool обновлён: v$SKIPIT_VERSION -> v$new (бэкап: $bak)"
}

# ---- Удаление самого SkipIt Tool ----
# Два режима: убрать только инструмент или вместе с тем, что он ставил.
# SSH и его правило UFW не трогаем ни в одном из режимов - остаться без доступа
# к серверу хуже любого мусора в системе.
menu_self_remove() {
    local c hdr tab=$'\t' p n s
    panel_installed 2>/dev/null && p=1 || p=0
    node_installed  2>/dev/null && n=1 || n=0
    sub_installed   2>/dev/null && s=1 || s=0

    hdr="Компонент${tab}Состояние"
    hdr+=$'\n'"Панель${tab}$( (( p )) && echo "$PANEL_DOMAIN" || echo "нет" )"
    hdr+=$'\n'"Нода${tab}$( (( n )) && echo "$NODE_DOMAIN" || echo "нет" )"
    hdr+=$'\n'"Страница подписки${tab}$( (( s )) && echo "$SUB_DOMAIN" || echo "нет" )"

    c=$(ui_choose "Удаление SkipIt Tool" "$hdr

Что убрать с сервера?" \
        tool "Только SkipIt Tool — панель, нода и страница останутся работать" \
        all  "SkipIt Tool и всё, что он ставил") || return
    case $c in
        tool) self_remove_tool ;;
        all)  self_remove_all ;;
    esac
}

# Уходит только инструмент: контейнеры, папки компонентов, сертификаты и правила
# фаервола остаются как есть и продолжают работать сами по себе.
self_remove_tool() {
    ui_yesno "Только SkipIt Tool" "── Будет удалено
Команда:      $SKIPIT_BIN
Настройки:    $SKIPIT_ETC — записи о том, что и где установлено
Автобэкап:    ежедневная задача cron

── Останется работать
Компоненты:   панель, нода и страница подписки — контейнеры и их папки
Сеть:         сертификаты, правила UFW, настройки SSH и ядра
Бэкапы:       $SKIPIT_BACKUPS

ℹ Управлять компонентами дальше придётся руками: docker compose в их папках.
ℹ Поставить SkipIt Tool заново можно в любой момент — он подхватит
  установленное по файлам в /opt.

Удалить SkipIt Tool?" no || return

    clear; say "Удаляю SkipIt Tool..."
    rm -f "$PANEL_BACKUP_CRON"
    rm -rf "$SKIPIT_ETC"
    rm -f "$SKIPIT_UPDATE_LATEST"
    log "self remove: только инструмент"
    rm -f "$SKIPIT_BIN"
    echo
    say "SkipIt Tool удалён — компоненты работают дальше."
    say "Бэкапы остались: $SKIPIT_BACKUPS"
    pause
    clear
    exit 0
}

# Уходит всё, что ставил SkipIt Tool. Настройки SSH, ядра и fail2ban не трогаем:
# это общесистемная настройка сервера, её откат - отдельное осознанное действие,
# а снос вслепую может оставить сервер без доступа.
self_remove_all() {
    local p n s del_cert=0 bak
    panel_installed 2>/dev/null && p=1 || p=0
    node_installed  2>/dev/null && n=1 || n=0
    sub_installed   2>/dev/null && s=1 || s=0

    ui_yesno "Удалить всё" "── Будет удалено
$( (( p )) && printf 'Панель:       %s вместе с базой\n' "$PANEL_DOMAIN" )$( (( n )) && printf 'Нода:         %s, Xray и сайт-заглушка\n' "$NODE_DOMAIN" )$( (( s )) && printf 'Подписка:     %s\n' "$SUB_DOMAIN" )Папки:        $PANEL_DIR$( (( n )) && printf ', %s' "$NODE_DIR" )
Фаервол:      правила SkipIt Tool, кроме SSH
Команда:      $SKIPIT_BIN и настройки $SKIPIT_ETC

── Останется
Доступ:       SSH и его правило UFW — их не трогаем
Система:      настройки ядра, fail2ban и sshd остаются как есть
Бэкапы:       $SKIPIT_BACKUPS
Сертификаты:  спрошу отдельно

! База панели уйдёт вместе с томом: пользователи, ноды и секреты.
  Вернуть их можно будет только из бэкапа.

Удалить всё?" no || return

    if (( p )); then
        ui_yesno "Ещё раз про базу" "Это снесёт базу панели $PANEL_DOMAIN целиком.
После запуска отменить будет нельзя.

Перед удалением сделаю дамп в $SKIPIT_BACKUPS — он останется на диске.

Продолжить?" no || return
    fi

    ui_yesno "Сертификаты" "Удалить сертификаты Let's Encrypt этих доменов?

Если домены ещё понадобятся — оставьте: перевыпуск ограничен лимитами
Let's Encrypt (5 повторов в неделю на один набор имён)." no && del_cert=1

    clear; say "Удаляю всё, что ставил SkipIt Tool..."

    # Дамп базы напоследок: он переживёт удаление и останется в бэкапах
    if (( p )); then
        bak="${SKIPIT_BACKUPS}/panel-db-before-remove-$(date +%Y%m%d-%H%M%S).sql.gz"
        mkdir -p "$SKIPIT_BACKUPS"
        if panel_dump_db "$bak" 2>/dev/null; then
            say "Дамп базы: $bak"
        else
            say "Дамп базы сделать не удалось — база уже не отвечает."
            bak=""
        fi
    fi

    # Нода: контейнеры, папка, её правила фаервола
    if (( n )); then
        say "Нода $NODE_DOMAIN..."
        [[ -f $NODE_COMPOSE ]] && node_compose_run down --remove-orphans >/dev/null 2>&1
        node_ufw_remove "$NODE_PANEL_IP" "$NODE_PORT"
        node_ufw_close_balancer
        rm -rf "$NODE_DIR"
        (( del_cert )) && [[ -n $NODE_CERT_NAME ]] &&
            certbot delete --non-interactive --cert-name "$NODE_CERT_NAME" >/dev/null 2>&1
        find "$NODE_WEBROOT" -mindepth 1 -delete 2>/dev/null
    fi

    # Панель со страницей подписки: контейнеры, тома, папка
    if (( p )); then
        say "Панель $PANEL_DOMAIN..."
        [[ -f $PANEL_COMPOSE ]] && panel_compose_run down -v --remove-orphans >/dev/null 2>&1
        docker volume rm remnawave-db-data valkey-socket >/dev/null 2>&1
        rm -rf "$PANEL_DIR"
        (( del_cert )) && [[ -n $PANEL_CERT_NAME ]] &&
            certbot delete --non-interactive --cert-name "$PANEL_CERT_NAME" >/dev/null 2>&1
    fi
    # Страница подписки своей папкой - только когда стоит отдельно от панели
    if (( s )) && [[ ${SUB_BUNDLED:-0} != 1 && -n ${SUB_DIR:-} && -d $SUB_DIR ]]; then
        say "Страница подписки $SUB_DOMAIN..."
        [[ -f $SUB_COMPOSE ]] && sub_compose_run down --remove-orphans >/dev/null 2>&1
        rm -rf "$SUB_DIR"
    fi

    docker network rm remnawave-network >/dev/null 2>&1

    # Фаервол: снимаем 443, SSH не трогаем ни при каких условиях
    if command -v ufw >/dev/null 2>&1; then
        ufwc --force delete allow 443/tcp >/dev/null 2>&1
    fi

    rm -f "$PANEL_BACKUP_CRON"
    rm -rf "$SKIPIT_ETC"
    rm -f "$SKIPIT_UPDATE_LATEST"
    log "self remove: всё (панель=$p нода=$n подписка=$s серты=$del_cert)"
    rm -f "$SKIPIT_BIN"

    echo
    say "Удалено. SSH и правило UFW на порт SSH оставлены нетронутыми."
    [[ -n ${bak:-} ]] && say "Дамп базы на диске: $bak"
    say "Бэкапы и архивы: $SKIPIT_BACKUPS"
    say "Настройки ядра, sshd и fail2ban остались — если они больше не нужны, уберите их вручную."
    pause
    clear
    exit 0
}

menu_about() {
    ui_dims
    { clear; ui_banner; echo; } >"$TTY"
    ui_body "── Где SkipIt Tool
Команда:  ${SKIPIT_CMD}
Скрипт:   ${SKIPIT_BIN}
Лог:      ${SKIPIT_LOG}
Бэкапы:   ${SKIPIT_BACKUPS}

── Файлы, которые меняет SkipIt Tool
SSH:      ${SSHD_DROPIN}
sysctl:   ${SYSCTL_FILE}
IPv6:     ${IPV6_SYSCTL}
fail2ban: ${F2B_JAIL}
Нода:     ${NODE_DIR}
Сайт:     ${NODE_WEBROOT}
Настройки ноды:  ${NODE_STATE}

── Что использует SkipIt Tool
Нода:            Remnawave Node — github.com/remnawave
Веб-сервер:      nginx (${NODE_NGINX_IMAGE})
Docker:          установщик get.docker.com
Сертификаты:     Let's Encrypt, certbot и плагин Cloudflare
Шаблоны сайтов:  Mrvibecodic (GitHub), learning-zone/website-templates (GitHub)
Проверка IP:     ipregion — github.com/vernette/ipregion
Тест скорости:   Speedtest CLI от Ookla
Монитор:         btop
Внешний IP:      api.ipify.org, ifconfig.me
Защита:          UFW, fail2ban"
    printf '\n  %s ' "$(ui_keys "Enter — назад")" >"$TTY"
    ui_readline _
}

main_menu() {
    local c rc ufw_st upd autoupd_st
    while :; do
        if ! autoupd_supported; then autoupd_st=""
        elif autoupd_on; then autoupd_st=""; else autoupd_st="выключены"; fi
        if ! command -v ufw >/dev/null 2>&1; then ufw_st="не установлен"
        elif ufw_active; then ufw_st="включён"; else ufw_st="выключен"; fi
        upd=$(update_available)
        UI_CANCEL="Выход"; UI_BANNER=1
        UI_FOOTER=$'\n'"  ${C_HINT}запуск в любой момент: ${C_ACC}${SKIPIT_CMD}${C_RESET}"
        [[ -n $upd ]] && UI_FOOTER+=$'\n'"  ${C_WARN}доступна новая версия SkipIt Tool: v${upd}${C_RESET} ${C_HINT}— пункт «Обновить SkipIt Tool»${C_RESET}"
        c=$(ui_menu "" "сервер:     $(hostname) · $SERVER_IP
система:    $OS_NAME · $VIRT
сеть:       IPv6 $(ipv6_state_ru) · TCP $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
remnawave:  $(remna_hdr)

SSH:        порт $(ssh_ports)$([[ $(sshd_eff permitrootlogin) == yes ]] && echo " · root по паролю")
UFW:        $ufw_st
fail2ban:   $(f2b_state_ru)
патчи:      $(autoupd_supported && { autoupd_on && echo "автоматически" || echo "вручную"; } || echo "вручную")$(reboot_required && echo " · сервер ждёт перезагрузки")

процессор:  $(sys_cpu_line)
память:     $(sys_mem_line)
диск:       $(sys_disk_line)
нагрузка:   $(sys_load_line)" \
            ""      "Remnawave" \
            remna   "Компоненты Remnawave" \
            rdiag   "Диагностика" \
            ""      "Защита" \
            users   "SSH и пользователи" \
            ufw     "Фаервол UFW" \
            f2b     "fail2ban" \
            ""      "Сервер" \
            kernel  "Ядро Linux — sysctl, BBR" \
            ipv6    "IPv6 — включить, выключить, основной протокол" \
            tz      "Часовой пояс — $(tz_current) · $(date '+%H:%M')" \
            upgrade "Обновление сервера — пакеты системы" \
            autoupd "Автообновления безопасности${autoupd_st:+ — $autoupd_st}" \
            monitor "Монитор ресурсов (btop)" \
            ""      "Сервис" \
            regions "Проверка IP по регионам (ipregion)" \
            speed   "Тест скорости канала" \
            clean   "Очистка диска" \
            ""      "SkipIt Tool" \
            update  "Обновить SkipIt Tool${upd:+ — доступна v$upd}" \
            selfrm  "Удаление SkipIt Tool" \
            about   "О программе")
        rc=$?
        UI_CANCEL="Назад"; UI_FOOTER=""; UI_BANNER=0
        (( rc != 0 )) && return
        case $c in
            remna)  menu_remnawave ;;
            rdiag)  menu_remna_diag ;;
            users)  menu_users ;;
            ufw)    menu_ufw ;;
            f2b)    menu_fail2ban ;;
            kernel) menu_kernel ;;
            ipv6)   menu_ipv6 ;;
            tz)     menu_timezone ;;
            upgrade) menu_sys_upgrade ;;
            autoupd) menu_autoupd ;;
            monitor) sys_btop ;;
            regions) region_check ;;
            speed)   sys_speedtest ;;
            clean)   sys_disk_clean ;;
            update) menu_update ;;
            about)  menu_about ;;
            selfrm) menu_self_remove ;;
        esac
    done
}

# Один SkipIt Tool на сервер. Если он уже открыт в другом окне - закрываем тот
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
    say "SkipIt Tool уже открыт в другом окне — закрываю его..."
    local pids; pids=$(lock_holders)
    [[ -n $pids ]] && kill -TERM $pids 2>/dev/null
    exec 9>>"$SKIPIT_LOCK"
    if ! flock -w 5 9; then
        exec 9>&-
        pids=$(lock_holders)
        [[ -n $pids ]] && kill -KILL $pids 2>/dev/null
        exec 9>>"$SKIPIT_LOCK"
        flock -w 3 9 || die "Не удалось закрыть SkipIt Tool в другом окне. Закройте его вручную: kill $(echo $pids)"
    fi
    sleep 0.3
}

main() {
    case ${1:-} in
        version|-v|--version) echo "SkipIt Tool v${SKIPIT_VERSION}"; exit 0 ;;
        help|-h|--help)       usage; exit 0 ;;
        install|uninstall|update|menu|panel-backup|"") ;;
        *) usage; exit 1 ;;
    esac
    require_root "$@"
    setup_env
    detect_pm
    # Бэкап по расписанию (cron): без меню, без обновления системы
    if [[ ${1:-} == panel-backup ]]; then
        panel_state_load || exit 0
        local f
        if f=$(panel_backup_make); then log "panel backup (cron): $f"; else log "panel backup (cron): FAIL"; exit 1; fi
        exit 0
    fi
    # Команда skipit ещё не установлена - это первый запуск на сервере
    [[ -x $SKIPIT_BIN || ${1:-} == uninstall ]] || sys_upgrade first

    case ${1:-} in
        install)
            bootstrap_deps; self_install; tz_first_run
            say "Готово! Запускайте командой: ${C_ACC}${SKIPIT_CMD}${C_RESET}"
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
        tz_first_run
    fi

    { : >"$TTY"; } 2>/dev/null || die "Нужен интерактивный терминал (SSH-сессия)."
    lock_take
    trap 'tx_end; stty echo <"$TTY" 2>/dev/null' EXIT
    trap 'printf "\n\n  %sSkipIt Tool%s закрыт: его открыли в другом окне.\n\n" "$C_BRAND" "$C_RESET" >"$TTY" 2>/dev/null; exit 143' TERM HUP
    trap ':' INT   # Ctrl+C отменяет текущее действие, а не закрывает панель
    update_check_bg
    tz_first_run pending

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
