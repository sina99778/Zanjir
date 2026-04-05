#!/usr/bin/env bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
BUNDLE_DIR="${SCRIPT_DIR}/offline-bundle"
IMAGES_DIR="${BUNDLE_DIR}/images"
ARCHIVE_NAME="${SCRIPT_DIR}/zanjir-offline.tar.gz"

info() {
  printf '%b\n' "${YELLOW}[INFO]${NC} $1"
}

success() {
  printf '%b\n' "${GREEN}[OK]${NC} $1"
}

error() {
  printf '%b\n' "${RED}[ERROR]${NC} $1" >&2
}

cleanup() {
  if [ -d "${BUNDLE_DIR}" ]; then
    rm -rf "${BUNDLE_DIR}"
  fi
}

trap cleanup EXIT

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    error "Required command not found: $1"
    exit 1
  fi
}

sanitize_filename() {
  local image_ref="$1"
  local sanitized
  sanitized="$(printf '%s' "${image_ref}" | sed 's#/#_#g; s#:#_#g; s#@#_#g; s#[^A-Za-z0-9._-]#_#g')"
  printf '%s' "${sanitized}"
}

collect_compose_images() {
  awk '
    /^[[:space:]]*image:[[:space:]]*/ {
      value=$0
      sub(/^[[:space:]]*image:[[:space:]]*/, "", value)
      print value
    }
  ' "${COMPOSE_FILE}" |
    sed 's/[[:space:]]*#.*$//' |
    sed 's/^["'\'']//; s/["'\'']$//' |
    while IFS= read -r image_ref; do
      [ -z "${image_ref}" ] && continue

      if [[ "${image_ref}" =~ ^\$\{([A-Za-z_][A-Za-z0-9_]*):-([^}]+)\}$ ]]; then
        var_name="${BASH_REMATCH[1]}"
        default_value="${BASH_REMATCH[2]}"
        if [ -n "${!var_name:-}" ]; then
          printf '%s\n' "${!var_name}"
        else
          printf '%s\n' "${default_value}"
        fi
      elif [[ "${image_ref}" =~ ^\$\{([A-Za-z_][A-Za-z0-9_]*)-([^}]+)\}$ ]]; then
        var_name="${BASH_REMATCH[1]}"
        default_value="${BASH_REMATCH[2]}"
        if [ -n "${!var_name:-}" ]; then
          printf '%s\n' "${!var_name}"
        else
          printf '%s\n' "${default_value}"
        fi
      elif [[ "${image_ref}" =~ ^\$\{([A-Za-z_][A-Za-z0-9_]*)\}$ ]]; then
        var_name="${BASH_REMATCH[1]}"
        [ -n "${!var_name:-}" ] && printf '%s\n' "${!var_name}"
      else
        printf '%s\n' "${image_ref}"
      fi
    done |
    sed '/^[[:space:]]*$/d' |
    sort -u
}

collect_build_contexts() {
  awk '
    /^[[:space:]]*services:/ { in_services=1; next }
    in_services && /^[^[:space:]]/ && $0 !~ /^[[:space:]]*services:/ { in_services=0 }
    !in_services { next }
    /^[[:space:]]{2}[A-Za-z0-9_.-]+:[[:space:]]*$/ { service_indent=match($0, /[^ ]/) - 1; next }
    /^[[:space:]]+build:[[:space:]]*[^[:space:]]+[[:space:]]*$/ {
      value=$0
      sub(/^[[:space:]]*build:[[:space:]]*/, "", value)
      print value
      next
    }
    /^[[:space:]]+context:[[:space:]]*[^[:space:]]+[[:space:]]*$/ {
      value=$0
      sub(/^[[:space:]]*context:[[:space:]]*/, "", value)
      print value
    }
  ' "${COMPOSE_FILE}" | sed 's/[[:space:]]*#.*$//' | sed 's/^["'\'']//; s/["'\'']$//' | sort -u
}

collect_dockerfile_images() {
  local context
  while IFS= read -r context; do
    [ -z "${context}" ] && continue
    local context_path="${SCRIPT_DIR}/${context}"
    local dockerfile_path="${context_path}/Dockerfile"

    if [ ! -f "${dockerfile_path}" ]; then
      info "Skipping build context without Dockerfile: ${context}"
      continue
    fi

    awk '
      toupper($1) == "FROM" {
        image=$2
        if (image ~ /^--platform=/) {
          image=$3
        }
        if (image != "" && toupper(image) != "AS" && image !~ /^scratch$/ && image !~ /^\$/) {
          print image
        }
      }
    ' "${dockerfile_path}"
  done < <(collect_build_contexts)
}

prepare_bundle_dir() {
  info "Preparing bundle directories..."
  rm -rf "${BUNDLE_DIR}"
  mkdir -p "${IMAGES_DIR}"
  success "Created ${BUNDLE_DIR}"
}

pull_and_save_images() {
  mapfile -t images < <(
    {
      collect_compose_images
      collect_dockerfile_images
    } | sed '/^[[:space:]]*$/d' | sort -u
  )

  if [ "${#images[@]}" -eq 0 ]; then
    error "No Docker images were discovered from docker-compose.yml"
    exit 1
  fi

  info "Discovered ${#images[@]} Docker image(s)."

  local image
  for image in "${images[@]}"; do
    info "Pulling ${image}"
    docker pull "${image}"

    local archive_path="${IMAGES_DIR}/$(sanitize_filename "${image}").tar"
    info "Saving ${image} to ${archive_path}"
    docker save -o "${archive_path}" "${image}"
    success "Packed image ${image}"
  done
}

copy_path_if_exists() {
  local source_path="$1"
  local destination_path="${BUNDLE_DIR}/$1"

  if [ -e "${SCRIPT_DIR}/${source_path}" ]; then
    mkdir -p "$(dirname "${destination_path}")"
    cp -R "${SCRIPT_DIR}/${source_path}" "${destination_path}"
    success "Copied ${source_path}"
  else
    info "Skipping missing path: ${source_path}"
  fi
}

copy_project_files() {
  info "Copying project files into offline bundle..."

  local static_paths=(
    "docker-compose.yml"
    ".env.example"
    "install.sh"
    "Caddyfile"
    "Caddyfile.ip-mode"
    "zanjir-cli.sh"
    "config"
    "dendrite"
    "scripts"
  )

  local path
  for path in "${static_paths[@]}"; do
    copy_path_if_exists "${path}"
  done

  while IFS= read -r context; do
    [ -z "${context}" ] && continue
    copy_path_if_exists "${context}"
  done < <(collect_build_contexts)
}

write_image_manifest() {
  local manifest_path="${BUNDLE_DIR}/images/manifest.txt"
  {
    printf 'Offline bundle image manifest\n'
    printf 'Generated at: %s\n\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    collect_compose_images
    collect_dockerfile_images | sed '/^[[:space:]]*$/d' | sort -u
  } | awk '!seen[$0]++' > "${manifest_path}"
  success "Wrote image manifest"
}

create_archive() {
  info "Creating compressed archive ${ARCHIVE_NAME}"
  rm -f "${ARCHIVE_NAME}"
  tar -C "${SCRIPT_DIR}" -czf "${ARCHIVE_NAME}" "$(basename "${BUNDLE_DIR}")"
  success "Created ${ARCHIVE_NAME}"
}

main() {
  require_command docker
  require_command tar
  require_command awk
  require_command sed
  require_command cp
  if ! docker compose version >/dev/null 2>&1; then
    error "docker compose is required but not available"
    exit 1
  fi

  if [ ! -f "${COMPOSE_FILE}" ]; then
    error "docker-compose.yml was not found in ${SCRIPT_DIR}"
    exit 1
  fi

  info "Starting Zanjir offline bundle creation..."
  prepare_bundle_dir
  pull_and_save_images
  copy_project_files
  write_image_manifest
  create_archive
  success "Offline bundle is ready: ${ARCHIVE_NAME}"
}

main "$@"
