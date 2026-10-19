#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
#  Rejoiner Termux (butuh root)
#  Pantau klon Roblox terpilih, buka ulang otomatis kalau mati.
#  Jendela freeform + grid otomatis (split 2x2 untuk 4 klon).
#  + Optimizer anti-lag (proses root tunggal, default tiap 1 detik).
#  + Health check frame/ANR (default tiap 10 detik): black screen / hang.
# ============================================================

BASE="$HOME/.rejoiner"
CONF="$BASE/clones.conf"      # format: package|label|url
ACTIVE="$BASE/active.list"    # klon yang sedang dipantau
SET="$BASE/settings.conf"
LOG="$BASE/rejoiner.log"
PIDF="$BASE/rejoiner.pid"
WEBHOOK_FILE="$BASE/webhook.conf"   # berisi 1 baris: URL webhook Discord
WAKE="$BASE/wake"
OPTPIDF="$BASE/opt.pid"       # pid proses optimizer
ORIG="$BASE/orig.conf"        # nilai asli sistem (untuk dipulihkan saat stop)
declare -A TUNED              # klon yang sudah diberi whitelist baterai
RAW="/dev/rj.raw"            # screencap sementara di RAM (tmpfs), dihapus tiap selesai cek
OPTRUN="$BASE/opt.run"        # token proses root optimizer (dihapus = optimizer berhenti)
HCPIDF="$BASE/hc.pid"         # pid proses health check
HUNGDIR="$BASE/hung"          # permintaan restart dari health check -> monitor
STARTDIR="$BASE/started"      # waktu buka terakhir tiap klon (dipakai bersama)
KILLLIST="$BASE/kill.list"    # app lain yang di-force-stop berkala (opsional)
ANR_EVERY=3                   # dumpsys ANR (berat) dicek tiap N kali cek frame
declare -A BLACKC LASTH SAMESINCE DCOUNT LASTSTART   # state health check per klon
declare -A SC_PID SC_ST SC_KIND SC_HASH              # hasil scan terakhir per klon
HC_PKGS=(); HC_N=0; SW=""; SH=""
ANR_TXT=""; SCR_AWAKE=1; VISERR_SHOWN=""; HUNG=""; H_INFO=""
SCRIPT="$(readlink -f "$0")"
SPLASH="com.roblox.client.startup.ActivitySplash"

mkdir -p "$BASE"
mkdir -p "$HUNGDIR" "$STARTDIR"
touch "$CONF" "$LOG" "$ACTIVE" "$KILLLIST"
if [ ! -f "$SET" ]; then
  cat > "$SET" <<'EOF'
INTERVAL=60
LAUNCH_WAIT=25
RESTART_EVERY=0
MAX_FAILS=5
GRID=1
LANDSCAPE=0
GRID_SLOTS=4
OPT_EVERY=1
MEM_MIN=900
PERF=1
REGRID_SEC=60
HEALTH=1
HEALTH_EVERY=10
BLACK_CHECKS=3
FREEZE_MIN=5
STARTUP_GRACE=90
CFG_VER=3
EOF
fi
# migrasi pengaturan lama: optimasi 1 dtk, cek frame 10 dtk
if ! grep -q '^CFG_VER=3' "$SET"; then
  for kv in OPT_EVERY=1 HEALTH_EVERY=10 BLACK_CHECKS=3 REGRID_SEC=60 CFG_VER=3; do
    grep -v "^${kv%%=*}=" "$SET" > "$SET.tmp"; echo "$kv" >> "$SET.tmp"; mv "$SET.tmp" "$SET"
  done
fi

# ---------- util ----------
log() { echo "$(date '+%H:%M:%S') $*"; }

# su dibaca dari /dev/null supaya tidak memakan stdin loop
root() { su -c "$1" </dev/null 2>/dev/null; }

need_root() {
  if ! command -v su >/dev/null 2>&1 || [ "$(root 'id -u')" != "0" ]; then
    echo "Root tidak tersedia (butuh su)." >&2
    exit 1
  fi
}

load_settings() { # shellcheck disable=SC1090
  . "$SET"
  INTERVAL=${INTERVAL:-60}; LAUNCH_WAIT=${LAUNCH_WAIT:-25}
  RESTART_EVERY=${RESTART_EVERY:-0}; MAX_FAILS=${MAX_FAILS:-5}
  GRID=${GRID:-1}; LANDSCAPE=${LANDSCAPE:-0}
  GRID_SLOTS=${GRID_SLOTS:-4}; OPT_EVERY=${OPT_EVERY:-1}
  MEM_MIN=${MEM_MIN:-900}; PERF=${PERF:-1}; REGRID_SEC=${REGRID_SEC:-60}
  [ "$REGRID_SEC" -ge 10 ] || REGRID_SEC=10
  HEALTH=${HEALTH:-1}; HEALTH_EVERY=${HEALTH_EVERY:-10}
  [ "$HEALTH_EVERY" -ge 5 ] || HEALTH_EVERY=5
  BLACK_CHECKS=${BLACK_CHECKS:-3}
  FREEZE_MIN=${FREEZE_MIN:-5}; STARTUP_GRACE=${STARTUP_GRACE:-90}
}

valid_pkg() { [[ "$1" =~ ^[A-Za-z0-9_.]+$ ]]; }
valid_url() { [ -z "$1" ] || { [[ "$1" =~ ^(https://|roblox://)[^\'\"\ ]+$ ]]; }; }

is_running() { [ -n "$(root "pidof '$1'")" ]; }
is_active()  { grep -qxF "$1" "$ACTIVE" 2>/dev/null; }
label_of()   { grep "^$1|" "$CONF" | head -1 | cut -d'|' -f2; }

# ---------- webhook Discord ----------
webhook_url() { [ -f "$WEBHOOK_FILE" ] && head -1 "$WEBHOOK_FILE"; }
valid_webhook() { [[ "$1" =~ ^https://(discord|discordapp)\.com/api/webhooks/[A-Za-z0-9_/.-]+$ ]]; }
json_esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' '; }

# kirim pesan ke Discord (di background, tidak menghambat monitoring)
notify() {
  local url msg dev
  url=$(webhook_url); [ -n "$url" ] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  dev=$(getprop ro.product.model 2>/dev/null)
  msg=$(json_esc "$1${dev:+  [$dev]}")
  ( curl -s -m 15 -H "Content-Type: application/json" \
      -d "{\"content\":\"$msg\"}" "$url" >/dev/null 2>&1 </dev/null ) &
}

# tunggu $1 detik, tapi bangun lebih cepat kalau ada klon baru ditambahkan
nap() {
  local i=0
  while [ "$i" -lt "$1" ]; do
    [ -f "$WAKE" ] && { rm -f "$WAKE"; return; }
    sleep 1; i=$((i + 1))
  done
}

# ---------- freeform + grid ----------
enable_freeform() {
  root "settings put global enable_freeform_support 1"
  root "settings put global force_resizable_activities 1"
}

launch() { # $1=pkg $2=url  (mode freeform = windowingMode 5)
  local pkg="$1" url="$2"
  if [ -n "$url" ]; then
    root "am start --windowingMode 5 -a android.intent.action.VIEW -d '$url' -p '$pkg'" >/dev/null
  else
    root "am start --windowingMode 5 -n '$pkg/$SPLASH'" >/dev/null
  fi
}

screen_size() {
  local s; s=$(root "wm size" | grep -oE '[0-9]+x[0-9]+' | tail -1)
  SW=${s%x*}; SH=${s#*x}
  [[ "$SW" =~ ^[0-9]+$ && "$SH" =~ ^[0-9]+$ ]] || { SW=1080; SH=1920; }
  if [ "${LANDSCAPE:-0}" = "1" ] && [ "$SW" -lt "$SH" ]; then
    local t=$SW; SW=$SH; SH=$t
  fi
}

place_grid() { # slot tetap sesuai urutan di daftar aktif; GRID_SLOTS=4 -> selalu 2x2
  [ "${GRID:-1}" = "1" ] || return 0
  local ACT; mapfile -t ACT < "$ACTIVE"
  local n=${#ACT[@]}
  [ "$n" -gt 0 ] || return 0
  local cells=$n
  [ "${GRID_SLOTS:-0}" -gt "$cells" ] && cells=$GRID_SLOTS
  screen_size
  local cols=1
  while [ $((cols * cols)) -lt "$cells" ]; do cols=$((cols + 1)); done
  local rows=$(( (cells + cols - 1) / cols ))
  local w=$((SW / cols)) h=$((SH / rows)) i c r tid l t rr b dump pat
  dump=$(root "dumpsys activity activities")      # 1x saja, bukan per klon (ini berat)
  for i in "${!ACT[@]}"; do
    pat="${ACT[$i]//./\\.}"
    tid=$(grep -E "Task\{.*:${pat}[ }]" <<< "$dump" | grep -oE '#[0-9]+' | head -1 | tr -d '#')
    [ -n "$tid" ] || continue
    c=$((i % cols)); r=$((i / cols))
    l=$((c * w)); t=$((r * h)); rr=$(((c + 1) * w)); b=$(((r + 1) * h))
    root "am task resize $tid $l $t $rr $b || cmd activity task resize $tid $l $t $rr $b"
  done
}

stop_clone() { root "am force-stop '$1'"; }

# ---------- optimizer anti-lag ----------
# Sekali jalan: matikan animasi, cegah Android membunuh proses, whitelist baterai.
tune_system() {
  load_settings
  if [ ! -f "$ORIG" ]; then
    {
      echo "WA=$(root 'settings get global window_animation_scale' | tr -cd 'A-Za-z0-9._-')"
      echo "TA=$(root 'settings get global transition_animation_scale' | tr -cd 'A-Za-z0-9._-')"
      echo "DA=$(root 'settings get global animator_duration_scale' | tr -cd 'A-Za-z0-9._-')"
      echo "GOV=$(root 'cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor' | tr -cd 'A-Za-z0-9._-')"
    } > "$ORIG"
  fi
  root "settings put global window_animation_scale 0; settings put global transition_animation_scale 0; settings put global animator_duration_scale 0"
  # Android 12+: matikan "phantom process killer" yang suka membunuh Termux/klon
  root "settings put global settings_enable_monitor_phantom_procs false"
  root "device_config set_sync_disabled_for_tests persistent; device_config put activity_manager max_phantom_processes 2147483647"
  # Termux jangan dibunuh sistem
  root "for i in \$(pidof com.termux); do echo -900 > /proc/\$i/oom_score_adj; done"
  command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock
  if [ "$PERF" = "1" ]; then
    root 'for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > "$g"; done'
  fi
  root "cmd activity kill-all || am kill-all"      # mulai dengan RAM lega
  log "[opt] tuning sistem selesai"
}

restore_system() {
  [ -f "$ORIG" ] || return 0
  local WA TA DA GOV
  . "$ORIG"
  [[ "$WA" =~ ^[0-9.]+$ ]] || WA=1.0
  [[ "$TA" =~ ^[0-9.]+$ ]] || TA=1.0
  [[ "$DA" =~ ^[0-9.]+$ ]] || DA=1.0
  root "settings put global window_animation_scale $WA; settings put global transition_animation_scale $TA; settings put global animator_duration_scale $DA"
  [ -n "$GOV" ] && root "for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo $GOV > \$g; done"
  rm -f "$ORIG"
}

# Optimizer = SATU proses root yang hidup terus (tanpa spawn su tiap detik).
# Per detik hanya kerja murah (builtin shell): proteksi proses klon + baca RAM.
# Pembersihan berat hanya saat RAM menipis, dengan jeda supaya tidak jadi sumber lag.
write_optd() {
  cat > "$BASE/optd.sh" <<'OPTD_EOF'
#!/system/bin/sh
# optd.sh TOKEN RUNFLAG SETFILE ACTIVEFILE LOGFILE KILLLIST [once]
TOK=$1; RUN=$2; SET=$3; ACT=$4; LOGF=$5; KL=$6; MODE=$7
OPT_EVERY=1; MEM_MIN=900; PERF=1
n=0; tuned=" "; last_soft=0; last_hard=0; last_say=0; AVAIL=""
say() { echo "$(date '+%H:%M:%S') [opt] $*" >> "$LOGF"; }
meminfo() {
  AVAIL=""
  while read -r k v u; do
    if [ "$k" = "MemAvailable:" ]; then AVAIL=$((v / 1024)); break; fi
  done < /proc/meminfo
}
killall_bg() { cmd activity kill-all </dev/null >/dev/null 2>&1 || am kill-all </dev/null >/dev/null 2>&1; }
hard_clean() {
  killall_bg
  { echo 3 > /proc/sys/vm/drop_caches; } 2>/dev/null
  { echo 1 > /proc/sys/vm/compact_memory; } 2>/dev/null
}
while :; do
  if [ "$MODE" != "once" ]; then
    cur=""; { read -r cur < "$RUN"; } 2>/dev/null
    [ "$cur" = "$TOK" ] || exit 0
  fi
  if [ $((n % 5)) -eq 0 ]; then . "$SET" 2>/dev/null; fi
  case "$OPT_EVERY" in ''|*[!0-9]*) OPT_EVERY=1;; esac
  [ "$OPT_EVERY" -ge 1 ] || exit 0

  # 1) tiap tick: lindungi proses klon dari pembunuh memori (Android suka menimpa nilai ini)
  while read -r p; do
    [ -n "$p" ] || continue
    for i in $(pidof "$p" 2>/dev/null); do
      { echo -800 > "/proc/$i/oom_score_adj"; } 2>/dev/null
    done
    case "$tuned" in
      *" $p "*) ;;
      *) dumpsys deviceidle whitelist "+$p" </dev/null >/dev/null 2>&1
         cmd appops set "$p" RUN_IN_BACKGROUND allow </dev/null >/dev/null 2>&1
         cmd appops set "$p" RUN_ANY_IN_BACKGROUND allow </dev/null >/dev/null 2>&1
         tuned="$tuned$p "; say "whitelist baterai: $p" ;;
    esac
  done < "$ACT"

  # 2) RAM: ringan (kill cache bg) di bawah 1.5x MEM_MIN, berat di bawah MEM_MIN
  meminfo
  if [ "$MODE" = "once" ]; then
    echo "RAM tersedia sebelum: ${AVAIL}MB -> bersih berat"
    hard_clean; exit 0
  fi
  if [ -n "$AVAIL" ] && [ "$AVAIL" -lt $((MEM_MIN * 3 / 2)) ]; then
    now=$(date +%s)
    if [ "$AVAIL" -lt "$MEM_MIN" ] && [ $((now - last_hard)) -ge 30 ]; then
      hard_clean; last_hard=$now; last_soft=$now
      [ $((now - last_say)) -ge 60 ] && { say "RAM ${AVAIL}MB < ${MEM_MIN}MB: bersih berat"; last_say=$now; }
    elif [ $((now - last_soft)) -ge 20 ]; then
      killall_bg; last_soft=$now
      [ $((now - last_say)) -ge 60 ] && { say "RAM ${AVAIL}MB: bersih ringan"; last_say=$now; }
    fi
  fi

  # 3) governor CPU sering ditimpa vendor: set ulang tiap 30 tick
  if [ "$PERF" = "1" ] && [ $((n % 30)) -eq 0 ]; then
    for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
      { echo performance > "$g"; } 2>/dev/null
    done
  fi

  # 4) app lain di kill.list di-force-stop tiap ~60 tick (klon & Termux dilindungi)
  if [ $((n % 60)) -eq 30 ] && [ -s "$KL" ]; then
    while read -r p; do
      [ -n "$p" ] || continue
      case "$p" in com.termux*|android|com.android.systemui|com.android.phone) continue;; esac
      grep -qxF "$p" "$ACT" && continue
      [ -n "$(pidof "$p" 2>/dev/null)" ] && cmd activity force-stop "$p" </dev/null >/dev/null 2>&1
    done < "$KL"
  fi

  n=$((n + 1))
  sleep "$OPT_EVERY"
done
OPTD_EOF
  chmod 644 "$BASE/optd.sh"
}

opt_loop() {
  need_root; load_settings
  [ "$OPT_EVERY" -gt 0 ] || { log "[opt] OPT_EVERY=0, optimizer mati"; return; }
  write_optd
  tune_system
  local tok="$$.$RANDOM"
  echo "$tok" > "$OPTRUN"
  log "[opt] optimizer jalan tiap ${OPT_EVERY} detik (1 proses root, ringan)"
  root "sh '$BASE/optd.sh' '$tok' '$OPTRUN' '$SET' '$ACTIVE' '$LOG' '$KILLLIST'"
  log "[opt] optimizer berhenti"
}

cmd_kill() { # kill add <pkg> | del <pkg> | list
  touch "$KILLLIST"
  case "$1" in
    add)
      valid_pkg "$2" || { echo "Package tidak valid."; return 1; }
      case "$2" in com.termux*|android|com.android.systemui|com.android.phone) echo "Package itu dilindungi."; return 1;; esac
      if grep -q "^$2|" "$CONF"; then echo "Itu klon Roblox, tidak boleh."; return 1; fi
      grep -qxF "$2" "$KILLLIST" || echo "$2" >> "$KILLLIST"
      echo "OK: $2 akan di-force-stop berkala." ;;
    del)
      grep -vxF "$2" "$KILLLIST" > "$KILLLIST.tmp"; mv "$KILLLIST.tmp" "$KILLLIST"; echo "OK dihapus: $2" ;;
    *) echo "Daftar kill:"; cat "$KILLLIST" ;;
  esac
}

# ---------- kelola klon ----------
cmd_detect() {
  need_root
  echo "Paket Roblox:"
  root "pm list packages" | sed 's/^package://' | grep -i roblox || echo "  (tidak ada)"
}

cmd_add() { # add <package> [url] [label]
  local pkg="$1" url="$2" label="${3:-$1}"
  [ -z "$pkg" ] && { echo "Pemakaian: $0 add <package> [url] [label]"; return 1; }
  valid_pkg "$pkg" || { echo "Nama package tidak valid."; return 1; }
  valid_url "$url" || { echo "URL harus diawali https:// atau roblox://"; return 1; }
  label="${label//|/ }"
  grep -v "^$pkg|" "$CONF" > "$CONF.tmp"; mv "$CONF.tmp" "$CONF"
  echo "$pkg|$label|$url" >> "$CONF"
  echo "Tersimpan: $label"
}

cmd_remove() {
  [ -z "$1" ] && { echo "Pemakaian: $0 remove <package>"; return 1; }
  grep -v "^$1|" "$CONF" > "$CONF.tmp"; mv "$CONF.tmp" "$CONF"
  grep -vxF "$1" "$ACTIVE" > "$ACTIVE.tmp"; mv "$ACTIVE.tmp" "$ACTIVE"
  echo "Dihapus: $1"
}

cmd_list() {
  [ -s "$CONF" ] || { echo "Belum ada klon."; return; }
  local i=0 pkg label url
  while IFS='|' read -r pkg label url; do
    [ -z "$pkg" ] && continue
    i=$((i + 1))
    printf ' %d) %-12s %s\n' "$i" "$label" "${url:-(app saja)}"
  done < "$CONF"
}

cmd_config() { # config KEY=VALUE
  local k="${1%%=*}" v="${1#*=}"
  case "$k" in INTERVAL|LAUNCH_WAIT|RESTART_EVERY|MAX_FAILS|GRID|LANDSCAPE|GRID_SLOTS|OPT_EVERY|MEM_MIN|PERF|REGRID_SEC|HEALTH|HEALTH_EVERY|BLACK_CHECKS|FREEZE_MIN|STARTUP_GRACE) ;;
    *) echo "Kunci: INTERVAL LAUNCH_WAIT RESTART_EVERY MAX_FAILS GRID LANDSCAPE GRID_SLOTS OPT_EVERY MEM_MIN PERF REGRID_SEC HEALTH HEALTH_EVERY BLACK_CHECKS FREEZE_MIN STARTUP_GRACE"; return 1;; esac
  [[ "$v" =~ ^[0-9]+$ ]] || { echo "Nilai harus angka."; return 1; }
  grep -v "^$k=" "$SET" > "$SET.tmp"
  echo "$k=$v" >> "$SET.tmp"
  mv "$SET.tmp" "$SET"
  echo "OK: $k=$v"
}

cmd_webhook() { # webhook <url> | off | test | show
  local u
  case "$1" in
    ""|show)
      u=$(webhook_url)
      if [ -n "$u" ]; then echo "Webhook: AKTIF (${u:0:45}...)"; else echo "Webhook: belum diatur"; fi ;;
    off)
      rm -f "$WEBHOOK_FILE"; echo "Webhook dimatikan." ;;
    test)
      [ -n "$(webhook_url)" ] || { echo "Webhook belum diatur."; return 1; }
      command -v curl >/dev/null 2>&1 || { echo "curl belum ada: pkg install curl"; return 1; }
      notify "✅ Tes webhook Rejoiner berhasil"
      wait; echo "Tes terkirim, cek channel Discord." ;;
    *)
      valid_webhook "$1" || { echo "URL webhook Discord tidak valid."; return 1; }
      command -v curl >/dev/null 2>&1 || echo "Peringatan: curl belum ada (pkg install curl)"
      echo "$1" > "$WEBHOOK_FILE"; chmod 600 "$WEBHOOK_FILE"
      echo "Webhook tersimpan." ;;
  esac
}

# ---------- pilih klon: "1", "1 2", "1,2", "a" = semua ----------
choose() { # choose [multi]  -> hasil di array SEL
  SEL=()
  [ -s "$CONF" ] || { echo "Belum ada klon."; return 1; }
  mapfile -t CL < "$CONF"
  local i pkg label url mark ans tok
  for i in "${!CL[@]}"; do
    IFS='|' read -r pkg label url <<< "${CL[$i]}"
    mark=""; is_active "$pkg" && mark="  *"
    printf ' %d) %s%s\n' "$((i + 1))" "$label" "$mark"
  done
  if [ "$1" = multi ]; then
    read -rp "Pilih (contoh: 1 2 | a = semua): " ans
  else
    read -rp "Pilih nomor: " ans
  fi
  ans="${ans//,/ }"
  [ -z "${ans// /}" ] && return 1
  if [ "$1" = multi ] && [[ "$ans" =~ ^[[:space:]]*[aA] ]]; then
    for i in "${!CL[@]}"; do SEL+=("${CL[$i]%%|*}"); done
    return 0
  fi
  for tok in $ans; do
    [[ "$tok" =~ ^[0-9]+$ ]] && [ "$tok" -ge 1 ] && [ "$tok" -le "${#CL[@]}" ] \
      || { echo "Nomor tidak valid: $tok"; return 1; }
    SEL+=("${CL[$((tok - 1))]%%|*}")
  done
  [ "$1" = multi ] || SEL=("${SEL[0]}")
  [ "${#SEL[@]}" -gt 0 ]
}

# ubah argumen CLI (nomor / all / package) menjadi array SEL
resolve_args() {
  SEL=()
  mapfile -t CL < "$CONF"
  local a l
  for a in "$@"; do
    if [ "$a" = all ]; then
      SEL=(); for l in "${CL[@]}"; do SEL+=("${l%%|*}"); done; break
    elif [[ "$a" =~ ^[0-9]+$ ]] && [ "$a" -ge 1 ] && [ "$a" -le "${#CL[@]}" ]; then
      SEL+=("${CL[$((a - 1))]%%|*}")
    elif grep -q "^$a|" "$CONF"; then
      SEL+=("$a")
    else
      echo "Klon tidak ada: $a"; return 1
    fi
  done
  [ "${#SEL[@]}" -gt 0 ]
}

# ---------- health check: black screen / hang / ANR ----------
# scan.sh = SATU panggilan root per siklus: status layar, ANR, screencap (di RAM),
# lalu per klon: pid, state proses, hasil sampel piksel (BLACK/OK + hash).
write_scan() {
  cat > "$BASE/scan.sh" <<'SCAN_EOF'
#!/system/bin/sh
# scan.sh RAW SW SH DOVIS DOANR pkg:l:t:r:b ...
RAW=$1; SW=$2; SH=$3; DOVIS=$4; DOANR=$5; shift 5
AWAKE=0
dumpsys power </dev/null 2>/dev/null | grep -q 'mWakefulness=Awake' && AWAKE=1
echo "AWAKE $AWAKE"
if [ "$DOANR" = "1" ]; then
  echo "ANRBEGIN"
  dumpsys window windows </dev/null 2>/dev/null | grep 'Application Not Responding' | sed 's/^/ANR /'
  dumpsys activity processes </dev/null 2>/dev/null | awk '/ProcessRecord\{/{p=$0} /notResponding=true/{print "ANR " p}'
fi
SNAP=0; FRAMEOK=0
if [ "$DOVIS" = "1" ] && [ "$AWAKE" = "1" ]; then
  for R in "$RAW" /data/local/tmp/rj.raw; do
    rm -f "$R"; screencap "$R" 2>/dev/null
    if [ -s "$R" ]; then RAW=$R; SNAP=1; break; fi
  done
  if [ "$SNAP" = "1" ]; then
    od -An -tu4 -N8 "$RAW" > "$RAW.h" 2>/dev/null
    read -r W H _ < "$RAW.h"; rm -f "$RAW.h"
    case "$W$H" in ''|*[!0-9]*) ;; *)
      size=$(stat -c %s "$RAW")
      HDR=$((size - W * H * 4))
      if [ "$HDR" -ge 0 ] && [ "$HDR" -le 64 ]; then FRAMEOK=1; OFF=$((HDR / 4)); fi ;;
    esac
  fi
fi
probe() { # l t r b -> KIND HASH
  [ "$FRAMEOK" = "1" ] || { KIND="ERR-frame"; HASH="-"; return; }
  pl=$(($1 * W / SW)); pr=$(($3 * W / SW)); pt=$(($2 * H / SH)); pb=$(($4 * H / SH))
  mx=$(((pr - pl) / 10)); my=$(((pb - pt) / 10))
  pl=$((pl + mx)); pr=$((pr - mx)); pt=$((pt + my)); pb=$((pb - my))
  cnt=$((pr - pl))
  if [ "$cnt" -le 0 ] || [ "$pb" -le "$pt" ]; then KIND="ERR-area"; HASH="-"; return; fi
  step=$(((pb - pt) / 16)); [ "$step" -ge 1 ] || step=1
  tmp="$RAW.s"; : > "$tmp"; y=$pt; k=0
  while [ "$y" -lt "$pb" ] && [ "$k" -lt 16 ]; do
    dd if="$RAW" bs=4 skip=$((OFF + y * W + pl)) count=$cnt 2>/dev/null >> "$tmp"
    y=$((y + step)); k=$((k + 1))
  done
  npix=$((k * cnt))
  nz=$(tr -d '\000' < "$tmp" | wc -c)
  HASH=$( (md5sum < "$tmp" 2>/dev/null || cksum < "$tmp") | cut -d' ' -f1)
  rm -f "$tmp"
  if [ "$nz" -le "$npix" ]; then KIND=BLACK; else KIND=OK; fi
}
for item in "$@"; do
  pkg=${item%%:*}; rest=${item#*:}
  l=${rest%%:*}; rest=${rest#*:}; t=${rest%%:*}; rest=${rest#*:}; r=${rest%%:*}; b=${rest#*:}
  pid=""
  for i in $(pidof "$pkg" 2>/dev/null); do pid=$i; break; done
  if [ -z "$pid" ]; then echo "CLONE $pkg - - SKIP -"; continue; fi
  line=""; { read -r line < "/proc/$pid/stat"; } 2>/dev/null
  s=${line##*) }; st=${s%% *}; [ -n "$st" ] || st="?"
  KIND=SKIP; HASH="-"
  [ "$SNAP" = "1" ] && probe "$l" "$t" "$r" "$b"
  echo "CLONE $pkg $pid $st $KIND $HASH"
done
rm -f "$RAW" "$RAW.s" /data/local/tmp/rj.raw /data/local/tmp/rj.raw.s
SCAN_EOF
  chmod 644 "$BASE/scan.sh"
}

# area (l t r b) jendela klon $1 (daftar HC_PKGS), sama dengan hitungan place_grid
slot_rect() {
  local i idx=-1 n cells cols=1 rows w h c r
  if [ "${GRID:-1}" != "1" ]; then echo "0 0 $SW $SH"; return; fi
  n=${#HC_PKGS[@]}
  for i in "${!HC_PKGS[@]}"; do [ "${HC_PKGS[$i]}" = "$1" ] && idx=$i; done
  if [ "$idx" -lt 0 ]; then echo "0 0 $SW $SH"; return; fi
  cells=$n; [ "${GRID_SLOTS:-0}" -gt "$cells" ] && cells=$GRID_SLOTS
  while [ $((cols * cols)) -lt "$cells" ]; do cols=$((cols + 1)); done
  rows=$(( (cells + cols - 1) / cols ))
  w=$((SW / cols)); h=$((SH / rows))
  c=$((idx % cols)); r=$((idx / cols))
  echo "$((c * w)) $((r * h)) $(((c + 1) * w)) $(((r + 1) * h))"
}

# satu siklus scan untuk semua klon di HC_PKGS -> isi SCR_AWAKE, ANR_TXT, SC_*
health_tick() {
  local p args="" rect dovis=0 doanr=0 out line tag a b c d e
  [ "${#HC_PKGS[@]}" -gt 0 ] || return 1
  if [ -z "$SW" ] || [ $((HC_N % 30)) -eq 0 ]; then screen_size; fi
  for p in "${HC_PKGS[@]}"; do
    [ -n "$p" ] && valid_pkg "$p" || continue
    rect=$(slot_rect "$p"); args="$args $p:${rect// /:}"
  done
  if [ "$BLACK_CHECKS" -gt 0 ] || [ "$FREEZE_MIN" -gt 0 ]; then dovis=1; fi
  [ $((HC_N % ANR_EVERY)) -eq 0 ] && doanr=1
  HC_N=$((HC_N + 1))
  out=$(root "sh '$BASE/scan.sh' '$RAW' $SW $SH $dovis $doanr $args")
  [ -n "$out" ] || return 1
  SC_PID=(); SC_ST=(); SC_KIND=(); SC_HASH=()
  SCR_AWAKE=1
  while IFS= read -r line; do
    tag=${line%% *}
    case "$tag" in
      AWAKE)     SCR_AWAKE=${line#* } ;;
      ANRBEGIN)  ANR_TXT="" ;;
      ANR)       ANR_TXT+="$line"$'\n' ;;
      CLONE)     read -r tag a b c d e <<< "$line"
                 SC_PID[$a]=$b; SC_ST[$a]=$c; SC_KIND[$a]=$d; SC_HASH[$a]=$e ;;
    esac
  done <<< "$out"
  return 0
}

health_reset() {
  BLACKC[$1]=0; DCOUNT[$1]=0
  unset "LASTH[$1]" "SAMESINCE[$1]"
}

# $1=pkg (butuh health_tick sebelumnya) -> HUNG (alasan; kosong = sehat), H_INFO (ringkasan)
health_check() {
  local pkg="$1" now st pat kind h
  HUNG=""; H_INFO=""
  now=$(date +%s)
  st="${SC_ST[$pkg]}"; kind="${SC_KIND[$pkg]}"; h="${SC_HASH[$pkg]}"
  pat="(^|[^A-Za-z0-9_.])${pkg//./\\.}([^A-Za-z0-9_.]|\$)"

  # 1) status proses: pid ada belum tentu hidup
  H_INFO="proc=${st:-?}"
  case "$st" in
    Z) HUNG="proses zombie"; return 0 ;;
    T|t) HUNG="proses terhenti (stopped)"; return 0 ;;
    D) DCOUNT[$pkg]=$(( ${DCOUNT[$pkg]:-0} + 1 ))
       if [ "${DCOUNT[$pkg]}" -ge 3 ]; then HUNG="proses macet (state D)"; return 0; fi ;;
    *) DCOUNT[$pkg]=0 ;;
  esac

  # 2) ANR / "tidak merespons"
  if grep -qE "$pat" <<< "$ANR_TXT"; then
    H_INFO="$H_INFO anr=1"; HUNG="ANR (aplikasi tidak merespons)"; return 0
  fi
  H_INFO="$H_INFO anr=0"

  # 3) visual: layar hitam & layar beku
  { [ "$BLACK_CHECKS" -gt 0 ] || [ "$FREEZE_MIN" -gt 0 ]; } || return 0
  if [ "$SCR_AWAKE" != "1" ]; then H_INFO="$H_INFO vis=skip(layar mati)"; return 0; fi
  H_INFO="$H_INFO vis=${kind:-?}"
  case "$kind" in
    BLACK|OK) ;;
    SKIP|"") return 0 ;;
    *) if [ -z "$VISERR_SHOWN" ]; then log "[health] cek visual gagal: $kind"; VISERR_SHOWN=1; fi
       return 0 ;;
  esac

  if [ "$kind" = "BLACK" ] && [ "$BLACK_CHECKS" -gt 0 ]; then
    BLACKC[$pkg]=$(( ${BLACKC[$pkg]:-0} + 1 ))
    if [ "${BLACKC[$pkg]}" -ge "$BLACK_CHECKS" ]; then
      HUNG="layar hitam (${BLACKC[$pkg]}x cek berturut)"; return 0
    fi
  else
    BLACKC[$pkg]=0
  fi

  if [ "$h" = "${LASTH[$pkg]}" ]; then
    [ -z "${SAMESINCE[$pkg]}" ] && SAMESINCE[$pkg]=$now
  else
    LASTH[$pkg]=$h; SAMESINCE[$pkg]=$now
  fi
  if [ "$FREEZE_MIN" -gt 0 ] && [ $((now - ${SAMESINCE[$pkg]:-$now})) -ge $((FREEZE_MIN * 60)) ]; then
    HUNG="layar beku (frame sama ${FREEZE_MIN} menit)"; return 0
  fi
  return 0
}

get_started() { [ -f "$STARTDIR/$1" ] && cat "$STARTDIR/$1"; }
set_started() { mkdir -p "$STARTDIR"; echo "$2" > "$STARTDIR/$1"; }
# dipanggil monitor setiap klon dibuka: catat waktu & buang permintaan restart lama
mark_started() { started[$1]=$(date +%s); set_started "$1" "${started[$1]}"; rm -f "$HUNGDIR/$1"; }

# proses terpisah: cek frame/ANR tiap HEALTH_EVERY detik, minta monitor restart kalau bermasalah
hc_loop() {
  need_root; load_settings
  [ "$HEALTH" = "1" ] || { log "[health] HEALTH=0, health check mati"; return; }
  write_scan; mkdir -p "$HUNGDIR" "$STARTDIR"
  log "[health] cek frame/ANR tiap ${HEALTH_EVERY} detik"
  local pkg now st last_regrid=0
  while true; do
    load_settings
    [ "$HEALTH" = "1" ] || { log "[health] dimatikan"; return; }
    mapfile -t HC_PKGS < "$ACTIVE"
    if [ "${#HC_PKGS[@]}" -gt 0 ]; then
      now=$(date +%s)
      if health_tick; then
        for pkg in "${HC_PKGS[@]}"; do
          [ -n "$pkg" ] || continue
          [ "${SC_PID[$pkg]:--}" != "-" ] || continue          # klon mati: urusan monitor
          st=$(get_started "$pkg")
          if [ -z "$st" ]; then set_started "$pkg" "$now"; continue; fi
          if [ "${LASTSTART[$pkg]}" != "$st" ]; then health_reset "$pkg"; LASTSTART[$pkg]=$st; fi
          [ $((now - st)) -ge "$STARTUP_GRACE" ] || continue   # masa loading, jangan dicek
          health_check "$pkg"
          if [ -n "$HUNG" ]; then
            echo "$now|$HUNG" > "$HUNGDIR/$pkg"
            log "[health] $(label_of "$pkg"): $HUNG -> minta restart"
            touch "$WAKE"
            health_reset "$pkg"
          fi
        done
      fi
      if [ $((now - last_regrid)) -ge "$REGRID_SEC" ]; then place_grid; last_regrid=$now; fi
    fi
    sleep "$HEALTH_EVERY"
  done
}

# diagnosa manual tanpa restart: bash JOINBYDIMZZ.sh health
cmd_health() {
  need_root; load_settings; write_scan
  mapfile -t HC_PKGS < "$ACTIVE"
  if [ "${#HC_PKGS[@]}" -eq 0 ]; then
    local pk lb ur
    while IFS='|' read -r pk lb ur; do [ -n "$pk" ] && HC_PKGS+=("$pk"); done < "$CONF"
  fi
  [ "${#HC_PKGS[@]}" -gt 0 ] || { echo "Belum ada klon."; return 1; }
  health_tick || { echo "Scan gagal (root/dumpsys bermasalah)."; return 1; }
  echo "layar menyala: $SCR_AWAKE | ukuran: ${SW}x${SH}"
  local pkg
  for pkg in "${HC_PKGS[@]}"; do
    if [ "${SC_PID[$pkg]:--}" = "-" ]; then printf ' %-12s MATI\n' "$(label_of "$pkg")"; continue; fi
    health_check "$pkg"
    printf ' %-12s %s  -> %s\n' "$(label_of "$pkg")" "$H_INFO" "${HUNG:-sehat}"
  done
}

# ---------- loop monitoring ----------
loop() {
  need_root
  declare -A fails started
  root "echo -900 > /proc/$$/oom_score_adj"
  enable_freeform
  log "Monitoring mulai"
  while true; do
    load_settings
    while IFS='|' read -r pkg label url; do
      [[ -z "$pkg" || "$pkg" == \#* ]] && continue
      is_active "$pkg" || continue
      now=$(date +%s)

      # catat hasil deteksi setiap cek (hanya di log/terminal, tidak ke Discord)
      pid=$(root "pidof '$pkg'")
      if [ -n "$pid" ]; then
        log "$label cek: JALAN (pid $pid)"
      else
        log "$label cek: MATI (pid kosong)"
      fi

      # pid ada belum tentu sehat: health check (proses terpisah) menulis permintaan restart di $HUNGDIR
      hung=""
      if [ -n "$pid" ]; then
        if [ -z "${started[$pkg]}" ]; then
          started[$pkg]=$(get_started "$pkg")
          [ -n "${started[$pkg]}" ] || { started[$pkg]=$now; set_started "$pkg" "$now"; }
        fi
        if [ -f "$HUNGDIR/$pkg" ]; then
          IFS='|' read -r hts hreason < "$HUNGDIR/$pkg"
          rm -f "$HUNGDIR/$pkg"
          [ "${hts:-0}" -ge "${started[$pkg]:-0}" ] && hung="$hreason"   # abaikan permintaan basi
        fi
      fi

      if [ -n "$pid" ] && [ -z "$hung" ]; then
        fails[$pkg]=0
        if [ "$RESTART_EVERY" -gt 0 ] && [ -n "${started[$pkg]}" ] &&
           [ $((now - started[$pkg])) -ge $((RESTART_EVERY * 60)) ]; then
          log "$label restart berkala"
          stop_clone "$pkg"; sleep 3
          launch "$pkg" "$url"; mark_started "$pkg"
          sleep "$LAUNCH_WAIT"; place_grid
        fi
        continue
      fi

      n=$(( ${fails[$pkg]:-0} + 1 ))
      if [ -n "$hung" ]; then
        log "$label bermasalah: $hung, buka ulang"
        notify "🟠 $label bermasalah: $hung, mencoba buka ulang"
      else
        log "$label mati, buka ulang"
        notify "🔴 $label disconnect / mati, mencoba buka ulang"
      fi
      rm -f "$HUNGDIR/$pkg"
      stop_clone "$pkg"; sleep 2
      launch "$pkg" "$url"; mark_started "$pkg"
      sleep "$LAUNCH_WAIT"

      if is_running "$pkg"; then
        log "$label OK"
        notify "🟢 $label berhasil dibuka ulang"
        fails[$pkg]=0
        place_grid
      else
        fails[$pkg]=$n
        log "$label gagal ($n/$MAX_FAILS)"
        notify "⚠️ $label gagal dibuka ulang ($n/$MAX_FAILS)"
        if [ "$n" -ge "$MAX_FAILS" ]; then
          log "$label jeda 120 detik"
          fails[$pkg]=0; sleep 120
        fi
      fi
    done < "$CONF"
    nap "$INTERVAL"
  done
}

# ---------- start / stop / status ----------
hc_pid() { [ -f "$HCPIDF" ] && kill -0 "$(cat "$HCPIDF")" 2>/dev/null && cat "$HCPIDF"; }
opt_pid() { [ -f "$OPTPIDF" ] && kill -0 "$(cat "$OPTPIDF")" 2>/dev/null && cat "$OPTPIDF"; }
running_pid() { [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null && cat "$PIDF"; }

follow_log() { # Ctrl+C hanya keluar dari log, monitoring tetap jalan
  echo "--- log (Ctrl+C = keluar, monitoring tetap jalan) ---"
  trap ':' INT
  tail -n 15 -f "$LOG"
  trap - INT
}

cmd_start() { # start [nomor... | all | package...]
  need_root
  [ -s "$CONF" ] || { echo "Belum ada klon. Tambah dulu."; return 1; }
  local SEL=() p
  if [ $# -eq 0 ]; then
    choose multi || { echo "Dibatalkan."; return 1; }
  else
    resolve_args "$@" || return 1
  fi
  : > "$LOG"      # setiap mulai, log yang lama dihapus
  for p in "${SEL[@]}"; do is_active "$p" || echo "$p" >> "$ACTIVE"; done
  if running_pid >/dev/null; then
    touch "$WAKE"
  else
    command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock
    nohup setsid "$SCRIPT" run >> "$LOG" 2>&1 &
    echo $! > "$PIDF"
  fi
  load_settings
  if [ "$OPT_EVERY" -gt 0 ] && ! opt_pid >/dev/null; then
    nohup setsid "$SCRIPT" opt >> "$LOG" 2>&1 &
    echo $! > "$OPTPIDF"
  fi
  if [ "$HEALTH" = "1" ] && ! hc_pid >/dev/null; then
    nohup setsid "$SCRIPT" hc >> "$LOG" 2>&1 &
    echo $! > "$HCPIDF"
  fi
  follow_log
}

stop_loop() {
  if pid=$(running_pid); then kill "$pid" 2>/dev/null; fi
  rm -f "$OPTRUN"                       # sinyal berhenti untuk proses root optimizer
  if pid=$(opt_pid); then kill "$pid" 2>/dev/null; fi
  if pid=$(hc_pid); then kill "$pid" 2>/dev/null; fi
  rm -f "$PIDF" "$WAKE" "$OPTPIDF" "$HCPIDF"
  rm -rf "$HUNGDIR" "$STARTDIR"; mkdir -p "$HUNGDIR" "$STARTDIR"
  root "pkill -f 'optd[.]sh'; pkill -f 'scan[.]sh'; rm -f '$RAW' '$RAW.s'"   # [.] supaya tidak membunuh shell pembungkusnya sendiri
  sleep 1
  restore_system
  command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock
}

cmd_stop() { # stop [nomor... | all | package...]
  need_root
  local SEL=() p
  if [ $# -eq 0 ]; then
    choose multi || { echo "Dibatalkan."; return 1; }
  else
    resolve_args "$@" || return 1
  fi
  for p in "${SEL[@]}"; do
    grep -vxF "$p" "$ACTIVE" > "$ACTIVE.tmp"; mv "$ACTIVE.tmp" "$ACTIVE"
    stop_clone "$p"
    echo "Berhenti: $(label_of "$p")"
  done
  if [ ! -s "$ACTIVE" ]; then
    stop_loop
    echo "Monitoring berhenti."
  fi
}

cmd_status() {
  need_root
  if running_pid >/dev/null; then echo "Monitoring: AKTIF"; else echo "Monitoring: mati"; fi
  if opt_pid >/dev/null; then echo "Optimizer : AKTIF"; else echo "Optimizer : mati"; fi
  if hc_pid >/dev/null; then echo "Health    : AKTIF"; else echo "Health    : mati"; fi
  local i=0 pkg label url s m
  while IFS='|' read -r pkg label url; do
    [ -z "$pkg" ] && continue
    i=$((i + 1))
    if is_running "$pkg"; then s="jalan"; else s="mati"; fi
    if is_active "$pkg"; then m="*"; else m=""; fi
    printf ' %d) %-12s %-6s %s\n' "$i" "$label" "$s" "$m"
  done < "$CONF"
  echo " (* = dipantau)"
}

# ---------- menu ----------
pause() { echo; read -rp "Enter untuk kembali... " _; }

menu_add() {
  mapfile -t PK < <(root "pm list packages" | sed 's/^package://' | grep -i roblox)
  local pkg label url i
  if [ "${#PK[@]}" -gt 0 ]; then
    for i in "${!PK[@]}"; do echo " $((i + 1))) ${PK[$i]}"; done
    read -rp "Nomor / nama package: " pkg
    if [[ "$pkg" =~ ^[0-9]+$ ]]; then pkg="${PK[$((pkg - 1))]}"; fi
  else
    read -rp "Nama package: " pkg
  fi
  [ -z "$pkg" ] && { echo "Dibatalkan."; return; }
  read -rp "Label [$pkg]: " label
  read -rp "Link private server (kosong = buka app saja): " url
  cmd_add "$pkg" "$url" "${label:-$pkg}"
}

menu_edit() {
  choose || { echo "Dibatalkan."; return; }
  local pkg="${SEL[0]}" cur_label cur_url label url
  IFS='|' read -r _ cur_label cur_url < <(grep "^$pkg|" "$CONF")
  read -rp "Label [$cur_label]: " label
  read -rp "Link [${cur_url:-kosong}] (- = kosongkan): " url
  if [ "$url" = "-" ]; then url=""; else url="${url:-$cur_url}"; fi
  cmd_add "$pkg" "$url" "${label:-$cur_label}"
}

menu_remove() {
  choose || { echo "Dibatalkan."; return; }
  local ok; read -rp "Hapus $(label_of "${SEL[0]}")? (y/N): " ok
  if [[ "$ok" =~ ^[yY]$ ]]; then cmd_remove "${SEL[0]}"; else echo "Dibatalkan."; fi
}

menu_settings() {
  load_settings
  echo " 1) INTERVAL      $INTERVAL (detik antar cek hidup/mati)"
  echo " 2) LAUNCH_WAIT   $LAUNCH_WAIT (detik tunggu buka)"
  echo " 3) RESTART_EVERY $RESTART_EVERY (menit, 0 = mati)"
  echo " 4) MAX_FAILS     $MAX_FAILS"
  echo " 5) GRID          $GRID (1 = tata otomatis)"
  echo " 6) LANDSCAPE     $LANDSCAPE (1 = layar landscape)"
  echo " 7) GRID_SLOTS    $GRID_SLOTS (4 = selalu split 2x2, 0 = ikut jumlah klon)"
  echo " 8) OPT_EVERY     $OPT_EVERY (detik antar optimasi, 0 = mati, min 1)"
  echo " 9) MEM_MIN       $MEM_MIN (MB; di bawah ini RAM dibersihkan)"
  echo "10) PERF          $PERF (1 = CPU governor performance)"
  echo "11) REGRID_SEC    $REGRID_SEC (detik; rapikan jendela 2x2, min 10)"
  echo "12) HEALTH        $HEALTH (1 = deteksi hang/black screen/ANR)"
  echo "13) BLACK_CHECKS  $BLACK_CHECKS (layar hitam N cek berturut = restart, 0 = mati)"
  echo "14) FREEZE_MIN    $FREEZE_MIN (menit frame sama = beku, 0 = mati)"
  echo "15) STARTUP_GRACE $STARTUP_GRACE (detik tunggu setelah buka sebelum dicek)"
  echo "16) HEALTH_EVERY  $HEALTH_EVERY (detik antar cek frame/ANR, min 5)"
  local n v key
  read -rp "Ubah nomor (Enter = batal): " n
  case "$n" in 1) key=INTERVAL;; 2) key=LAUNCH_WAIT;; 3) key=RESTART_EVERY;; 4) key=MAX_FAILS;; 5) key=GRID;; 6) key=LANDSCAPE;;
    7) key=GRID_SLOTS;; 8) key=OPT_EVERY;; 9) key=MEM_MIN;; 10) key=PERF;; 11) key=REGRID_SEC;; 16) key=HEALTH_EVERY;;
    12) key=HEALTH;; 13) key=BLACK_CHECKS;; 14) key=FREEZE_MIN;; 15) key=STARTUP_GRACE;; *) return;; esac
  read -rp "Nilai baru: " v
  cmd_config "$key=$v"
}

menu_webhook() {
  cmd_webhook show
  echo " 1) Atur / ganti URL"
  echo " 2) Tes kirim"
  echo " 3) Matikan"
  local n v
  read -rp "Pilih (Enter = batal): " n
  case "$n" in
    1) read -rp "URL webhook Discord: " v; [ -n "$v" ] && cmd_webhook "$v" ;;
    2) cmd_webhook test ;;
    3) cmd_webhook off ;;
    *) ;;
  esac
}

menu() {
  need_root
  local st c
  while true; do
    clear 2>/dev/null
    st="mati"; running_pid >/dev/null && st="AKTIF"
    echo "== REJOINER  |  monitoring: $st =="
    echo " 1) Mulai       4) Tambah"
    echo " 2) Hentikan    5) Edit"
    echo " 3) Status      6) Hapus"
    echo " 7) Pengaturan  8) Webhook"
    echo " 0) Keluar"
    read -rp "> " c || exit 0
    echo
    case "$c" in
      1) cmd_start ;;
      2) cmd_stop; pause ;;
      3) cmd_status; pause ;;
      4) menu_add; pause ;;
      5) menu_edit; pause ;;
      6) menu_remove; pause ;;
      7) menu_settings; pause ;;
      8) menu_webhook; pause ;;
      0|q) exit 0 ;;
      *) ;;
    esac
  done
}

usage() {
cat <<EOF
Rejoiner Termux (root)

  $0                      menu
  $0 start [1 2 | all]    mulai klon terpilih, log langsung tampil
  $0 stop  [1 2 | all]    hentikan klon
  $0 status               status
  $0 list                 daftar klon
  $0 detect               cari package Roblox
  $0 add <pkg> [url] [label]
  $0 remove <pkg>
  $0 config KEY=VALUE
  $0 webhook <url|test|off|show>   notifikasi Discord
  $0 logs                 lihat log
  $0 optnow               jalankan optimasi berat 1x sekarang
  $0 kill add|del|list    app lain yang di-force-stop berkala (opsional)
  $0 health               diagnosa hang/black screen/ANR (tanpa restart)
EOF
}

case "$1" in
  detect)  cmd_detect ;;
  add)     shift; cmd_add "$@" ;;
  remove)  cmd_remove "$2" ;;
  list)    cmd_list ;;
  config)  cmd_config "$2" ;;
  webhook) shift; cmd_webhook "$@" ;;
  start)   shift; cmd_start "$@" ;;
  stop)    shift; cmd_stop "$@" ;;
  status)  cmd_status ;;
  logs)    follow_log ;;
  run)     loop ;;
  opt)     opt_loop ;;
  hc)      hc_loop ;;
  kill)    shift; cmd_kill "$@" ;;
  health)  cmd_health ;;
  optnow)  need_root; load_settings; write_optd
           root "sh '$BASE/optd.sh' x x '$SET' '$ACTIVE' '$LOG' '$KILLLIST' once"; echo "Optimasi selesai." ;;
  menu|"") menu ;;
  *)       usage ;;
esac
