#!/data/data/com.termux/files/usr/bin/bash
# ===== Saba Rejoin - menu auto rejoin Roblox (Termux + root) =====
# Mở menu:      rejoin
# Chạy ngầm:    rejoin.sh --run   (menu và chế độ tự khởi động dùng cái này)

T="/data/data/com.termux/files"
DIR="$T/home/rejoin"
SELF="$DIR/rejoin.sh"
CONF="$DIR/config.conf"
LINKS="$DIR/links.conf"
LOG="$DIR/rejoin.log"
PIDF="$DIR/rejoin.pid"
SD_BOOT="/data/adb/service.d/rejoin.sh"
TB_BOOT="$T/home/.termux/boot/rejoin-boot.sh"

export PATH="/system/bin:/system/xbin:$T/usr/bin:$PATH"
export LD_LIBRARY_PATH="$T/usr/lib"
export TMPDIR="$T/usr/tmp"

R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[34m'; M=$'\e[35m'
C=$'\e[36m'; D=$'\e[2m'; BD=$'\e[1m'; N=$'\e[0m'

# ---------------- Mặc định ----------------
SELECTED=""
CHECK_EVERY=15       # giây giữa mỗi vòng kiểm tra
LAUNCH_WAIT=30       # giây chờ sau khi mở 1 app
RESTART_EVERY=0      # phút kill+rejoin định kỳ (0 = tắt)
KICK_DETECT=1        # rejoin khi bị kick/disconnect
KICK_GRACE=60        # mất kết nối bao nhiêu giây thì coi là bị kick
BACKOFF_AFTER=3      # lỗi liên tiếp bao nhiêu lần thì bắt đầu chờ lâu dần
RAM_MIN=500          # MB: dưới mức này thì cảnh báo
SCH_START=""         # giờ bắt đầu chạy (0-23), trống = chạy cả ngày
SCH_END=""           # giờ dừng
WEBHOOK=""           # link webhook Discord
DEV_NAME=""          # tên máy hiện trong thông báo
UPDATE_URL=""        # link raw rejoin.sh trên GitHub của bạn

mkdir -p "$DIR"; touch "$LINKS"

# ---------------- Cấu hình ----------------
load_conf() { [ -f "$CONF" ] && . "$CONF"; [ -z "$DEV_NAME" ] && DEV_NAME=$(getprop ro.product.model 2>/dev/null); }
save_conf() {
  cat > "$CONF" <<EOF
SELECTED="$SELECTED"
CHECK_EVERY="$CHECK_EVERY"
LAUNCH_WAIT="$LAUNCH_WAIT"
RESTART_EVERY="$RESTART_EVERY"
KICK_DETECT="$KICK_DETECT"
KICK_GRACE="$KICK_GRACE"
BACKOFF_AFTER="$BACKOFF_AFTER"
RAM_MIN="$RAM_MIN"
SCH_START="$SCH_START"
SCH_END="$SCH_END"
WEBHOOK="$WEBHOOK"
DEV_NAME="$DEV_NAME"
UPDATE_URL="$UPDATE_URL"
EOF
}
get_link() { awk -F'|' -v p="$1" '$1==p {sub(/^[^|]*\|/,""); print; exit}' "$LINKS"; }
set_link() {
  awk -F'|' -v p="$1" '$1!=p' "$LINKS" > "$LINKS.tmp"
  echo "$1|$2" >> "$LINKS.tmp"
  mv "$LINKS.tmp" "$LINKS"
}

# Nhận: Place ID / link game / link private server / link share / roblox://
parse_link() {
  local s="${1// /}"
  if   [[ "$s" =~ ^[0-9]+$ ]]; then echo "roblox://placeId=$s"
  elif [[ "$s" == roblox://* ]]; then echo "$s"
  elif [[ "$s" =~ share\?code=([A-Za-z0-9]+) ]]; then
       echo "roblox://navigation/share_links?code=${BASH_REMATCH[1]}&type=Server"
  elif [[ "$s" =~ games/([0-9]+).*privateServerLinkCode=([A-Za-z0-9_-]+) ]]; then
       echo "roblox://placeId=${BASH_REMATCH[1]}&linkCode=${BASH_REMATCH[2]}"
  elif [[ "$s" =~ games/([0-9]+) ]]; then echo "roblox://placeId=${BASH_REMATCH[1]}"
  else return 1; fi
}

ask_link() {   # $1 = lời nhắc, $2 = link hiện tại (Enter để giữ)
  local in out
  while true; do
    read -r -p "$1" in
    if [ -z "$in" ] && [ -n "$2" ]; then echo "$2"; return; fi
    if out=$(parse_link "$in"); then echo "$out"; return; fi
    echo "${R}Link không hợp lệ. Dán Place ID, link game, link private server hoặc link share.${N}" >&2
  done
}

# ---------------- Tiện ích ----------------
log() { echo "[$(date '+%m-%d %H:%M:%S')] $*"; }
list_roblox() { pm list packages 2>/dev/null | sed 's/^package://' | grep -i roblox | sort; }
app_running() { pidof "$1" >/dev/null 2>&1; }
app_foreground() { dumpsys window windows 2>/dev/null | grep -E 'mCurrentFocus|mFocusedApp' | grep -q "$1"; }

ram_free()  { awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo; }
ram_total() { awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo; }

# Trong khung giờ chạy? (hỗ trợ qua đêm, vd 22 -> 8)
in_schedule() {
  [ -z "$SCH_START" ] || [ -z "$SCH_END" ] && return 0
  [ "$SCH_START" = "$SCH_END" ] && return 0
  local h=$((10#$(date +%H)))
  if [ "$SCH_START" -lt "$SCH_END" ]; then
    [ "$h" -ge "$SCH_START" ] && [ "$h" -lt "$SCH_END" ]
  else
    [ "$h" -ge "$SCH_START" ] || [ "$h" -lt "$SCH_END" ]
  fi
}

# Gửi Discord (chạy nền, không làm chậm vòng lặp)
json_escape() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }
notify() {
  [ -z "$WEBHOOK" ] && return 0
  local msg; msg=$(json_escape "**[$DEV_NAME]** $1")
  curl -s -m 15 -H "Content-Type: application/json" \
       -d "{\"content\":\"$msg\"}" "$WEBHOOK" >/dev/null 2>&1 &
}

# ---- Phát hiện bị kick / mất kết nối ----
# Cách 1: log của Roblox có dòng ngắt kết nối (sau lần mở gần nhất)
KICK_RE='Disconnection Notification|Sending disconnect with reason|Lost connection|Connection lost|You were kicked|leaveUGCGame'
newest_log() { ls -t /data/data/$1/files/appData/logs/*.log 2>/dev/null | head -n1; }
log_kicked() {   # $1 = package, $2 = thời điểm mở
  local f m; f=$(newest_log "$1"); [ -z "$f" ] && return 1
  m=$(stat -c %Y "$f" 2>/dev/null); [ "${m:-0}" -lt "${2:-0}" ] && return 1
  grep -qiE "$KICK_RE" "$f"
}
# Cách 2: khi đang trong game, Roblox giữ kết nối UDP tới server game.
udp_count() {    # số socket UDP của app (bỏ DNS:53 và QUIC:443)
  local uid; uid=$(stat -c %u "/data/data/$1" 2>/dev/null) || { echo -1; return; }
  awk -v u="$uid" 'FNR>1 && $8==u { split($3,r,":"); if (r[2]!="0035" && r[2]!="01BB") c++ }
                   END { print c+0 }' /proc/net/udp /proc/net/udp6 2>/dev/null
}

open_app() {   # $1 = package, $2 = giây chờ
  local link; link=$(get_link "$1")
  if [ -z "$link" ]; then log "[$1] Chưa gán link, bỏ qua"; return 1; fi
  log "[$1] Mở game"
  am force-stop "$1"; sleep 2
  am start -a android.intent.action.VIEW -d "$link" -p "$1" >/dev/null 2>&1
  sleep "${2:-0}"
}

# ---------------- Vòng lặp rejoin (chạy ngầm) ----------------
declare -A STARTED NOUDP FAILS NEXT

# Rejoin có chống lặp: nếu app lại hỏng trong vòng 3 phút sau lần mở trước
# thì tính là 1 lần lỗi. Lỗi liên tiếp >= BACKOFF_AFTER -> chờ 1, 2, 4, 8... phút (tối đa 30).
rejoin_app() {   # $1 = package, $2 = lý do
  local p="$1" reason="$2" now; now=$(date +%s)
  if [ $(( now - ${STARTED[$p]:-0} )) -lt 180 ]; then
    FAILS[$p]=$(( ${FAILS[$p]:-0} + 1 ))
  else
    FAILS[$p]=0
  fi
  if [ "${FAILS[$p]}" -ge "$BACKOFF_AFTER" ]; then
    local e=$(( FAILS[$p] - BACKOFF_AFTER )) w
    [ "$e" -gt 5 ] && e=5
    w=$(( 60 * (1 << e) )); [ "$w" -gt 1800 ] && w=1800
    NEXT[$p]=$(( now + w ))
    am force-stop "$p"
    log "[$p] $reason - lỗi ${FAILS[$p]} lần liền -> chờ $((w/60)) phút rồi thử lại"
    notify "⏳ \`$p\` lỗi ${FAILS[$p]} lần liền ($reason) — chờ $((w/60)) phút rồi thử lại"
    return
  fi
  log "[$p] $reason -> rejoin"
  notify "🔄 \`$p\` $reason → rejoin"
  open_app "$p" "$LAUNCH_WAIT"
  STARTED[$p]=$(date +%s); NOUDP[$p]=""
}

run_loop() {
  load_conf
  echo $$ > "$PIDF"
  read -r -a APPS <<< "$SELECTED"
  [ ${#APPS[@]} -eq 0 ] && { log "Chưa chọn app nào"; exit 1; }
  local COUNT=${#APPS[@]} p now PAUSED=0 LAST_RAM_WARN=0 free

  log "=== Bắt đầu: $COUNT app | kiểm tra ${CHECK_EVERY}s | kill+rejoin ${RESTART_EVERY} phút ==="
  notify "▶️ Bắt đầu auto rejoin $COUNT acc"
  if in_schedule; then
    for p in "${APPS[@]}"; do open_app "$p" "$LAUNCH_WAIT"; STARTED[$p]=$(date +%s); done
  else
    PAUSED=1; log "Ngoài giờ chạy ($SCH_START h → $SCH_END h), chờ tới giờ"
  fi

  while true; do
    now=$(date +%s)

    # --- Hẹn giờ ---
    if ! in_schedule; then
      if [ "$PAUSED" != "1" ]; then
        PAUSED=1
        for p in "${APPS[@]}"; do am force-stop "$p"; done
        log "Ngoài giờ chạy -> đóng tất cả game"
        notify "🌙 Hết giờ chạy ($SCH_START h → $SCH_END h), đã đóng game"
      fi
      sleep 60; continue
    elif [ "$PAUSED" = "1" ]; then
      PAUSED=0
      log "Tới giờ chạy -> mở lại game"
      notify "☀️ Tới giờ chạy, mở lại $COUNT acc"
      for p in "${APPS[@]}"; do open_app "$p" "$LAUNCH_WAIT"; STARTED[$p]=$(date +%s); FAILS[$p]=0; NEXT[$p]=""; done
      continue
    fi

    # --- RAM ---
    free=$(ram_free)
    if [ "${free:-9999}" -lt "$RAM_MIN" ] && [ $(( now - LAST_RAM_WARN )) -ge 1800 ]; then
      LAST_RAM_WARN=$now
      log "⚠ RAM thấp: còn ${free} MB"
      notify "⚠️ RAM thấp: còn ${free} MB / $(ram_total) MB — nên giảm số clone"
    fi

    # --- Từng app ---
    for p in "${APPS[@]}"; do
      now=$(date +%s)
      # Đang trong thời gian chờ (chống rejoin liên tục)
      if [ -n "${NEXT[$p]}" ]; then
        if [ "$now" -lt "${NEXT[$p]}" ]; then continue; fi
        NEXT[$p]=""
        log "[$p] Hết thời gian chờ -> thử lại"
        open_app "$p" "$LAUNCH_WAIT"; STARTED[$p]=$(date +%s); NOUDP[$p]=""
        continue
      fi

      if ! app_running "$p"; then
        rejoin_app "$p" "crash / bị tắt"
      elif [ "$COUNT" -eq 1 ] && ! app_foreground "$p"; then
        rejoin_app "$p" "bị đẩy ra nền"
      elif [ "$RESTART_EVERY" -gt 0 ] && [ $(( now - ${STARTED[$p]:-now} )) -ge $(( RESTART_EVERY * 60 )) ]; then
        log "[$p] Đủ $RESTART_EVERY phút -> kill + rejoin"
        open_app "$p" "$LAUNCH_WAIT"; STARTED[$p]=$(date +%s); NOUDP[$p]=""
      elif [ "$KICK_DETECT" = "1" ]; then
        if log_kicked "$p" "${STARTED[$p]:-0}"; then
          rejoin_app "$p" "bị kick / mất kết nối (log)"
        elif [ "$(udp_count "$p")" = "0" ]; then
          [ -z "${NOUDP[$p]}" ] && NOUDP[$p]=$now
          if [ $(( now - NOUDP[$p] )) -ge "$KICK_GRACE" ]; then
            rejoin_app "$p" "mất kết nối server ${KICK_GRACE}s (kick/disconnect)"
          fi
        else
          NOUDP[$p]=""
          # Ổn định > 5 phút trong game -> xoá bộ đếm lỗi
          [ $(( now - ${STARTED[$p]:-now} )) -ge 300 ] && FAILS[$p]=0
        fi
      fi
    done
    sleep "$CHECK_EVERY"
  done
}

bg_running() { [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; }

boot_state() {
  if [ -f "$SD_BOOT" ]; then echo "${G}Bật (service.d)${N}"
  elif [ -f "$TB_BOOT" ]; then echo "${G}Bật (Termux:Boot)${N}"
  else echo "${R}Tắt${N}"; fi
}

pause() { read -r -p "${D}Enter để quay lại menu...${N}" _; }
onoff() { [ "$1" = "1" ] && echo "${G}Bật${N}" || echo "${R}Tắt${N}"; }

# ---------------- Chức năng menu ----------------
start_rejoin() {
  load_conf
  if bg_running; then echo "${Y}Auto rejoin đang chạy rồi.${N}"; return; fi
  [ -z "$SELECTED" ] && { echo "${R}Chưa chọn app. Dùng mục 4 hoặc 6 trước.${N}"; return; }
  local p miss=""
  for p in $SELECTED; do [ -z "$(get_link "$p")" ] && miss="$miss $p"; done
  [ -n "$miss" ] && { echo "${R}Chưa gán link cho:${N}$miss"; return; }
  setsid nohup "$T/usr/bin/bash" "$SELF" --run >> "$LOG" 2>&1 < /dev/null &
  sleep 1
  echo "${G}✔ Đã bắt đầu auto rejoin (chạy ngầm). Xem log ở mục 3.${N}"
}

stop_rejoin() {
  load_conf
  if bg_running; then
    local pid; pid=$(cat "$PIDF")
    pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null
    notify "⏹️ Đã dừng auto rejoin"
  fi
  pkill -f "rejoin.sh --run" 2>/dev/null; pkill -f "rejoin.sh --auto" 2>/dev/null
  rm -f "$PIDF"
  echo "${G}✔ Đã dừng auto rejoin.${N}"
}

view_log() {
  echo "${D}Ctrl+C để quay lại menu${N}"
  trap 'true' INT
  tail -n 30 -f "$LOG"
  trap - INT
}

select_apps() {
  load_conf
  mapfile -t PKGS < <(list_roblox)
  [ ${#PKGS[@]} -eq 0 ] && { echo "${R}Không tìm thấy app Roblox nào.${N}"; return; }
  echo "${C}Các app Roblox trên máy:${N}"
  local i
  for i in "${!PKGS[@]}"; do printf "  ${M}%2d${N}) %s\n" "$((i+1))" "${PKGS[$i]}"; done
  read -r -p "Chọn số (vd: 1 3 4) hoặc 'a' = tất cả: " choice
  local sel=""
  if [ "$choice" = "a" ] || [ "$choice" = "A" ]; then sel="${PKGS[*]}"
  else
    for n in $choice; do
      [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le ${#PKGS[@]} ] && sel="$sel ${PKGS[$((n-1))]}"
    done
  fi
  sel=$(echo $sel)
  [ -z "$sel" ] && { echo "${R}Chưa chọn app nào.${N}"; return; }

  read -r -p "Dùng chung 1 link cho tất cả app vừa chọn? (Y/n): " same
  local p link
  if [ "$same" = "n" ] || [ "$same" = "N" ]; then
    for p in $sel; do
      link=$(ask_link "Link cho ${Y}$p${N} (Enter = giữ link cũ): " "$(get_link "$p")")
      set_link "$p" "$link"
    done
  else
    link=$(ask_link "Dán link server / Place ID: " "")
    for p in $sel; do set_link "$p" "$link"; done
  fi
  SELECTED="$sel"; save_conf
  echo "${G}✔ Đã lưu cho: $sel${N}"
  bg_running && echo "${Y}Đang chạy: dừng rồi bắt đầu lại để áp dụng.${N}"
}

list_selected() {
  load_conf
  [ -z "$SELECTED" ] && { echo "${R}Chưa chọn app nào.${N}"; return; }
  local p st
  for p in $SELECTED; do
    app_running "$p" && st="${G}đang mở${N}" || st="${D}đã đóng${N}"
    echo "${Y}$p${N} [$st]"
    echo "   ${D}$(get_link "$p")${N}"
  done
}

select_all() {
  load_conf
  mapfile -t PKGS < <(list_roblox)
  [ ${#PKGS[@]} -eq 0 ] && { echo "${R}Không tìm thấy app Roblox nào.${N}"; return; }
  echo "Tìm thấy ${#PKGS[@]} app: ${PKGS[*]}"
  local link p; link=$(ask_link "Dán link server / Place ID: " "")
  for p in "${PKGS[@]}"; do set_link "$p" "$link"; done
  SELECTED="${PKGS[*]}"; save_conf
  echo "${G}✔ Đã chọn tất cả ${#PKGS[@]} app.${N}"
}

open_all() {
  load_conf
  [ -z "$SELECTED" ] && { echo "${R}Chưa chọn app nào.${N}"; return; }
  local p; for p in $SELECTED; do open_app "$p" 5; done
  echo "${G}✔ Đã mở tất cả (không theo dõi).${N}"
}

close_all() {
  bg_running && stop_rejoin
  local p; for p in $(list_roblox); do am force-stop "$p"; done
  echo "${G}✔ Đã đóng tất cả app Roblox.${N}"
}

webhook_menu() {
  load_conf
  local v
  echo "${C}Thông báo Discord${N}"
  if [ -n "$WEBHOOK" ]; then echo "Webhook : ${G}đã đặt${N} ${D}(...${WEBHOOK: -8})${N}"; else echo "Webhook : ${R}chưa đặt${N}"; fi
  echo "Tên máy : ${Y}$DEV_NAME${N}"
  echo " ${M}1${N} Đặt link webhook"
  echo " ${M}2${N} Gửi tin nhắn thử"
  echo " ${M}3${N} Đổi tên máy (hiện trong thông báo)"
  echo " ${M}4${N} Xoá webhook (tắt thông báo)"
  read -r -p "Chọn: " v
  case "$v" in
    1) read -r -p "Dán link webhook: " v
       if [[ "$v" =~ ^https://(discord|discordapp|canary\.discord|ptb\.discord)\.com/api/webhooks/ ]]; then
         WEBHOOK="$v"; save_conf; echo "${G}✔ Đã lưu. Thử gửi ở mục 2.${N}"
       else echo "${R}Link không đúng dạng https://discord.com/api/webhooks/...${N}"; fi ;;
    2) [ -z "$WEBHOOK" ] && { echo "${R}Chưa đặt webhook.${N}"; return; }
       local msg code; msg=$(json_escape "**[$DEV_NAME]** ✅ Saba Rejoin kết nối Discord thành công")
       code=$(curl -s -m 15 -o /dev/null -w '%{http_code}' -H "Content-Type: application/json" \
              -d "{\"content\":\"$msg\"}" "$WEBHOOK")
       if [ "$code" = "204" ] || [ "$code" = "200" ]; then echo "${G}✔ Đã gửi! Kiểm tra kênh Discord.${N}"
       else echo "${R}Gửi thất bại (mã $code). Kiểm tra lại link hoặc mạng.${N}"; fi ;;
    3) read -r -p "Tên máy mới: " v; [ -n "$v" ] && { DEV_NAME="$v"; save_conf; echo "${G}✔ Đã lưu.${N}"; } ;;
    4) WEBHOOK=""; save_conf; echo "${G}✔ Đã tắt thông báo Discord.${N}" ;;
  esac
  bg_running && echo "${Y}Đang chạy: dừng rồi bắt đầu lại để áp dụng.${N}"
}

config_menu() {
  load_conf
  local v
  echo "${C}Enter = giữ nguyên${N}"
  read -r -p "Giây giữa mỗi lần kiểm tra [$CHECK_EVERY]: " v; [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge 5 ] && CHECK_EVERY=$v
  read -r -p "Giây chờ game load sau khi mở [$LAUNCH_WAIT]: " v; [[ "$v" =~ ^[0-9]+$ ]] && LAUNCH_WAIT=$v
  read -r -p "Bao nhiêu phút thì kill + rejoin (0 = tắt) [$RESTART_EVERY]: " v; [[ "$v" =~ ^[0-9]+$ ]] && RESTART_EVERY=$v
  read -r -p "Rejoin khi bị kick/disconnect? 1=bật 0=tắt [$KICK_DETECT]: " v; [[ "$v" =~ ^[01]$ ]] && KICK_DETECT=$v
  read -r -p "Mất kết nối bao nhiêu giây thì coi là bị kick [$KICK_GRACE]: " v; [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge 15 ] && KICK_GRACE=$v
  read -r -p "Lỗi liên tiếp bao nhiêu lần thì bắt đầu chờ lâu dần [$BACKOFF_AFTER]: " v; [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge 1 ] && BACKOFF_AFTER=$v
  read -r -p "Cảnh báo khi RAM trống dưới bao nhiêu MB [$RAM_MIN]: " v; [[ "$v" =~ ^[0-9]+$ ]] && RAM_MIN=$v
  save_conf
  echo "${G}✔ Đã lưu.${N}"
  bg_running && echo "${Y}Đang chạy: dừng rồi bắt đầu lại để áp dụng.${N}"
}

schedule_menu() {
  load_conf
  local a b
  if [ -n "$SCH_START" ]; then echo "Hiện tại: chạy từ ${Y}${SCH_START}h${N} đến ${Y}${SCH_END}h${N}"
  else echo "Hiện tại: ${Y}chạy cả ngày${N}"; fi
  echo "${D}Ví dụ: bắt đầu 22, kết thúc 8 = chạy qua đêm từ 22h tới 8h sáng.${N}"
  read -r -p "Giờ bắt đầu (0-23, Enter = chạy cả ngày): " a
  if [ -z "$a" ]; then SCH_START=""; SCH_END=""; save_conf; echo "${G}✔ Chạy cả ngày.${N}"; return; fi
  read -r -p "Giờ kết thúc (0-23): " b
  if [[ "$a" =~ ^[0-9]+$ ]] && [[ "$b" =~ ^[0-9]+$ ]] && [ "$a" -le 23 ] && [ "$b" -le 23 ]; then
    SCH_START=$((10#$a)); SCH_END=$((10#$b)); save_conf
    echo "${G}✔ Chạy từ ${SCH_START}h đến ${SCH_END}h. Ngoài giờ này game sẽ được đóng.${N}"
  else echo "${R}Giờ không hợp lệ.${N}"; fi
  bg_running && echo "${Y}Đang chạy: dừng rồi bắt đầu lại để áp dụng.${N}"
}

kick_debug() {
  load_conf
  [ -z "$SELECTED" ] && { echo "${R}Chưa chọn app nào.${N}"; return; }
  echo "${C}Đang trong game thì UDP > 0. Khi hiện bảng kick/Disconnected thì UDP về 0.${N}"
  local p f
  for p in $SELECTED; do
    echo "${Y}$p${N}"
    app_running "$p" && echo "  App     : ${G}đang chạy${N}" || echo "  App     : ${R}không chạy${N}"
    echo "  UDP game: $(udp_count "$p")"
    f=$(newest_log "$p")
    if [ -n "$f" ]; then
      echo "  Log     : $(basename "$f")"
      echo "  Kick log: $(grep -iE "$KICK_RE" "$f" | tail -n1 | cut -c1-120)"
    else
      echo "  Log     : ${D}không tìm thấy (chỉ dùng cách UDP)${N}"
    fi
  done
}

toggle_boot() {
  if [ -f "$SD_BOOT" ] || [ -f "$TB_BOOT" ]; then
    rm -f "$SD_BOOT" "$TB_BOOT"
    echo "${G}✔ Đã TẮT tự chạy khi khởi động.${N}"; return
  fi
  load_conf
  [ -z "$SELECTED" ] && { echo "${R}Chọn app (mục 4/6) trước đã.${N}"; return; }
  if [ -d /data/adb ]; then
    mkdir -p /data/adb/service.d
    cat > "$SD_BOOT" <<EOF
#!/system/bin/sh
until [ "\$(getprop sys.boot_completed)" = "1" ]; do sleep 5; done
sleep 40
LD_LIBRARY_PATH=$T/usr/lib $T/usr/bin/bash $SELF --run >> $LOG 2>&1 &
EOF
    chmod 755 "$SD_BOOT"
    echo "${G}✔ Đã BẬT tự chạy khi khởi động (Magisk/KernelSU).${N}"
  else
    mkdir -p "$(dirname "$TB_BOOT")"
    cat > "$TB_BOOT" <<EOF
#!$T/usr/bin/bash
termux-wake-lock 2>/dev/null
sleep 40
su -c "LD_LIBRARY_PATH=$T/usr/lib $T/usr/bin/bash $SELF --run >> $LOG 2>&1"
EOF
    chmod 755 "$TB_BOOT"; chown "$(stat -c %u "$T/home")" "$TB_BOOT" "$(dirname "$TB_BOOT")" 2>/dev/null
    echo "${G}✔ Đã BẬT qua Termux:Boot.${N} Cần cài app Termux:Boot (cùng nguồn với Termux) và mở nó 1 lần."
  fi
}

update_tool() {
  load_conf
  local v tmp="$DIR/rejoin.new"
  echo "${C}Cập nhật từ file rejoin.sh trên GitHub của bạn${N}"
  echo "${D}Dạng: https://raw.githubusercontent.com/<tên>/<repo>/main/rejoin.sh${N}"
  read -r -p "Link [${UPDATE_URL:-chưa đặt}] (Enter = giữ): " v
  [ -n "$v" ] && UPDATE_URL="$v"
  [ -z "$UPDATE_URL" ] && { echo "${R}Chưa có link.${N}"; return; }
  save_conf
  echo "Đang tải..."
  if ! curl -fsSL -m 30 "$UPDATE_URL" -o "$tmp"; then echo "${R}Tải thất bại. Kiểm tra link/mạng.${N}"; rm -f "$tmp"; return; fi
  if ! grep -q "Saba Rejoin" "$tmp" || ! "$T/usr/bin/bash" -n "$tmp" 2>/dev/null; then
    echo "${R}File tải về không phải Saba Rejoin hoặc bị lỗi. Không cập nhật.${N}"; rm -f "$tmp"; return
  fi
  if cmp -s "$tmp" "$SELF"; then echo "${G}Đang là bản mới nhất.${N}"; rm -f "$tmp"; return; fi
  local was=0; bg_running && { was=1; stop_rejoin >/dev/null; }
  cp "$SELF" "$DIR/rejoin.bak"; mv "$tmp" "$SELF"; chmod 755 "$SELF"
  echo "${G}✔ Đã cập nhật! (bản cũ lưu ở rejoin.bak)${N}"
  if [ "$was" = "1" ]; then
    setsid nohup "$T/usr/bin/bash" "$SELF" --run >> "$LOG" 2>&1 < /dev/null &
    echo "${G}✔ Đã chạy lại auto rejoin với bản mới.${N}"
  fi
  sleep 2
  exec "$T/usr/bin/bash" "$SELF"
}

# ---------------- Menu ----------------
menu() {
  while true; do
    load_conf
    local st n=0 free total sch
    bg_running && st="${G}● Đang chạy${N}" || st="${R}○ Đã dừng${N}"
    [ -n "$SELECTED" ] && n=$(echo $SELECTED | wc -w)
    free=$(ram_free); total=$(ram_total)
    if [ "${free:-0}" -lt "$RAM_MIN" ]; then free="${R}${free}${N}"; else free="${G}${free}${N}"; fi
    if [ -n "$SCH_START" ]; then sch="${SCH_START}h → ${SCH_END}h"; else sch="cả ngày"; fi
    clear
    echo "${BD}${C}⚡ Saba Rejoin${N}"
    echo "Trạng thái  : $st"
    echo "App đã chọn : ${Y}$n${N}"
    echo "RAM trống   : $free / $total MB"
    echo "Kill+rejoin : ${Y}$([ "$RESTART_EVERY" -gt 0 ] 2>/dev/null && echo "mỗi $RESTART_EVERY phút" || echo "tắt")${N}"
    echo "Rejoin kick : $(onoff "$KICK_DETECT")"
    echo "Giờ chạy    : ${Y}$sch${N}"
    echo "Discord     : $([ -n "$WEBHOOK" ] && echo "${G}Bật${N}" || echo "${R}Tắt${N}")"
    echo "Tự khởi động: $(boot_state)"
    echo "${D}──────────────────────────────${N}"
    echo "${B}— Auto Rejoin —${N}"
    echo " ${M}1${N}  Bắt đầu auto rejoin"
    echo " ${M}2${N}  Dừng auto rejoin"
    echo " ${M}3${N}  Xem log trực tiếp"
    echo "${B}— Server Setup —${N}"
    echo " ${M}4${N}  Chọn app & gán link server"
    echo " ${M}5${N}  Xem app đã chọn"
    echo " ${M}6${N}  Chọn tất cả app Roblox (1 link)"
    echo "${B}— Tabs —${N}"
    echo " ${M}7${N}  Mở tất cả app đã chọn"
    echo " ${M}8${N}  Đóng tất cả app Roblox"
    echo "${B}— Thông báo —${N}"
    echo " ${M}9${N}  Discord webhook"
    echo "${B}— System —${N}"
    echo " ${M}10${N} Cấu hình (thời gian, kick, chống lặp, RAM)"
    echo " ${M}11${N} Hẹn giờ chạy"
    echo " ${M}12${N} Bật/Tắt tự chạy khi khởi động"
    echo " ${M}13${N} Kiểm tra phát hiện kick"
    echo " ${M}14${N} Cập nhật tool"
    echo " ${R}0${N}  Thoát ${D}(auto rejoin vẫn chạy ngầm)${N}"
    echo "${D}──────────────────────────────${N}"
    read -r -p "${M}Chọn: ${N}" c
    echo
    case "$c" in
      1) start_rejoin; pause ;;
      2) stop_rejoin; pause ;;
      3) view_log ;;
      4) select_apps; pause ;;
      5) list_selected; pause ;;
      6) select_all; pause ;;
      7) open_all; pause ;;
      8) close_all; pause ;;
      9) webhook_menu; pause ;;
      10) config_menu; pause ;;
      11) schedule_menu; pause ;;
      12) toggle_boot; pause ;;
      13) kick_debug; pause ;;
      14) update_tool; pause ;;
      0) exit 0 ;;
    esac
  done
}

# ---------------- Bắt đầu ----------------
if [ "$(id -u)" != "0" ]; then echo "Cần root. Chạy bằng lệnh: rejoin"; exit 1; fi
case "$1" in
  --run|--auto) run_loop ;;
  *) menu ;;
esac
