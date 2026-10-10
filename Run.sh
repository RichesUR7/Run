#!/usr/bin/env bash
# Run — portable, read-only system and hardware health inspector.
# Supports Linux, macOS, BSD, and many embedded Linux systems.
# It does not install packages, change settings, write test data to disks, or run stress tests.

set -uo pipefail

RUN_VERSION="1.0.0"
PROGRAM_NAME="Run"
QUICK=0
TUI=0
VERBOSE=0
PLAIN=0
NETWORK_TEST=0
REPORT_FILE=""
JSON_FILE=""
WATCH_INTERVAL=""
SECTION_FILTER=""
COLOR=0

# Colors are enabled only for an interactive terminal, and can be disabled with --plain or NO_COLOR.
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then COLOR=1; fi

# Results are kept in arrays so the same scan can be rendered as text and JSON.
CHECK_SECTION=()
CHECK_NAME=()
CHECK_STATUS=()
CHECK_DETAIL=()
COUNT_PASS=0
COUNT_WARN=0
COUNT_FAIL=0
COUNT_INFO=0
COUNT_SKIP=0

usage() {
  cat <<'USAGE'
Run — system, hardware, storage, and embedded-device health checker

Usage:
  ./Run.sh [options]

Options:
  --help, -h              Show this help text
  --version               Show version
  --quick                 Run a short OS, CPU, memory, storage, and network scan
  --all                   Run all available checks (the default)
  --section NAME[,NAME]  Run only selected sections; repeatable
                          Sections: system,cpu,memory,storage,network,thermal,
                                   battery,devices,embedded,processes,security,logs
  --tui                   Open a terminal menu (dialog/whiptail, or text fallback)
  --network-test          Also test DNS and outbound connectivity (makes network requests)
  --report FILE           Save the human-readable report to FILE
  --json FILE             Save structured results as JSON to FILE
  --watch SECONDS         Repeat the scan at this interval (interactive dashboard)
  --verbose               Show additional device inventory details when available
  --plain, --no-color     Disable ANSI colors

Examples:
  ./Run.sh
  ./Run.sh --quick
  ./Run.sh --section storage,devices --verbose
  ./Run.sh --network-test --json run-report.json --report run-report.txt
  ./Run.sh --tui
  ./Run.sh --section thermal,battery --watch 5

Notes:
  • Checks are read-only and best-effort; access and available data vary by OS/device.
  • SMART, temperature, firmware, and embedded-board checks need suitable hardware/tools.
  • WARN means a possible issue or a threshold was crossed; it is not automatically a diagnosis.
  • Run as an administrator only when you need extra hardware/log visibility. Avoid using
    elevated privileges unless you understand the implications.
USAGE
}

exists() { command -v "$1" >/dev/null 2>&1; }

trim_one_line() {
  local s="${1:-}"
  s="${s//$'\n'/; }"
  s="${s//$'\r'/ }"
  s="${s//$'\t'/ }"
  # Keep report rows readable even when a system string is unusually long.
  if (( ${#s} > 230 )); then s="${s:0:227}..."; fi
  printf '%s' "$s"
}

status_color() {
  local status="$1"
  if (( COLOR )); then
    case "$status" in
      PASS) printf '\033[32m' ;;
      WARN) printf '\033[33m' ;;
      FAIL) printf '\033[31m' ;;
      INFO) printf '\033[36m' ;;
      SKIP) printf '\033[90m' ;;
      *) printf '\033[0m' ;;
    esac
  fi
}

reset_color() { (( COLOR )) && printf '\033[0m' || true; }

section_header() {
  printf '\n== %s ==\n' "$1"
  if (( COLOR )); then printf '\033[90m'; fi
  printf '%s\n' '--------------------------------------------------------------------------------'
  reset_color
}

record_check() {
  local section="$1" name="$2" status="$3" detail
  detail="$(trim_one_line "${4:-}")"
  CHECK_SECTION+=("$section")
  CHECK_NAME+=("$name")
  CHECK_STATUS+=("$status")
  CHECK_DETAIL+=("$detail")

  case "$status" in
    PASS) COUNT_PASS=$((COUNT_PASS + 1)) ;;
    WARN) COUNT_WARN=$((COUNT_WARN + 1)) ;;
    FAIL) COUNT_FAIL=$((COUNT_FAIL + 1)) ;;
    INFO) COUNT_INFO=$((COUNT_INFO + 1)) ;;
    SKIP) COUNT_SKIP=$((COUNT_SKIP + 1)) ;;
    *) COUNT_INFO=$((COUNT_INFO + 1)) ;;
  esac

  status_color "$status"
  printf '  %-5s ' "$status"
  reset_color
  printf '%-25s %s\n' "$name" "$detail"
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

count_glob() {
  local pattern="$1" n
  n="$(compgen -G "$pattern" 2>/dev/null | wc -l | awk '{print $1}')"
  printf '%s' "${n:-0}"
}

first_nonempty() {
  local value
  for value in "$@"; do
    if [[ -n "$value" ]]; then printf '%s' "$value"; return 0; fi
  done
  return 1
}

percent_status() {
  # Prints PASS/WARN/FAIL for a used percentage.
  local value="${1:-0}"
  awk -v p="$value" 'BEGIN { if (p >= 95) print "FAIL"; else if (p >= 85) print "WARN"; else print "PASS" }'
}

safe_read() {
  local file="$1"
  if [[ -r "$file" ]]; then head -n 1 "$file" 2>/dev/null; fi
}

reset_results() {
  CHECK_SECTION=()
  CHECK_NAME=()
  CHECK_STATUS=()
  CHECK_DETAIL=()
  COUNT_PASS=0
  COUNT_WARN=0
  COUNT_FAIL=0
  COUNT_INFO=0
  COUNT_SKIP=0
}

check_system() {
  section_header "Operating system and platform"
  local os_name kernel arch host uptime_text virt user_name root_status model
  os_name=""
  if [[ -r /etc/os-release ]]; then
    os_name="$(awk -F= '$1=="PRETTY_NAME" {gsub(/^"|"$/, "", $2); print $2; exit}' /etc/os-release 2>/dev/null)"
  fi
  if [[ -z "$os_name" ]] && exists sw_vers; then
    os_name="$(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null)"
  fi
  [[ -n "$os_name" ]] || os_name="$(uname -s 2>/dev/null || printf 'Unknown OS')"
  kernel="$(uname -sr 2>/dev/null || printf 'unknown kernel')"
  arch="$(uname -m 2>/dev/null || printf 'unknown architecture')"
  host="$(hostname 2>/dev/null || printf 'unknown-host')"
  record_check system "Operating system" PASS "$os_name"
  record_check system "Kernel / architecture" INFO "$kernel; $arch"
  record_check system "Hostname" INFO "$host"

  if exists uptime; then
    uptime_text="$(uptime -p 2>/dev/null || uptime 2>/dev/null || true)"
    [[ -n "$uptime_text" ]] && record_check system "Uptime" INFO "$uptime_text" || record_check system "Uptime" SKIP "uptime information unavailable"
  else
    record_check system "Uptime" SKIP "uptime command unavailable"
  fi

  user_name="$(id -un 2>/dev/null || printf 'unknown')"
  if [[ "$user_name" == "root" ]] || [[ "$(id -u 2>/dev/null || printf '1')" == "0" ]]; then
    root_status="Running with administrator/root privileges; additional hardware details may be visible"
  else
    root_status="Running as $user_name; some hardware/log checks may be restricted"
  fi
  record_check system "Execution privileges" INFO "$root_status"

  virt=""
  if exists systemd-detect-virt; then
    virt="$(systemd-detect-virt 2>/dev/null || true)"
  fi
  if [[ -z "$virt" ]] && [[ -r /proc/1/cgroup ]]; then
    if grep -Eqi 'docker|containerd|kubepods|lxc|podman' /proc/1/cgroup 2>/dev/null; then virt="container (detected from cgroups)"; fi
  fi
  if [[ -n "$virt" && "$virt" != "none" ]]; then
    record_check system "Virtualization" INFO "$virt; host hardware visibility may be limited"
  else
    record_check system "Virtualization" INFO "No supported virtualization detector reported a guest"
  fi

  if [[ -r /sys/class/dmi/id/product_name ]]; then
    model="$(safe_read /sys/class/dmi/id/product_name)"
    [[ -n "$model" ]] && record_check system "System model" INFO "$model"
  elif [[ -r /proc/device-tree/model ]]; then
    model="$(tr -d '\000' < /proc/device-tree/model 2>/dev/null || true)"
    [[ -n "$model" ]] && record_check system "System model" INFO "$model"
  elif exists sysctl; then
    model="$(sysctl -n hw.model 2>/dev/null || true)"
    [[ -n "$model" ]] && record_check system "System model" INFO "$model"
  fi

  if exists timedatectl; then
    local sync_state
    sync_state="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
    case "$sync_state" in
      yes) record_check system "Clock synchronization" PASS "System reports time synchronized" ;;
      no) record_check system "Clock synchronization" INFO "System reports clock is not synchronized; offline systems may be expected" ;;
      *) record_check system "Clock synchronization" SKIP "Synchronization status unavailable" ;;
    esac
  else
    record_check system "Clock synchronization" SKIP "timedatectl not available; time-sync state not evaluated"
  fi
}

check_cpu() {
  section_header "CPU and chip"
  local cpu_model cores load microcode vendor
  cpu_model=""
  if exists sysctl; then
    cpu_model="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || true)"
    [[ -n "$cpu_model" ]] || cpu_model="$(sysctl -n hw.model 2>/dev/null || true)"
  fi
  if [[ -z "$cpu_model" ]] && exists lscpu; then
    cpu_model="$(lscpu 2>/dev/null | awk -F: '/Model name|Hardware|Processor|Model:/ {gsub(/^[ \t]+/, "", $2); if ($2!="") {print $2; exit}}')"
  fi
  if [[ -z "$cpu_model" && -r /proc/cpuinfo ]]; then
    cpu_model="$(awk -F: '/^(model name|Hardware|Processor|cpu model)[ \t]*:/ {gsub(/^[ \t]+/, "", $2); if ($2!="") {print $2; exit}}' /proc/cpuinfo 2>/dev/null)"
  fi
  [[ -n "$cpu_model" ]] && record_check cpu "CPU / SoC model" PASS "$cpu_model" || record_check cpu "CPU / SoC model" INFO "Model string not exposed by this OS or environment"

  cores=""
  if exists getconf; then cores="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"; fi
  if [[ -z "$cores" ]] && exists sysctl; then cores="$(sysctl -n hw.ncpu 2>/dev/null || true)"; fi
  if [[ -z "$cores" && -r /proc/cpuinfo ]]; then cores="$(grep -c '^processor[[:space:]]*:' /proc/cpuinfo 2>/dev/null || true)"; fi
  if [[ "$cores" =~ ^[0-9]+$ ]] && (( cores > 0 )); then
    record_check cpu "Logical CPU count" PASS "$cores online logical processor(s)"
  else
    cores=0
    record_check cpu "Logical CPU count" SKIP "CPU core count unavailable"
  fi

  load=""
  if [[ -r /proc/loadavg ]]; then
    load="$(awk '{print $1 " / " $2 " / " $3}' /proc/loadavg 2>/dev/null)"
  elif exists sysctl; then
    load="$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}')"
  fi
  if [[ -n "$load" ]]; then
    record_check cpu "Load average" INFO "$load (1 / 5 / 15 minute values where provided)"
    if [[ -r /proc/loadavg && "$cores" =~ ^[0-9]+$ ]] && (( cores > 0 )); then
      local load1
      load1="$(awk '{print $1}' /proc/loadavg)"
      if awk -v l="$load1" -v c="$cores" 'BEGIN {exit !(l > c * 1.5)}'; then
        record_check cpu "CPU load pressure" WARN "1-minute load $load1 is over 1.5 × $cores logical CPUs"
      else
        record_check cpu "CPU load pressure" PASS "1-minute load $load1 is not above the advisory threshold"
      fi
    fi
  else
    record_check cpu "Load average" SKIP "Load average unavailable"
  fi

  microcode=""
  if [[ -r /proc/cpuinfo ]]; then
    microcode="$(awk -F: '/^microcode[ \t]*:/ {gsub(/^[ \t]+/, "", $2); if ($2!="") {print $2; exit}}' /proc/cpuinfo 2>/dev/null)"
  fi
  if [[ -n "$microcode" ]]; then
    record_check cpu "CPU microcode" INFO "$microcode (reported by kernel)"
  else
    record_check cpu "CPU microcode" SKIP "Microcode revision not exposed through /proc/cpuinfo"
  fi

  vendor=""
  if [[ -r /proc/cpuinfo ]]; then
    vendor="$(awk -F: '/^(vendor_id|CPU implementer)[ \t]*:/ {gsub(/^[ \t]+/, "", $2); if ($2!="") {print $2; exit}}' /proc/cpuinfo 2>/dev/null)"
  fi
  [[ -n "$vendor" ]] && record_check cpu "CPU vendor / implementer" INFO "$vendor"
}

check_memory() {
  section_header "Memory and swap"
  local total_kb avail_kb used_pct total_mb avail_mb status swap_line
  total_kb=""; avail_kb=""
  if [[ -r /proc/meminfo ]]; then
    read -r total_kb avail_kb < <(awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END {print t, a}' /proc/meminfo 2>/dev/null)
  elif exists sysctl; then
    local total_bytes vm_data page_size free_pages inactive_pages speculative_pages purgeable_pages avail_pages
    total_bytes="$(sysctl -n hw.memsize 2>/dev/null || true)"
    if [[ "$total_bytes" =~ ^[0-9]+$ ]] && exists vm_stat; then
      vm_data="$(vm_stat 2>/dev/null || true)"
      page_size="$(printf '%s\n' "$vm_data" | sed -n 's/.*page size of \([0-9][0-9]*\) bytes.*/\1/p' | head -n 1)"
      [[ "$page_size" =~ ^[0-9]+$ ]] || page_size=4096
      free_pages="$(printf '%s\n' "$vm_data" | awk -F: '/Pages free/ {gsub(/[^0-9]/,"",$2); print $2; exit}')"
      inactive_pages="$(printf '%s\n' "$vm_data" | awk -F: '/Pages inactive/ {gsub(/[^0-9]/,"",$2); print $2; exit}')"
      speculative_pages="$(printf '%s\n' "$vm_data" | awk -F: '/Pages speculative/ {gsub(/[^0-9]/,"",$2); print $2; exit}')"
      purgeable_pages="$(printf '%s\n' "$vm_data" | awk -F: '/Pages purgeable/ {gsub(/[^0-9]/,"",$2); print $2; exit}')"
      avail_pages="$(awk -v a="${free_pages:-0}" -v b="${inactive_pages:-0}" -v c="${speculative_pages:-0}" -v d="${purgeable_pages:-0}" 'BEGIN {printf "%.0f", a+b+c+d}')"
      total_kb="$((total_bytes / 1024))"
      avail_kb="$(awk -v p="$avail_pages" -v s="$page_size" 'BEGIN {printf "%.0f", p*s/1024}')"
    fi
  fi

  if [[ "${total_kb:-}" =~ ^[0-9]+$ ]] && (( total_kb > 0 )) && [[ "${avail_kb:-}" =~ ^[0-9]+$ ]]; then
    used_pct="$(awk -v t="$total_kb" -v a="$avail_kb" 'BEGIN {if(t>0) printf "%.1f", (t-a)*100/t; else print "0"}')"
    total_mb=$((total_kb / 1024)); avail_mb=$((avail_kb / 1024))
    status="$(percent_status "$used_pct")"
    record_check memory "Physical memory" "$status" "${used_pct}% estimated in use; ${avail_mb} MiB available of ${total_mb} MiB"
  else
    record_check memory "Physical memory" SKIP "Memory totals unavailable on this platform"
  fi

  swap_line=""
  if [[ -r /proc/meminfo ]]; then
    swap_line="$(awk '/^SwapTotal:/ {t=$2} /^SwapFree:/ {f=$2} END {if (t!="") printf "%.0f MiB total, %.0f MiB free", t/1024, f/1024}' /proc/meminfo 2>/dev/null)"
  elif exists sysctl && exists vm_stat; then
    swap_line="$(sysctl -n vm.swapusage 2>/dev/null || true)"
  fi
  [[ -n "$swap_line" ]] && record_check memory "Swap" INFO "$swap_line" || record_check memory "Swap" SKIP "Swap statistics unavailable"
}

check_storage() {
  section_header "Storage and file systems"
  local df_line total_k used_k avail_k pct mountpoint fs_type inode_pct inode_line devices dev_count
  mountpoint="/"
  df_line="$(df -Pk "$mountpoint" 2>/dev/null | awk 'NR==2 {print $2, $3, $4, $5}')"
  if [[ -n "$df_line" ]]; then
    read -r total_k used_k avail_k pct <<< "$df_line"
    pct="${pct%%%}"
    if [[ "$pct" =~ ^[0-9]+$ ]]; then
      local st
      st="$(percent_status "$pct")"
      record_check storage "Root filesystem space" "$st" "${pct}% used; $((avail_k / 1024)) MiB available of $((total_k / 1024)) MiB"
    else
      record_check storage "Root filesystem space" INFO "df reported: $df_line"
    fi
  else
    record_check storage "Root filesystem space" SKIP "Could not read free space for $mountpoint"
  fi

  fs_type=""
  if exists findmnt; then fs_type="$(findmnt -n -o FSTYPE / 2>/dev/null || true)"; fi
  if [[ -z "$fs_type" ]]; then
    fs_type="$(mount 2>/dev/null | awk '$3=="/" {if ($4=="type") print $5; else if ($4 ~ /^\(/) {gsub(/[(),]/,"",$4); print $4}; exit}')"
  fi
  [[ -n "$fs_type" ]] && record_check storage "Root filesystem type" INFO "$fs_type" || record_check storage "Root filesystem type" SKIP "Filesystem type unavailable"

  inode_line="$(df -iP / 2>/dev/null | awk 'NR==2 {print $5}')"
  inode_pct="${inode_line%%%}"
  if [[ "$inode_pct" =~ ^[0-9]+$ ]]; then
    local inode_status
    inode_status="$(percent_status "$inode_pct")"
    record_check storage "Root inode usage" "$inode_status" "${inode_pct}% inodes used"
  else
    record_check storage "Root inode usage" SKIP "Inode usage not supported or not reported by df"
  fi

  devices=""
  if exists lsblk; then
    devices="$(lsblk -dn -o NAME,SIZE,TYPE,MODEL 2>/dev/null | awk '$3=="disk" {print $1 " " $2 " " $4; n++} END {if(n==0) print ""}')"
  elif exists diskutil; then
    devices="$(diskutil list 2>/dev/null | awk '/^\/dev\/disk/ {print; n++; if(n>=8) exit}')"
  elif exists geom; then
    devices="$(geom disk list 2>/dev/null | awk '/Geom name:/ {print $3; n++; if(n>=8) exit}')"
  fi
  if [[ -n "$devices" ]]; then
    dev_count="$(printf '%s\n' "$devices" | awk 'NF {n++} END {print n+0}')"
    record_check storage "Physical storage devices" INFO "$dev_count device(s) detected; $(printf '%s' "$devices" | tr '\n' ';' | cut -c1-180)"
    if (( VERBOSE )); then printf '    Device inventory:\n%s\n' "$devices" | sed 's/^/      /'; fi
  else
    record_check storage "Physical storage devices" SKIP "No supported disk inventory command returned devices (common in containers)"
  fi

  if exists smartctl; then
    local smart_devices smart_dev smart_out smart_health smart_count
    smart_devices="$(smartctl --scan 2>/dev/null | awk 'NF && $1 ~ /^\// {print $1}' | head -n 4)"
    smart_count=0
    if [[ -n "$smart_devices" ]]; then
      while IFS= read -r smart_dev; do
        [[ -n "$smart_dev" ]] || continue
        smart_count=$((smart_count + 1))
        smart_out="$(smartctl -H "$smart_dev" 2>/dev/null || true)"
        smart_health="$(printf '%s\n' "$smart_out" | awk -F: '/overall-health|SMART Health Status/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')"
        if printf '%s' "$smart_out" | grep -Eqi 'PASSED|OK$'; then
          record_check storage "SMART $(basename "$smart_dev")" PASS "Drive health self-assessment passed${smart_health:+: $smart_health}"
        elif printf '%s' "$smart_out" | grep -Eqi 'FAILED|FAILING|BAD'; then
          record_check storage "SMART $(basename "$smart_dev")" FAIL "Drive reports a failing health status${smart_health:+: $smart_health}"
        elif [[ -n "$smart_out" ]]; then
          record_check storage "SMART $(basename "$smart_dev")" INFO "SMART query returned data but no clear overall status; privileges/device support may limit results"
        else
          record_check storage "SMART $(basename "$smart_dev")" SKIP "No SMART health response; permission or controller support may be limited"
        fi
      done <<< "$smart_devices"
    else
      record_check storage "SMART health" SKIP "smartctl exists but no drives were discovered by its scan"
    fi
  else
    record_check storage "SMART health" SKIP "smartctl not installed; disk SMART health was not queried"
  fi

  if exists nvme; then
    local nvme_list nvme_node nvme_out nvme_temp nvme_used nvme_errors
    nvme_list="$(nvme list 2>/dev/null | awk '/^\/dev\/nvme/ {print $1}' | head -n 4)"
    if [[ -n "$nvme_list" ]]; then
      while IFS= read -r nvme_node; do
        [[ -n "$nvme_node" ]] || continue
        nvme_out="$(nvme smart-log "$nvme_node" 2>/dev/null || true)"
        if [[ -n "$nvme_out" ]]; then
          nvme_temp="$(printf '%s\n' "$nvme_out" | awk -F: '/^temperature/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')"
          nvme_used="$(printf '%s\n' "$nvme_out" | awk -F: '/^percentage_used/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')"
          nvme_errors="$(printf '%s\n' "$nvme_out" | awk -F: '/^media_errors/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')"
          if [[ "$nvme_errors" =~ ^[0-9]+$ ]] && (( nvme_errors > 0 )); then
            record_check storage "NVMe $(basename "$nvme_node")" WARN "media_errors=$nvme_errors; temperature=${nvme_temp:-unknown}; percentage_used=${nvme_used:-unknown}"
          else
            record_check storage "NVMe $(basename "$nvme_node")" INFO "temperature=${nvme_temp:-unknown}; percentage_used=${nvme_used:-unknown}; media_errors=${nvme_errors:-unknown}"
          fi
        else
          record_check storage "NVMe $(basename "$nvme_node")" SKIP "Could not read NVMe SMART log; privilege/device support may be limited"
        fi
      done <<< "$nvme_list"
    else
      record_check storage "NVMe health" SKIP "nvme tool is installed but no NVMe controller was listed"
    fi
  else
    record_check storage "NVMe health" SKIP "nvme-cli not installed; NVMe logs not queried"
  fi
}

check_network() {
  section_header "Network and connectivity"
  local iface_list route_info dns_count
  iface_list=""
  if exists ip; then
    iface_list="$(ip -o link show up 2>/dev/null | awk -F': ' '$2!="lo" {sub(/@.*/,"",$2); print $2}' | paste -sd ',' -)"
  elif exists ifconfig; then
    iface_list="$(ifconfig -a 2>/dev/null | awk '/^[a-zA-Z0-9_.-]+: flags=/ {n=$1; sub(":$","",n); if(n!="lo0" && n!="lo") print n}' | paste -sd ',' -)"
  fi
  if [[ -n "$iface_list" ]]; then
    record_check network "Active interfaces" INFO "$iface_list"
  else
    record_check network "Active interfaces" INFO "No active non-loopback interface found, or interface listing is restricted"
  fi

  route_info=""
  if exists ip; then route_info="$(ip route show default 2>/dev/null | head -n 1)"; fi
  if [[ -z "$route_info" ]] && exists route; then route_info="$(route -n get default 2>/dev/null | awk '/gateway:|interface:/ {printf "%s%s ", $1, $2}')"; fi
  if [[ -n "$route_info" ]]; then
    record_check network "Default route" PASS "${route_info}"
  else
    record_check network "Default route" INFO "No default route found; offline or isolated networks may be intentional"
  fi

  dns_count="$(awk '$1=="nameserver" {n++} END {print n+0}' /etc/resolv.conf 2>/dev/null)"
  if [[ "$dns_count" =~ ^[0-9]+$ ]] && (( dns_count > 0 )); then
    record_check network "DNS configuration" PASS "$dns_count nameserver entr$( (( dns_count == 1 )) && printf 'y' || printf 'ies' ) in /etc/resolv.conf"
  else
    record_check network "DNS configuration" INFO "No nameserver entry visible in /etc/resolv.conf; resolver may be managed elsewhere"
  fi

  if (( NETWORK_TEST )); then
    local dns_result ping_result
    dns_result=""
    if exists getent; then dns_result="$(getent hosts example.com 2>/dev/null | head -n 1)"
    elif exists nslookup; then dns_result="$(nslookup example.com 2>/dev/null | tail -n 2 | head -n 1)"
    elif exists host; then dns_result="$(host example.com 2>/dev/null | head -n 1)"
    fi
    if [[ -n "$dns_result" ]]; then
      record_check network "External DNS test" PASS "example.com resolved"
    else
      record_check network "External DNS test" WARN "Could not resolve example.com; network policy or DNS may block the test"
    fi

    ping_result=1
    if exists ping; then
      if ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then ping_result=0
      elif ping -c 1 -t 2 1.1.1.1 >/dev/null 2>&1; then ping_result=0
      fi
    fi
    if (( ping_result == 0 )); then
      record_check network "Outbound IP test" PASS "ICMP response received from 1.1.1.1"
    else
      record_check network "Outbound IP test" INFO "No ICMP response; ping may be blocked even when internet access works"
    fi
  else
    record_check network "External connectivity test" SKIP "Not run; pass --network-test to perform DNS/ICMP requests"
  fi
}

check_thermal() {
  section_header "Thermal sensors and cooling"
  local zone temp_raw temp_c label zone_count fan_count sensors_out max_temp
  zone_count=0
  max_temp=""
  for zone in /sys/class/thermal/thermal_zone*; do
    [[ -d "$zone" ]] || continue
    temp_raw="$(safe_read "$zone/temp")"
    label="$(safe_read "$zone/type")"
    [[ -n "$label" ]] || label="$(basename "$zone")"
    [[ "$temp_raw" =~ ^-?[0-9]+$ ]] || continue
    temp_c="$(awk -v t="$temp_raw" 'BEGIN {if (t > 1000 || t < -1000) printf "%.1f", t/1000; else printf "%.1f", t}')"
    zone_count=$((zone_count + 1))
    if awk -v t="$temp_c" 'BEGIN {exit !(t >= 100)}'; then
      record_check thermal "$label temperature" FAIL "${temp_c}°C; critical advisory threshold reached"
    elif awk -v t="$temp_c" 'BEGIN {exit !(t >= 85)}'; then
      record_check thermal "$label temperature" WARN "${temp_c}°C; elevated temperature, check airflow/load"
    else
      record_check thermal "$label temperature" PASS "${temp_c}°C"
    fi
    if [[ -z "$max_temp" ]] || awk -v a="$temp_c" -v b="$max_temp" 'BEGIN {exit !(a>b)}'; then max_temp="$temp_c"; fi
  done

  if (( zone_count == 0 )); then
    if exists sensors; then
      sensors_out="$(sensors 2>/dev/null | awk 'NF && $0 !~ /^Adapter:/ {print; n++; if(n>=5) exit}' | paste -sd ';' -)"
      if [[ -n "$sensors_out" ]]; then
        record_check thermal "Thermal sensor inventory" INFO "lm-sensors output detected; temperatures not normalized across sensor types"
        if (( VERBOSE )); then sensors 2>/dev/null | head -n 35 | sed 's/^/      /'; fi
      else
        record_check thermal "Thermal sensors" SKIP "sensors command did not return readable values"
      fi
    else
      record_check thermal "Thermal sensors" SKIP "No readable Linux thermal zones or lm-sensors command"
    fi
  fi

  if exists vcgencmd; then
    local pi_temp throttled code
    pi_temp="$(vcgencmd measure_temp 2>/dev/null | sed 's/^temp=//')"
    [[ -n "$pi_temp" ]] && record_check thermal "Board temperature" INFO "$pi_temp (vcgencmd)"
    throttled="$(vcgencmd get_throttled 2>/dev/null | sed 's/^.*=//')"
    if [[ "$throttled" =~ ^0x[0-9a-fA-F]+$ ]]; then
      code=$((throttled))
      if (( code == 0 )); then
        record_check thermal "Raspberry Pi throttling flags" PASS "get_throttled=$throttled; no current or historical flags reported"
      else
        record_check thermal "Raspberry Pi throttling flags" WARN "get_throttled=$throttled; nonzero bits can indicate current or historical undervoltage/throttling"
      fi
    elif [[ -n "$throttled" ]]; then
      record_check thermal "Raspberry Pi throttling flags" INFO "$throttled"
    fi
  fi

  fan_count="$(count_glob '/sys/class/hwmon/hwmon*/fan*_input')"
  if [[ "$fan_count" =~ ^[0-9]+$ ]] && (( fan_count > 0 )); then
    record_check thermal "Fan tachometer readings" INFO "$fan_count fan reading(s) exposed through hwmon"
  else
    record_check thermal "Fan tachometer readings" SKIP "No Linux hwmon fan tachometer reading exposed; this is common on laptops and embedded devices"
  fi
}

check_battery() {
  section_header "Battery and power"
  local battery_count b capacity status health energy_full energy_design health_pct
  battery_count=0
  for b in /sys/class/power_supply/BAT* /sys/class/power_supply/battery; do
    [[ -d "$b" ]] || continue
    battery_count=$((battery_count + 1))
    capacity="$(safe_read "$b/capacity")"
    status="$(safe_read "$b/status")"
    health="$(safe_read "$b/health")"
    energy_full="$(safe_read "$b/energy_full")"
    energy_design="$(safe_read "$b/energy_full_design")"
    [[ -n "$capacity" ]] || capacity="$(safe_read "$b/charge_now")"
    local battery_detail="${status:-state unknown}; capacity=${capacity:-unknown}%${health:+; reported health=$health}"
    if [[ "$capacity" =~ ^[0-9]+$ ]] && (( capacity <= 15 )) && [[ "$status" == "Discharging" ]]; then
      record_check battery "$(basename "$b") charge" WARN "$battery_detail; low charge while discharging"
    elif [[ "$capacity" =~ ^[0-9]+$ ]]; then
      record_check battery "$(basename "$b") charge" PASS "$battery_detail"
    else
      record_check battery "$(basename "$b") charge" INFO "$battery_detail"
    fi
    if [[ "$energy_full" =~ ^[0-9]+$ && "$energy_design" =~ ^[0-9]+$ ]] && (( energy_design > 0 )); then
      health_pct="$(awk -v f="$energy_full" -v d="$energy_design" 'BEGIN {printf "%.1f", f*100/d}')"
      if awk -v h="$health_pct" 'BEGIN {exit !(h < 60)}'; then
        record_check battery "$(basename "$b") battery health" WARN "Full/design energy ratio ${health_pct}%; battery may be significantly worn"
      else
        record_check battery "$(basename "$b") battery health" INFO "Full/design energy ratio ${health_pct}% (not a vendor-specific diagnosis)"
      fi
    elif [[ -n "$health" ]]; then
      case "$health" in Good|good|Ok|ok) record_check battery "$(basename "$b") reported health" PASS "$health" ;; *) record_check battery "$(basename "$b") reported health" INFO "$health" ;; esac
    else
      record_check battery "$(basename "$b") health data" SKIP "Battery wear data not exposed by this device"
    fi
  done

  if (( battery_count == 0 )) && exists ioreg; then
    local apple_batt maxcap designcap cyclecount currentcap external charging
    apple_batt="$(ioreg -r -c AppleSmartBattery -w0 2>/dev/null || true)"
    if [[ -n "$apple_batt" ]]; then
      maxcap="$(printf '%s\n' "$apple_batt" | awk -F'= ' '/"MaxCapacity"/ {gsub(/[^0-9]/,"",$2); print $2; exit}')"
      designcap="$(printf '%s\n' "$apple_batt" | awk -F'= ' '/"DesignCapacity"/ {gsub(/[^0-9]/,"",$2); print $2; exit}')"
      cyclecount="$(printf '%s\n' "$apple_batt" | awk -F'= ' '/"CycleCount"/ {gsub(/[^0-9]/,"",$2); print $2; exit}')"
      currentcap="$(printf '%s\n' "$apple_batt" | awk -F'= ' '/"CurrentCapacity"/ {gsub(/[^0-9]/,"",$2); print $2; exit}')"
      external="$(printf '%s\n' "$apple_batt" | awk -F'= ' '/"ExternalConnected"/ {gsub(/[^A-Za-z]/,"",$2); print $2; exit}')"
      charging="$(printf '%s\n' "$apple_batt" | awk -F'= ' '/"IsCharging"/ {gsub(/[^A-Za-z]/,"",$2); print $2; exit}')"
      if [[ "$maxcap" =~ ^[0-9]+$ && "$designcap" =~ ^[0-9]+$ ]] && (( designcap > 0 )); then
        health_pct="$(awk -v f="$maxcap" -v d="$designcap" 'BEGIN {printf "%.1f", f*100/d}')"
        if awk -v h="$health_pct" 'BEGIN {exit !(h < 60)}'; then
          record_check battery "Apple battery health" WARN "Maximum/design capacity ratio ${health_pct}%; cycles=${cyclecount:-unknown}"
        else
          record_check battery "Apple battery health" INFO "Maximum/design capacity ratio ${health_pct}%; cycles=${cyclecount:-unknown}"
        fi
      else
        record_check battery "Apple battery health" INFO "Apple Smart Battery detected; capacity ratio unavailable; cycles=${cyclecount:-unknown}"
      fi
      record_check battery "Apple battery power" INFO "current capacity=${currentcap:-unknown}; external power=${external:-unknown}; charging=${charging:-unknown}"
      battery_count=1
    fi
  fi

  if (( battery_count == 0 )); then
    record_check battery "Battery presence" SKIP "No readable battery interface detected; desktop devices and some embedded boards have no battery"
  fi
}

check_devices() {
  section_header "Hardware and peripheral inventory"
  local pci_count usb_count gpu_count serial_count i2c_count spi_count pci_sample usb_sample gpu_info

  if exists lspci; then
    pci_count="$(lspci 2>/dev/null | awk 'NF {n++} END {print n+0}')"
    record_check devices "PCI / PCIe inventory" INFO "$pci_count device(s) enumerated by lspci"
    if (( VERBOSE )); then lspci -nn 2>/dev/null | head -n 25 | sed 's/^/      /'; fi
  elif [[ -d /sys/bus/pci/devices ]]; then
    pci_count="$(count_glob '/sys/bus/pci/devices/*')"
    record_check devices "PCI / PCIe inventory" INFO "$pci_count device(s) visible in sysfs; lspci is not installed"
  elif [[ "$(uname -s 2>/dev/null)" == "Darwin" ]] && exists system_profiler; then
    pci_count="$(system_profiler SPPCIDataType 2>/dev/null | grep -Ec '^    [^ ].*:$' || true)"
    record_check devices "PCI / PCIe inventory" INFO "$pci_count reported PCI device section(s) from macOS system_profiler"
    if (( VERBOSE )); then system_profiler SPPCIDataType 2>/dev/null | head -n 30 | sed 's/^/      /'; fi
  else
    record_check devices "PCI / PCIe inventory" SKIP "PCI inventory unavailable or hidden by a virtualized environment"
  fi

  if exists lsusb; then
    usb_count="$(lsusb 2>/dev/null | awk 'NF {n++} END {print n+0}')"
    record_check devices "USB inventory" INFO "$usb_count device(s) enumerated by lsusb"
    if (( VERBOSE )); then lsusb 2>/dev/null | head -n 25 | sed 's/^/      /'; fi
  elif [[ -d /sys/bus/usb/devices ]]; then
    usb_count="$(find /sys/bus/usb/devices -mindepth 1 -maxdepth 1 -type l 2>/dev/null | wc -l | awk '{print $1}')"
    record_check devices "USB inventory" INFO "$usb_count sysfs USB entries; lsusb is not installed"
  elif [[ "$(uname -s 2>/dev/null)" == "Darwin" ]] && exists system_profiler; then
    usb_count="$(system_profiler SPUSBDataType 2>/dev/null | grep -Ec '^    [^ ].*:$' || true)"
    record_check devices "USB inventory" INFO "$usb_count reported USB device section(s) from macOS system_profiler"
    if (( VERBOSE )); then system_profiler SPUSBDataType 2>/dev/null | head -n 35 | sed 's/^/      /'; fi
  else
    record_check devices "USB inventory" SKIP "USB inventory unavailable or not exposed"
  fi

  gpu_count="$(find /sys/class/drm -maxdepth 1 -type d -regextype posix-extended -regex '.*/card[0-9]+' 2>/dev/null | wc -l | awk '{print $1}')"
  if [[ "$gpu_count" =~ ^[0-9]+$ ]] && (( gpu_count > 0 )); then
    record_check devices "Graphics / DRM devices" INFO "$gpu_count DRM card node(s) found; virtual displays can also create nodes"
  else
    record_check devices "Graphics / DRM devices" SKIP "No Linux DRM card nodes found or this platform uses another graphics stack"
  fi

  if exists nvidia-smi; then
    gpu_info="$(nvidia-smi --query-gpu=name,temperature.gpu,utilization.gpu,memory.used,memory.total --format=csv,noheader 2>/dev/null | head -n 4)"
    if [[ -n "$gpu_info" ]]; then
      record_check devices "NVIDIA GPU status" INFO "$(printf '%s' "$gpu_info" | tr '\n' ';')"
      if (( VERBOSE )); then printf '%s\n' "$gpu_info" | sed 's/^/      /'; fi
    else
      record_check devices "NVIDIA GPU status" SKIP "nvidia-smi is installed but did not return GPU data"
    fi
  else
    record_check devices "NVIDIA GPU status" SKIP "nvidia-smi not available; NVIDIA telemetry not queried"
  fi

  serial_count=0
  for p in /dev/ttyUSB* /dev/ttyACM* /dev/ttyS* /dev/ttyAMA*; do [[ -e "$p" ]] && serial_count=$((serial_count + 1)); done
  record_check devices "Serial device nodes" INFO "$serial_count matching USB/UART serial node(s) in /dev"
  i2c_count="$(count_glob '/dev/i2c-*')"
  spi_count="$(count_glob '/dev/spidev*')"
  record_check devices "I2C device nodes" INFO "$i2c_count /dev/i2c-* node(s); permissions and driver support not tested"
  record_check devices "SPI device nodes" INFO "$spi_count /dev/spidev* node(s); permissions and driver support not tested"
}

check_embedded() {
  section_header "Embedded systems and board health"
  local model compatible dt_status throttled fw_count
  model=""
  if [[ -r /proc/device-tree/model ]]; then model="$(tr -d '\000' < /proc/device-tree/model 2>/dev/null || true)"; fi
  if [[ -z "$model" && -r /sys/firmware/devicetree/base/model ]]; then model="$(tr -d '\000' < /sys/firmware/devicetree/base/model 2>/dev/null || true)"; fi
  compatible=""
  if [[ -r /proc/device-tree/compatible ]]; then compatible="$(tr '\000' ',' < /proc/device-tree/compatible 2>/dev/null | sed 's/,$//')"; fi
  if [[ -n "$model" ]]; then
    record_check embedded "Device-tree board model" PASS "$model"
    [[ -n "$compatible" ]] && record_check embedded "Device-tree compatibility" INFO "$(printf '%s' "$compatible" | cut -c1-180)"
  else
    record_check embedded "Device-tree board model" SKIP "No device-tree model found; common on PCs, Macs, and some virtual machines"
  fi

  if [[ -r /sys/firmware/devicetree/base/serial-number ]]; then
    # Deliberately do not display board serial numbers in a routine health report.
    record_check embedded "Device-tree serial field" INFO "A board serial field exists; its value is intentionally not displayed"
  fi

  fw_count="$(count_glob '/sys/firmware/*')"
  if [[ -d /sys/firmware ]]; then
    record_check embedded "Firmware interfaces" INFO "$fw_count top-level firmware interface(s) visible under /sys/firmware"
  else
    record_check embedded "Firmware interfaces" SKIP "/sys/firmware not present on this OS"
  fi

  if exists vcgencmd; then
    throttled="$(vcgencmd get_throttled 2>/dev/null || true)"
    if [[ -n "$throttled" ]]; then
      record_check embedded "Board power/throttle telemetry" INFO "$throttled (also assessed in thermal section when selected)"
    fi
  else
    record_check embedded "Board-specific telemetry" SKIP "No vcgencmd utility; Raspberry Pi-specific power flags unavailable"
  fi

  local edac_out
  if exists edac-util; then
    edac_out="$(edac-util -v 2>&1 | head -n 8 || true)"
    if printf '%s' "$edac_out" | grep -Eqi 'No errors|0 errors'; then
      record_check embedded "ECC memory telemetry" PASS "edac-util reports no ECC errors in its visible summary"
    elif [[ -n "$edac_out" ]]; then
      record_check embedded "ECC memory telemetry" INFO "ECC utility output available; inspect platform-specific details"
    else
      record_check embedded "ECC memory telemetry" SKIP "edac-util returned no readable result"
    fi
  else
    record_check embedded "ECC memory telemetry" SKIP "edac-util not installed; ECC telemetry is platform-specific"
  fi
}

check_processes() {
  section_header "Processes and system pressure"
  local proc_count zombie_count load1 mem_pressure
  proc_count="$(ps -e -o pid= 2>/dev/null | awk 'NF {n++} END {print n+0}')"
  if [[ "$proc_count" =~ ^[0-9]+$ ]] && (( proc_count > 0 )); then
    record_check processes "Process count" INFO "$proc_count process(es) visible to the current user"
  else
    record_check processes "Process count" SKIP "Process list unavailable"
  fi

  if ps -e -o stat= >/dev/null 2>&1; then
    zombie_count="$(ps -e -o stat= 2>/dev/null | awk '$1 ~ /^Z/ {n++} END {print n+0}')"
    if (( zombie_count > 0 )); then
      record_check processes "Zombie processes" WARN "$zombie_count zombie process(es) visible; parent process may need inspection"
    else
      record_check processes "Zombie processes" PASS "No visible zombie processes"
    fi
  else
    record_check processes "Zombie processes" SKIP "Process-state details unavailable"
  fi

  mem_pressure=""
  if [[ -r /proc/pressure/memory ]]; then
    mem_pressure="$(awk '/^some / {print $2 " " $3 " " $4; exit}' /proc/pressure/memory 2>/dev/null)"
    record_check processes "Memory PSI" INFO "Linux pressure-stall summary: $mem_pressure"
  else
    record_check processes "Memory PSI" SKIP "Linux pressure-stall metrics are not exposed on this platform"
  fi

  if exists vmstat; then
    local vm_out
    vm_out="$(vmstat 1 2 2>/dev/null | tail -n 1)"
    [[ -n "$vm_out" ]] && record_check processes "vmstat snapshot" INFO "$(printf '%s' "$vm_out" | awk '{$1=$1; print}' | cut -c1-180)"
  fi
}

check_security() {
  section_header "Security posture (read-only indicators)"
  local selinux apparmor fw_state pf_info lockdown

  if exists getenforce; then
    selinux="$(getenforce 2>/dev/null || true)"
    case "$selinux" in
      Enforcing) record_check security "SELinux" PASS "Enforcing mode" ;;
      Permissive) record_check security "SELinux" WARN "Permissive mode; policy violations may be logged but not blocked" ;;
      Disabled) record_check security "SELinux" INFO "Disabled or unavailable in this configuration" ;;
      *) record_check security "SELinux" INFO "State: ${selinux:-unknown}" ;;
    esac
  else
    record_check security "SELinux" SKIP "getenforce not installed; SELinux state not queried"
  fi

  if exists aa-status; then
    if aa-status --enabled >/dev/null 2>&1; then
      record_check security "AppArmor" PASS "Enabled according to aa-status"
    else
      record_check security "AppArmor" INFO "aa-status found but AppArmor is not reported enabled"
    fi
  else
    record_check security "AppArmor" SKIP "aa-status not installed; AppArmor state not queried"
  fi

  if exists ufw; then
    fw_state="$(ufw status 2>/dev/null | head -n 1)"
    case "$fw_state" in
      *active*) record_check security "UFW firewall" PASS "$fw_state" ;;
      *inactive*) record_check security "UFW firewall" WARN "$fw_state; confirm whether another firewall is active" ;;
      *) record_check security "UFW firewall" INFO "Status unavailable or permission restricted" ;;
    esac
  elif exists firewall-cmd; then
    fw_state="$(firewall-cmd --state 2>/dev/null || true)"
    case "$fw_state" in
      running) record_check security "firewalld" PASS "Firewall service reports running" ;;
      "") record_check security "firewalld" INFO "Could not query firewall state; privileges may be required" ;;
      *) record_check security "firewalld" WARN "Firewall service state: $fw_state" ;;
    esac
  elif exists pfctl && [[ "$(uname -s)" == "Darwin" ]]; then
    pf_info="$(pfctl -s info 2>&1 | head -n 3 || true)"
    if printf '%s' "$pf_info" | grep -qi 'Status: Enabled'; then
      record_check security "Packet Filter (pf)" PASS "Status enabled"
    elif printf '%s' "$pf_info" | grep -qi 'Status: Disabled'; then
      record_check security "Packet Filter (pf)" INFO "Status disabled; macOS firewall controls may be managed separately"
    else
      record_check security "Packet Filter (pf)" SKIP "Could not read pf status; elevated access may be required"
    fi
  else
    record_check security "Host firewall" SKIP "No supported firewall status tool found; this is not proof that no firewall exists"
  fi

  lockdown="$(safe_read /sys/kernel/security/lockdown)"
  if [[ -n "$lockdown" ]]; then
    record_check security "Kernel lockdown" INFO "$lockdown"
  else
    record_check security "Kernel lockdown" SKIP "Kernel lockdown state is not exposed here"
  fi

  if [[ -r /proc/sys/kernel/randomize_va_space ]]; then
    local aslr
    aslr="$(safe_read /proc/sys/kernel/randomize_va_space)"
    case "$aslr" in
      2) record_check security "Linux ASLR" PASS "Full address-space layout randomization reported (value 2)" ;;
      1) record_check security "Linux ASLR" WARN "Partial address-space layout randomization reported (value 1)" ;;
      0) record_check security "Linux ASLR" WARN "Address-space layout randomization reported disabled (value 0)" ;;
      *) record_check security "Linux ASLR" INFO "Value: ${aslr:-unknown}" ;;
    esac
  else
    record_check security "Linux ASLR" SKIP "Linux ASLR setting not exposed on this platform"
  fi
}

check_logs() {
  section_header "Kernel and recent system logs"
  local dmesg_text hw_errors journal_text journal_lines
  if [[ "$(uname -s 2>/dev/null)" == "Linux" ]] && exists dmesg; then
    dmesg_text="$(dmesg 2>/dev/null || true)"
    if [[ -n "$dmesg_text" ]]; then
      hw_errors="$(printf '%s\n' "$dmesg_text" | grep -Eic 'I/O error|hardware error|uncorrectable|EXT4-fs error|BTRFS.*error|XFS.*(error|corrupt)|nvme.*(error|fail)|ata[0-9].*(error|fail)|mmc.*error|MCE:|machine check|thermal.*critical' 2>/dev/null || true)"
      [[ "$hw_errors" =~ ^[0-9]+$ ]] || hw_errors=0
      if (( hw_errors > 0 )); then
        record_check logs "Hardware-related kernel messages" WARN "$hw_errors matching line(s) in the readable kernel buffer; review logs for context"
      else
        record_check logs "Hardware-related kernel messages" PASS "No matching storage/hardware/thermal error pattern in the readable kernel buffer"
      fi
      if (( VERBOSE )); then
        printf '%s\n' "$dmesg_text" | grep -Ei 'I/O error|hardware error|uncorrectable|EXT4-fs error|BTRFS.*error|XFS.*(error|corrupt)|nvme.*(error|fail)|ata[0-9].*(error|fail)|mmc.*error|MCE:|machine check|thermal.*critical' | tail -n 12 | sed 's/^/      /' || true
      fi
    else
      record_check logs "Hardware-related kernel messages" SKIP "Kernel log buffer is empty or permission-restricted"
    fi
  else
    record_check logs "Hardware-related kernel messages" SKIP "Linux dmesg check not available on this OS"
  fi

  if exists journalctl; then
    journal_text="$(journalctl -b -p err --no-pager -n 100 2>/dev/null || true)"
    journal_lines="$(printf '%s\n' "$journal_text" | awk 'NF && $0 !~ /^-- / {n++} END {print n+0}')"
    if [[ "$journal_lines" =~ ^[0-9]+$ ]] && (( journal_lines > 0 )); then
      record_check logs "Recent journal errors" INFO "$journal_lines error-priority line(s) returned from the current boot (not necessarily hardware faults)"
      if (( VERBOSE )); then printf '%s\n' "$journal_text" | tail -n 12 | sed 's/^/      /'; fi
    else
      record_check logs "Recent journal errors" INFO "No error-priority lines returned, or journal access is restricted"
    fi
  else
    record_check logs "Recent journal errors" SKIP "systemd journal is not available"
  fi
}

run_checks() {
  local os_name host stamp overall
  stamp="$(date '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || date)"
  host="$(hostname 2>/dev/null || printf 'unknown-host')"
  os_name="$(uname -s 2>/dev/null || printf 'Unknown OS')"
  printf '%s\n' '================================================================================'
  printf ' %s — System Health Report\n' "$PROGRAM_NAME"
  printf ' Host: %s | Platform: %s | Generated: %s\n' "$host" "$os_name" "$stamp"
  printf '%s\n' ' Read-only, best-effort diagnostics; unavailable checks are marked SKIP.'
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

  printf '\n%s\n' '== Summary =='
  if (( COUNT_FAIL > 0 )); then overall="FAIL"
  elif (( COUNT_WARN > 0 )); then overall="WARN"
  else overall="PASS"
  fi
  status_color "$overall"
  printf '  OVERALL: %s' "$overall"
  reset_color
  printf ' | PASS: %d | WARN: %d | FAIL: %d | INFO: %d | SKIP: %d | Checks: %d\n' \
    "$COUNT_PASS" "$COUNT_WARN" "$COUNT_FAIL" "$COUNT_INFO" "$COUNT_SKIP" \
    "${#CHECK_STATUS[@]}"
  printf '%s\n' 'Thresholds are advisory. A PASS means no issue was detected by the checks available here.'
}

json_escape() {
  local s="$1" out="" ch i
  local LC_ALL=C
  for ((i=0; i<${#s}; i++)); do
    ch="${s:i:1}"
    case "$ch" in
      \\) out+=$'\\\\' ;;
      \" ) out+=$'\\"' ;;
      $'\n') out+=$'\\n' ;;
      $'\r') out+=$'\\r' ;;
      $'\t') out+=$'\\t' ;;
      *) out+="$ch" ;;
    esac
  done
  printf '%s' "$out"
}

write_json() {
  local target="$1" i generated host os_name overall tmp_dir
  generated="$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')"
  host="$(hostname 2>/dev/null || printf 'unknown-host')"
  os_name="$(uname -s 2>/dev/null || printf 'Unknown OS')"
  if (( COUNT_FAIL > 0 )); then overall="FAIL"; elif (( COUNT_WARN > 0 )); then overall="WARN"; else overall="PASS"; fi

  # Write atomically beside the destination where possible.
  tmp_dir="$(dirname "$target")"
  [[ -d "$tmp_dir" ]] || { printf 'Run: JSON output directory does not exist: %s\n' "$tmp_dir" >&2; return 1; }
  local tmpfile
  tmpfile="$(mktemp "$tmp_dir/.Run-json.XXXXXX" 2>/dev/null)" || { printf 'Run: cannot create temporary JSON file in %s\n' "$tmp_dir" >&2; return 1; }
  {
    printf '{\n'
    printf '  "program": "%s",\n' "$(json_escape "$PROGRAM_NAME")"
    printf '  "version": "%s",\n' "$(json_escape "$RUN_VERSION")"
    printf '  "generated_at": "%s",\n' "$(json_escape "$generated")"
    printf '  "hostname": "%s",\n' "$(json_escape "$host")"
    printf '  "platform": "%s",\n' "$(json_escape "$os_name")"
    printf '  "overall": "%s",\n' "$overall"
    printf '  "summary": {"pass": %d, "warn": %d, "fail": %d, "info": %d, "skip": %d, "total": %d},\n' \
      "$COUNT_PASS" "$COUNT_WARN" "$COUNT_FAIL" "$COUNT_INFO" "$COUNT_SKIP" "${#CHECK_STATUS[@]}"
    printf '  "checks": [\n'
    for ((i=0; i<${#CHECK_STATUS[@]}; i++)); do
      printf '    {"section":"%s","name":"%s","status":"%s","detail":"%s"}' \
        "$(json_escape "${CHECK_SECTION[$i]}")" \
        "$(json_escape "${CHECK_NAME[$i]}")" \
        "$(json_escape "${CHECK_STATUS[$i]}")" \
        "$(json_escape "${CHECK_DETAIL[$i]}")"
      if (( i + 1 < ${#CHECK_STATUS[@]} )); then printf ','; fi
      printf '\n'
    done
    printf '  ]\n}\n'
  } > "$tmpfile"
  if mv -f "$tmpfile" "$target"; then
    printf 'Run: JSON report saved to %s\n' "$target"
  else
    rm -f "$tmpfile"
    printf 'Run: failed to write JSON report to %s\n' "$target" >&2
    return 1
  fi
}

normalize_sections() {
  local raw="$1" part out="" old_ifs="$IFS"
  raw="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr ' ' ',')"
  IFS=','
  for part in $raw; do
    [[ -n "$part" ]] || continue
    case "$part" in
      os|platform) part=system ;;
      chip|processor) part=cpu ;;
      hardware) part=devices ;;
      ram) part=memory ;;
      disk|disks|filesystem|filesystems) part=storage ;;
      sensors|temperature|temps) part=thermal ;;
      peripherals|devices) part=devices ;;
      embedded-system|board) part=embedded ;;
      process|processes) part=processes ;;
      log|journal) part=logs ;;
    esac
    case "$part" in
      system|cpu|memory|storage|network|thermal|battery|devices|embedded|processes|security|logs) ;;
      *) IFS="$old_ifs"; printf 'Run: unknown section: %s\n' "$part" >&2; return 1 ;;
    esac
    case ",$out," in *",$part,"*) ;; *) out="${out:+$out,}$part" ;; esac
  done
  IFS="$old_ifs"
  [[ -n "$out" ]] || { printf 'Run: no valid section names supplied\n' >&2; return 1; }
  SECTION_FILTER="$out"
}

run_tui() {
  local choice
  if exists dialog && [[ -t 0 && -t 1 ]]; then
    choice="$(dialog --stdout --title 'Run — System Health' --menu 'Choose a scan:' 19 72 10 \
      all 'Full health scan' \
      quick 'Quick scan' \
      storage 'Storage, file systems and drive health' \
      compute 'CPU, memory and thermal sensors' \
      devices 'Hardware, peripherals and embedded board' \
      network 'Network configuration' \
      battery 'Battery and power' \
      security 'Security posture' \
      logs 'Kernel and system logs' \
      exit 'Exit' 2>/dev/null)" || choice=exit
  elif exists whiptail && [[ -t 0 && -t 1 ]]; then
    choice="$(whiptail --title 'Run — System Health' --menu 'Choose a scan:' 19 72 10 \
      all 'Full health scan' \
      quick 'Quick scan' \
      storage 'Storage, file systems and drive health' \
      compute 'CPU, memory and thermal sensors' \
      devices 'Hardware, peripherals and embedded board' \
      network 'Network configuration' \
      battery 'Battery and power' \
      security 'Security posture' \
      logs 'Kernel and system logs' \
      exit 'Exit' 3>&1 1>&2 2>&3)" || choice=exit
  else
    printf '%s\n' 'Run — Terminal menu' '1) Full health scan' '2) Quick scan' '3) Storage / disks' \
      '4) CPU / memory / thermal' '5) Hardware / embedded' '6) Network' '7) Battery' \
      '8) Security' '9) Logs' '0) Exit'
    printf 'Select [1-9,0]: '
    IFS= read -r choice || choice=0
    case "$choice" in
      1) choice=all ;; 2) choice=quick ;; 3) choice=storage ;; 4) choice=compute ;;
      5) choice=devices ;; 6) choice=network ;; 7) choice=battery ;; 8) choice=security ;;
      9) choice=logs ;; 0) choice=exit ;; *) choice=exit ;;
    esac
  fi

  case "$choice" in
    all) SECTION_FILTER=""; QUICK=0 ;;
    quick) SECTION_FILTER=""; QUICK=1 ;;
    storage) SECTION_FILTER="storage" ;;
    compute) SECTION_FILTER="cpu,memory,thermal" ;;
    devices) SECTION_FILTER="devices,embedded,thermal" ;;
    network) SECTION_FILTER="network" ;;
    battery) SECTION_FILTER="battery" ;;
    security) SECTION_FILTER="security" ;;
    logs) SECTION_FILTER="logs" ;;
    *) printf 'Run: exiting without a scan.\n'; exit 0 ;;
  esac
}

# Parse arguments after all functions are declared so --help stays dependency-free.
while (( $# > 0 )); do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --version) printf '%s %s\n' "$PROGRAM_NAME" "$RUN_VERSION"; exit 0 ;;
    --quick) QUICK=1 ;;
    --all) QUICK=0 ;;
    --tui) TUI=1 ;;
    --network-test) NETWORK_TEST=1 ;;
    --verbose) VERBOSE=1 ;;
    --plain|--no-color) PLAIN=1; COLOR=0 ;;
    --section)
      shift
      if (( $# == 0 )); then printf 'Run: --section requires a section name\n' >&2; exit 2; fi
      if [[ -n "$SECTION_FILTER" ]]; then SECTION_FILTER="$SECTION_FILTER,$1"; else SECTION_FILTER="$1"; fi
      ;;
    --report)
      shift
      if (( $# == 0 )); then printf 'Run: --report requires a file path\n' >&2; exit 2; fi
      REPORT_FILE="$1"
      ;;
    --json)
      shift
      if (( $# == 0 )); then printf 'Run: --json requires a file path\n' >&2; exit 2; fi
      JSON_FILE="$1"
      ;;
    --watch)
      shift
      if (( $# == 0 )); then printf 'Run: --watch requires seconds\n' >&2; exit 2; fi
      if [[ ! "$1" =~ ^[1-9][0-9]*$ ]]; then printf 'Run: --watch interval must be a positive whole number of seconds\n' >&2; exit 2; fi
      WATCH_INTERVAL="$1"
      ;;
    --*) printf 'Run: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    *) printf 'Run: unexpected positional argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ -n "$SECTION_FILTER" ]]; then
  # Normalize/validate names; support aliases and comma-separated filters.
  normalize_sections "$SECTION_FILTER" || exit 2
fi

if (( TUI )); then run_tui; fi

if [[ -n "$WATCH_INTERVAL" ]]; then
  if [[ -n "$REPORT_FILE" || -n "$JSON_FILE" ]]; then
    printf 'Run: --watch cannot be combined with --report or --json because those outputs would be repeatedly overwritten.\n' >&2
    exit 2
  fi
  while :; do
    if [[ -t 1 ]] && exists clear; then clear; fi
    reset_results
    run_checks
    printf '\nRefreshing in %s second(s). Press Ctrl+C to stop.\n' "$WATCH_INTERVAL"
    sleep "$WATCH_INTERVAL" || break
  done
  exit 0
fi

# Reports are generated to a temporary text file first so check records remain in this shell
# for JSON output. The finished text is then displayed and/or saved at the requested path.
if [[ -n "$REPORT_FILE" ]]; then
  report_dir="$(dirname "$REPORT_FILE")"
  if [[ ! -d "$report_dir" ]]; then printf 'Run: report directory does not exist: %s\n' "$report_dir" >&2; exit 2; fi
  report_tmp="$(mktemp "${TMPDIR:-/tmp}/Run-report.XXXXXX" 2>/dev/null)" || { printf 'Run: could not create temporary report file\n' >&2; exit 2; }
  COLOR=0
  run_checks > "$report_tmp"
  if ! cp "$report_tmp" "$REPORT_FILE"; then rm -f "$report_tmp"; printf 'Run: could not write report file: %s\n' "$REPORT_FILE" >&2; exit 2; fi
  cat "$report_tmp"
  rm -f "$report_tmp"
else
  run_checks
fi

if [[ -n "$JSON_FILE" ]]; then write_json "$JSON_FILE" || exit 2; fi

# Exit status is useful for scripts: 2=usage/output error, 1=health warning/failure, 0=no WARN/FAIL.
if (( COUNT_FAIL > 0 )); then exit 1; fi
if (( COUNT_WARN > 0 )); then exit 1; fi
exit 0
