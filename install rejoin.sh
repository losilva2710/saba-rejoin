#!/data/data/com.termux/files/usr/bin/bash
# ===== Saba Rejoin installer / Bộ cài Saba Rejoin =====
# bash <(curl -sL https://raw.githubusercontent.com/losilva2710/saba-rejoin/main/install_rejoin.sh)
T="/data/data/com.termux/files"
DIR="$T/home/rejoin"
ok()   { echo "✔ $*"; }
fail() { echo "✘ $*"; exit 1; }

echo "=== Saba Rejoin - Install / Cài đặt ==="
su -c "id -u" 2>/dev/null | grep -q '^0$' || fail "No root access. Grant root to Termux and run again. / Không có root. Cấp quyền root cho Termux rồi chạy lại."
ok "Root OK"

for p in bash coreutils grep sed gawk procps curl sqlite; do
  dpkg -s "$p" >/dev/null 2>&1 || NEED="$NEED $p"
done
if [ -n "$NEED" ]; then
  echo "Installing / Đang cài:$NEED"
  yes | pkg install -y $NEED >/dev/null 2>&1 || fail "Package install failed, check network. / Cài gói thất bại, kiểm tra mạng."
fi
ok "Packages OK / Đủ gói cần thiết"

# Stop old version if running / Dừng bản cũ nếu đang chạy
su -c "pkill -f 'rejoin.sh --run'; pkill -f 'rejoin.sh --auto'" 2>/dev/null

mkdir -p "$DIR"
cat > "$DIR/rejoin.sh" <<'REJOIN_EOF'
#!/data/data/com.termux/files/usr/bin/bash
# ===== Saba Rejoin - Roblox auto rejoin menu (Termux + root) =====
# Menu:        rejoin
# Background:  rejoin.sh --run   (used by the menu and by auto start on boot)
# Language:    Tiếng Việt / English (Settings)

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

# ---------------- Defaults ----------------
UI_LANG=""           # vi / en
SELECTED=""
CHECK_EVERY=15       # seconds between checks
LAUNCH_WAIT=30       # seconds to wait after opening an app
RESTART_EVERY=0      # minutes for periodic kill + rejoin (0 = off)
KICK_DETECT=1        # rejoin on kick / disconnect
KICK_GRACE=60        # seconds without connection = kicked
BACKOFF_AFTER=3      # consecutive failures before waiting longer
RAM_MIN=500          # MB: warn below this
SCH_START=""         # start hour (0-23), empty = all day
SCH_END=""           # stop hour
WEBHOOK=""           # Discord webhook
DEV_NAME=""          # device name shown in notifications
DEFAULT_UPDATE_URL="https://raw.githubusercontent.com/losilva2710/saba-rejoin/main/rejoin.sh"
UPDATE_URL=""        # empty = DEFAULT_UPDATE_URL

mkdir -p "$DIR"; touch "$LINKS"

# t "tiếng việt" "english"
t() { if [ "$UI_LANG" = "en" ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }

# ---------------- Config ----------------
load_conf() {
  [ -f "$CONF" ] && . "$CONF"
  [ -z "$DEV_NAME" ] && DEV_NAME=$(getprop ro.product.model 2>/dev/null)
  [ -z "$UPDATE_URL" ] && UPDATE_URL="$DEFAULT_UPDATE_URL"
}
save_conf() {
  cat > "$CONF" <<EOF
UI_LANG="$UI_LANG"
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

# Accepts: Place ID / game link / private server link / share link / roblox://
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

ask_link() {   # $1 = prompt, $2 = current link (Enter keeps it)
  local in out
  while true; do
    read -r -p "$1" in
    if [ -z "$in" ] && [ -n "$2" ]; then echo "$2"; return; fi
    if out=$(parse_link "$in"); then echo "$out"; return; fi
    echo "${R}$(t 'Link không hợp lệ. Dán Place ID, link game, link private server hoặc link share.' 'Invalid link. Paste a Place ID, game link, private server link or share link.')${N}" >&2
  done
}

# ---------------- Utilities ----------------
log() { echo "[$(date '+%m-%d %H:%M:%S')] $*"; }
list_roblox() { pm list packages 2>/dev/null | sed 's/^package://' | grep -i roblox | sort; }
app_running() { pidof "$1" >/dev/null 2>&1; }
app_foreground() { dumpsys window windows 2>/dev/null | grep -E 'mCurrentFocus|mFocusedApp' | grep -q "$1"; }

ram_free()  { awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo; }
ram_total() { awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo; }

# Inside the run window? (supports overnight, e.g. 22 -> 8)
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

# Discord (sent in background so the loop is not slowed down)
json_escape() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }
notify() {
  [ -z "$WEBHOOK" ] && return 0
  local msg; msg=$(json_escape "**[$DEV_NAME]** $1")
  curl -s -m 15 -H "Content-Type: application/json" \
       -d "{\"content\":\"$msg\"}" "$WEBHOOK" >/dev/null 2>&1 &
}

# ---- Kick / disconnect detection ----
# Method 1: Roblox log contains a disconnect line (since the last launch)
KICK_RE='Disconnection Notification|Sending disconnect with reason|Lost connection|Connection lost|You were kicked|leaveUGCGame'
newest_log() { ls -t /data/data/$1/files/appData/logs/*.log 2>/dev/null | head -n1; }
log_kicked() {   # $1 = package, $2 = launch time
  local f m; f=$(newest_log "$1"); [ -z "$f" ] && return 1
  m=$(stat -c %Y "$f" 2>/dev/null); [ "${m:-0}" -lt "${2:-0}" ] && return 1
  grep -qiE "$KICK_RE" "$f"
}
# Method 2: while in game, Roblox keeps a UDP connection to the game server.
udp_count() {    # app UDP sockets (ignoring DNS:53 and QUIC:443)
  local uid; uid=$(stat -c %u "/data/data/$1" 2>/dev/null) || { echo -1; return; }
  awk -v u="$uid" 'FNR>1 && $8==u { split($3,r,":"); if (r[2]!="0035" && r[2]!="01BB") c++ }
                   END { print c+0 }' /proc/net/udp /proc/net/udp6 2>/dev/null
}

open_app() {   # $1 = package, $2 = seconds to wait
  local link; link=$(get_link "$1")
  if [ -z "$link" ]; then log "[$1] $(t 'Chưa gán link, bỏ qua' 'No link assigned, skipping')"; return 1; fi
  log "[$1] $(t 'Mở game' 'Opening game')"
  am force-stop "$1"; sleep 2
  am start -a android.intent.action.VIEW -d "$link" -p "$1" >/dev/null 2>&1
  sleep "${2:-0}"
}

# ---------------- Rejoin loop (background) ----------------
declare -A STARTED NOUDP FAILS NEXT

# Anti-loop: failing again within 3 minutes of the last launch counts as a failure.
# After BACKOFF_AFTER failures in a row -> wait 1, 2, 4, 8... minutes (max 30).
rejoin_app() {   # $1 = package, $2 = reason
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
    log "[$p] $reason - $(t "lỗi ${FAILS[$p]} lần liền -> chờ $((w/60)) phút rồi thử lại" "failed ${FAILS[$p]} times in a row -> waiting $((w/60)) min before retry")"
    notify "⏳ \`$p\` $(t "lỗi ${FAILS[$p]} lần liền ($reason) — chờ $((w/60)) phút rồi thử lại" "failed ${FAILS[$p]} times in a row ($reason) — retrying in $((w/60)) min")"
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
  [ ${#APPS[@]} -eq 0 ] && { log "$(t 'Chưa chọn app nào' 'No apps selected')"; exit 1; }
  local COUNT=${#APPS[@]} p now PAUSED=0 LAST_RAM_WARN=0 free

  log "=== $(t "Bắt đầu: $COUNT app | kiểm tra ${CHECK_EVERY}s | kill+rejoin ${RESTART_EVERY} phút" "Started: $COUNT apps | check ${CHECK_EVERY}s | kill+rejoin ${RESTART_EVERY} min") ==="
  notify "▶️ $(t "Bắt đầu auto rejoin $COUNT acc" "Auto rejoin started for $COUNT accounts")"
  if in_schedule; then
    for p in "${APPS[@]}"; do open_app "$p" "$LAUNCH_WAIT"; STARTED[$p]=$(date +%s); done
  else
    PAUSED=1; log "$(t "Ngoài giờ chạy ($SCH_START h → $SCH_END h), chờ tới giờ" "Outside run hours ($SCH_START h → $SCH_END h), waiting")"
  fi

  while true; do
    now=$(date +%s)

    # --- Schedule ---
    if ! in_schedule; then
      if [ "$PAUSED" != "1" ]; then
        PAUSED=1
        for p in "${APPS[@]}"; do am force-stop "$p"; done
        log "$(t 'Ngoài giờ chạy -> đóng tất cả game' 'Outside run hours -> closing all games')"
        notify "🌙 $(t "Hết giờ chạy ($SCH_START h → $SCH_END h), đã đóng game" "Run hours over ($SCH_START h → $SCH_END h), games closed")"
      fi
      sleep 60; continue
    elif [ "$PAUSED" = "1" ]; then
      PAUSED=0
      log "$(t 'Tới giờ chạy -> mở lại game' 'Run hours started -> reopening games')"
      notify "☀️ $(t "Tới giờ chạy, mở lại $COUNT acc" "Run hours started, reopening $COUNT accounts")"
      for p in "${APPS[@]}"; do open_app "$p" "$LAUNCH_WAIT"; STARTED[$p]=$(date +%s); FAILS[$p]=0; NEXT[$p]=""; done
      continue
    fi

    # --- RAM ---
    free=$(ram_free)
    if [ "${free:-9999}" -lt "$RAM_MIN" ] && [ $(( now - LAST_RAM_WARN )) -ge 1800 ]; then
      LAST_RAM_WARN=$now
      log "⚠ $(t "RAM thấp: còn ${free} MB" "Low RAM: ${free} MB free")"
      notify "⚠️ $(t "RAM thấp: còn ${free} MB / $(ram_total) MB — nên giảm số clone" "Low RAM: ${free} MB / $(ram_total) MB free — consider fewer clones")"
    fi

    # --- Each app ---
    for p in "${APPS[@]}"; do
      now=$(date +%s)
      # Waiting (anti-loop)
      if [ -n "${NEXT[$p]}" ]; then
        if [ "$now" -lt "${NEXT[$p]}" ]; then continue; fi
        NEXT[$p]=""
        log "[$p] $(t 'Hết thời gian chờ -> thử lại' 'Wait over -> retrying')"
        open_app "$p" "$LAUNCH_WAIT"; STARTED[$p]=$(date +%s); NOUDP[$p]=""
        continue
      fi

      if ! app_running "$p"; then
        rejoin_app "$p" "$(t 'crash / bị tắt' 'crashed / closed')"
      elif [ "$COUNT" -eq 1 ] && ! app_foreground "$p"; then
        rejoin_app "$p" "$(t 'bị đẩy ra nền' 'sent to background')"
      elif [ "$RESTART_EVERY" -gt 0 ] && [ $(( now - ${STARTED[$p]:-now} )) -ge $(( RESTART_EVERY * 60 )) ]; then
        log "[$p] $(t "Đủ $RESTART_EVERY phút -> kill + rejoin" "$RESTART_EVERY min reached -> kill + rejoin")"
        open_app "$p" "$LAUNCH_WAIT"; STARTED[$p]=$(date +%s); NOUDP[$p]=""
      elif [ "$KICK_DETECT" = "1" ]; then
        if log_kicked "$p" "${STARTED[$p]:-0}"; then
          rejoin_app "$p" "$(t 'bị kick / mất kết nối (log)' 'kicked / disconnected (log)')"
        elif [ "$(udp_count "$p")" = "0" ]; then
          [ -z "${NOUDP[$p]}" ] && NOUDP[$p]=$now
          if [ $(( now - NOUDP[$p] )) -ge "$KICK_GRACE" ]; then
            rejoin_app "$p" "$(t "mất kết nối server ${KICK_GRACE}s (kick/disconnect)" "no server connection for ${KICK_GRACE}s (kick/disconnect)")"
          fi
        else
          NOUDP[$p]=""
          # Stable in game > 5 min -> reset failure counter
          [ $(( now - ${STARTED[$p]:-now} )) -ge 300 ] && FAILS[$p]=0
        fi
      fi
    done
    sleep "$CHECK_EVERY"
  done
}

bg_running() { [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; }

boot_state() {
  if [ -f "$SD_BOOT" ]; then echo "${G}$(t 'Bật' 'On') (service.d)${N}"
  elif [ -f "$TB_BOOT" ]; then echo "${G}$(t 'Bật' 'On') (Termux:Boot)${N}"
  else echo "${R}$(t 'Tắt' 'Off')${N}"; fi
}

pause() { read -r -p "${D}$(t 'Enter để quay lại menu...' 'Press Enter to return to menu...')${N}" _; }
onoff() { [ "$1" = "1" ] && echo "${G}$(t 'Bật' 'On')${N}" || echo "${R}$(t 'Tắt' 'Off')${N}"; }
need_restart() { bg_running && echo "${Y}$(t 'Đang chạy: dừng rồi bắt đầu lại để áp dụng.' 'Running: stop and start again to apply.')${N}"; }

# ---------------- Account / cookie login ----------------
# The cookie the user pastes is only: checked with Roblox (to show the account name)
# and written into that Roblox app's own cookie store. It is never saved by this tool,
# never logged and never sent anywhere else.

cookie_db() {
  local f
  for f in "/data/data/$1/app_webview/Default/Cookies" "/data/data/$1/app_webview/Cookies"; do
    [ -f "$f" ] && { echo "$f"; return 0; }
  done
  return 1
}

clean_cookie() {
  local c="$1"
  c="${c//[$'\r\n\t ']/}"; c="${c#.ROBLOSECURITY=}"; c="${c%;}"
  printf '%s' "$c"
}

# Check cookie with Roblox -> prints "id|name", empty if invalid
cookie_user() {
  local r id name
  r=$(printf 'Cookie: .ROBLOSECURITY=%s\n' "$1" | curl -s -m 15 -H @- https://users.roblox.com/v1/users/authenticated)
  id=$(printf '%s' "$r" | grep -o '"id":[0-9]*' | head -n1 | cut -d: -f2)
  name=$(printf '%s' "$r" | grep -o '"name":"[^"]*"' | head -n1 | cut -d'"' -f4)
  [ -n "$id" ] && [ -n "$name" ] && echo "$id|$name"
}

# Cookie currently stored in an app (empty if none / unreadable)
app_cookie() {
  local db; db=$(cookie_db "$1") || return 1
  sqlite3 "$db" "SELECT value FROM cookies WHERE name='.ROBLOSECURITY' AND host_key LIKE '%roblox.com' LIMIT 1;" 2>/dev/null
}

inject_cookie() {   # $1 = package, $2 = cookie
  local p="$1" ck="$2" db uid now exp col typ v names="" vals=""
  if ! db=$(cookie_db "$p"); then
    echo "${R}$(t "[$p] Chưa có dữ liệu đăng nhập. Mở app này 1 lần tới màn hình đăng nhập rồi thử lại." "[$p] No login data yet. Open this app once (to the login screen) and try again.")${N}"
    return 1
  fi
  uid=$(stat -c %u "/data/data/$p")
  am force-stop "$p"; sleep 1
  now=$(( ($(date +%s) + 11644473600) * 1000000 ))   # Chromium time (µs since 1601)
  exp=$(( now + 315360000000000 ))                    # +10 years
  ck="${ck//\'/\'\'}"
  while IFS='|' read -r _ col typ _; do
    case "$col" in
      creation_utc|last_access_utc|last_update_utc) v="$now" ;;
      expires_utc) v="$exp" ;;
      host_key) v="'.roblox.com'" ;;
      name) v="'.ROBLOSECURITY'" ;;
      value) v="'$ck'" ;;
      path) v="'/'" ;;
      is_secure|secure|is_httponly|httponly|has_expires|is_persistent|persistent|priority) v=1 ;;
      samesite) v=-1 ;;
      source_scheme) v=2 ;;
      source_port) v=443 ;;
      encrypted_value) v="X''" ;;
      *) case "${typ^^}" in *INT*) v=0 ;; *BLOB*) v="X''" ;; *) v="''" ;; esac ;;
    esac
    names="$names${names:+,}$col"; vals="$vals${vals:+,}$v"
  done < <(sqlite3 "$db" "PRAGMA table_info(cookies);")
  [ -z "$names" ] && { echo "${R}$(t "[$p] Không đọc được dữ liệu cookie của app." "[$p] Could not read the app's cookie store.")${N}"; return 1; }
  if ! sqlite3 "$db" "DELETE FROM cookies WHERE name='.ROBLOSECURITY'; INSERT INTO cookies ($names) VALUES ($vals);" 2>/dev/null; then
    echo "${R}$(t "[$p] Ghi cookie thất bại." "[$p] Failed to write cookie.")${N}"; return 1
  fi
  chown "$uid:$uid" "$db"* 2>/dev/null
  restorecon "$db"* 2>/dev/null
  return 0
}

pick_one_app() {   # prints chosen package
  mapfile -t PKGS < <(list_roblox)
  [ ${#PKGS[@]} -eq 0 ] && { echo "${R}$(t 'Không tìm thấy app Roblox nào.' 'No Roblox apps found.')${N}" >&2; return 1; }
  local i n
  for i in "${!PKGS[@]}"; do printf "  ${M}%2d${N}) %s\n" "$((i+1))" "${PKGS[$i]}" >&2; done
  read -r -p "$(t 'Chọn số app: ' 'App number: ')" n
  [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le ${#PKGS[@]} ] || { echo "${R}$(t 'Số không hợp lệ.' 'Invalid number.')${N}" >&2; return 1; }
  echo "${PKGS[$((n-1))]}"
}

login_one() {
  local p ck u ans
  echo "${C}$(t 'Chọn app để đăng nhập:' 'Choose the app to log in:')${N}"
  p=$(pick_one_app) || return
  echo "${D}$(t 'Dán cookie .ROBLOSECURITY (sẽ không hiện trên màn hình), rồi Enter:' 'Paste your .ROBLOSECURITY cookie (hidden), then Enter:')${N}"
  read -r -s ck; echo
  ck=$(clean_cookie "$ck")
  [ ${#ck} -lt 100 ] && { echo "${R}$(t 'Cookie quá ngắn, có thể bị thiếu.' 'Cookie too short, it may be incomplete.')${N}"; return; }
  echo "$(t 'Đang kiểm tra với Roblox...' 'Checking with Roblox...')"
  u=$(cookie_user "$ck")
  if [ -z "$u" ]; then
    echo "${R}$(t 'Cookie không hợp lệ hoặc đã hết hạn.' 'Cookie is invalid or expired.')${N}"; ck=""; return
  fi
  echo "$(t 'Tài khoản' 'Account'): ${Y}${u#*|}${N} ${D}(ID ${u%%|*})${N}"
  read -r -p "$(t "Đăng nhập tài khoản này vào $p? (Y/n): " "Log this account into $p? (Y/n): ")" ans
  if [ "$ans" = "n" ] || [ "$ans" = "N" ]; then ck=""; return; fi
  if inject_cookie "$p" "$ck"; then
    echo "${G}✔ $(t "Đã đăng nhập ${u#*|} vào $p." "Logged ${u#*|} into $p.")${N}"
    log "[$p] $(t "Đăng nhập bằng cookie: ${u#*|}" "Logged in by cookie: ${u#*|}")" >> "$LOG"
  fi
  ck=""
}

login_file() {
  local f ans i p u ok=0 bad=0
  read -r -p "$(t 'Đường dẫn file cookie [/sdcard/Download/cookies.txt]: ' 'Cookie file path [/sdcard/Download/cookies.txt]: ')" f
  f="${f:-/sdcard/Download/cookies.txt}"
  [ -f "$f" ] || { echo "${R}$(t 'Không tìm thấy file.' 'File not found.')${N}"; return; }
  mapfile -t CKS < <(grep -v '^[[:space:]]*$' "$f")
  [ ${#CKS[@]} -eq 0 ] && { echo "${R}$(t 'File trống.' 'File is empty.')${N}"; return; }
  mapfile -t PKGS < <(list_roblox)
  [ ${#PKGS[@]} -eq 0 ] && { echo "${R}$(t 'Không tìm thấy app Roblox nào.' 'No Roblox apps found.')${N}"; return; }
  echo "$(t "File có ${#CKS[@]} cookie. Các app Roblox:" "File has ${#CKS[@]} cookies. Roblox apps:")"
  for i in "${!PKGS[@]}"; do printf "  ${M}%2d${N}) %s\n" "$((i+1))" "${PKGS[$i]}"; done
  echo "${D}$(t 'Cookie dòng 1 -> app chọn thứ 1, dòng 2 -> app thứ 2...' 'Cookie line 1 -> 1st chosen app, line 2 -> 2nd...')${N}"
  read -r -p "$(t "Chọn app theo thứ tự (vd: 1 2 3) hoặc 'a' = tất cả: " "Pick apps in order (e.g. 1 2 3) or 'a' = all: ")" ans
  local sel=()
  if [ "$ans" = "a" ] || [ "$ans" = "A" ]; then sel=("${PKGS[@]}")
  else for i in $ans; do [[ "$i" =~ ^[0-9]+$ ]] && [ "$i" -ge 1 ] && [ "$i" -le ${#PKGS[@]} ] && sel+=("${PKGS[$((i-1))]}"); done; fi
  [ ${#sel[@]} -eq 0 ] && { echo "${R}$(t 'Chưa chọn app nào.' 'No apps selected.')${N}"; return; }
  for i in "${!sel[@]}"; do
    p="${sel[$i]}"
    if [ "$i" -ge ${#CKS[@]} ]; then echo "${Y}[$p] $(t 'Hết cookie trong file, bỏ qua.' 'No more cookies in file, skipped.')${N}"; continue; fi
    local ck; ck=$(clean_cookie "${CKS[$i]}")
    u=$(cookie_user "$ck")
    if [ -z "$u" ]; then echo "${R}[$p] $(t "Cookie dòng $((i+1)) không hợp lệ/hết hạn." "Cookie on line $((i+1)) invalid/expired.")${N}"; bad=$((bad+1)); continue; fi
    if inject_cookie "$p" "$ck"; then
      echo "${G}✔ [$p] ${u#*|}${N}"; ok=$((ok+1))
      log "[$p] $(t "Đăng nhập bằng cookie: ${u#*|}" "Logged in by cookie: ${u#*|}")" >> "$LOG"
    else bad=$((bad+1)); fi
  done
  CKS=()
  echo "$(t "Xong: $ok thành công, $bad lỗi." "Done: $ok succeeded, $bad failed.")"
  read -r -p "$(t 'Xoá file cookie cho an toàn? (Y/n): ' 'Delete the cookie file for safety? (Y/n): ')" ans
  if [ "$ans" != "n" ] && [ "$ans" != "N" ]; then rm -f "$f"; echo "${G}✔ $(t 'Đã xoá file.' 'File deleted.')${N}"; fi
}

check_accounts() {
  mapfile -t PKGS < <(list_roblox)
  [ ${#PKGS[@]} -eq 0 ] && { echo "${R}$(t 'Không tìm thấy app Roblox nào.' 'No Roblox apps found.')${N}"; return; }
  echo "$(t 'Đang kiểm tra...' 'Checking...')"
  local p ck u
  for p in "${PKGS[@]}"; do
    ck=$(app_cookie "$p")
    if [ -z "$ck" ]; then
      echo "${Y}$p${N}: ${D}$(t 'chưa đăng nhập (không thấy cookie)' 'not logged in (no cookie found)')${N}"
    elif u=$(cookie_user "$ck") && [ -n "$u" ]; then
      echo "${Y}$p${N}: ${G}${u#*|}${N} ${D}(ID ${u%%|*})${N}"
    else
      echo "${Y}$p${N}: ${R}$(t 'cookie hết hạn / không hợp lệ' 'cookie expired / invalid')${N}"
    fi
  done
  ck=""
}

logout_app() {
  local p db
  echo "${C}$(t 'Chọn app để đăng xuất:' 'Choose the app to log out:')${N}"
  p=$(pick_one_app) || return
  db=$(cookie_db "$p") || { echo "${Y}$(t 'App này chưa đăng nhập.' 'This app is not logged in.')${N}"; return; }
  am force-stop "$p"; sleep 1
  sqlite3 "$db" "DELETE FROM cookies WHERE name='.ROBLOSECURITY';" 2>/dev/null
  chown "$(stat -c %u "/data/data/$p"):$(stat -c %u "/data/data/$p")" "$db"* 2>/dev/null
  echo "${G}✔ $(t "Đã đăng xuất $p." "Logged out $p.")${N}"
}

# ---------------- Menu actions ----------------
start_rejoin() {
  load_conf
  if bg_running; then echo "${Y}$(t 'Auto rejoin đang chạy rồi.' 'Auto rejoin is already running.')${N}"; return; fi
  [ -z "$SELECTED" ] && { echo "${R}$(t 'Chưa chọn app. Vào mục 3 (App & server) trước.' 'No apps selected. Go to item 3 (Apps & server) first.')${N}"; return; }
  local p miss=""
  for p in $SELECTED; do [ -z "$(get_link "$p")" ] && miss="$miss $p"; done
  [ -n "$miss" ] && { echo "${R}$(t 'Chưa gán link cho:' 'No link assigned for:')${N}$miss"; return; }
  setsid nohup "$T/usr/bin/bash" "$SELF" --run >> "$LOG" 2>&1 < /dev/null &
  sleep 1
  echo "${G}✔ $(t 'Đã bắt đầu auto rejoin (chạy ngầm). Xem log ở mục 2.' 'Auto rejoin started (in background). See the log in item 2.')${N}"
}

stop_rejoin() {
  load_conf
  if bg_running; then
    local pid; pid=$(cat "$PIDF")
    pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null
    notify "⏹️ $(t 'Đã dừng auto rejoin' 'Auto rejoin stopped')"
  fi
  pkill -f "rejoin.sh --run" 2>/dev/null; pkill -f "rejoin.sh --auto" 2>/dev/null
  rm -f "$PIDF"
  echo "${G}✔ $(t 'Đã dừng auto rejoin.' 'Auto rejoin stopped.')${N}"
}

view_log() {
  echo "${D}$(t 'Ctrl+C để quay lại menu' 'Ctrl+C to return to menu')${N}"
  trap 'true' INT
  tail -n 30 -f "$LOG"
  trap - INT
}

select_apps() {
  load_conf
  mapfile -t PKGS < <(list_roblox)
  [ ${#PKGS[@]} -eq 0 ] && { echo "${R}$(t 'Không tìm thấy app Roblox nào.' 'No Roblox apps found.')${N}"; return; }
  echo "${C}$(t 'Các app Roblox trên máy:' 'Roblox apps on this device:')${N}"
  local i
  for i in "${!PKGS[@]}"; do printf "  ${M}%2d${N}) %s\n" "$((i+1))" "${PKGS[$i]}"; done
  read -r -p "$(t "Chọn số (vd: 1 3 4) hoặc 'a' = tất cả: " "Pick numbers (e.g. 1 3 4) or 'a' = all: ")" choice
  local sel=""
  if [ "$choice" = "a" ] || [ "$choice" = "A" ]; then sel="${PKGS[*]}"
  else
    for n in $choice; do
      [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le ${#PKGS[@]} ] && sel="$sel ${PKGS[$((n-1))]}"
    done
  fi
  sel=$(echo $sel)
  [ -z "$sel" ] && { echo "${R}$(t 'Chưa chọn app nào.' 'No apps selected.')${N}"; return; }

  read -r -p "$(t 'Dùng chung 1 link cho tất cả app vừa chọn? (Y/n): ' 'Use one link for all selected apps? (Y/n): ')" same
  local p link
  if [ "$same" = "n" ] || [ "$same" = "N" ]; then
    for p in $sel; do
      link=$(ask_link "$(t "Link cho ${Y}$p${N} (Enter = giữ link cũ): " "Link for ${Y}$p${N} (Enter = keep current): ")" "$(get_link "$p")")
      set_link "$p" "$link"
    done
  else
    link=$(ask_link "$(t 'Dán link server / Place ID: ' 'Paste server link / Place ID: ')" "")
    for p in $sel; do set_link "$p" "$link"; done
  fi
  SELECTED="$sel"; save_conf
  echo "${G}✔ $(t 'Đã lưu cho:' 'Saved for:') $sel${N}"
  need_restart
}

list_selected() {
  load_conf
  [ -z "$SELECTED" ] && { echo "${R}$(t 'Chưa chọn app nào.' 'No apps selected.')${N}"; return; }
  local p st
  for p in $SELECTED; do
    app_running "$p" && st="${G}$(t 'đang mở' 'running')${N}" || st="${D}$(t 'đã đóng' 'closed')${N}"
    echo "${Y}$p${N} [$st]"
    echo "   ${D}$(get_link "$p")${N}"
  done
}

select_all() {
  load_conf
  mapfile -t PKGS < <(list_roblox)
  [ ${#PKGS[@]} -eq 0 ] && { echo "${R}$(t 'Không tìm thấy app Roblox nào.' 'No Roblox apps found.')${N}"; return; }
  echo "$(t 'Tìm thấy' 'Found') ${#PKGS[@]} app: ${PKGS[*]}"
  local link p; link=$(ask_link "$(t 'Dán link server / Place ID: ' 'Paste server link / Place ID: ')" "")
  for p in "${PKGS[@]}"; do set_link "$p" "$link"; done
  SELECTED="${PKGS[*]}"; save_conf
  echo "${G}✔ $(t "Đã chọn tất cả ${#PKGS[@]} app." "Selected all ${#PKGS[@]} apps.")${N}"
}

open_all() {
  load_conf
  [ -z "$SELECTED" ] && { echo "${R}$(t 'Chưa chọn app nào.' 'No apps selected.')${N}"; return; }
  local p; for p in $SELECTED; do open_app "$p" 5; done
  echo "${G}✔ $(t 'Đã mở tất cả (không theo dõi).' 'All opened (not monitored).')${N}"
}

close_all() {
  bg_running && stop_rejoin
  local p; for p in $(list_roblox); do am force-stop "$p"; done
  echo "${G}✔ $(t 'Đã đóng tất cả app Roblox.' 'All Roblox apps closed.')${N}"
}

webhook_menu() {
  load_conf
  local v
  echo "${C}$(t 'Thông báo Discord' 'Discord notifications')${N}"
  if [ -n "$WEBHOOK" ]; then echo "Webhook : ${G}$(t 'đã đặt' 'set')${N} ${D}(...${WEBHOOK: -8})${N}"; else echo "Webhook : ${R}$(t 'chưa đặt' 'not set')${N}"; fi
  echo "$(t 'Tên máy' 'Device ') : ${Y}$DEV_NAME${N}"
  echo " ${M}1${N} $(t 'Đặt link webhook' 'Set webhook link')"
  echo " ${M}2${N} $(t 'Gửi tin nhắn thử' 'Send test message')"
  echo " ${M}3${N} $(t 'Đổi tên máy (hiện trong thông báo)' 'Rename device (shown in notifications)')"
  echo " ${M}4${N} $(t 'Xoá webhook (tắt thông báo)' 'Remove webhook (disable notifications)')"
  read -r -p "$(t 'Chọn: ' 'Choice: ')" v
  case "$v" in
    1) read -r -p "$(t 'Dán link webhook: ' 'Paste webhook link: ')" v
       if [[ "$v" =~ ^https://(discord|discordapp|canary\.discord|ptb\.discord)\.com/api/webhooks/ ]]; then
         WEBHOOK="$v"; save_conf; echo "${G}✔ $(t 'Đã lưu. Thử gửi ở mục 2.' 'Saved. Test it with option 2.')${N}"
       else echo "${R}$(t 'Link không đúng dạng' 'Link must look like') https://discord.com/api/webhooks/...${N}"; fi ;;
    2) [ -z "$WEBHOOK" ] && { echo "${R}$(t 'Chưa đặt webhook.' 'Webhook not set.')${N}"; return; }
       local msg code; msg=$(json_escape "**[$DEV_NAME]** ✅ $(t 'Saba Rejoin kết nối Discord thành công' 'Saba Rejoin connected to Discord')")
       code=$(curl -s -m 15 -o /dev/null -w '%{http_code}' -H "Content-Type: application/json" \
              -d "{\"content\":\"$msg\"}" "$WEBHOOK")
       if [ "$code" = "204" ] || [ "$code" = "200" ]; then echo "${G}✔ $(t 'Đã gửi! Kiểm tra kênh Discord.' 'Sent! Check your Discord channel.')${N}"
       else echo "${R}$(t "Gửi thất bại (mã $code). Kiểm tra lại link hoặc mạng." "Failed (code $code). Check the link or network.")${N}"; fi ;;
    3) read -r -p "$(t 'Tên máy mới: ' 'New device name: ')" v; [ -n "$v" ] && { DEV_NAME="$v"; save_conf; echo "${G}✔ $(t 'Đã lưu.' 'Saved.')${N}"; } ;;
    4) WEBHOOK=""; save_conf; echo "${G}✔ $(t 'Đã tắt thông báo Discord.' 'Discord notifications disabled.')${N}" ;;
  esac
  need_restart
}

config_menu() {
  load_conf
  local v
  echo "${C}$(t 'Enter = giữ nguyên' 'Enter = keep current')${N}"
  read -r -p "$(t "Giây giữa mỗi lần kiểm tra [$CHECK_EVERY]: " "Seconds between checks [$CHECK_EVERY]: ")" v; [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge 5 ] && CHECK_EVERY=$v
  read -r -p "$(t "Giây chờ game load sau khi mở [$LAUNCH_WAIT]: " "Seconds to wait for game to load [$LAUNCH_WAIT]: ")" v; [[ "$v" =~ ^[0-9]+$ ]] && LAUNCH_WAIT=$v
  read -r -p "$(t "Bao nhiêu phút thì kill + rejoin (0 = tắt) [$RESTART_EVERY]: " "Kill + rejoin every N minutes (0 = off) [$RESTART_EVERY]: ")" v; [[ "$v" =~ ^[0-9]+$ ]] && RESTART_EVERY=$v
  read -r -p "$(t "Rejoin khi bị kick/disconnect? 1=bật 0=tắt [$KICK_DETECT]: " "Rejoin on kick/disconnect? 1=on 0=off [$KICK_DETECT]: ")" v; [[ "$v" =~ ^[01]$ ]] && KICK_DETECT=$v
  read -r -p "$(t "Mất kết nối bao nhiêu giây thì coi là bị kick [$KICK_GRACE]: " "Seconds without connection = kicked [$KICK_GRACE]: ")" v; [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge 15 ] && KICK_GRACE=$v
  read -r -p "$(t "Lỗi liên tiếp bao nhiêu lần thì bắt đầu chờ lâu dần [$BACKOFF_AFTER]: " "Failures in a row before backing off [$BACKOFF_AFTER]: ")" v; [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge 1 ] && BACKOFF_AFTER=$v
  read -r -p "$(t "Cảnh báo khi RAM trống dưới bao nhiêu MB [$RAM_MIN]: " "Warn when free RAM is below (MB) [$RAM_MIN]: ")" v; [[ "$v" =~ ^[0-9]+$ ]] && RAM_MIN=$v
  save_conf
  echo "${G}✔ $(t 'Đã lưu.' 'Saved.')${N}"
  need_restart
}

schedule_menu() {
  load_conf
  local a b
  if [ -n "$SCH_START" ]; then echo "$(t 'Hiện tại: chạy từ' 'Current: run from') ${Y}${SCH_START}h${N} $(t 'đến' 'to') ${Y}${SCH_END}h${N}"
  else echo "$(t 'Hiện tại:' 'Current:') ${Y}$(t 'chạy cả ngày' 'all day')${N}"; fi
  echo "${D}$(t 'Ví dụ: bắt đầu 22, kết thúc 8 = chạy qua đêm từ 22h tới 8h sáng.' 'Example: start 22, end 8 = run overnight from 22:00 to 08:00.')${N}"
  read -r -p "$(t 'Giờ bắt đầu (0-23, Enter = chạy cả ngày): ' 'Start hour (0-23, Enter = all day): ')" a
  if [ -z "$a" ]; then SCH_START=""; SCH_END=""; save_conf; echo "${G}✔ $(t 'Chạy cả ngày.' 'Running all day.')${N}"; return; fi
  read -r -p "$(t 'Giờ kết thúc (0-23): ' 'End hour (0-23): ')" b
  if [[ "$a" =~ ^[0-9]+$ ]] && [[ "$b" =~ ^[0-9]+$ ]] && [ "$a" -le 23 ] && [ "$b" -le 23 ]; then
    SCH_START=$((10#$a)); SCH_END=$((10#$b)); save_conf
    echo "${G}✔ $(t "Chạy từ ${SCH_START}h đến ${SCH_END}h. Ngoài giờ này game sẽ được đóng." "Running from ${SCH_START}h to ${SCH_END}h. Games are closed outside these hours.")${N}"
  else echo "${R}$(t 'Giờ không hợp lệ.' 'Invalid hour.')${N}"; fi
  need_restart
}

kick_debug() {
  load_conf
  [ -z "$SELECTED" ] && { echo "${R}$(t 'Chưa chọn app nào.' 'No apps selected.')${N}"; return; }
  echo "${C}$(t 'Đang trong game thì UDP > 0. Khi hiện bảng kick/Disconnected thì UDP về 0.' 'In game: UDP > 0. On the kick/Disconnected screen: UDP drops to 0.')${N}"
  local p f
  for p in $SELECTED; do
    echo "${Y}$p${N}"
    app_running "$p" && echo "  App     : ${G}$(t 'đang chạy' 'running')${N}" || echo "  App     : ${R}$(t 'không chạy' 'not running')${N}"
    echo "  UDP game: $(udp_count "$p")"
    f=$(newest_log "$p")
    if [ -n "$f" ]; then
      echo "  Log     : $(basename "$f")"
      echo "  Kick log: $(grep -iE "$KICK_RE" "$f" | tail -n1 | cut -c1-120)"
    else
      echo "  Log     : ${D}$(t 'không tìm thấy (chỉ dùng cách UDP)' 'not found (UDP method only)')${N}"
    fi
  done
}

toggle_boot() {
  if [ -f "$SD_BOOT" ] || [ -f "$TB_BOOT" ]; then
    rm -f "$SD_BOOT" "$TB_BOOT"
    echo "${G}✔ $(t 'Đã TẮT tự chạy khi khởi động.' 'Auto start on boot DISABLED.')${N}"; return
  fi
  load_conf
  [ -z "$SELECTED" ] && { echo "${R}$(t 'Chọn app (mục 3) trước đã.' 'Select apps (item 3) first.')${N}"; return; }
  if [ -d /data/adb ]; then
    mkdir -p /data/adb/service.d
    cat > "$SD_BOOT" <<EOF
#!/system/bin/sh
until [ "\$(getprop sys.boot_completed)" = "1" ]; do sleep 5; done
sleep 40
LD_LIBRARY_PATH=$T/usr/lib $T/usr/bin/bash $SELF --run >> $LOG 2>&1 &
EOF
    chmod 755 "$SD_BOOT"
    echo "${G}✔ $(t 'Đã BẬT tự chạy khi khởi động (Magisk/KernelSU).' 'Auto start on boot ENABLED (Magisk/KernelSU).')${N}"
  else
    mkdir -p "$(dirname "$TB_BOOT")"
    cat > "$TB_BOOT" <<EOF
#!$T/usr/bin/bash
termux-wake-lock 2>/dev/null
sleep 40
su -c "LD_LIBRARY_PATH=$T/usr/lib $T/usr/bin/bash $SELF --run >> $LOG 2>&1"
EOF
    chmod 755 "$TB_BOOT"; chown "$(stat -c %u "$T/home")" "$TB_BOOT" "$(dirname "$TB_BOOT")" 2>/dev/null
    echo "${G}✔ $(t 'Đã BẬT qua Termux:Boot.' 'ENABLED via Termux:Boot.')${N} $(t 'Cần cài app Termux:Boot (cùng nguồn với Termux) và mở nó 1 lần.' 'Install the Termux:Boot app (same source as Termux) and open it once.')"
  fi
}

update_tool() {
  load_conf
  local v tmp="$DIR/rejoin.new"
  echo "${C}$(t 'Cập nhật từ:' 'Update from:')${N} ${D}$UPDATE_URL${N}"
  read -r -p "$(t 'Enter = cập nhật ngay (hoặc dán link khác để đổi): ' 'Enter = update now (or paste another link to change): ')" v
  if [ -n "$v" ]; then UPDATE_URL="$v"; save_conf; fi
  echo "$(t 'Đang tải...' 'Downloading...')"
  if ! curl -fsSL -m 30 "$UPDATE_URL" -o "$tmp"; then echo "${R}$(t 'Tải thất bại. Kiểm tra link/mạng.' 'Download failed. Check the link/network.')${N}"; rm -f "$tmp"; return; fi
  if ! grep -q "Saba Rejoin" "$tmp" || ! "$T/usr/bin/bash" -n "$tmp" 2>/dev/null; then
    echo "${R}$(t 'File tải về không phải Saba Rejoin hoặc bị lỗi. Không cập nhật.' 'Downloaded file is not Saba Rejoin or is broken. Not updating.')${N}"; rm -f "$tmp"; return
  fi
  if cmp -s "$tmp" "$SELF"; then echo "${G}$(t 'Đang là bản mới nhất.' 'Already up to date.')${N}"; rm -f "$tmp"; return; fi
  local was=0; bg_running && { was=1; stop_rejoin >/dev/null; }
  cp "$SELF" "$DIR/rejoin.bak"; mv "$tmp" "$SELF"; chmod 755 "$SELF"
  echo "${G}✔ $(t 'Đã cập nhật! (bản cũ lưu ở rejoin.bak)' 'Updated! (old version saved as rejoin.bak)')${N}"
  if [ "$was" = "1" ]; then
    setsid nohup "$T/usr/bin/bash" "$SELF" --run >> "$LOG" 2>&1 < /dev/null &
    echo "${G}✔ $(t 'Đã chạy lại auto rejoin với bản mới.' 'Auto rejoin restarted with the new version.')${N}"
  fi
  sleep 2
  exec "$T/usr/bin/bash" "$SELF"
}

choose_lang() {
  local v
  echo "${C}Ngôn ngữ / Language${N}"
  echo " ${M}1${N} Tiếng Việt"
  echo " ${M}2${N} English"
  read -r -p "> " v
  case "$v" in
    2) UI_LANG="en" ;;
    *) UI_LANG="vi" ;;
  esac
  save_conf
}

# ---------------- Menu ----------------
line() { echo "${D}──────────────────────────────${N}"; }
item() { printf " ${M}%s${N}  %s\n" "$1" "$2"; }
back() { echo " ${R}0${N}  $(t 'Quay lại' 'Back')"; }
ask()  { read -r -p "${M}$(t 'Chọn: ' 'Choice: ')${N}" c; echo; }

apps_menu() {
  while true; do
    clear; echo "${BD}${C}📱 $(t 'App & server' 'Apps & server')${N}"; line
    item 1 "$(t 'Chọn app & gán link server' 'Select apps & assign server link')"
    item 2 "$(t 'Chọn tất cả app (1 link)' 'Select all apps (one link)')"
    item 3 "$(t 'Xem app đã chọn' 'List selected apps')"
    item 4 "$(t 'Mở tất cả app đã chọn' 'Open all selected apps')"
    item 5 "$(t 'Đóng tất cả app Roblox' 'Close all Roblox apps')"
    back; line; ask
    case "$c" in
      1) select_apps ;; 2) select_all ;; 3) list_selected ;; 4) open_all ;; 5) close_all ;;
      0|"") return ;; *) continue ;;
    esac
    pause
  done
}

account_menu() {
  while true; do
    clear; echo "${BD}${C}🔑 $(t 'Tài khoản' 'Accounts')${N}"
    echo "${D}$(t 'Chỉ dùng cookie của chính bạn. Tool không lưu cookie.' 'Only use your own cookies. The tool does not store them.')${N}"; line
    item 1 "$(t 'Đăng nhập 1 app (dán cookie)' 'Log in one app (paste cookie)')"
    item 2 "$(t 'Đăng nhập nhiều app từ file' 'Log in many apps from a file')"
    item 3 "$(t 'Xem tài khoản từng app' 'Show account of each app')"
    item 4 "$(t 'Đăng xuất 1 app' 'Log out an app')"
    back; line; ask
    case "$c" in
      1) login_one ;; 2) login_file ;; 3) check_accounts ;; 4) logout_app ;;
      0|"") return ;; *) continue ;;
    esac
    pause
  done
}

settings_menu() {
  while true; do
    load_conf
    clear; echo "${BD}${C}⚙️  $(t 'Cài đặt' 'Settings')${N}"; line
    item 1 "$(t 'Thời gian, kick, chống lặp, RAM' 'Timing, kick, anti-loop, RAM')"
    item 2 "$(t 'Hẹn giờ chạy' 'Run schedule')"
    item 3 "$(t 'Tự chạy khi khởi động' 'Auto start on boot'): $(boot_state)"
    item 4 "$(t 'Kiểm tra phát hiện kick' 'Test kick detection')"
    item 5 "Ngôn ngữ / Language"
    back; line; ask
    case "$c" in
      1) config_menu ;; 2) schedule_menu ;; 3) toggle_boot ;; 4) kick_debug ;;
      5) choose_lang; need_restart ;;
      0|"") return ;; *) continue ;;
    esac
    pause
  done
}

menu() {
  load_conf
  [ -z "$UI_LANG" ] && { clear; choose_lang; }
  while true; do
    load_conf
    local run n=0 free sch rs
    bg_running && run=1 || run=0
    [ -n "$SELECTED" ] && n=$(echo $SELECTED | wc -w)
    free=$(ram_free)
    if [ "${free:-0}" -lt "$RAM_MIN" ]; then free="${R}${free}${N}"; else free="${G}${free}${N}"; fi
    if [ -n "$SCH_START" ]; then sch="${SCH_START}h→${SCH_END}h"; else sch="$(t 'cả ngày' 'all day')"; fi
    if [ "$RESTART_EVERY" -gt 0 ] 2>/dev/null; then rs="${RESTART_EVERY}$(t 'p' 'm')"; else rs="$(t 'tắt' 'off')"; fi
    clear
    echo "${BD}${C}⚡ Saba Rejoin${N}"
    if [ "$run" = "1" ]; then printf '%s' "${G}● $(t 'Đang chạy' 'Running')${N}"; else printf '%s' "${R}○ $(t 'Đã dừng' 'Stopped')${N}"; fi
    echo "  ${D}·${N} ${Y}$n${N} app  ${D}·${N} RAM $free/$(ram_total) MB"
    echo "${D}Kick:${N} $(onoff "$KICK_DETECT")  ${D}Kill:${N} ${Y}$rs${N}  ${D}$(t 'Giờ' 'Hours'):${N} ${Y}$sch${N}  ${D}Discord:${N} $([ -n "$WEBHOOK" ] && echo "${G}✔${N}" || echo "${R}✘${N}")"
    line
    if [ "$run" = "1" ]; then item 1 "${R}$(t 'Dừng auto rejoin' 'Stop auto rejoin')${N}"
    else item 1 "${G}$(t 'Bắt đầu auto rejoin' 'Start auto rejoin')${N}"; fi
    item 2 "$(t 'Xem log' 'View log')"
    item 3 "$(t 'App & server' 'Apps & server')"
    item 4 "$(t 'Tài khoản (cookie)' 'Accounts (cookie)')"
    item 5 "Discord"
    item 6 "$(t 'Cài đặt' 'Settings')"
    item 7 "$(t 'Cập nhật tool' 'Update tool')"
    echo " ${R}0${N}  $(t 'Thoát' 'Exit') ${D}($(t 'vẫn chạy ngầm' 'keeps running'))${N}"
    line; ask
    case "$c" in
      1) if [ "$run" = "1" ]; then stop_rejoin; else start_rejoin; fi; pause ;;
      2) view_log ;;
      3) apps_menu ;;
      4) account_menu ;;
      5) webhook_menu; pause ;;
      6) settings_menu ;;
      7) update_tool; pause ;;
      0) exit 0 ;;
    esac
  done
}

# ---------------- Start ----------------
if [ "$(id -u)" != "0" ]; then echo "Root required / Cần root. Run / Chạy: rejoin"; exit 1; fi
case "$1" in
  --run|--auto) run_loop ;;
  *) menu ;;
esac
REJOIN_EOF
chmod 755 "$DIR/rejoin.sh"
ok "Installed to / Đã cài vào $DIR"

cat > "$T/usr/bin/rejoin" <<EOF
#!$T/usr/bin/bash
termux-wake-lock 2>/dev/null
exec su -c "LD_LIBRARY_PATH=$T/usr/lib $T/usr/bin/bash $DIR/rejoin.sh \$*"
EOF
chmod 755 "$T/usr/bin/rejoin"

cat > "$T/usr/bin/rejoin-uninstall" <<EOF
#!$T/usr/bin/bash
su -c "pkill -f 'rejoin.sh --run'; pkill -f 'rejoin.sh --auto'; rm -rf /data/adb/service.d/rejoin.sh $DIR $T/home/.termux/boot/rejoin-boot.sh"
rm -f "$T/usr/bin/rejoin" "$T/usr/bin/rejoin-uninstall"
echo "Saba Rejoin removed. / Đã gỡ Saba Rejoin."
EOF
chmod 755 "$T/usr/bin/rejoin-uninstall"
rm -f "$T/usr/bin/rejoin-boot"   # old command, now in the menu

echo
ok "DONE! / CÀI XONG!  Type / Gõ:  rejoin"
echo "  rejoin-uninstall -> uninstall / gỡ cài đặt"
sleep 2
exec "$T/usr/bin/rejoin"
