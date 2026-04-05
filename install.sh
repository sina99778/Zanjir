#!/usr/bin/env bash

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
DOCKER_MIRRORS=(
  "https://docker.arvancloud.ir"
  "https://registry.docker.ir"
)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info() {
  printf '%b\n' "${YELLOW}[INFO]${NC} $1"
}

success() {
  printf '%b\n' "${GREEN}[OK]${NC} $1"
}

warn() {
  printf '%b\n' "${YELLOW}[WARN]${NC} $1"
}

error() {
  printf '%b\n' "${RED}[ERROR]${NC} $1" >&2
}

prompt() {
  echo -n -e "${BLUE}$1${NC}"
}

require_root() {
  if [ "${EUID}" -ne 0 ]; then
    error "Please run this installer as root or with sudo."
    exit 1
  fi
}

is_ip_address() {
  local value="$1"
  [[ "${value}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

read_env_value() {
  local key="$1"
  local default_value="${2:-}"

  if [ -f "${ENV_FILE}" ]; then
    local value
    value="$(grep -E "^${key}=" "${ENV_FILE}" | tail -n 1 | cut -d= -f2- || true)"
    if [ -n "${value}" ]; then
      printf '%s' "${value}"
      return 0
    fi
  fi

  printf '%s' "${default_value}"
}

generate_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
  else
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48
  fi
}

configure_apt_for_iran() {
  [ -f /etc/os-release ] || return 0
  . /etc/os-release

  local sources_file="/etc/apt/sources.list"
  if [ ! -f "${sources_file}" ]; then
    return 0
  fi

  cp -n "${sources_file}" "${sources_file}.zanjir.bak"

  case "${ID:-}" in
    ubuntu)
      sed -i \
        -e 's#https\?://[A-Za-z0-9./-]*archive\.ubuntu\.com/ubuntu/#https://mirror.arvancloud.ir/ubuntu/#g' \
        -e 's#https\?://[A-Za-z0-9./-]*security\.ubuntu\.com/ubuntu/#https://mirror.arvancloud.ir/ubuntu/#g' \
        -e 's#https\?://[A-Za-z0-9./-]*ports\.ubuntu\.com/ubuntu-ports/#https://mirror.arvancloud.ir/ubuntu/#g' \
        "${sources_file}"
      ;;
    debian)
      sed -i \
        -e 's#https\?://[A-Za-z0-9./-]*deb\.debian\.org/debian#https://mirror.arvancloud.ir/debian#g' \
        -e 's#https\?://[A-Za-z0-9./-]*security\.debian\.org/debian-security#https://mirror.arvancloud.ir/debian-security#g' \
        "${sources_file}"
      ;;
  esac

  cat > /etc/apt/apt.conf.d/99zanjir <<'EOF'
Acquire::Retries "5";
Acquire::http::Timeout "30";
Acquire::https::Timeout "30";
EOF
}

configure_docker_mirrors() {
  mkdir -p /etc/docker

  local daemon_file="/etc/docker/daemon.json"
  if [ -f "${daemon_file}" ] && [ ! -f "${daemon_file}.zanjir.bak" ]; then
    cp "${daemon_file}" "${daemon_file}.zanjir.bak"
  fi

  cat > "${daemon_file}" <<EOF
{
  "registry-mirrors": [
    "${DOCKER_MIRRORS[0]}",
    "${DOCKER_MIRRORS[1]}"
  ],
  "insecure-registries": [
    "docker.arvancloud.ir",
    "registry.docker.ir"
  ]
}
EOF

  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl restart docker >/dev/null 2>&1 || true
  fi
}

docker_ready() {
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

compose_ready() {
  if docker compose version >/dev/null 2>&1; then
    return 0
  fi

  docker-compose version >/dev/null 2>&1
}

run_compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif docker-compose version >/dev/null 2>&1; then
    docker-compose "$@"
  else
    error "Docker Compose is not available on this server."
    exit 1
  fi
}

install_docker_stack() {
  info "Checking Docker prerequisites and applying Iran-friendly mirrors..."
  configure_apt_for_iran
  configure_docker_mirrors

  export DEBIAN_FRONTEND=noninteractive
  apt-get update

  if ! command -v docker >/dev/null 2>&1; then
    info "Installing Docker..."
    apt-get install -y ca-certificates curl docker.io
  fi

  if ! docker compose version >/dev/null 2>&1; then
    info "Installing Docker Compose..."
    if ! apt-get install -y docker-compose-plugin >/dev/null 2>&1; then
      if ! apt-get install -y docker-compose-v2 >/dev/null 2>&1; then
        apt-get install -y docker-compose
      fi
    fi
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now docker >/dev/null 2>&1 || systemctl start docker >/dev/null 2>&1
  else
    service docker start >/dev/null 2>&1 || true
  fi

  configure_docker_mirrors

  if ! docker_ready; then
    error "Docker could not be started on this server. Please verify the Docker service and try again."
    exit 1
  fi

  if ! compose_ready; then
    error "Docker Compose could not be installed automatically."
    exit 1
  fi

  success "Docker and Docker Compose are ready."
}

ensure_docker_stack() {
  info "Checking Docker and Docker Compose..."

  if docker_ready && compose_ready; then
    success "Docker and Docker Compose are already available."
    return 0
  fi

  prompt "Docker or Docker Compose is missing. Configure Iranian mirrors and install them now? [Y/n]: "
  read -r install_choice
  install_choice="${install_choice:-Y}"

  if [[ "${install_choice}" =~ ^[Yy]$ ]]; then
    install_docker_stack
  else
    error "Installation cancelled because Docker is required."
    exit 1
  fi
}

load_offline_images() {
  local images_dir="${SCRIPT_DIR}/images"
  if [ ! -d "${images_dir}" ]; then
    warn "No offline image bundle was detected in ${images_dir}. Continuing without image preloading."
    return 0
  fi

  shopt -s nullglob
  local image_files=("${images_dir}"/*.tar)
  shopt -u nullglob

  if [ "${#image_files[@]}" -eq 0 ]; then
    warn "The images directory exists, but no .tar files were found. Continuing without image preloading."
    return 0
  fi

  info "Loading offline Docker images..."
  local tar_file
  for tar_file in "${image_files[@]}"; do
    info "Loading $(basename "${tar_file}")"
    docker load -i "${tar_file}"
  done
  success "Offline Docker images loaded successfully."
}

prompt_required_value() {
  local message="$1"
  local default_value="${2:-}"
  local value=""

  while :; do
    if [ -n "${default_value}" ]; then
      prompt "${message} [${default_value}]: "
    else
      prompt "${message}: "
    fi
    read -r value
    value="${value:-${default_value}}"

    if [ -n "${value}" ]; then
      printf '%s' "${value}"
      return 0
    fi

    warn "This field cannot be empty."
  done
}

prompt_configuration() {
  local saved_address saved_http_port saved_https_port saved_email

  saved_address="$(read_env_value "SERVER_ADDRESS" "$(read_env_value "DOMAIN" "")")"
  SERVER_ADDRESS="$(prompt_required_value "Enter the public domain name or IP address for this Zanjir server" "${saved_address}")"

  saved_http_port="$(read_env_value "HTTP_PORT" "80")"
  HTTP_PORT="$(prompt_required_value "Enter the HTTP port for Zanjir" "${saved_http_port}")"
  if ! [[ "${HTTP_PORT}" =~ ^[0-9]+$ ]] || [ "${HTTP_PORT}" -lt 1 ] || [ "${HTTP_PORT}" -gt 65535 ]; then
    error "HTTP port must be a number between 1 and 65535."
    exit 1
  fi

  saved_https_port="$(read_env_value "HTTPS_PORT" "443")"
  HTTPS_PORT="$(prompt_required_value "Enter the HTTPS port for Zanjir" "${saved_https_port}")"
  if ! [[ "${HTTPS_PORT}" =~ ^[0-9]+$ ]] || [ "${HTTPS_PORT}" -lt 1 ] || [ "${HTTPS_PORT}" -gt 65535 ]; then
    error "HTTPS port must be a number between 1 and 65535."
    exit 1
  fi

  if is_ip_address "${SERVER_ADDRESS}"; then
    saved_email="$(read_env_value "LETSENCRYPT_EMAIL" "")"
  else
    saved_email="$(read_env_value "LETSENCRYPT_EMAIL" "admin@${SERVER_ADDRESS}")"
  fi

  prompt "Enter the admin email address used for TLS notifications [${saved_email}]: "
  read -r ADMIN_EMAIL
  ADMIN_EMAIL="${ADMIN_EMAIL:-${saved_email}}"

  DOMAIN="${SERVER_ADDRESS}"
  PROTOCOL="https"
  if is_ip_address "${SERVER_ADDRESS}"; then
    IP_MODE="true"
    ADMIN_EMAIL="${ADMIN_EMAIL:-}"
  else
    IP_MODE="false"
    if [ -z "${ADMIN_EMAIL}" ]; then
      ADMIN_EMAIL="admin@${SERVER_ADDRESS}"
    fi
  fi

  printf '\n'
  info "Installation settings:"
  printf '  Address: %s\n' "${SERVER_ADDRESS}"
  printf '  HTTP Port: %s\n' "${HTTP_PORT}"
  printf '  HTTPS Port: %s\n' "${HTTPS_PORT}"
  printf '  Admin Email: %s\n' "${ADMIN_EMAIL:-none}"
  printf '  Offline Images: %s\n' "$( [ -d "${SCRIPT_DIR}/images" ] && printf 'yes' || printf 'no' )"
  printf '\n'

  prompt "Continue with these settings? [Y/n]: "
  read -r confirm_choice
  confirm_choice="${confirm_choice:-Y}"
  if ! [[ "${confirm_choice}" =~ ^[Yy]$ ]]; then
    error "Installation cancelled."
    exit 1
  fi
}

write_env_file() {
  local registration_secret
  local turn_secret
  local conduit_image
  local coturn_image
  local element_image
  local caddy_image

  registration_secret="$(read_env_value "REGISTRATION_SHARED_SECRET" "")"
  turn_secret="$(read_env_value "TURN_SECRET" "")"
  conduit_image="$(read_env_value "CONDUIT_IMAGE" "docker.io/matrixconduit/matrix-conduit:latest")"
  coturn_image="$(read_env_value "COTURN_IMAGE" "coturn/coturn:latest")"
  element_image="$(read_env_value "ELEMENT_IMAGE" "vectorim/element-web:v1.11.50")"
  caddy_image="$(read_env_value "CADDY_IMAGE" "caddy:2-alpine")"

  if [ -z "${registration_secret}" ]; then
    registration_secret="$(generate_secret)"
  fi
  if [ -z "${turn_secret}" ]; then
    turn_secret="$(generate_secret)"
  fi

  cat > "${ENV_FILE}" <<EOF
DOMAIN=${DOMAIN}
SERVER_ADDRESS=${SERVER_ADDRESS}
PROTOCOL=${PROTOCOL}
IP_MODE=${IP_MODE}
HTTPS_PORT=${HTTPS_PORT}
HTTP_PORT=${HTTP_PORT}
REGISTRATION_SHARED_SECRET=${registration_secret}
TURN_SECRET=${turn_secret}
LETSENCRYPT_EMAIL=${ADMIN_EMAIL}
CONDUIT_IMAGE=${conduit_image}
COTURN_IMAGE=${coturn_image}
ELEMENT_IMAGE=${element_image}
CADDY_IMAGE=${caddy_image}
EOF

  chmod 600 "${ENV_FILE}"
  success "Wrote ${ENV_FILE}."
}

configure_caddy() {
  if [ ! -f "${SCRIPT_DIR}/Caddyfile" ]; then
    error "Caddyfile was not found in ${SCRIPT_DIR}."
    exit 1
  fi
}

configure_element() {
  sed -i -E \
    -e "s#\"base_url\": \"[^\"]*\"#\"base_url\": \"https://${SERVER_ADDRESS}\"#g" \
    -e "s#\"server_name\": \"[^\"]*\"#\"server_name\": \"${SERVER_ADDRESS}\"#g" \
    -e "s#\"permalink_prefix\": \"[^\"]*\"#\"permalink_prefix\": \"https://${SERVER_ADDRESS}\"#g" \
    "${SCRIPT_DIR}/config/element-config.json"
  success "Updated Element configuration."
}

start_services() {
  info "Preparing Zanjir service configuration..."
  write_env_file
  configure_caddy
  configure_element

  info "Building local admin image..."
  run_compose build admin

  info "Starting services..."
  run_compose up -d
  success "Services started."
}

install_cli_tool() {
  cp "${SCRIPT_DIR}/zanjir-cli.sh" /usr/local/bin/zanjir
  chmod +x /usr/local/bin/zanjir
  success "Installed zanjir CLI to /usr/local/bin/zanjir."
}

show_success() {
  local base_url="${PROTOCOL}://${SERVER_ADDRESS}"
  if [ "${HTTPS_PORT}" != "443" ]; then
    base_url="${base_url}:${HTTPS_PORT}"
  fi

  local admin_url="${base_url}/admin/"

  printf '\n%b\n' "${GREEN}Zanjir installation completed successfully.${NC}"
  printf '%b\n' "${GREEN}----------------------------------------${NC}"
  printf 'Main URL: %s\n' "${base_url}"
  printf 'Admin Panel: %s\n' "${admin_url}"
  printf 'Registration Secret: %s\n' "$(read_env_value "REGISTRATION_SHARED_SECRET")"
  printf '\n'
  printf '%b\n' "${CYAN}You can now type 'zanjir' or 'zanjir doctor' from anywhere in your terminal.${NC}"
  if [ "${IP_MODE}" = "true" ]; then
    printf '%b\n' "${YELLOW}Because you are using an IP address, your browser may warn about the self-signed certificate on first access.${NC}"
  fi
}

main() {
  printf '\n%b\n' "${CYAN}========================================${NC}"
  printf '%b\n' "${CYAN}      Zanjir Air-Gapped Installer       ${NC}"
  printf '%b\n\n' "${CYAN}========================================${NC}"

  require_root
  ensure_docker_stack
  load_offline_images
  prompt_configuration
  start_services
  install_cli_tool
  show_success
}

main "$@"
