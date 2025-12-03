#!/bin/bash
#===============================================================================
# docker_manager.sh - Docker Container Management Script
# Author: Mikhail Miasnikou
# Description: Manage Docker containers, images, and volumes with easy commands
# Usage: ./docker_manager.sh [command] [options]
#===============================================================================

set -euo pipefail

# === COLORS ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# === FUNCTIONS ===

print_header() {
    echo -e "${BLUE}"
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║             🐳 DOCKER MANAGER                             ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_section() {
    echo -e "\n${CYAN}▶ $1${NC}\n"
}

check_docker() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}Error: Docker is not installed${NC}"
        exit 1
    fi
    
    if ! docker info &> /dev/null; then
        echo -e "${RED}Error: Docker daemon is not running${NC}"
        exit 1
    fi
}

# === STATUS COMMAND ===
cmd_status() {
    print_header
    
    print_section "DOCKER INFO"
    echo "  Version:      $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo 'N/A')"
    echo "  Storage:      $(docker system df --format '{{.Size}}' 2>/dev/null | head -1 || echo 'N/A')"
    
    print_section "CONTAINERS"
    local running=$(docker ps -q | wc -l)
    local stopped=$(docker ps -aq --filter "status=exited" | wc -l)
    local total=$(docker ps -aq | wc -l)
    
    echo -e "  Running:      ${GREEN}${running}${NC}"
    echo -e "  Stopped:      ${YELLOW}${stopped}${NC}"
    echo "  Total:        ${total}"
    
    if [[ $running -gt 0 ]]; then
        echo ""
        echo "  NAME                          STATUS          PORTS"
        echo "  ────────────────────────────────────────────────────────────"
        docker ps --format "  {{.Names}}\t{{.Status}}\t{{.Ports}}" | head -10
    fi
    
    print_section "IMAGES"
    local images=$(docker images -q | wc -l)
    local dangling=$(docker images -f "dangling=true" -q | wc -l)
    echo "  Total:        ${images}"
    echo -e "  Dangling:     ${YELLOW}${dangling}${NC}"
    
    print_section "VOLUMES"
    local volumes=$(docker volume ls -q | wc -l)
    echo "  Total:        ${volumes}"
    
    print_section "DISK USAGE"
    docker system df 2>/dev/null || echo "  Unable to get disk usage"
}

# === LIST COMMAND ===
cmd_list() {
    local filter="${1:-all}"
    
    print_section "CONTAINERS ($filter)"
    
    case "$filter" in
        running)
            docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"
            ;;
        stopped)
            docker ps -a --filter "status=exited" --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"
            ;;
        all|*)
            docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"
            ;;
    esac
}

# === LOGS COMMAND ===
cmd_logs() {
    local container="${1:-}"
    local lines="${2:-100}"
    
    if [[ -z "$container" ]]; then
        echo -e "${RED}Error: Container name required${NC}"
        echo "Usage: $0 logs <container_name> [lines]"
        return 1
    fi
    
    print_section "LOGS: $container (last $lines lines)"
    docker logs --tail "$lines" -f "$container"
}

# === SHELL COMMAND ===
cmd_shell() {
    local container="${1:-}"
    local shell="${2:-/bin/bash}"
    
    if [[ -z "$container" ]]; then
        echo -e "${RED}Error: Container name required${NC}"
        echo "Usage: $0 shell <container_name> [shell]"
        return 1
    fi
    
    echo -e "${GREEN}Connecting to ${container}...${NC}"
    docker exec -it "$container" "$shell" || docker exec -it "$container" /bin/sh
}

# === RESTART COMMAND ===
cmd_restart() {
    local container="${1:-}"
    
    if [[ -z "$container" ]]; then
        echo -e "${RED}Error: Container name required${NC}"
        return 1
    fi
    
    echo -e "${YELLOW}Restarting ${container}...${NC}"
    docker restart "$container"
    echo -e "${GREEN}✓ Container restarted${NC}"
}

# === CLEANUP COMMAND ===
cmd_cleanup() {
    print_section "CLEANUP"
    
    echo -e "${YELLOW}This will remove:${NC}"
    echo "  - Stopped containers"
    echo "  - Unused networks"
    echo "  - Dangling images"
    echo "  - Build cache"
    echo ""
    
    read -p "Continue? (y/N) " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo ""
        echo "Removing stopped containers..."
        docker container prune -f
        
        echo "Removing unused networks..."
        docker network prune -f
        
        echo "Removing dangling images..."
        docker image prune -f
        
        echo "Removing build cache..."
        docker builder prune -f
        
        echo ""
        echo -e "${GREEN}✓ Cleanup complete${NC}"
        
        print_section "SPACE RECOVERED"
        docker system df
    else
        echo "Cancelled"
    fi
}

# === BACKUP COMMAND ===
cmd_backup() {
    local container="${1:-}"
    local backup_dir="${2:-./docker_backups}"
    
    if [[ -z "$container" ]]; then
        echo -e "${RED}Error: Container name required${NC}"
        echo "Usage: $0 backup <container_name> [backup_dir]"
        return 1
    fi
    
    mkdir -p "$backup_dir"
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local backup_file="${backup_dir}/${container}_${timestamp}.tar"
    
    print_section "BACKUP: $container"
    
    # Get volumes
    local volumes=$(docker inspect "$container" --format '{{range .Mounts}}{{.Source}}:{{.Destination}} {{end}}' 2>/dev/null)
    
    echo "Exporting container..."
    docker export "$container" > "${backup_file}"
    gzip "${backup_file}"
    
    echo "Backup saved: ${backup_file}.gz"
    echo -e "${GREEN}✓ Backup complete${NC}"
}

# === STATS COMMAND ===
cmd_stats() {
    print_section "CONTAINER STATS (Press Ctrl+C to exit)"
    docker stats --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}"
}

# === COMPOSE COMMAND ===
cmd_compose() {
    local action="${1:-}"
    local compose_file="${2:-docker-compose.yml}"
    
    if [[ ! -f "$compose_file" ]]; then
        echo -e "${RED}Error: $compose_file not found${NC}"
        return 1
    fi
    
    case "$action" in
        up)
            echo -e "${GREEN}Starting services...${NC}"
            docker compose -f "$compose_file" up -d
            ;;
        down)
            echo -e "${YELLOW}Stopping services...${NC}"
            docker compose -f "$compose_file" down
            ;;
        restart)
            echo -e "${YELLOW}Restarting services...${NC}"
            docker compose -f "$compose_file" restart
            ;;
        logs)
            docker compose -f "$compose_file" logs -f
            ;;
        ps)
            docker compose -f "$compose_file" ps
            ;;
        *)
            echo "Usage: $0 compose <up|down|restart|logs|ps> [compose_file]"
            ;;
    esac
}

# === HELP ===
show_help() {
    print_header
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  status              Show Docker system status"
    echo "  list [filter]       List containers (all|running|stopped)"
    echo "  logs <name> [n]     Show container logs (last n lines)"
    echo "  shell <name>        Open shell in container"
    echo "  restart <name>      Restart container"
    echo "  stats               Show live container stats"
    echo "  cleanup             Remove unused resources"
    echo "  backup <name>       Backup container to archive"
    echo "  compose <action>    Docker Compose shortcuts"
    echo "  help                Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 status"
    echo "  $0 list running"
    echo "  $0 logs nginx 50"
    echo "  $0 shell my_container"
    echo "  $0 compose up"
}

# === MAIN ===

main() {
    check_docker
    
    local command="${1:-help}"
    shift || true
    
    case "$command" in
        status)     cmd_status "$@" ;;
        list|ls)    cmd_list "$@" ;;
        logs)       cmd_logs "$@" ;;
        shell|sh)   cmd_shell "$@" ;;
        restart)    cmd_restart "$@" ;;
        stats)      cmd_stats "$@" ;;
        cleanup)    cmd_cleanup "$@" ;;
        backup)     cmd_backup "$@" ;;
        compose|dc) cmd_compose "$@" ;;
        help|--help|-h) show_help ;;
        *)
            echo -e "${RED}Unknown command: $command${NC}"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
