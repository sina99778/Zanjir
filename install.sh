#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
WHIPTAIL_TITLE="Zanjir Installer"
DOCKER_MIRRORS=(
  "https://docker.arvancloud.ir"
  "https://registry.docker.ir"
)

cleanup() {
  rm -f /tmp/zanjir-whiptail-* 2>/dev/null || true
}

show_error() {
  local message="$1"
  if command -v whiptail >/dev/null 2>&1; then
    whiptail --title "${WHIPTAIL_TITLE}" --msgbox "${message}" 12 72
  else
    printf 'ERROR: %s\n' "${message}" >&2
  fi
}

handle_error() {
  local exit_code="$1"
  local line_no="$2"
  trap - ERR
  cleanup
  show_error "Installation failed at line ${line_no} with exit code ${exit_code}."
  exit "${exit_code}"
}

trap 'handle_error $? $LINENO' ERR
trap cleanup EXIT

require_root() {
  if [ "${EUID}" -ne 0 ]; then
    show_error "Please run this installer as root or with sudo."
    exit 1
  fi
}

bootstrap_whiptail() {
  if command -v whiptail >/dev/null 2>&1; then
    return 0
  fi

  export DEBIAN_FRONTEND=noninteractive
  configure_apt_for_iran
  apt-get update >/dev/null
  apt-get install -y whiptail >/dev/null
}

msgbox() {
  whiptail --title "${WHIPTAIL_TITLE}" --msgbox "$1" 14 78
}

infobox() {
  whiptail --title "${WHIPTAIL_TITLE}" --infobox "$1" 10 78
}

yesno() {
  whiptail --title "${WHIPTAIL_TITLE}" --yesno "$1" 12 78
}

inputbox() {
  local prompt="$1"
  local default_value="${2:-}"
  local output_file
  output_file="$(mktemp /tmp/zanjir-whiptail-input.XXXXXX)"

  if ! whiptail --title "${WHIPTAIL_TITLE}" --inputbox "${prompt}" 12 78 "${default_value}" 2>"${output_file}"; then
    rm -f "${output_file}"
    return 1
  fi

  cat "${output_file}"
  rm -f "${output_file}"
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
    show_error "Docker Compose is not available on this server."
    exit 1
  fi
}

install_docker_stack() {
  infobox "Checking Docker prerequisites and applying Iran-friendly mirrors..."
  configure_apt_for_iran
  configure_docker_mirrors

  export DEBIAN_FRONTEND=noninteractive
  apt-get update >/dev/null

  if ! command -v docker >/dev/null 2>&1; then
    apt-get install -y ca-certificates curl docker.io >/dev/null
  fi

  if ! docker compose version >/dev/null 2>&1; then
    if ! apt-get install -y docker-compose-plugin >/dev/null 2>&1; then
      if ! apt-get install -y docker-compose-v2 >/dev/null 2>&1; then
        apt-get install -y docker-compose >/dev/null
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
    show_error "Docker could not be started on this server. Please verify the Docker service and try again."
    exit 1
  fi

  if ! compose_ready; then
    show_error "Docker Compose could not be installed automatically."
    exit 1
  fi
}

ensure_docker_stack() {
  infobox "Checking Docker and Docker Compose..."

  if docker_ready && compose_ready; then
    return 0
  fi

  if yesno "Docker or Docker Compose is missing. The installer can configure Iranian mirrors and try to install them now. Continue?"; then
    install_docker_stack
  else
    show_error "Installation cancelled because Docker is required."
    exit 1
  fi
}

load_offline_images() {
  local images_dir="${SCRIPT_DIR}/images"
  if [ ! -d "${images_dir}" ]; then
    msgbox "No offline image bundle was detected in ${images_dir}. The installer will continue with local or online Docker sources."
    return 0
  fi

  shopt -s nullglob
  local image_files=("${images_dir}"/*.tar)
  shopt -u nullglob

  if [ "${#image_files[@]}" -eq 0 ]; then
    msgbox "The images directory exists, but no .tar files were found. The installer will continue without offline image loading."
    return 0
  fi

  local total="${#image_files[@]}"
  {
    local index=0
    local tar_file
    for tar_file in "${image_files[@]}"; do
      local percent=$(( index * 100 / total ))
      echo "${percent}"
      echo "XXX"
      echo "Loading offline image $(basename "${tar_file}")..."
      echo "XXX"
      docker load -i "${tar_file}" >/dev/null
      index=$(( index + 1 ))
    done
    echo "100"
    echo "XXX"
    echo "Offline Docker images loaded successfully."
    echo "XXX"
  } | whiptail --title "${WHIPTAIL_TITLE}" --gauge "Loading offline Docker images..." 10 78 0
}

prompt_required_input() {
  local prompt="$1"
  local default_value="${2:-}"
  local result=""

  while :; do
    if ! result="$(inputbox "${prompt}" "${default_value}")"; then
      show_error "Installation cancelled."
      exit 1
    fi

    if [ -n "${result}" ]; then
      printf '%s' "${result}"
      return 0
    fi

    msgbox "This field cannot be empty."
  done
}

prompt_configuration() {
  local saved_address
  saved_address="$(read_env_value "SERVER_ADDRESS" "$(read_env_value "DOMAIN" "")")"
  SERVER_ADDRESS="$(prompt_required_input "Enter the public domain name or IP address for this Zanjir server." "${saved_address}")"

  local saved_port
  saved_port="$(read_env_value "HTTPS_PORT" "443")"
  HTTPS_PORT="$(prompt_required_input "Enter the HTTPS port for Zanjir." "${saved_port}")"
  if ! [[ "${HTTPS_PORT}" =~ ^[0-9]+$ ]] || [ "${HTTPS_PORT}" -lt 1 ] || [ "${HTTPS_PORT}" -gt 65535 ]; then
    show_error "HTTPS port must be a number between 1 and 65535."
    exit 1
  fi

  local email_default
  if is_ip_address "${SERVER_ADDRESS}"; then
    email_default="$(read_env_value "LETSENCRYPT_EMAIL" "")"
  else
    email_default="$(read_env_value "LETSENCRYPT_EMAIL" "admin@${SERVER_ADDRESS}")"
  fi

  if ! ADMIN_EMAIL="$(inputbox "Enter the admin email address used for TLS notifications. Leave blank if you are installing by IP only." "${email_default}")"; then
    show_error "Installation cancelled."
    exit 1
  fi

  DOMAIN="${SERVER_ADDRESS}"
  HTTP_PORT="80"
  PROTOCOL="https"
  if is_ip_address "${SERVER_ADDRESS}"; then
    IP_MODE="true"
    [ -n "${ADMIN_EMAIL}" ] || ADMIN_EMAIL=""
  else
    IP_MODE="false"
    if [ -z "${ADMIN_EMAIL}" ]; then
      ADMIN_EMAIL="admin@${SERVER_ADDRESS}"
    fi
  fi

  if ! yesno "Please confirm the configuration:\n\nAddress: ${SERVER_ADDRESS}\nHTTPS Port: ${HTTPS_PORT}\nAdmin Email: ${ADMIN_EMAIL:-none}\nOffline Images: $( [ -d "${SCRIPT_DIR}/images" ] && printf 'yes' || printf 'no' )"; then
    show_error "Installation cancelled."
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
}

configure_caddy() {
  if [ ! -f "${SCRIPT_DIR}/Caddyfile" ]; then
    show_error "Caddyfile was not found in ${SCRIPT_DIR}."
    exit 1
  fi
}

configure_element() {
  sed -i -E \
    -e "s#\"base_url\": \"[^\"]*\"#\"base_url\": \"https://${SERVER_ADDRESS}\"#g" \
    -e "s#\"server_name\": \"[^\"]*\"#\"server_name\": \"${SERVER_ADDRESS}\"#g" \
    -e "s#\"permalink_prefix\": \"[^\"]*\"#\"permalink_prefix\": \"https://${SERVER_ADDRESS}\"#g" \
    "${SCRIPT_DIR}/config/element-config.json"
}

start_services() {
  infobox "Preparing Zanjir service configuration..."
  write_env_file
  configure_caddy
  configure_element

  infobox "Building local images and starting services..."
  run_compose build admin >/dev/null
  run_compose up -d >/dev/null
}

show_success() {
  local base_url="${PROTOCOL}://${SERVER_ADDRESS}"
  if [ "${HTTPS_PORT}" != "443" ]; then
    base_url="${base_url}:${HTTPS_PORT}"
  fi

  local admin_url="${base_url}/admin/"
  msgbox "Zanjir installation completed successfully.\n\nMain URL: ${base_url}\nAdmin Panel: ${admin_url}\nRegistration Secret: $(read_env_value "REGISTRATION_SHARED_SECRET")\n\nIf you are using an IP address, your browser will likely warn about a self-signed certificate the first time you connect."
}

main() {
  require_root
  bootstrap_whiptail

  msgbox "Welcome to the Zanjir air-gapped installer.\n\nThis wizard will check Docker, optionally configure Iranian mirrors, load offline Docker images if available, collect your deployment settings, and start the stack."
  ensure_docker_stack
  load_offline_images
  prompt_configuration
  start_services
  show_success
}

main "$@"
