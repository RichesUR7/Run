#!/usr/bin/env bash
# Run — portable, read-only system and hardware health inspector.
# Diagnostics do not change system settings or write test data. Reports are written only
# when --report or --json is explicitly requested.
set -uo pipefail

RUN_VERSION="1.1.0"
PROGRAM_NAME="Run"
QUICK=0 TUI=0 VERBOSE=0 NETWORK_TEST=0
PLAIN=0 REPORT_FILE="" JSON_FILE="" WATCH_INTERVAL="" SECTION_FILTER=""
COLOR=0
[[ -t 1 && -z "${NO_COLOR:-}" ]] && COLOR=1
CHECK_SECTION=() CHECK_NAME=() CHECK_STATUS=() CHECK_DETAIL=()
COUNT_PASS=0 COUNT_WARN=0 COUNT_FAIL=0 COUNT_INFO=0 COUNT_SKIP=0
OVERALL="INFO"

usage() {
cat <<'EOF'
Run — portable system and hardware health inspector

Usage: ./Run.sh [options]
  -h, --help              Show help
  --version               Show version
  --quick                 Check system, CPU, memory, storage, network
  --all                   Run all checks (default)
  --section LIST          Comma-separated sections; repeatable
  --tui                   Interactive terminal menu
  --network-test          Perform external DNS and ICMP tests
  --report FILE           Save human-readable report
  --json FILE             Save JSON report
  --watch SECONDS         Repeat scan (no report output)
  --verbose               Show additional inventory/log details
  --plain, --no-color     Disable ANSI color

Sections: system,cpu,memory,storage,network,thermal,battery,devices,
          embedded,processes,security,logs

Exit codes: 0 = no WARN/FAIL; 1 = WARN or FAIL; 2 = usage/output error.
Checks are best-effort. SKIP means a check could not be performed, not that hardware is healthy.
EOF
}
exists() { command -v "$1" >/dev/null 2>&1; }
trim_one_line() {
  local s="${1:-}"
  # Replace terminal control characters to prevent escape-sequence injection.
  s="$(printf '%s' "$s" | LC_ALL=C tr '\001-\010\013\014\016-\037\177' ' ')"
  s="${s//$'\n'/; }"; s="${s//$'\r'/ }"; s="${s//$'\t'/ }"
  ((${#s} <= 230)) || s="${s:0:227}..."
  printf '%s' "$s"
}
status_color() {
  (( COLOR )) || return 0
  case "$1" in
    PASS) printf '\033[32m' ;; WARN) printf '\033[33m' ;;
    FAIL) printf '\033[31m' ;; INFO) printf '\033[36m' ;;
    SKIP) printf '\033[90m' ;; *) printf '\033[0m' ;;
  esac
}
reset_color() { if (( COLOR )); then printf '\033[0m'; fi; }
section_header() { printf '\n== %s ==\n'; printf '%s\n' '--------------------------------------------------------------------------------'; }
record_check() {
  local section="$1" name="$2" status="$3" detail
  detail="$(trim_one_line "${4:-}")"
  CHECK_SECTION+=("$section"); CHECK_NAME+=("$name")
  CHECK_STATUS+=("$status"); CHECK_DETAIL+=("$detail")
  case "$status" in
    PASS) ((COUNT_PASS+=1)) ;; WARN) ((COUNT_WARN+=1)) ;;
    FAIL) ((COUNT_FAIL+=1)) ;; SKIP) ((COUNT_SKIP+=1)) ;;
    *) ((COUNT_INFO+=1)) ;;
  esac
  status_color "$status"; printf '  %-5s ' "$status"; reset_color
  printf '%-28s %s\n' "$name" "$detail"
}
reset_results() {
  CHECK_SECTION=() CHECK_NAME=() CHECK_STATUS=() CHECK_DETAIL=()
  COUNT_PASS=0 COUNT_WARN=0 COUNT_FAIL=0 COUNT_INFO=0 COUNT_SKIP=0
}
section_enabled() {
  local wanted="$1"
  if [[ -n "$SECTION_FILTER" ]]; then
    case ",$SECTION_FILTER," in *",$wanted,"*) return 0 ;; *) return 1 ;; esac
  fi
  if (( QUICK )); then
    case "$wanted" in system|cpu|memory|storage|network) return 0 ;; *) return 1 ;; esac
  fi
  return 0
}
safe_read() { [[ -r "$1" ]] && head -n 1 "$1" 2>/dev/null || true; }
percent_status() {
  awk -v p="${1:-0}" 'BEGIN {if (p>=95) print "FAIL"; else if (p>=85) print "WARN"; else print "PASS"}'
}
count_glob() {
  local n
  n="$(compgen -G "$1" 2>/dev/null | wc -l | awk '{print $1}')"
  printf '%s' "${n:-0}"
}
reset_section_header() { printf '\n== %s ==\n%s\n' "$1" '--------------------------------------------------------------------------------'; }

check_system() {
  reset_section_header "Operating system and platform"
  local os kernel arch host up virt model
  os=""
  if [[ -r /etc/os-release ]]; then
    os="$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-}")"
  fi
  if [[ -z "$os" ]] && exists sw_vers; then os="$(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null)"; fi
  [[ -n "$os" ]] || os="$(uname -s 2>/dev/null || printf Unknown)"
  kernel="$(uname -sr 2>/dev/null || printf unknown)"
  arch="$(uname -m 2>/dev/null || printf unknown)"
  host="$(hostname 2>/dev/null || printf unknown)"
  record_check system "Operating system" INFO "$os"
  record_check system "Kernel / architecture" INFO "$kernel; $arch"
  record_check system "Hostname" INFO "$host"
  if exists uptime; then
    up="$(uptime -p 2>/dev/null || uptime 2>/dev/null || true)"
    [[ -n "$up" ]] && record_check system "Uptime" INFO "$up" || record_check system "Uptime" SKIP "Unavailable"
  else record_check system "Uptime" SKIP "uptime command unavailable"; fi
  if [[ "$(id -u 2>/dev/null || printf 1)" == 0 ]]; then
    record_check system "Privileges" INFO "Running as root; no automatic privilege escalation is used"
  else record_check system "Privileges" INFO "Running as non-root; some hardware and log checks may be restricted"; fi
  virt=""
  if exists systemd-detect-virt; then virt="$(systemd-detect-virt 2>/dev/null || true)"; fi
  if [[ -z "$virt" && -r /proc/1/cgroup ]] && grep -Eqi 'docker|containerd|kubepods|lxc|podman' /proc/1/cgroup 2>/dev/null; then virt="container"; fi
  if [[ -n "$virt" && "$virt" != none ]]; then record_check system "Virtualization" INFO "$virt; host hardware visibility may be limited"
  else record_check system "Virtualization" INFO "No supported guest detector reported virtualization"; fi
  model=""
  [[ -r /sys/class/dmi/id/product_name ]] && model="$(safe_read /sys/class/dmi/id/product_name)"
  [[ -n "$model" ]] || { [[ -r /proc/device-tree/model ]] && model="$(tr -d '\000' < /proc/device-tree/model 2>/dev/null || true)"; }
  [[ -n "$model" ]] || { exists sysctl && model="$(sysctl -n hw.model 2>/dev/null || true)"; }
  [[ -n "$model" ]] && record_check system "System model" INFO "$model"
  if exists timedatectl; then
    case "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)" in
      yes) record_check system "Clock synchronization" INFO "System reports clock synchronized" ;;
      no) record_check system "Clock synchronization" INFO "Clock not synchronized; may be expected offline" ;;
      *) record_check system "Clock synchronization" SKIP "Status unavailable" ;;
    esac
  else record_check system "Clock synchronization" SKIP "No supported time-sync status command"; fi
}
check_cpu() {
  reset_section_header "CPU and chip"
  local model cores load vendor
  model=""
  if exists sysctl; then model="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || sysctl -n hw.model 2>/dev/null || true)"; fi
  [[ -n "$model" ]] || { exists lscpu && model="$(lscpu 2>/dev/null | awk -F: '/Model name|Hardware|Processor|Model:/ {sub(/^[ \t]+/,"",$2); if($2!=""){print $2;exit}}')"; }
  [[ -n "$model" ]] || { [[ -r /proc/cpuinfo ]] && model="$(awk -F: '/^(model name|Hardware|Processor|cpu model)[ \t]*:/ {sub(/^[ \t]+/,"",$2);if($2!=""){print $2;exit}}' /proc/cpuinfo)"; }
  [[ -n "$model" ]] && record_check cpu "CPU / SoC model" INFO "$model" || record_check cpu "CPU / SoC model" SKIP "Model string unavailable"
  cores="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  [[ "$cores" =~ ^[1-9][0-9]*$ ]] || { cores="$(sysctl -n hw.ncpu 2>/dev/null || true)"; }
  [[ "$cores" =~ ^[1-9][0-9]*$ ]] || { cores="$(grep -c '^processor[[:space:]]*:' /proc/cpuinfo 2>/dev/null || true)"; }
  if [[ "$cores" =~ ^[1-9][0-9]*$ ]]; then record_check cpu "Logical CPU count" PASS "$cores online processor(s)"
  else cores=0; record_check cpu "Logical CPU count" SKIP "CPU count unavailable"; fi
  load=""
  [[ -r /proc/loadavg ]] && load="$(awk '{print $1 " / " $2 " / " $3}' /proc/loadavg)"
  [[ -n "$load" ]] || { exists sysctl && load="$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}')"; }
  if [[ -n "$load" ]]; then
    record_check cpu "Load average" INFO "$load (typically 1 / 5 / 15 minute values)"
    if [[ -r /proc/loadavg && "$cores" =~ ^[1-9][0-9]*$ ]]; then
      local l1
      l1="$(awk '{print $1}' /proc/loadavg)"
      if awk -v l="$l1" -v c="$cores" 'BEGIN{exit !(l>c*1.5)}'; then
        record_check cpu "CPU load pressure" INFO "Load exceeds 1.5 × CPU count; load includes runnable and some blocked tasks"
      else record_check cpu "CPU load pressure" PASS "Load below advisory threshold"; fi
    fi
  else record_check cpu "Load average" SKIP "Unavailable"; fi
  vendor=""
  [[ -r /proc/cpuinfo ]] && vendor="$(awk -F: '/^(vendor_id|CPU implementer)[ \t]*:/ {sub(/^[ \t]+/,"",$2);print $2;exit}' /proc/cpuinfo)"
  [[ -n "$vendor" ]] && record_check cpu "CPU vendor / implementer" INFO "$vendor"
}
check_memory() {
  reset_section_header "Memory and swap"
  local total avail used status swap
  total="" avail=""
  if [[ -r /proc/meminfo ]]; then
    read -r total avail < <(awk '/^MemTotal:/{t=$2}/^MemAvailable:/{a=$2}END{print t,a}' /proc/meminfo)
  elif exists sysctl && exists vm_stat; then
    local bytes vm page free inactive spec purge pages
    bytes="$(sysctl -n hw.memsize 2>/dev/null || true)"; vm="$(vm_stat 2>/dev/null || true)"
    page="$(printf '%s\n' "$vm" | sed -n 's/.*page size of \([0-9][0-9]*\) bytes.*/\1/p' | head -n1)"
    [[ "$page" =~ ^[1-9][0-9]*$ ]] || page=4096
    free="$(printf '%s\n' "$vm" | awk -F: '/Pages free/ {gsub(/[^0-9]/,"",$2);print $2;exit}')"
    inactive="$(printf '%s\n' "$vm" | awk -F: '/Pages inactive/ {gsub(/[^0-9]/,"",$2);print $2;exit}')"
    spec="$(printf '%s\n' "$vm" | awk -F: '/Pages speculative/ {gsub(/[^0-9]/,"",$2);print $2;exit}')"
    purge="$(printf '%s\n' "$vm" | awk -F: '/Pages purgeable/ {gsub(/[^0-9]/,"",$2);print $2;exit}')"
    if [[ "$bytes" =~ ^[1-9][0-9]*$ ]]; then
      total=$((bytes/1024))
      pages="$(awk -v a="${free:-0}" -v b="${inactive:-0}" -v c="${spec:-0}" -v d="${purge:-0}" 'BEGIN{printf "%.0f",a+b+c+d}')"
      avail="$(awk -v p="$pages" -v s="$page" 'BEGIN{printf "%.0f",p*s/1024}')"
    fi
  fi
  if [[ "$total" =~ ^[1-9][0-9]*$ && "$avail" =~ ^[0-9]+$ ]] && (( avail <= total )); then
    used="$(awk -v t="$total" -v a="$avail" 'BEGIN{printf "%.1f",(t-a)*100/t}')"
    status="$(percent_status "$used")"
    record_check memory "Physical memory" "$status" "${used}% estimated in use; $((avail/1024)) MiB available of $((total/1024)) MiB"
  else record_check memory "Physical memory" SKIP "Reliable total/available memory values unavailable"; fi
  swap=""
  if [[ -r /proc/meminfo ]]; then swap="$(awk '/^SwapTotal:/{t=$2}/^SwapFree:/{f=$2}END{if(t!="")printf "%.0f MiB total, %.0f MiB free",t/1024,f/1024}' /proc/meminfo)"
  elif exists sysctl; then swap="$(sysctl -n vm.swapusage 2>/dev/null || true)"; fi
  [[ -n "$swap" ]] && record_check memory "Swap" INFO "$swap" || record_check memory "Swap" SKIP "Swap metrics unavailable"
}
check_storage() {
  reset_section_header "Storage and file systems"
  local line total used avail pct fs devs smartlist dev out health
  line="$(df -Pk / 2>/dev/null | awk 'NR==2{print $2,$3,$4,$5}')"
  if [[ -n "$line" ]]; then
    read -r total used avail pct <<< "$line"; pct="${pct%%%}"
    if [[ "$pct" =~ ^[0-9]+$ ]]; then record_check storage "Root filesystem space" "$(percent_status "$pct")" "${pct}% used; $((avail/1024)) MiB available"
    else record_check storage "Root filesystem space" INFO "df returned: $line"; fi
  else record_check storage "Root filesystem space" SKIP "df could not report root filesystem"; fi
  fs=""
  exists findmnt && fs="$(findmnt -n -o FSTYPE / 2>/dev/null || true)"
  [[ -n "$fs" ]] || fs="$(mount 2>/dev/null | awk '$3=="/"{print $5;exit}')"
  [[ -n "$fs" ]] && record_check storage "Root filesystem type" INFO "$fs" || record_check storage "Root filesystem type" SKIP "Filesystem type unavailable"
  line="$(df -iP / 2>/dev/null | awk 'NR==2{print $5}')"; pct="${line%%%}"
  if [[ "$pct" =~ ^[0-9]+$ ]]; then record_check storage "Root inode usage" "$(percent_status "$pct")" "${pct}% inodes used"
  else record_check storage "Root inode usage" SKIP "Inode usage not reported"; fi
  devs=""
  if exists lsblk; then devs="$(lsblk -dn -o NAME,SIZE,TYPE,MODEL 2>/dev/null | awk '$3=="disk"{print $1,$2,$4}' | head -n 8)"
  elif exists diskutil; then devs="$(diskutil list 2>/dev/null | awk '/^\/dev\/disk/{print; n++;if(n==8)exit}')"
  elif exists geom; then devs="$(geom disk list 2>/dev/null | awk '/Geom name:/{print $3;n++;if(n==8)exit}')"; fi
  if [[ -n "$devs" ]]; then record_check storage "Physical storage devices" INFO "$(printf '%s' "$devs" | tr '\n' ';' | cut -c1-180)"
    (( VERBOSE )) && printf '%s\n' "$devs" | sed 's/^/    /'
  else record_check storage "Physical storage devices" SKIP "No supported disk inventory result (common in containers)"; fi
  if exists smartctl; then
    smartlist="$(smartctl --scan 2>/dev/null | awk 'NF&&$1~/^\//{print $1}' | head -n 6)"
    if [[ -z "$smartlist" ]]; then record_check storage "SMART health" SKIP "smartctl found but no compatible devices were discovered"
    else
      while IFS= read -r dev; do
        [[ -n "$dev" ]] || continue
        out="$(smartctl -H "$dev" 2>&1 || true)"
        if printf '%s\n' "$out" | grep -Eqi 'overall-health.*PASSED|SMART Health Status:[[:space:]]*OK'; then
          record_check storage "SMART $(basename "$dev")" PASS "Drive self-assessment passed; this does not guarantee remaining lifespan"
        elif printf '%s\n' "$out" | grep -Eqi 'overall-health.*FAILED|SMART Health Status:[[:space:]]*(FAILED|BAD)|FAILING_NOW'; then
          record_check storage "SMART $(basename "$dev")" FAIL "Drive reports a failing SMART health status"
        elif printf '%s\n' "$out" | grep -Eqi 'SMART overall-health self-assessment test result:.*PASSED'; then
          record_check storage "SMART $(basename "$dev")" PASS "Drive self-assessment passed"
        else record_check storage "SMART $(basename "$dev")" SKIP "Health status unavailable/unsupported or access denied"; fi
        if (( VERBOSE )) && [[ -n "$out" ]]; then printf '%s\n' "$out" | head -n 12 | sed 's/^/    /'; fi
      done <<< "$smartlist"
    fi
  else record_check storage "SMART health" SKIP "smartctl not installed"; fi
  if exists nvme; then
    smartlist="$(nvme list 2>/dev/null | awk '$1~/^\/dev\/nvme[0-9]+n[0-9]+$/{print $1}' | head -n 6)"
    if [[ -z "$smartlist" ]]; then record_check storage "NVMe health" SKIP "nvme-cli found but no NVMe namespaces were listed"
    else
      while IFS= read -r dev; do
        [[ -n "$dev" ]] || continue
        out="$(nvme smart-log "$dev" 2>/dev/null || true)"
        if [[ -z "$out" ]]; then record_check storage "NVMe $(basename "$dev")" SKIP "SMART log unavailable; access/controller support may be limited"; continue; fi
        local critical spare usedp errors temp
        critical="$(printf '%s\n' "$out" | awk -F: '/^critical_warning/{gsub(/[ \t]/,"",$2);print $2;exit}')"
        spare="$(printf '%s\n' "$out" | awk -F: '/^available_spare:/{gsub(/[ \t%]/,"",$2);print $2;exit}')"
        usedp="$(printf '%s\n' "$out" | awk -F: '/^percentage_used:/{gsub(/[ \t%]/,"",$2);print $2;exit}')"
        errors="$(printf '%s\n' "$out" | awk -F: '/^media_errors:/{gsub(/[ \t]/,"",$2);print $2;exit}')"
        temp="$(printf '%s\n' "$out" | awk -F: '/^temperature:/{sub(/^[ \t]+/,"",$2);print $2;exit}')"
        if [[ "$critical" =~ ^[0-9]+$ ]] && (( critical != 0 )); then
          record_check storage "NVMe $(basename "$dev")" FAIL "critical_warning=$critical; temp=${temp:-unknown}; media_errors=${errors:-unknown}"
        elif [[ "$spare" =~ ^[0-9]+$ ]] && (( spare < 10 )); then
          record_check storage "NVMe $(basename "$dev")" WARN "Available spare is low (${spare}%); temp=${temp:-unknown}"
        elif [[ "$errors" =~ ^[0-9]+$ ]] && (( errors > 0 )); then
          record_check storage "NVMe $(basename "$dev")" WARN "media_errors=$errors; investigate drive logs"
        elif [[ "$usedp" =~ ^[0-9]+$ ]] && (( usedp >= 100 )); then
          record_check storage "NVMe $(basename "$dev")" WARN "percentage_used=${usedp}%; rated endurance estimate reached/exceeded"
        else
          record_check storage "NVMe $(basename "$dev")" INFO "critical_warning=${critical:-unknown}; spare=${spare:-unknown}%; used=${usedp:-unknown}%; media_errors=${errors:-unknown}; temp=${temp:-unknown}"
        fi
      done <<< "$smartlist"
    fi
  else record_check storage "NVMe health" SKIP "nvme-cli not installed"; fi
}
check_network() {
  reset_section_header "Network and connectivity"
  local ifs route dns result
  ifs=""
  if exists ip; then ifs="$(ip -o link show up 2>/dev/null | awk -F': ' '$2!="lo"{sub(/@.*/,"",$2);print $2}' | paste -sd ',' -)"
  elif exists ifconfig; then ifs="$(ifconfig -a 2>/dev/null | awk '/^[[:alnum:]_.-]+: flags=/{n=$1;sub(/:$/,"",n);if(n!="lo0"&&n!="lo")print n}' | paste -sd ',' -)"; fi
  [[ -n "$ifs" ]] && record_check network "Active interfaces" INFO "$ifs" || record_check network "Active interfaces" INFO "No visible active non-loopback interface"
  route=""
  exists ip && route="$(ip route show default 2>/dev/null | head -n1)"
  [[ -n "$route" ]] || { exists route && route="$(route -n get default 2>/dev/null | awk '/gateway:|interface:/{printf "%s%s ",$1,$2}')"; }
  [[ -n "$route" ]] && record_check network "Default route" INFO "$route" || record_check network "Default route" INFO "No default route visible; offline/isolated systems may be intentional"
  dns="$(awk '$1=="nameserver"{n++}END{print n+0}' /etc/resolv.conf 2>/dev/null)"
  if [[ "$dns" =~ ^[0-9]+$ ]] && (( dns > 0 )); then record_check network "DNS configuration" INFO "$dns nameserver entr$( ((dns==1)) && printf 'y' || printf 'ies') visible in /etc/resolv.conf"
  else record_check network "DNS configuration" INFO "No nameserver visible in resolv.conf; resolver may be managed elsewhere"; fi
  if (( NETWORK_TEST )); then
    result=""
    if exists getent; then result="$(getent hosts example.com 2>/dev/null | head -n1)"
    elif exists host; then result="$(host example.com 2>/dev/null | head -n1)"
    elif exists nslookup; then result="$(nslookup example.com 2>/dev/null | grep -m1 'Address' || true)"; fi
    [[ -n "$result" ]] && record_check network "External DNS test" PASS "example.com resolved" || record_check network "External DNS test" INFO "DNS test failed or unsupported; captive portals and policy may affect results"
    if exists ping; then
      if [[ "$(uname -s)" == Darwin || "$(uname -s)" == *BSD ]]; then ping -n -c 1 -W 2000 1.1.1.1 >/dev/null 2>&1
      else ping -n -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; fi
      if (( $? == 0 )); then record_check network "Outbound ICMP test" PASS "Received reply from 1.1.1.1"
      else record_check network "Outbound ICMP test" INFO "No ICMP reply; firewalls may block ping even when internet works"; fi
    else record_check network "Outbound ICMP test" SKIP "ping unavailable"; fi
  else record_check network "External connectivity test" SKIP "Not run; --network-test makes DNS/ICMP requests"; fi
}
check_thermal() {
  reset_section_header "Thermal sensors and cooling"
  local z raw label temp n=0 fans
  for z in /sys/class/thermal/thermal_zone*; do
    [[ -d "$z" ]] || continue
    raw="$(safe_read "$z/temp")"; label="$(safe_read "$z/type")"; [[ -n "$label" ]] || label="$(basename "$z")"
    [[ "$raw" =~ ^-?[0-9]+$ ]] || continue
    temp="$(awk -v t="$raw" 'BEGIN{if(t>1000||t< -1000)printf "%.1f",t/1000;else printf "%.1f",t}')"
    n=$((n+1))
    # Generic thresholds are deliberately advisory; sensors may represent different components.
    if awk -v t="$temp" 'BEGIN{exit !(t>=100)}'; then record_check thermal "$label temperature" WARN "${temp} C; generic high-temperature threshold, verify sensor-specific limits"
    elif awk -v t="$temp" 'BEGIN{exit !(t>=85)}'; then record_check thermal "$label temperature" INFO "${temp} C; elevated reading, sensor type/limit may differ"
    else record_check thermal "$label temperature" INFO "${temp} C"; fi
  done
  if (( n == 0 )); then
    if exists sensors; then
      local s
      s="$(sensors 2>/dev/null | awk '/^[^ \t].*:/{print; n++;if(n==5)exit}' | paste -sd ';' -)"
      [[ -n "$s" ]] && record_check thermal "lm-sensors inventory" INFO "Sensor data available; raw sensor limits are not normalized" || record_check thermal "Thermal sensors" SKIP "sensors returned no readable inventory"
      (( VERBOSE )) && sensors 2>/dev/null | head -n 35 | sed 's/^/    /'
    else record_check thermal "Thermal sensors" SKIP "No readable thermal zones or sensors command"; fi
  fi
  if exists vcgencmd; then
    local pi flags
    pi="$(vcgencmd measure_temp 2>/dev/null | sed 's/^temp=//')"
    [[ -n "$pi" ]] && record_check thermal "Raspberry Pi temperature" INFO "$pi"
    flags="$(vcgencmd get_throttled 2>/dev/null | sed 's/^.*=//')"
    if [[ "$flags" =~ ^0x[0-9a-fA-F]+$ ]]; then
      if (( flags == 0 )); then record_check thermal "Raspberry Pi throttling" PASS "No current or historical flags reported"
      else record_check thermal "Raspberry Pi throttling" WARN "Nonzero flags $flags may include historical undervoltage/throttling; decode bit flags for details"; fi
    fi
  fi
  fans="$(count_glob '/sys/class/hwmon/hwmon*/fan*_input')"
  if (( fans > 0 )); then record_check thermal "Fan tachometer readings" INFO "$fans fan reading(s) exposed"
  else record_check thermal "Fan tachometer readings" SKIP "No fan tachometer values exposed; common on laptops and embedded boards"; fi
}
check_battery() {
  reset_section_header "Battery and power"
  local b n=0 cap state full design hp health
  for b in /sys/class/power_supply/BAT* /sys/class/power_supply/battery; do
    [[ -d "$b" ]] || continue
    n=$((n+1)); cap="$(safe_read "$b/capacity")"; state="$(safe_read "$b/status")"
    health="$(safe_read "$b/health")"; full="$(safe_read "$b/energy_full")"; design="$(safe_read "$b/energy_full_design")"
    if [[ "$cap" =~ ^[0-9]+$ ]] && (( cap <= 100 )); then
      if (( cap <= 15 )) && [[ "$state" == Discharging ]]; then record_check battery "$(basename "$b") charge" WARN "${cap}% remaining; low while discharging"
      else record_check battery "$(basename "$b") charge" INFO "${cap}% remaining; state=${state:-unknown}"; fi
    else record_check battery "$(basename "$b") charge" SKIP "Valid percentage not exposed; charge_now is deliberately not treated as percent"; fi
    if [[ "$full" =~ ^[0-9]+$ && "$design" =~ ^[0-9]+$ ]] && (( design > 0 )); then
      hp="$(awk -v f="$full" -v d="$design" 'BEGIN{printf "%.1f",100*f/d}')"
      if awk -v h="$hp" 'BEGIN{exit !(h<60)}'; then record_check battery "$(basename "$b") wear estimate" WARN "Full/design ratio ${hp}%; vendor-specific diagnosis not available"
      else record_check battery "$(basename "$b") wear estimate" INFO "Full/design ratio ${hp}%; estimate only"; fi
    elif [[ -n "$health" ]]; then record_check battery "$(basename "$b") reported health" INFO "$health"
    else record_check battery "$(basename "$b") wear data" SKIP "Wear data unavailable"; fi
  done
  if (( n == 0 )) && exists pmset; then
    local apple
    apple="$(pmset -g batt 2>/dev/null || true)"
    if [[ -n "$apple" ]]; then record_check battery "macOS battery" INFO "$(printf '%s' "$apple" | tr '\n' ';')"
    else record_check battery "Battery presence" SKIP "No readable battery interface"; fi
  elif (( n == 0 )); then record_check battery "Battery presence" SKIP "No battery interface detected; desktops commonly have no battery"; fi
}
check_devices() {
  reset_section_header "Hardware and peripheral inventory"
  local n
  if exists lspci; then
    n="$(lspci 2>/dev/null | awk 'NF{n++}END{print n+0}')"; record_check devices "PCI/PCIe inventory" INFO "$n device(s)"
    (( VERBOSE )) && lspci -nn 2>/dev/null | head -n25 | sed 's/^/    /'
  elif [[ -d /sys/bus/pci/devices ]]; then n="$(count_glob '/sys/bus/pci/devices/*')"; record_check devices "PCI/PCIe inventory" INFO "$n sysfs device(s); lspci unavailable"
  elif [[ "$(uname -s)" == Darwin ]] && exists system_profiler; then record_check devices "PCI/PCIe inventory" INFO "macOS system_profiler is available; detailed inventory omitted unless requested"
  else record_check devices "PCI/PCIe inventory" SKIP "Inventory unavailable or hidden"; fi
  if exists lsusb; then
    n="$(lsusb 2>/dev/null | awk 'NF{n++}END{print n+0}')"; record_check devices "USB inventory" INFO "$n device(s)"
    (( VERBOSE )) && lsusb 2>/dev/null | head -n25 | sed 's/^/    /'
  elif [[ -d /sys/bus/usb/devices ]]; then n="$(count_glob '/sys/bus/usb/devices/*')"; record_check devices "USB inventory" INFO "$n sysfs entry/entries; lsusb unavailable"
  else record_check devices "USB inventory" SKIP "USB inventory unavailable"; fi
  n=0
  for p in /dev/ttyUSB* /dev/ttyACM* /dev/ttyS* /dev/ttyAMA*; do [[ -e "$p" ]] && ((n+=1)); done
  record_check devices "Serial device nodes" INFO "$n matching serial node(s)"
  record_check devices "I2C device nodes" INFO "$(count_glob '/dev/i2c-*') node(s)"
  record_check devices "SPI device nodes" INFO "$(count_glob '/dev/spidev*') node(s)"
  if exists nvidia-smi; then
    local gpu
    gpu="$(nvidia-smi --query-gpu=name,temperature.gpu,utilization.gpu,memory.used,memory.total --format=csv,noheader 2>/dev/null | head -n4)"
    [[ -n "$gpu" ]] && record_check devices "NVIDIA GPU telemetry" INFO "$(printf '%s' "$gpu" | tr '\n' ';')" || record_check devices "NVIDIA GPU telemetry" SKIP "No GPU telemetry returned"
  else record_check devices "NVIDIA GPU telemetry" SKIP "nvidia-smi unavailable"; fi
}
check_embedded() {
  reset_section_header "Embedded systems and board health"
  local model compat n
  model=""
  [[ -r /proc/device-tree/model ]] && model="$(tr -d '\000' < /proc/device-tree/model 2>/dev/null || true)"
  [[ -n "$model" ]] || { [[ -r /sys/firmware/devicetree/base/model ]] && model="$(tr -d '\000' < /sys/firmware/devicetree/base/model 2>/dev/null || true)"; }
  if [[ -n "$model" ]]; then record_check embedded "Device-tree board model" INFO "$model"
  else record_check embedded "Device-tree board model" SKIP "No device-tree model exposed"; fi
  compat=""
  [[ -r /proc/device-tree/compatible ]] && compat="$(tr '\000' ',' < /proc/device-tree/compatible 2>/dev/null | sed 's/,$//')"
  [[ -n "$compat" ]] && record_check embedded "Device-tree compatible" INFO "$(printf '%s' "$compat" | cut -c1-180)"
  [[ -r /proc/device-tree/serial-number || -r /sys/firmware/devicetree/base/serial-number ]] && record_check embedded "Board serial field" INFO "Serial field exists; value withheld from routine report"
  if [[ -d /sys/firmware ]]; then n="$(count_glob '/sys/firmware/*')"; record_check embedded "Firmware interfaces" INFO "$n top-level entries"
  else record_check embedded "Firmware interfaces" SKIP "/sys/firmware unavailable"; fi
  if exists edac-util; then
    local ed
    ed="$(edac-util -v 2>&1 | head -n8 || true)"
    if printf '%s' "$ed" | grep -Eqi 'No errors|0 errors'; then record_check embedded "ECC memory telemetry" INFO "edac-util reports no errors in its summary"
    else record_check embedded "ECC memory telemetry" INFO "ECC utility output: $(printf '%s' "$ed" | tr '\n' ';' | cut -c1-160)"; fi
  else record_check embedded "ECC memory telemetry" SKIP "edac-util unavailable"; fi
}
check_processes() {
  reset_section_header "Processes and system pressure"
  local n z psi
  n="$(ps -e -o pid= 2>/dev/null | awk 'NF{n++}END{print n+0}')"
  record_check processes "Process count" INFO "$n process(es) visible"
  if ps -e -o stat= >/dev/null 2>&1; then
    z="$(ps -e -o stat= 2>/dev/null | awk '$1~/^Z/{n++}END{print n+0}')"
    if (( z > 0 )); then record_check processes "Zombie processes" INFO "$z zombie(s); some are transient and not necessarily a fault"
    else record_check processes "Zombie processes" PASS "No visible zombie processes"; fi
  else record_check processes "Zombie processes" SKIP "Process states unavailable"; fi
  if [[ -r /proc/pressure/memory ]]; then
    psi="$(awk '/^some /{print $2 " " $3 " " $4;exit}' /proc/pressure/memory)"
    record_check processes "Memory PSI" INFO "${psi:-Pressure metrics available}"
  else record_check processes "Memory PSI" SKIP "Linux PSI metrics unavailable"; fi
  if exists vmstat; then n="$(vmstat 1 2 2>/dev/null | tail -n1 | awk '{$1=$1;print}' | cut -c1-160)"; [[ -n "$n" ]] && record_check processes "vmstat snapshot" INFO "$n"; fi
}
check_security() {
  reset_section_header "Security posture (read-only indicators)"
  local state
  if exists getenforce; then
    state="$(getenforce 2>/dev/null || true)"
    case "$state" in Enforcing) record_check security "SELinux" PASS "Enforcing" ;; Permissive) record_check security "SELinux" INFO "Permissive; enforcement is not active" ;; Disabled) record_check security "SELinux" INFO "Disabled" ;; *) record_check security "SELinux" SKIP "State unavailable";; esac
  else record_check security "SELinux" SKIP "getenforce unavailable"; fi
  if exists aa-status; then
    if aa-status --enabled >/dev/null 2>&1; then record_check security "AppArmor" INFO "Enabled; profile enforcement varies"
    else record_check security "AppArmor" INFO "Not reported enabled"; fi
  else record_check security "AppArmor" SKIP "aa-status unavailable"; fi
  if exists ufw; then
    state="$(ufw status 2>/dev/null | head -n1)"
    case "$state" in *active*) record_check security "UFW firewall" INFO "$state; other firewall layers may also apply" ;; *inactive*) record_check security "UFW firewall" INFO "$state; this does not establish overall firewall state" ;; *) record_check security "UFW firewall" SKIP "Status unavailable or restricted";; esac
  elif exists firewall-cmd; then
    state="$(firewall-cmd --state 2>/dev/null || true)"
    [[ "$state" == running ]] && record_check security "firewalld" INFO "Service reports running" || record_check security "firewalld" SKIP "State unavailable or service not running"
  elif [[ "$(uname -s)" == Darwin ]] && exists /usr/libexec/ApplicationFirewall/socketfilterfw; then
    state="$(/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null || true)"
    [[ -n "$state" ]] && record_check security "macOS Application Firewall" INFO "$state" || record_check security "macOS Application Firewall" SKIP "State unavailable"
  else record_check security "Host firewall" SKIP "No supported firewall status command; this does not mean no firewall exists"; fi
  if [[ -r /proc/sys/kernel/randomize_va_space ]]; then
    state="$(safe_read /proc/sys/kernel/randomize_va_space)"
    case "$state" in 2) record_check security "Linux ASLR" PASS "Full randomization reported" ;; 1) record_check security "Linux ASLR" INFO "Partial randomization reported" ;; 0) record_check security "Linux ASLR" WARN "ASLR reported disabled" ;; *) record_check security "Linux ASLR" INFO "Value ${state:-unknown}";; esac
  else record_check security "Linux ASLR" SKIP "Linux ASLR setting unavailable"; fi
  state="$(safe_read /sys/kernel/security/lockdown)"
  [[ -n "$state" ]] && record_check security "Kernel lockdown" INFO "$state" || record_check security "Kernel lockdown" SKIP "Lockdown status unavailable"
}
check_logs() {
  reset_section_header "Kernel and recent system logs"
  local text n
  if [[ "$(uname -s)" == Linux ]] && exists dmesg; then
    text="$(dmesg 2>/dev/null || true)"
    if [[ -z "$text" ]]; then record_check logs "Kernel hardware messages" SKIP "Kernel buffer empty or permission-restricted"
    else
      n="$(printf '%s\n' "$text" | grep -Eic 'I/O error|hardware error|uncorrectable|EXT4-fs error|BTRFS.*error|XFS.*(error|corrupt)|nvme.*(error|fail)|ata[0-9].*(error|fail)|mmc.*error|MCE:|machine check|thermal.*critical' || true)"
      [[ "$n" =~ ^[0-9]+$ ]] || n=0
      if (( n > 0 )); then record_check logs "Kernel hardware messages" WARN "$n matching line(s); pattern matches need human review"
      else record_check logs "Kernel hardware messages" INFO "No matching patterns in readable kernel buffer; absence is not proof of health"; fi
      if (( VERBOSE )); then printf '%s\n' "$text" | grep -Ei 'I/O error|hardware error|uncorrectable|EXT4-fs error|BTRFS.*error|XFS.*(error|corrupt)|nvme.*(error|fail)|ata[0-9].*(error|fail)|mmc.*error|MCE:|machine check|thermal.*critical' | tail -n12 | sed 's/^/    /' || true; fi
    fi
  else record_check logs "Kernel hardware messages" SKIP "Linux dmesg check unavailable"; fi
  if exists journalctl; then
    text="$(journalctl -b -p err --no-pager -n 100 2>/dev/null || true)"
    n="$(printf '%s\n' "$text" | awk 'NF&&$0!~/^-- /{n++}END{print n+0}')"
    if (( n > 0 )); then record_check logs "Journal errors" INFO "$n error-priority line(s); not necessarily hardware faults"
    else record_check logs "Journal errors" INFO "No readable error-priority lines, or journal access is restricted"; fi
    (( VERBOSE )) && printf '%s\n' "$text" | tail -n12 | sed 's/^/    /'
  else record_check logs "Journal errors" SKIP "systemd journal unavailable"; fi
}
run_checks() {
  local stamp host os overall
  stamp="$(date '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || date)"
  host="$(hostname 2>/dev/null || printf unknown)"; os="$(uname -s 2>/dev/null || printf unknown)"
  printf '%s\n' '================================================================================'
  printf ' %s %s — System Health Report\n Host: %s | Platform: %s | Generated: %s\n' "$PROGRAM_NAME" "$RUN_VERSION" "$host" "$os" "$stamp"
  printf '%s\n' ' Best-effort diagnostics. SKIP means not assessed; warnings are not diagnoses.'
  printf '%s\n' '================================================================================'
  section_enabled system && check_system
  section_enabled cpu && check_cpu
  section_enabled memory && check_memory
  section_enabled storage && check_storage
  section_enabled network && check_network
  section_enabled thermal && check_thermal
  section_enabled battery && check_battery
  section_enabled devices && check_devices
  section_enabled embedded && check_embedded
  section_enabled processes && check_processes
  section_enabled security && check_security
  section_enabled logs && check_logs
  printf '\n== Summary ==\n'
  if (( COUNT_FAIL > 0 )); then overall=FAIL
  elif (( COUNT_WARN > 0 )); then overall=WARN
  elif (( COUNT_PASS > 0 )); then overall=PASS
  else overall=INFO; fi
  status_color "$overall"; printf '  OVERALL: %s' "$overall"; reset_color
  printf ' | PASS %d | WARN %d | FAIL %d | INFO %d | SKIP %d | Total %d\n' "$COUNT_PASS" "$COUNT_WARN" "$COUNT_FAIL" "$COUNT_INFO" "$COUNT_SKIP" "${#CHECK_STATUS[@]}"
  if (( COUNT_PASS + COUNT_WARN + COUNT_FAIL == 0 )); then printf '%s\n' 'No health conclusion: no check produced a PASS/WARN/FAIL result.'; fi
  printf '%s\n' 'PASS means no issue was detected by that check; it is not a guarantee of hardware health.'
}
json_escape() {
  local s="$1" out="" ch i n
  local LC_ALL=C
  for ((i=0;i<${#s};i++)); do
    ch="${s:i:1}"
    case "$ch" in
      \\) out+='\\' ;; '"') out+='\"' ;;
      $'\n') out+='\n' ;; $'\r') out+='\r' ;; $'\t') out+='\t' ;;
      *) printf -v n '%d' "'$ch"; if (( n < 32 )); then printf -v ch '\\u%04x' "$n"; out+="$ch"; else out+="$ch"; fi ;;
    esac
  done
  printf '%s' "$out"
}
write_json() {
  local target="$1" dir tmp i generated host os overall
  dir="$(dirname "$target")"
  [[ -d "$dir" ]] || { printf 'Run: JSON output directory does not exist: %s\n' "$dir" >&2; return 1; }
  tmp="$(mktemp "$dir/.Run-json.XXXXXX" 2>/dev/null)" || { printf 'Run: cannot create temporary JSON file in %s\n' "$dir" >&2; return 1; }
  generated="$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date)"
  host="$(hostname 2>/dev/null || printf unknown)"; os="$(uname -s 2>/dev/null || printf unknown)"
  if (( COUNT_FAIL > 0 )); then overall=FAIL; elif (( COUNT_WARN > 0 )); then overall=WARN; elif (( COUNT_PASS > 0 )); then overall=PASS; else overall=INFO; fi
  {
    printf '{\n "program":"%s","version":"%s","generated_at":"%s","hostname":"%s","platform":"%s","overall":"%s",\n' \
      "$(json_escape "$PROGRAM_NAME")" "$(json_escape "$RUN_VERSION")" "$(json_escape "$generated")" "$(json_escape "$host")" "$(json_escape "$os")" "$overall"
    printf ' "summary":{"pass":%d,"warn":%d,"fail":%d,"info":%d,"skip":%d,"total":%d},\n "checks":[\n' \
      "$COUNT_PASS" "$COUNT_WARN" "$COUNT_FAIL" "$COUNT_INFO" "$COUNT_SKIP" "${#CHECK_STATUS[@]}"
    for ((i=0;i<${#CHECK_STATUS[@]};i++)); do
      printf '  {"section":"%s","name":"%s","status":"%s","detail":"%s"}' \
        "$(json_escape "${CHECK_SECTION[$i]}")" "$(json_escape "${CHECK_NAME[$i]}")" \
        "$(json_escape "${CHECK_STATUS[$i]}")" "$(json_escape "${CHECK_DETAIL[$i]}")"
      (( i+1 < ${#CHECK_STATUS[@]} )) && printf ','; printf '\n'
    done
    printf ' ]\n}\n'
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  if exists python3; then
    python3 -m json.tool "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; printf 'Run: internal JSON validation failed\n' >&2; return 1; }
  fi
  mv -f "$tmp" "$target" || { rm -f "$tmp"; printf 'Run: could not write JSON file: %s\n' "$target" >&2; return 1; }
  printf 'Run: JSON report saved to %s\n' "$target"
}
normalize_sections() {
  local raw="$1" part out="" old="$IFS"
  raw="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr ' ' ',')"; IFS=','
  for part in $raw; do
    [[ -n "$part" ]] || continue
    case "$part" in os|platform) part=system ;; chip|processor) part=cpu ;; hardware|peripherals) part=devices ;; ram) part=memory ;; disk|disks|filesystem|filesystems) part=storage ;; sensors|temperature|temps) part=thermal ;; embedded-system|board) part=embedded ;; process) part=processes ;; log|journal) part=logs ;; esac
    case "$part" in system|cpu|memory|storage|network|thermal|battery|devices|embedded|processes|security|logs) ;;
      *) IFS="$old"; printf 'Run: unknown section: %s\n' "$part" >&2; return 1 ;; esac
    case ",$out," in *",$part,"*) ;; *) out="${out:+$out,}$part" ;; esac
  done
  IFS="$old"; [[ -n "$out" ]] || { printf 'Run: no valid section names supplied\n' >&2; return 1; }
  SECTION_FILTER="$out"
}
run_tui() {
  local choice
  printf '%s\n' 'Run — Terminal menu' '1) Full scan' '2) Quick scan' '3) Storage' '4) CPU/memory/thermal' '5) Devices/embedded' '6) Network' '7) Battery' '8) Security' '9) Logs' '0) Exit'
  printf 'Select [0-9]: '; IFS= read -r choice || choice=0
  case "$choice" in
    1) SECTION_FILTER="" ; QUICK=0 ;; 2) SECTION_FILTER="" ; QUICK=1 ;;
    3) SECTION_FILTER=storage ;; 4) SECTION_FILTER=cpu,memory,thermal ;;
    5) SECTION_FILTER=devices,embedded ;; 6) SECTION_FILTER=network ;;
    7) SECTION_FILTER=battery ;; 8) SECTION_FILTER=security ;; 9) SECTION_FILTER=logs ;;
    *) exit 0 ;;
  esac
}
while (($#)); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --version) printf '%s %s\n' "$PROGRAM_NAME" "$RUN_VERSION"; exit 0 ;;
    --quick) QUICK=1 ;; --all) QUICK=0 ;; --tui) TUI=1 ;;
    --network-test) NETWORK_TEST=1 ;; --verbose) VERBOSE=1 ;;
    --plain|--no-color) PLAIN=1; COLOR=0 ;;
    --section|--report|--json|--watch)
      opt="$1"; shift; (($#)) || { printf 'Run: %s requires an argument\n' "$opt" >&2; exit 2; }
      case "$opt" in
        --section) SECTION_FILTER="${SECTION_FILTER:+$SECTION_FILTER,}$1" ;;
        --report) REPORT_FILE="$1" ;;
        --json) JSON_FILE="$1" ;;
        --watch) [[ "$1" =~ ^[1-9][0-9]*$ ]] || { printf 'Run: --watch requires positive whole seconds\n' >&2; exit 2; }; WATCH_INTERVAL="$1" ;;
      esac ;;
    --*) printf 'Run: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    *) printf 'Run: unexpected argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done
[[ -n "$SECTION_FILTER" ]] && normalize_sections "$SECTION_FILTER" || { [[ -z "$SECTION_FILTER" ]] || exit 2; }
(( TUI )) && run_tui
if [[ -n "$WATCH_INTERVAL" && ( -n "$REPORT_FILE" || -n "$JSON_FILE" ) ]]; then printf 'Run: --watch cannot be combined with --report/--json\n' >&2; exit 2; fi
if [[ -n "$WATCH_INTERVAL" ]]; then
  while :; do
    [[ -t 1 ]] && exists clear && clear
    reset_results; run_checks
    printf '\nRefreshing every %s seconds. Press Ctrl+C to stop.\n' "$WATCH_INTERVAL"
    sleep "$WATCH_INTERVAL" || break
  done
  exit 0
fi
if [[ -n "$REPORT_FILE" ]]; then
  dir="$(dirname "$REPORT_FILE")"
  [[ -d "$dir" ]] || { printf 'Run: report directory does not exist: %s\n' "$dir" >&2; exit 2; }
  tmp="$(mktemp "${TMPDIR:-/tmp}/Run-report.XXXXXX" 2>/dev/null)" || { printf 'Run: cannot create temporary report\n' >&2; exit 2; }
  COLOR=0; run_checks > "$tmp"
  if ! cp "$tmp" "$REPORT_FILE"; then rm -f "$tmp"; printf 'Run: could not write report file\n' >&2; exit 2; fi
  cat "$tmp"; rm -f "$tmp"
else run_checks; fi
[[ -n "$JSON_FILE" ]] && write_json "$JSON_FILE" || { [[ -z "$JSON_FILE" ]] || exit 2; }
if (( COUNT_FAIL > 0 || COUNT_WARN > 0 )); then exit 1; fi
exit 0
