#!/bin/bash
#===============================================================================
# system_monitor.sh - System Health Monitoring Script
# Author: Mikhail Miasnikou
# Description: Monitors CPU, Memory, Disk, and services with alerting
# Usage: ./system_monitor.sh [--daemon] [--config config.conf]
#===============================================================================

set -euo pipefail

# === CONFIGURATION ===
CPU_THRESHOLD="${CPU_THRESHOLD:-80}"           # Alert if CPU > 80%
MEMORY_THRESHOLD="${MEMORY_THRESHOLD:-85}"     # Alert if Memory > 85%
DISK_THRESHOLD="${DISK_THRESHOLD:-90}"         # Alert if Disk > 90%
CHECK_INTERVAL="${CHECK_INTERVAL:-60}"         # Check every 60 seconds (daemon mode)
LOG_FILE="${LOG_FILE:-/var/log/system_monitor.log}"
REPORT_FILE="${REPORT_FILE:-/tmp/system_report.html}"

# Services to monitor (space-separated)
SERVICES="${SERVICES:-docker nginx ssh}"

# Telegram alerts (optional)
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

# === COLORS ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# === FUNCTIONS ===

log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} $1" | tee -a "$LOG_FILE"
}

send_alert() {
    local message="$1"
    local level="${2:-WARNING}"
    
    log "[${level}] ${message}"
    
    # Telegram notification
    if [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
        local emoji="⚠️"
        [[ "$level" == "CRITICAL" ]] && emoji="🔴"
        [[ "$level" == "OK" ]] && emoji="✅"
        
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="$TELEGRAM_CHAT_ID" \
            -d text="${emoji} <b>${level}</b>%0A${message}%0AHost: $(hostname)%0ATime: $(date '+%Y-%m-%d %H:%M:%S')" \
            -d parse_mode="HTML" > /dev/null 2>&1 || true
    fi
}

get_cpu_usage() {
    # Get CPU usage (average over 1 second)
    local cpu_idle=$(top -bn2 -d0.5 | grep "Cpu(s)" | tail -1 | awk '{print $8}' | cut -d'%' -f1)
    local cpu_usage=$(echo "100 - ${cpu_idle:-0}" | bc 2>/dev/null || echo "0")
    printf "%.0f" "$cpu_usage"
}

get_memory_usage() {
    free | awk '/Mem:/ {printf "%.0f", $3/$2 * 100}'
}

get_disk_usage() {
    local mount="${1:-/}"
    df -h "$mount" | awk 'NR==2 {gsub(/%/,""); print $5}'
}

get_load_average() {
    cat /proc/loadavg | awk '{print $1, $2, $3}'
}

get_uptime() {
    uptime -p 2>/dev/null || uptime | awk -F'up ' '{print $2}' | awk -F',' '{print $1}'
}

check_service() {
    local service="$1"
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        echo "running"
    elif pgrep -x "$service" > /dev/null 2>&1; then
        echo "running"
    else
        echo "stopped"
    fi
}

get_top_processes() {
    ps aux --sort=-%mem | head -6 | tail -5 | awk '{printf "%-10s %5s%% %5s%% %s\n", $1, $3, $4, $11}'
}

get_network_stats() {
    local interface="${1:-eth0}"
    if [[ -d "/sys/class/net/$interface" ]]; then
        local rx=$(cat /sys/class/net/$interface/statistics/rx_bytes 2>/dev/null || echo 0)
        local tx=$(cat /sys/class/net/$interface/statistics/tx_bytes 2>/dev/null || echo 0)
        echo "RX: $(numfmt --to=iec $rx 2>/dev/null || echo ${rx}B) | TX: $(numfmt --to=iec $tx 2>/dev/null || echo ${tx}B)"
    else
        echo "Interface not found"
    fi
}

get_docker_status() {
    if command -v docker &> /dev/null; then
        local running=$(docker ps -q 2>/dev/null | wc -l)
        local total=$(docker ps -aq 2>/dev/null | wc -l)
        echo "${running}/${total} containers running"
    else
        echo "Docker not installed"
    fi
}

print_header() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║           SYSTEM HEALTH MONITOR - $(hostname)${NC}"
    echo -e "${BLUE}║           $(date '+%Y-%m-%d %H:%M:%S')${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_section() {
    echo -e "${YELLOW}▶ $1${NC}"
}

status_color() {
    local value="$1"
    local threshold="$2"
    
    if [[ $value -ge $threshold ]]; then
        echo -e "${RED}${value}%${NC}"
    elif [[ $value -ge $((threshold - 10)) ]]; then
        echo -e "${YELLOW}${value}%${NC}"
    else
        echo -e "${GREEN}${value}%${NC}"
    fi
}

run_checks() {
    local alerts=()
    
    print_header
    
    # === SYSTEM INFO ===
    print_section "SYSTEM INFO"
    echo "  Hostname:     $(hostname)"
    echo "  Uptime:       $(get_uptime)"
    echo "  Load Average: $(get_load_average)"
    echo ""
    
    # === CPU ===
    print_section "CPU"
    local cpu=$(get_cpu_usage)
    echo -e "  Usage:        $(status_color $cpu $CPU_THRESHOLD)"
    if [[ $cpu -ge $CPU_THRESHOLD ]]; then
        alerts+=("CPU usage critical: ${cpu}%")
    fi
    echo ""
    
    # === MEMORY ===
    print_section "MEMORY"
    local mem=$(get_memory_usage)
    local mem_total=$(free -h | awk '/Mem:/ {print $2}')
    local mem_used=$(free -h | awk '/Mem:/ {print $3}')
    echo -e "  Usage:        $(status_color $mem $MEMORY_THRESHOLD) (${mem_used} / ${mem_total})"
    if [[ $mem -ge $MEMORY_THRESHOLD ]]; then
        alerts+=("Memory usage critical: ${mem}%")
    fi
    echo ""
    
    # === DISK ===
    print_section "DISK"
    while read -r line; do
        local mount=$(echo "$line" | awk '{print $6}')
        local usage=$(echo "$line" | awk '{gsub(/%/,""); print $5}')
        local size=$(echo "$line" | awk '{print $2}')
        local used=$(echo "$line" | awk '{print $3}')
        
        echo -e "  ${mount}:$(printf '%*s' $((12 - ${#mount})) '')$(status_color $usage $DISK_THRESHOLD) (${used} / ${size})"
        
        if [[ $usage -ge $DISK_THRESHOLD ]]; then
            alerts+=("Disk ${mount} critical: ${usage}%")
        fi
    done < <(df -h | grep -E '^/dev/' | head -5)
    echo ""
    
    # === SERVICES ===
    print_section "SERVICES"
    for service in $SERVICES; do
        local status=$(check_service "$service")
        if [[ "$status" == "running" ]]; then
            echo -e "  ${service}:$(printf '%*s' $((12 - ${#service})) '')${GREEN}● running${NC}"
        else
            echo -e "  ${service}:$(printf '%*s' $((12 - ${#service})) '')${RED}○ stopped${NC}"
            alerts+=("Service ${service} is not running")
        fi
    done
    echo ""
    
    # === DOCKER ===
    print_section "DOCKER"
    echo "  Status:       $(get_docker_status)"
    echo ""
    
    # === TOP PROCESSES ===
    print_section "TOP PROCESSES (by memory)"
    echo "  USER         CPU%   MEM%  COMMAND"
    get_top_processes | while read -r line; do
        echo "  $line"
    done
    echo ""
    
    # === NETWORK ===
    print_section "NETWORK"
    for iface in $(ls /sys/class/net/ | grep -E '^(eth|ens|enp|wlan)' | head -3); do
        echo "  ${iface}:$(printf '%*s' $((12 - ${#iface})) '')$(get_network_stats $iface)"
    done
    echo ""
    
    # === ALERTS ===
    if [[ ${#alerts[@]} -gt 0 ]]; then
        echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║                        ⚠️  ALERTS                             ║${NC}"
        echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
        for alert in "${alerts[@]}"; do
            echo -e "  ${RED}• ${alert}${NC}"
            send_alert "$alert" "CRITICAL"
        done
        echo ""
        return 1
    else
        echo -e "${GREEN}✓ All systems operational${NC}"
        echo ""
        return 0
    fi
}

generate_html_report() {
    local cpu=$(get_cpu_usage)
    local mem=$(get_memory_usage)
    local disk=$(get_disk_usage "/")
    
    cat > "$REPORT_FILE" << EOF
<!DOCTYPE html>
<html>
<head>
    <title>System Report - $(hostname)</title>
    <meta charset="UTF-8">
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; background: #f5f5f5; }
        .container { max-width: 800px; margin: 0 auto; background: white; padding: 20px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        h1 { color: #333; border-bottom: 2px solid #2b5797; padding-bottom: 10px; }
        .metric { display: inline-block; width: 30%; margin: 10px; padding: 20px; text-align: center; border-radius: 8px; }
        .metric-value { font-size: 36px; font-weight: bold; }
        .metric-label { color: #666; margin-top: 5px; }
        .ok { background: #d4edda; color: #155724; }
        .warning { background: #fff3cd; color: #856404; }
        .critical { background: #f8d7da; color: #721c24; }
        .timestamp { color: #999; font-size: 12px; margin-top: 20px; }
    </style>
</head>
<body>
    <div class="container">
        <h1>🖥️ System Health Report</h1>
        <p><strong>Host:</strong> $(hostname) | <strong>Generated:</strong> $(date '+%Y-%m-%d %H:%M:%S')</p>
        
        <div style="text-align: center;">
            <div class="metric $([ $cpu -ge $CPU_THRESHOLD ] && echo 'critical' || ([ $cpu -ge $((CPU_THRESHOLD-10)) ] && echo 'warning' || echo 'ok'))">
                <div class="metric-value">${cpu}%</div>
                <div class="metric-label">CPU Usage</div>
            </div>
            <div class="metric $([ $mem -ge $MEMORY_THRESHOLD ] && echo 'critical' || ([ $mem -ge $((MEMORY_THRESHOLD-10)) ] && echo 'warning' || echo 'ok'))">
                <div class="metric-value">${mem}%</div>
                <div class="metric-label">Memory Usage</div>
            </div>
            <div class="metric $([ $disk -ge $DISK_THRESHOLD ] && echo 'critical' || ([ $disk -ge $((DISK_THRESHOLD-10)) ] && echo 'warning' || echo 'ok'))">
                <div class="metric-value">${disk}%</div>
                <div class="metric-label">Disk Usage</div>
            </div>
        </div>
        
        <p class="timestamp">Report generated by system_monitor.sh</p>
    </div>
</body>
</html>
EOF
    echo "HTML report generated: $REPORT_FILE"
}

daemon_mode() {
    log "[INFO] Starting daemon mode (interval: ${CHECK_INTERVAL}s)"
    
    while true; do
        run_checks > /dev/null 2>&1 || true
        sleep "$CHECK_INTERVAL"
    done
}

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --daemon      Run in background with periodic checks"
    echo "  --html        Generate HTML report"
    echo "  --config FILE Load configuration from file"
    echo "  --help        Show this help"
    echo ""
    echo "Environment variables:"
    echo "  CPU_THRESHOLD      CPU alert threshold (default: 80)"
    echo "  MEMORY_THRESHOLD   Memory alert threshold (default: 85)"
    echo "  DISK_THRESHOLD     Disk alert threshold (default: 90)"
    echo "  CHECK_INTERVAL     Check interval in seconds for daemon mode (default: 60)"
    echo "  SERVICES           Space-separated list of services to monitor"
    echo "  TELEGRAM_BOT_TOKEN Telegram bot token for alerts"
    echo "  TELEGRAM_CHAT_ID   Telegram chat ID for alerts"
}

# === MAIN ===

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --daemon)
                daemon_mode
                exit 0
                ;;
            --html)
                generate_html_report
                exit 0
                ;;
            --config)
                if [[ -f "$2" ]]; then
                    source "$2"
                    shift
                else
                    echo "Config file not found: $2"
                    exit 1
                fi
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
        shift
    done
    
    # Run single check
    run_checks
}

main "$@"
