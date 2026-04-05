#!/usr/bin/env bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_PROJECT_CANDIDATES=(
  "${PROJECT_DIR:-}"
  "$(pwd)"
  "${SCRIPT_PATH}"
  "/opt/zanjir"
  "/root/zanjir"
)
REQUIRED_SERVICES=("caddy" "conduit" "element-web" "coturn")

print_banner() {
  printf '\n%b\n' "${CYAN}${BOLD}Zanjir Control${NC}"
  printf '%b\n\n' "${BLUE}========================================${NC}"
}

info() {
  printf '%b\n' "${BLUE}[INFO]${NC} $1"
}

ok() {
  printf '%b\n' "${GREEN}[OK]${NC} $1"
}

warn() {
  printf '%b\n' "${YELLOW}[WARN]${NC} $1"
}

fail() {
  printf '%b\n' "${RED}[FAIL]${NC} $1"
}

require_root() {
  if [ "${EUID}" -ne 0 ]; then
    fail "This action requires root privileges."
    exit 1
  fi
}

resolve_project_dir() {
  local candidate
  for candidate in "${DEFAULT_PROJECT_CANDIDATES[@]}"; do
    [ -n "${candidate}" ] || continue
    if [ -f "${candidate}/docker-compose.yml" ]; then
      PROJECT_DIR="${candidate}"
      return 0
    fi
  done

  fail "Could not locate the Zanjir project directory."
  exit 1
}

compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose -f "${PROJECT_DIR}/docker-compose.yml" --project-directory "${PROJECT_DIR}" "$@"
  elif docker-compose version >/dev/null 2>&1; then
    docker-compose -f "${PROJECT_DIR}/docker-compose.yml" "$@"
  else
    fail "Docker Compose is not available."
    exit 1
  fi
}

load_env() {
  ENV_FILE="${PROJECT_DIR}/.env"
  if [ -f "${ENV_FILE}" ]; then
    set -a
    . "${ENV_FILE}"
    set +a
  fi
}

show_status() {
  resolve_project_dir
  print_banner
  info "Project directory: ${PROJECT_DIR}"

  if ! command -v docker >/dev/null 2>&1; then
    fail "Docker is not installed."
    return 1
  fi

  compose ps
}

view_logs() {
  resolve_project_dir
  local service="${1:-}"
  if [ -n "${service}" ]; then
    compose logs --tail=100 -f "${service}"
  else
    compose logs --tail=100 -f
  fi
}

restart_services() {
  require_root
  resolve_project_dir
  compose restart
  ok "Services restarted."
}

container_running() {
  local service="$1"
  local state
  state="$(compose ps --format json 2>/dev/null | sed '/^[[:space:]]*$/d' || true)"
  printf '%s' "${state}" | grep -q "\"Service\":\"${service}\"" &&
    printf '%s' "${state}" | grep -q "\"State\":\"running\""
}

host_ips() {
  hostname -I 2>/dev/null || true
  ip -4 addr show scope global 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1
}

domain_resolves_to_host() {
  local domain="$1"
  local resolved_ips host_ip
  resolved_ips="$(getent ahostsv4 "${domain}" 2>/dev/null | awk '{print $1}' | sort -u || true)"
  [ -n "${resolved_ips}" ] || return 1

  while IFS= read -r host_ip; do
    [ -n "${host_ip}" ] || continue
    if printf '%s\n' "${resolved_ips}" | grep -Fxq "${host_ip}"; then
      return 0
    fi
  done < <(host_ips | tr ' ' '\n' | sed '/^[[:space:]]*$/d' | sort -u)

  return 1
}

check_port_binding() {
  local port="$1"
  local proto="$2"
  local expected_name="$3"
  local published

  published="$(docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep "${expected_name}" || true)"
  if printf '%s' "${published}" | grep -Eq "(0\.0\.0\.0|:::)?${port}->${port}/${proto}"; then
    ok "Port ${port}/${proto} is published by ${expected_name}."
    return 0
  fi

  local listener=""
  if command -v ss >/dev/null 2>&1; then
    if [ "${proto}" = "tcp" ]; then
      listener="$(ss -ltnp "( sport = :${port} )" 2>/dev/null | tail -n +2 || true)"
    else
      listener="$(ss -lunp "( sport = :${port} )" 2>/dev/null | tail -n +2 || true)"
    fi
  fi

  if [ -n "${listener}" ]; then
    fail "Port ${port}/${proto} is in use by a non-Zanjir process or is not mapped by ${expected_name}."
  else
    fail "Port ${port}/${proto} is not published."
  fi
  return 1
}

doctor() {
  resolve_project_dir
  load_env
  print_banner
  info "Running Zanjir doctor in ${PROJECT_DIR}"

  local failures=0
  local warnings=0

  if command -v docker >/dev/null 2>&1; then
    ok "Docker CLI is installed."
  else
    fail "Docker CLI is missing."
    failures=$((failures + 1))
  fi

  if docker info >/dev/null 2>&1; then
    ok "Docker daemon is reachable."
  else
    fail "Docker daemon is not reachable."
    failures=$((failures + 1))
  fi

  if docker compose version >/dev/null 2>&1 || docker-compose version >/dev/null 2>&1; then
    ok "Docker Compose is available."
  else
    fail "Docker Compose is missing."
    failures=$((failures + 1))
  fi

  if [ -f "${ENV_FILE}" ]; then
    ok ".env file exists."
  else
    fail ".env file is missing."
    failures=$((failures + 1))
  fi

  local key
  for key in DOMAIN HTTP_PORT HTTPS_PORT; do
    if [ -n "${!key:-}" ]; then
      ok ".env contains ${key}=${!key}."
    else
      fail ".env is missing ${key}."
      failures=$((failures + 1))
    fi
  done

  check_port_binding "${HTTP_PORT:-80}" tcp "zanjir-caddy" || failures=$((failures + 1))
  check_port_binding "${HTTPS_PORT:-443}" tcp "zanjir-caddy" || failures=$((failures + 1))
  check_port_binding "3478" udp "zanjir-coturn" || failures=$((failures + 1))
  check_port_binding "5349" udp "zanjir-coturn" || failures=$((failures + 1))

  local ps_json
  ps_json="$(compose ps --format json 2>/dev/null || true)"
  if [ -z "${ps_json}" ]; then
    fail "Could not inspect container status with Docker Compose."
    failures=$((failures + 1))
  else
    local service
    for service in "${REQUIRED_SERVICES[@]}"; do
      if printf '%s' "${ps_json}" | grep -q "\"Service\":\"${service}\""; then
        if printf '%s' "${ps_json}" | grep -q "\"Service\":\"${service}\".*\"State\":\"running\"" || container_running "${service}"; then
          ok "Container ${service} is running."
        else
          fail "Container ${service} is not running."
          failures=$((failures + 1))
        fi
      else
        fail "Container ${service} is not defined or not created."
        failures=$((failures + 1))
      fi
    done
  fi

  if [ -n "${DOMAIN:-}" ]; then
    if getent ahostsv4 "${DOMAIN}" >/dev/null 2>&1; then
      if domain_resolves_to_host "${DOMAIN}"; then
        ok "Domain ${DOMAIN} resolves to this host."
      else
        warn "Domain ${DOMAIN} resolves, but not to a detected host IP."
        warnings=$((warnings + 1))
      fi
    else
      fail "Domain ${DOMAIN} does not resolve on this server."
      failures=$((failures + 1))
    fi
  fi

  local caddy_logs
  caddy_logs="$(compose logs --no-color caddy 2>/dev/null || true)"
  if printf '%s' "${caddy_logs}" | grep -Eqi 'certificate (obtained|storage|loaded)|local ca|tls internal|issuer.*internal'; then
    ok "Caddy logs indicate internal certificate generation/storage."
  else
    warn "Caddy logs do not clearly show internal certificate issuance yet."
    warnings=$((warnings + 1))
  fi

  printf '\n'
  if [ "${failures}" -eq 0 ]; then
    ok "Doctor completed with ${warnings} warning(s) and no failures."
    return 0
  fi

  fail "Doctor found ${failures} failure(s) and ${warnings} warning(s)."
  return 1
}

show_menu() {
  while true; do
    print_banner
    printf '%b\n' "${BOLD}1.${NC} Show Status"
    printf '%b\n' "${BOLD}2.${NC} View Logs"
    printf '%b\n' "${BOLD}3.${NC} Restart Services"
    printf '%b\n' "${BOLD}4.${NC} Run Doctor"
    printf '%b\n' "${BOLD}5.${NC} Exit"
    printf '\n%b' "${CYAN}Select an option [1-5]: ${NC}"

    read -r choice
    printf '\n'

    case "${choice}" in
      1) show_status ;;
      2)
        printf '%b' "${CYAN}Service name (blank for all): ${NC}"
        read -r service
        view_logs "${service}"
        ;;
      3) restart_services ;;
      4) doctor ;;
      5) exit 0 ;;
      *) warn "Invalid option." ;;
    esac

    printf '\n%b' "${YELLOW}Press Enter to continue...${NC}"
    read -r _
  done
}

show_help() {
  print_banner
  cat <<'EOF'
Usage:
  zanjir                 Interactive menu
  zanjir status          Show service status
  zanjir logs [service]  View logs
  zanjir restart         Restart services
  zanjir doctor          Run diagnostics
EOF
}

main() {
  case "${1:-}" in
    status) show_status ;;
    logs) view_logs "${2:-}" ;;
    restart) restart_services ;;
    doctor) doctor ;;
    help|-h|--help) show_help ;;
    "") show_menu ;;
    *)
      fail "Unknown command: ${1}"
      show_help
      exit 1
      ;;
  esac
}

main "$@"
