#!/usr/bin/env bash
# nodecheck — проверка сервера под VPN-ноду. Самостоятельный скрипт, ни с чем не связан.
#
# Запуск одной строкой:
#   bash <(curl -sL https://raw.githubusercontent.com/ShuntVPN/nodecheck/main/nodecheck.sh)
# Поставить командой nodecheck:  ... nodecheck.sh) --install
#
#   bash nodecheck.sh              — только проверка, НИЧЕГО не меняет
#   bash nodecheck.sh --quick      — без замера скорости (не тратит трафик)
#   bash nodecheck.sh --fix        — проверка + применить настройки (спросит подтверждение)
#   bash nodecheck.sh --fix --yes  — то же без вопросов
#   bash nodecheck.sh --restore    — вернуть файлы настроек из последнего бэкапа
#
# Код выхода: 0 — всё хорошо, 1 — есть замечания, 2 — есть проблемы.
# Что меняет --fix (и кладёт копии старых файлов в /root/nodecheck-backup-ДАТА):
#   /etc/sysctl.d/99-nodecheck.conf  — BBR+fq, буферы, без сброса разгона, MTU probing, conntrack, очереди
#   /etc/systemd/journald.conf       — журнал не больше 200 МБ
#   /etc/docker/daemon.json          — лимит логов контейнеров (только если файла ещё нет)
#   docker.service.d/limits.conf     — лимит открытых файлов 1048576
#   /var/log/btmp                    — обнуляется (журнал неудачных входов по SSH)
#   Docker перезапускается только если вы согласитесь (клиенты переподключатся за секунды).

VERSION="1.0.2"
URL="https://raw.githubusercontent.com/ShuntVPN/nodecheck/main/nodecheck.sh"
MODE="check"; QUICK=0; YES=0
for a in "$@"; do
  case "$a" in
    --fix) MODE="fix";; --restore) MODE="restore";; --quick) QUICK=1;; --yes|-y) YES=1;; --install) MODE="install";;
    -h|--help) curl -sL "$URL" 2>/dev/null | sed -n '2,25p' | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "Неизвестный параметр: $a (см. --help)"; exit 3;;
  esac
done

# ---------- оформление ----------
if [ -t 1 ]; then G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; B=$'\e[1m'; D=$'\e[2m'; N=$'\e[0m'; else G=; Y=; R=; B=; D=; N=; fi
OK=0; WARN=0; BAD=0; FIXES=()
ok()   { OK=$((OK+1));     printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
warn() { WARN=$((WARN+1)); printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
bad()  { BAD=$((BAD+1));   printf '  %s✗%s %s\n' "$R" "$N" "$*"; }
info() { printf '  %s·%s %s\n' "$D" "$N" "$*"; }
hint() { printf '    %s→ %s%s\n' "$D" "$*" "$N"; }
sec()  { printf '\n%s%s%s\n' "$B" "$*" "$N"; }
have() { command -v "$1" >/dev/null 2>&1; }
human() { awk -v b="${1:-0}" 'BEGIN{s="Б КБ МБ ГБ ТБ";split(s,u," ");i=1;while(b>=1024&&i<5){b/=1024;i++};printf (i==1?"%d %s":"%.1f %s"),b,u[i]}'; }
sysget() { sysctl -n "$1" 2>/dev/null; }
# «да»: y/yes, д/да и «у» — так выглядит y, если включена русская раскладка
yes_ans() { case "$(echo "$1" | tr -d ' \r' | tr '[:upper:]' '[:lower:]')" in y|yes|д|да|у|Д|ДА|У) return 0;; *) return 1;; esac; }
pl() { local n=$1; if [ $((n%10)) -eq 1 ] && [ $((n%100)) -ne 11 ]; then echo "$2"; elif [ $((n%10)) -ge 2 ] && [ $((n%10)) -le 4 ] && { [ $((n%100)) -lt 12 ] || [ $((n%100)) -gt 14 ]; }; then echo "$3"; else echo "$4"; fi; }
case "$0" in /dev/fd/*|/proc/*|bash|-bash) SELF="${NODECHECK_CMD:-bash <(curl -sL $URL)}";; *) SELF="bash $0";; esac
IS_ROOT=0; [ "$(id -u)" = 0 ] && IS_ROOT=1

# ======================================================================= install
if [ "$MODE" = "install" ]; then
  [ "$(id -u)" = 0 ] || { echo "Нужен root"; exit 3; }
  printf '#!/usr/bin/env bash\n# всегда свежая версия nodecheck с GitHub\nNODECHECK_CMD=nodecheck exec bash <(curl -fsSL %s) "$@"\n' "$URL" > /usr/local/bin/nodecheck
  chmod 755 /usr/local/bin/nodecheck
  echo "Готово: теперь просто  nodecheck  (или nodecheck --fix, --quick, --restore)"
  exit 0
fi

# ======================================================================= restore
if [ "$MODE" = "restore" ]; then
  [ "$IS_ROOT" = 1 ] || { echo "Нужен root"; exit 3; }
  BK="$(ls -d /root/nodecheck-backup-* 2>/dev/null | sort | tail -1)"
  [ -n "$BK" ] || { echo "Бэкапов нет — нечего возвращать"; exit 3; }
  echo "Возвращаю файлы из $BK"
  [ -f "$BK/created.list" ] && while read -r f; do rm -f "$f" && echo "  удалён $f (его создал nodecheck)"; done < "$BK/created.list"
  (cd "$BK/files" 2>/dev/null && find . -type f) | while read -r f; do
    cp -a "$BK/files/$f" "/${f#./}" && echo "  восстановлен /${f#./}"
  done
  sysctl --system >/dev/null 2>&1; systemctl daemon-reload 2>/dev/null; systemctl restart systemd-journald 2>/dev/null
  echo "Готово. Значения ядра, которые уже действуют, вернутся к прежним после перезагрузки сервера (reboot)."
  echo "Docker не перезапускаю — если нужен прежний лимит файлов/логов: systemctl restart docker"
  exit 0
fi

printf '%snodecheck %s%s — %s, %s\n' "$B" "$VERSION" "$N" "$(hostname)" "$(date '+%d.%m.%Y %H:%M')"
[ "$IS_ROOT" = 1 ] || printf '%sЗапущено не от root — часть проверок будет неполной%s\n' "$Y" "$N"

# ======================================================================= 1. система
sec "1. Система"
. /etc/os-release 2>/dev/null
info "ОС: ${PRETTY_NAME:-неизвестно}, ядро $(uname -r), $(uname -m)"
VIRT="$(systemd-detect-virt 2>/dev/null || true)"
if [ -e /proc/user_beancounters ] || case "$VIRT" in openvz|lxc|lxc-libvirt|docker|podman|systemd-nspawn|wsl|proot) true;; *) false;; esac; then
  bad "Виртуализация ${VIRT:-openvz}: контейнер без своего ядра — BBR, буферы и tun не настроить"
elif [ -n "$VIRT" ] && [ "$VIRT" != "none" ]; then ok "Виртуализация: $VIRT (своё ядро)"
else info "Виртуализация: не определена (${VIRT:-нет systemd-detect-virt})"; fi
CORES="$(nproc 2>/dev/null || echo 1)"
CPU_MODEL="$(awk -F': ' '/model name/{print $2; exit}' /proc/cpuinfo)"
info "Процессор: ${CPU_MODEL:-?} · ядер: $CORES"
if grep -qw aes /proc/cpuinfo; then ok "AES-NI есть — шифрование аппаратное"
else bad "Нет AES-NI — шифрование программное, туннель упрётся в процессор"; fi
KMAJ="$(uname -r | cut -d. -f1)"; KMIN="$(uname -r | cut -d. -f2)"
if [ "$KMAJ" -gt 4 ] || { [ "$KMAJ" = 4 ] && [ "$KMIN" -ge 9 ]; }; then ok "Ядро $(uname -r) поддерживает BBR"
else bad "Ядро $(uname -r) слишком старое для BBR (нужно 4.9+)"; fi
UP="$(awk '{printf "%d", $1/86400}' /proc/uptime)"; info "Работает без перезагрузки: $UP дн."
if have timedatectl; then
  if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes; then ok "Время синхронизировано (NTP)"
  else warn "Время не синхронизировано — TLS и Reality чувствительны к часам"; hint "timedatectl set-ntp true"; fi
fi

# ======================================================================= 2. процессор
sec "2. Процессор"
read -r _ u1 n1 s1 i1 w1 q1 sq1 st1 _ < <(grep '^cpu ' /proc/stat)
sleep 5
read -r _ u2 n2 s2 i2 w2 q2 sq2 st2 _ < <(grep '^cpu ' /proc/stat)
T=$(( (u2+n2+s2+i2+w2+q2+sq2+st2) - (u1+n1+s1+i1+w1+q1+sq1+st1) )); [ "$T" -gt 0 ] || T=1
STEAL=$(( 100 * (st2-st1) / T )); BUSY=$(( 100 * (T - (i2-i1) - (w2-w1)) / T ))
if [ "$STEAL" -le 3 ]; then ok "Стил (время, отобранное соседями): ${STEAL}%"
elif [ "$STEAL" -le 10 ]; then warn "Стил ${STEAL}% — узел у хостера загружен, нода будет подтормаживать под нагрузкой"
else bad "Стил ${STEAL}% — узел перепродан, CPU отбирают соседи"; hint "просите у хостера перенос на другой узел или меняйте сервер"; fi
LOAD1="$(cut -d' ' -f1 /proc/loadavg)"
info "Загрузка CPU сейчас: ${BUSY}% · load average: $(cut -d' ' -f1-3 /proc/loadavg) (ядер $CORES)"
if awk -v l="$LOAD1" -v c="$CORES" 'BEGIN{exit !(l > c*0.8)}'; then warn "Load выше 80% от числа ядер — сервер нагружен"; fi
# процессы-паразиты: всё, что ест заметно CPU
HOGS="$(ps -eo pid,pcpu,etime,comm --sort=-pcpu 2>/dev/null | awk 'NR>1 && $2>=20 {printf "%s (pid %s, %s%%, работает %s); ", $4, $1, $2, $3}')"
if [ -n "$HOGS" ]; then warn "Процессы, которые едят процессор: ${HOGS%; }"; hint "забытый процесс снимайте по PID: kill PID (не pkill -f)"
else ok "Нет процессов, которые грузят CPU больше 20%"; fi

# ======================================================================= 3. память
sec "3. Память"
MT=$(awk '/MemTotal/{print $2*1024}' /proc/meminfo); MA=$(awk '/MemAvailable/{print $2*1024}' /proc/meminfo)
ST=$(awk '/SwapTotal/{print $2*1024}' /proc/meminfo)
MP=$(( 100 * (MT - MA) / MT ))
info "Всего $(human "$MT"), свободно $(human "$MA"), swap $(human "$ST")"
if [ "$MP" -lt 75 ]; then ok "Занято ${MP}% памяти"; elif [ "$MP" -lt 90 ]; then warn "Занято ${MP}% памяти"; else bad "Занято ${MP}% памяти — может прийти OOM-killer"; fi
if [ "$MT" -lt $((900*1024*1024)) ]; then warn "Меньше 1 ГБ памяти — под ноду впритык"; fi
OOM="$( (journalctl -k --since "-7 days" 2>/dev/null || dmesg 2>/dev/null) | grep -ci 'out of memory\|oom-kill' )"
if [ "${OOM:-0}" -gt 0 ]; then bad "За неделю $OOM раз убивались процессы из-за нехватки памяти (OOM)"; else ok "Падений из-за нехватки памяти не было"; fi

# ======================================================================= 4. диск
sec "4. Диск"
read -r DSIZE DUSED DAVAIL DPCT < <(df -B1 --output=size,used,avail,pcent / | tail -1 | tr -d '%')
info "Корневой раздел: $(human "$DSIZE"), занято $(human "$DUSED"), свободно $(human "$DAVAIL")"
if [ "$DPCT" -lt 70 ]; then ok "Диск занят на ${DPCT}%"; elif [ "$DPCT" -lt 85 ]; then warn "Диск занят на ${DPCT}%"; else bad "Диск занят на ${DPCT}% — нода на забитом диске ведёт себя непредсказуемо"; fi
IPCT="$(df --output=ipcent / 2>/dev/null | tail -1 | tr -dc '0-9')"
[ -n "$IPCT" ] && [ "$IPCT" -ge 80 ] && bad "Закончились файловые записи (inodes ${IPCT}%) — много мелких файлов"
big() { # путь порог_в_МБ описание совет
  local s; s="$(du -sb "$1" 2>/dev/null | cut -f1)"; [ -n "$s" ] || return
  if [ "$s" -gt $(( $2 * 1024 * 1024 )) ]; then warn "$3: $(human "$s")"; hint "$4"; fi
}
big /var/log/journal 300 "Журнал systemd" "journalctl --vacuum-size=200M (или --fix)"
big /var/log/nginx 500 "Логи nginx" "truncate -s 0 /var/log/nginx/*.log и access_log off; в nginx.conf"
big /var/log/btmp 50 "Журнал неудачных входов по SSH (/var/log/btmp)" "truncate -s 0 /var/log/btmp (или --fix); SSH на нестандартный порт / fail2ban"
big /var/log/remnanode 500 "Логи Xray (/var/log/remnanode)" "нужна ротация: logrotate с maxsize"
big /var/cache/apt 300 "Кэш пакетов apt" "apt-get clean"
if [ "$IS_ROOT" = 1 ] && [ -d /var/lib/docker/containers ]; then
  BIGLOG="$(find /var/lib/docker/containers -name '*-json.log' -size +200M -printf '%s %p\n' 2>/dev/null | sort -n | tail -1)"
  if [ -n "$BIGLOG" ]; then
    CID="$(basename "$(dirname "${BIGLOG#* }")" | cut -c1-12)"; CN="$(docker inspect -f '{{.Name}}' "$CID" 2>/dev/null | tr -d /)"
    warn "Лог контейнера ${CN:-$CID}: $(human "${BIGLOG%% *}")"; hint "лимит логов Docker (--fix) и пересоздать контейнер: docker compose up -d --force-recreate"
  fi
fi
TOPDIR="$(du -xh --max-depth=2 / 2>/dev/null | sort -h | tail -4 | head -3 | awk '{printf "%s %s; ", $2, $1}')"
info "Самые большие папки: ${TOPDIR%; }"

# ======================================================================= 5. сеть
sec "5. Сеть"
IFACE="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"
MTU="$(cat "/sys/class/net/${IFACE:-eth0}/mtu" 2>/dev/null)"
if [ -n "$IFACE" ]; then
  if [ "${MTU:-0}" -ge 1500 ]; then ok "Интерфейс $IFACE, MTU $MTU"; else warn "Интерфейс $IFACE, MTU $MTU (меньше 1500) — включите MTU probing (--fix)"; fi
fi
IP4="$(curl -4 -s --max-time 8 https://api.ipify.org 2>/dev/null)"
if [ -n "$IP4" ]; then ok "Интернет по IPv4 есть, внешний адрес $IP4"; else bad "Нет выхода в интернет по IPv4"; fi
if curl -6 -s --max-time 6 -o /dev/null https://www.google.com 2>/dev/null; then ok "IPv6 наружу работает"
else warn "IPv6 наружу не работает — в профиле Xray поставьте queryStrategy/domainStrategy: UseIPv4, иначе часть сайтов не откроется"; fi
if getent hosts google.com >/dev/null 2>&1; then ok "DNS работает"; else bad "DNS не резолвит имена"; fi
# до России: пинг и стабильность (если ICMP закрыт — время TCP-рукопожатия)
RU_HOST="ya.ru"
PINGOUT="$(ping -c 20 -i 0.3 -W 2 "$RU_HOST" 2>/dev/null)"
if [ -n "$PINGOUT" ] && echo "$PINGOUT" | grep -q 'min/avg'; then
  LOSS="$(echo "$PINGOUT" | grep -o '[0-9.]*% packet loss' | cut -d% -f1)"
  read -r PMIN PAVG PMAX PDEV < <(echo "$PINGOUT" | awk -F'= ' '/min\/avg/{print $2}' | tr '/' ' ' | awk '{print $1, $2, $3, $4}')
  PA="${PAVG%.*}"; PJ="${PDEV%.*}"; LS="${LOSS%.*}"
  MSG="до России ($RU_HOST): пинг ${PA} мс, разброс ${PJ} мс, потери ${LOSS}%"
  if [ "$PA" -le 160 ] && [ "$PJ" -le 30 ] && [ "${LS:-0}" -eq 0 ]; then ok "$MSG"
  elif [ "$PA" -le 400 ] && [ "$PJ" -le 80 ] && [ "${LS:-0}" -lt 15 ]; then warn "$MSG"
  else bad "$MSG"; fi
else
  T0=$(date +%s%N); if timeout 5 bash -c "exec 3<>/dev/tcp/$RU_HOST/443" 2>/dev/null; then
    T1=$(( ($(date +%s%N) - T0) / 1000000 )); info "До России ($RU_HOST) ICMP закрыт, TCP-рукопожатие ${T1} мс"
  else warn "До России ($RU_HOST) не достучаться ни пингом, ни по TCP"; fi
fi
# исходящий 25-й порт открыт — признак «грязной» подсети, где можно спамить
if timeout 5 bash -c "exec 3<>/dev/tcp/smtp.gmail.com/25" 2>/dev/null; then warn "Исходящий 25-й порт открыт — у хостера разрешена почта, такие подсети чаще в спам-листах"
else ok "Исходящий 25-й порт закрыт"; fi
if [ "$QUICK" = 0 ]; then
  SPD="$(curl -4 -o /dev/null -s --max-time 40 -w '%{speed_download}' 'https://speed.cloudflare.com/__down?bytes=50000000' 2>/dev/null)"
  MBIT="$(awk -v s="${SPD:-0}" 'BEGIN{printf "%d", s*8/1000000}')"
  if [ "$MBIT" -ge 500 ]; then ok "Скорость скачивания (Cloudflare, 50 МБ): $MBIT Мбит/с"
  elif [ "$MBIT" -ge 100 ]; then warn "Скорость скачивания: $MBIT Мбит/с — терпимо"
  else bad "Скорость скачивания: $MBIT Мбит/с — узкий канал или шейп"; fi
else info "Замер скорости пропущен (--quick)"; fi

# ======================================================================= 6. адрес и репутация
sec "6. IP-адрес"
if [ -n "$IP4" ]; then
  J="$(curl -s --max-time 8 "http://ip-api.com/json/$IP4?fields=status,country,countryCode,isp,org,as,proxy,hosting" 2>/dev/null)"
  jv() { echo "$J" | grep -o "\"$1\":[^,}]*" | head -1 | cut -d: -f2- | tr -d '"'; }
  if [ "$(jv status)" = "success" ]; then
    info "Гео: $(jv country) · провайдер: $(jv isp) · $(jv as)"
    if [ "$(jv proxy)" = "true" ]; then bad "IP в базах помечен как прокси/VPN — сайты будут показывать капчи"
    else ok "IP не помечен как прокси (по ip-api)"; fi
    case "$(jv isp) $(jv org) $(jv as)" in
      *OVH*|*Hetzner*|*Scaleway*|*Online\ S.A.S*) warn "Подсеть $(jv isp): такие часто закрыты из России — проверьте доступность напрямую, без моста";;
    esac
  else info "Сервис гео недоступен — пропускаю"; fi
fi

# ======================================================================= 7. ядро и сеть (тюнинг)
sec "7. Настройки ядра"
CC="$(sysget net.ipv4.tcp_congestion_control)"; QD_LIVE="$(tc qdisc show dev "${IFACE:-eth0}" 2>/dev/null | head -1 | awk '{print $2}')"
if [ "$CC" = "bbr" ]; then ok "Разгон TCP: BBR"; else warn "Разгон TCP: ${CC:-?} (не BBR) — на каналах с потерями теряется 20–60% скорости"; FIXES+=(bbr); fi
if [ -n "$IFACE" ]; then
  if [ "$QD_LIVE" = "fq" ]; then ok "Очередь на интерфейсе: fq"; else warn "Очередь на интерфейсе: ${QD_LIVE:-?} (лучше fq для BBR)"; FIXES+=(bbr); fi
fi
RMAX="$(sysget net.ipv4.tcp_rmem | awk '{print $3}')"
if [ "${RMAX:-0}" -ge 16000000 ]; then ok "Буфер TCP: до $(human "$RMAX")"; else warn "Буфер TCP: до $(human "${RMAX:-0}") — дальние клиенты упрутся в окно (нужно 16 МБ)"; FIXES+=(buffers); fi
if [ "$(sysget net.ipv4.tcp_slow_start_after_idle)" = "0" ]; then ok "Разгон после паузы не сбрасывается"; else warn "После паузы соединение разгоняется заново (tcp_slow_start_after_idle=1)"; FIXES+=(idle); fi
if [ "$(sysget net.ipv4.tcp_mtu_probing)" = "1" ]; then ok "MTU probing включён"; else warn "MTU probing выключен — за CDN и с мобильных крупные пакеты могут теряться"; FIXES+=(mtu); fi
CTMAX="$(sysget net.netfilter.nf_conntrack_max)"; CTNOW="$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)"
if [ -n "$CTMAX" ]; then
  if [ "$CTMAX" -ge 131072 ]; then ok "Таблица соединений: ${CTNOW:-?} из $CTMAX"
  else warn "Таблица соединений: ${CTNOW:-?} из $CTMAX — с запасом на рост лучше 262144 (при переполнении соединения молча отбрасываются)"; FIXES+=(conntrack); fi
  if [ -n "$CTNOW" ] && [ "$CTNOW" -gt $(( CTMAX * 8 / 10 )) ]; then bad "Таблица соединений почти полна ($CTNOW из $CTMAX)"; fi
else info "conntrack не загружен — таблица соединений не ограничивает"; fi
SOM="$(sysget net.core.somaxconn)"; if [ "${SOM:-0}" -ge 4096 ]; then ok "Очередь приёма соединений: $SOM"; else warn "Очередь приёма соединений: ${SOM:-?} (при всплесках подключений будут отказы)"; FIXES+=(queues); fi
if have systemctl && [ "$(systemctl show docker -p LoadState --value 2>/dev/null)" = "loaded" ]; then
  NOF="$(systemctl show docker -p LimitNOFILE --value 2>/dev/null)"
  if [ "$NOF" = "infinity" ] || [ "${NOF:-0}" -ge 500000 ] 2>/dev/null; then ok "Лимит открытых файлов у Docker: $NOF"
  else warn "Лимит открытых файлов у Docker: ${NOF:-?} — на сотне клиентов Xray начнёт отказывать"; FIXES+=(nofile); fi
fi

# ======================================================================= 8. docker, журнал, нода
sec "8. Docker и логи"
JMAX="$(grep -E '^SystemMaxUse=' /etc/systemd/journald.conf /etc/systemd/journald.conf.d/*.conf 2>/dev/null | tail -1 | cut -d= -f2)"
if [ -n "$JMAX" ]; then ok "Журнал systemd ограничен: $JMAX"; else warn "Размер журнала systemd не ограничен — со временем займёт гигабайты"; FIXES+=(journal); fi
if have docker; then
  DV="$(docker version -f '{{.Server.Version}}' 2>/dev/null | head -1)"; info "Docker ${DV:-не отвечает}"
  RNLIM="$(docker inspect -f '{{index .HostConfig.LogConfig.Config "max-size"}}' remnanode 2>/dev/null)"
  if [ -f /etc/docker/daemon.json ] && grep -q 'max-size' /etc/docker/daemon.json; then ok "Лимит логов контейнеров задан в daemon.json"
  elif [ -n "$RNLIM" ]; then info "Общего лимита логов Docker нет, но у remnanode свой ($RNLIM) — для остальных контейнеров можно добавить --fix"; FIXES+=(dockerlogs)
  else warn "Логи контейнеров Docker без лимита — могут разрастись до гигабайт"; FIXES+=(dockerlogs); fi
  if docker inspect remnanode >/dev/null 2>&1; then
    RS="$(docker inspect -f '{{.State.Status}}' remnanode)"; LC="$(docker inspect -f '{{index .HostConfig.LogConfig.Config "max-size"}}' remnanode 2>/dev/null)"
    [ "$RS" = "running" ] && ok "remnanode работает" || bad "remnanode: $RS"
    [ -n "$LC" ] && ok "У remnanode лимит логов $LC" || warn "У remnanode нет лимита логов — после настройки пересоздайте контейнер"
    NOFC="$(docker exec remnanode sh -c 'ulimit -n' 2>/dev/null)"
    [ -n "$NOFC" ] && { [ "$NOFC" -ge 65536 ] 2>/dev/null && ok "Лимит файлов внутри remnanode: $NOFC" || warn "Лимит файлов внутри remnanode: $NOFC"; }
  else info "Контейнера remnanode нет (сервер ещё без ноды)"; fi
  UNUSED="$(docker images -f dangling=true -q 2>/dev/null | wc -l)"
  [ "$UNUSED" -gt 0 ] && warn "Образов Docker без метки: $UNUSED" && hint "docker image prune -f"
else info "Docker не установлен"; fi

# ======================================================================= итог
TOTAL=$((OK+WARN+BAD))
sec "Итог"
if [ "$BAD" -gt 0 ]; then VERDICT="${R}НЕ ГОТОВ${N}: $BAD $(pl "$BAD" проблема проблемы проблем), $WARN $(pl "$WARN" замечание замечания замечаний)"; CODE=2
elif [ "$WARN" -gt 0 ]; then VERDICT="${Y}РАБОЧИЙ С ОГОВОРКАМИ${N}: $WARN $(pl "$WARN" замечание замечания замечаний)"; CODE=1
else VERDICT="${G}В ПОРЯДКЕ${N}"; CODE=0; fi
printf '  %s  (%d %s: ✓ %d · ! %d · ✗ %d)\n' "$VERDICT" "$TOTAL" "$(pl "$TOTAL" проверка проверки проверок)" "$OK" "$WARN" "$BAD"

# уникальные исправления
mapfile -t FIXES < <(printf '%s\n' "${FIXES[@]}" | awk 'NF && !seen[$0]++')
if [ "${#FIXES[@]}" -gt 0 ] && [ "$MODE" != "fix" ]; then
  printf '\n  Можно исправить автоматически: %s\n' "${FIXES[*]}"
  printf '  Запустите: %s%s --fix%s (перед изменением спросит и сделает бэкап)\n' "$B" "$SELF" "$N"
fi
[ "$MODE" = "fix" ] || exit "$CODE"

# ======================================================================= --fix
[ "$IS_ROOT" = 1 ] || { echo "Для --fix нужен root"; exit 3; }
if [ "${#FIXES[@]}" -eq 0 ]; then echo; echo "Исправлять нечего."; exit "$CODE"; fi
has() { printf '%s\n' "${FIXES[@]}" | grep -qx "$1"; }
echo; echo "${B}Будет сделано:${N}"
{ has bbr || has buffers || has idle || has mtu || has conntrack || has queues; } && echo "  • настройки ядра в /etc/sysctl.d/99-nodecheck.conf (применятся сразу, без перезагрузки)"
has journal && echo "  • журнал systemd: не больше 200 МБ"
has dockerlogs && echo "  • лимит логов Docker (50 МБ × 3) — для новых контейнеров"
has nofile && echo "  • лимит открытых файлов Docker 1048576"
[ -s /var/log/btmp ] && echo "  • обнулить /var/log/btmp (неудачные входы по SSH)"
if [ "$YES" != 1 ]; then read -r -p "Применить? [y/N] " ans </dev/tty; yes_ans "$ans" || { echo "Отменено, ничего не изменено (ответ: «$ans»)"; exit "$CODE"; }; fi

BK="/root/nodecheck-backup-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$BK/files"; : > "$BK/created.list"
backup() { if [ -e "$1" ]; then mkdir -p "$BK/files$(dirname "$1")"; cp -a "$1" "$BK/files$1"; else echo "$1" >> "$BK/created.list"; fi; }

if has bbr || has buffers || has idle || has mtu || has conntrack || has queues; then
  F=/etc/sysctl.d/99-nodecheck.conf; backup "$F"
  modprobe tcp_bbr 2>/dev/null; modprobe nf_conntrack 2>/dev/null
  {
    echo "# nodecheck: настройки сети под VPN-ноду. Откат: bash nodecheck.sh --restore"
    echo "net.core.default_qdisc = fq"
    echo "net.ipv4.tcp_congestion_control = bbr"
    echo "net.ipv4.tcp_rmem = 4096 131072 16777216"
    echo "net.ipv4.tcp_wmem = 4096 65536 16777216"
    echo "net.ipv4.tcp_slow_start_after_idle = 0"
    echo "net.ipv4.tcp_mtu_probing = 1"
    echo "net.netfilter.nf_conntrack_max = 262144"
    echo "net.netfilter.nf_conntrack_udp_timeout = 60"
    echo "net.netfilter.nf_conntrack_udp_timeout_stream = 180"
    echo "net.core.somaxconn = 4096"
    echo "net.core.netdev_max_backlog = 16384"
    echo "net.ipv4.tcp_max_syn_backlog = 8192"
    echo "net.ipv4.ip_local_port_range = 10000 65535"
    echo "fs.file-max = 2097152"
  } > "$F"
  sysctl -p "$F" 2>&1 | grep -i 'error\|cannot\|unknown' && echo "  (ключи выше это ядро не знает — остальные применились)"
  [ -n "$IFACE" ] && tc qdisc replace dev "$IFACE" root fq 2>/dev/null && echo "  • очередь fq на $IFACE включена сразу"
  echo "  ✓ ядро настроено"
fi
if has journal; then
  backup /etc/systemd/journald.conf
  if grep -qE '^#?SystemMaxUse=' /etc/systemd/journald.conf; then sed -i 's/^#\?SystemMaxUse=.*/SystemMaxUse=200M/' /etc/systemd/journald.conf
  else echo 'SystemMaxUse=200M' >> /etc/systemd/journald.conf; fi
  systemctl restart systemd-journald; journalctl --vacuum-size=200M >/dev/null 2>&1; echo "  ✓ журнал ограничен 200 МБ"
fi
[ -s /var/log/btmp ] && truncate -s 0 /var/log/btmp && echo "  ✓ /var/log/btmp обнулён"
NEED_DOCKER=0
if has dockerlogs; then
  if [ -f /etc/docker/daemon.json ]; then
    echo "  ! /etc/docker/daemon.json уже есть — не трогаю. Добавьте в него вручную:"
    echo '      "log-driver": "json-file", "log-opts": { "max-size": "50m", "max-file": "3" }'
  else
    mkdir -p /etc/docker; backup /etc/docker/daemon.json
    printf '{\n  "log-driver": "json-file",\n  "log-opts": { "max-size": "50m", "max-file": "3" }\n}\n' > /etc/docker/daemon.json
    NEED_DOCKER=1; echo "  ✓ лимит логов Docker записан"
  fi
fi
if has nofile; then
  mkdir -p /etc/systemd/system/docker.service.d; backup /etc/systemd/system/docker.service.d/limits.conf
  printf '[Service]\nLimitNOFILE=1048576\nLimitNPROC=1048576\n' > /etc/systemd/system/docker.service.d/limits.conf
  systemctl daemon-reload; NEED_DOCKER=1; echo "  ✓ лимит файлов Docker записан"
fi
if [ "$NEED_DOCKER" = 1 ]; then
  echo; echo "  Чтобы Docker взял новые лимиты, его нужно перезапустить, а контейнер ноды — пересоздать."
  echo "  Клиенты отвалятся на 10–20 секунд и переподключатся сами."
  R2=n; [ "$YES" = 1 ] || read -r -p "  Перезапустить Docker сейчас? [y/N] " R2 </dev/tty
  if yes_ans "$R2"; then
    systemctl restart docker && echo "  ✓ Docker перезапущен"
    DIRN="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' remnanode 2>/dev/null)"
    if [ -n "$DIRN" ] && [ -d "$DIRN" ]; then (cd "$DIRN" && docker compose up -d --force-recreate >/dev/null 2>&1) && echo "  ✓ remnanode пересоздан с новыми лимитами"; fi
  else echo "  Позже: systemctl restart docker && cd /opt/remnanode && docker compose up -d --force-recreate"; fi
fi
echo; echo "Бэкап старых файлов: $BK  (откат: $SELF --restore)"
echo "Проверьте результат: $SELF --quick"
exit 0
