#!/usr/bin/env bash
set -Eeuo pipefail

script_name="$(basename "$0")"
default_repo_url="${AMFICO_REPO_URL:-git@github.com:pennyMorant/amfico.git}"
default_git_ref="${AMFICO_GIT_REF:-main}"
default_app_dir="${AMFICO_APP_DIR:-/opt/amfico}"

if (($# == 0)); then
  command="install"
elif [[ "$1" == "-h" || "$1" == "--help" || "$1" == "help" ]]; then
  command="help"
  shift
elif [[ "$1" == "--interactive" ]]; then
  command="menu"
  shift
elif [[ "$1" == -* ]]; then
  command="install"
else
  command="$1"
  shift
fi

usage() {
  cat <<EOUSAGE
Usage:
  ${script_name} [command] [options]

This public installer is safe to host outside the private repository. It only
prepares SSH access, clones the private source checkout, then runs:
  <app-dir>/source/scripts/vps/amfico.sh

Common options:
  --repo-url URL          SSH Git repository URL. Default: ${default_repo_url}
  --git-ref REF           Git branch/tag/ref. Default: ${default_git_ref}
  --app-dir PATH          Deploy root. Default: ${default_app_dir}
  --ssh-key PATH          Deploy key path. Default: ~/.ssh/amfico_deploy
  --ssh-host-alias NAME   SSH config host alias. Default: amfico-<repo-host>
  --no-keygen             Do not generate a missing deploy key.
  --print-public-key      Print the deploy public key and exit.
  -h, --help              Show this help.

Examples:
  curl -fsSL https://example.com/amfico-install.sh -o amfico-install.sh
  chmod +x amfico-install.sh
  ./amfico-install.sh install --repo-url git@github.com:YOUR_ORG/amfico.git

Private repository setup:
  1. Run this installer once.
  2. Add the printed public key to the GitHub repository Deploy keys.
  3. Run the same command again.
EOUSAGE
}

die() {
  echo "Error: $*" >&2
  exit 1
}

log() {
  printf '\n==> %s\n' "$*"
}

repo_url="$default_repo_url"
git_ref="$default_git_ref"
app_dir="$default_app_dir"
ssh_key_path=""
ssh_host_alias=""
allow_keygen="true"
print_public_key="false"
manager_args=()

while (($#)); do
  case "$1" in
    --repo-url)
      repo_url="${2:-}"
      shift 2
      ;;
    --git-ref|--branch|--ref)
      git_ref="${2:-}"
      shift 2
      ;;
    --app-dir)
      app_dir="${2:-}"
      shift 2
      ;;
    --ssh-key)
      ssh_key_path="${2:-}"
      shift 2
      ;;
    --ssh-host-alias)
      ssh_host_alias="${2:-}"
      shift 2
      ;;
    --no-keygen)
      allow_keygen="false"
      shift
      ;;
    --print-public-key)
      print_public_key="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      manager_args+=("$1")
      shift
      ;;
  esac
done

if [[ "$command" == "help" ]]; then
  usage
  exit 0
fi

[[ -n "$repo_url" ]] || die "--repo-url cannot be empty."
[[ -n "$git_ref" ]] || die "--git-ref cannot be empty."
[[ -n "$app_dir" ]] || die "--app-dir cannot be empty."

if [[ "$(id -u)" -eq 0 ]]; then
  SUDO=()
else
  command -v sudo >/dev/null 2>&1 || die "sudo is required when running as a non-root user."
  sudo -n true >/dev/null 2>&1 || die "Passwordless sudo is required. Log in as root or grant this user NOPASSWD sudo."
  SUDO=(sudo)
fi

deploy_user="$(id -un)"
deploy_home="$(getent passwd "$deploy_user" | cut -d: -f6)"
[[ -n "$deploy_home" ]] || die "Cannot resolve home directory for ${deploy_user}."

if [[ -z "$ssh_key_path" ]]; then
  ssh_key_path="${deploy_home}/.ssh/amfico_deploy"
fi

extract_repo_parts() {
  local value="$1"

  if [[ "$value" =~ ^([^@]+)@([^:]+):(.+)$ ]]; then
    repo_user="${BASH_REMATCH[1]}"
    repo_host="${BASH_REMATCH[2]}"
    repo_path="${BASH_REMATCH[3]}"
    repo_style="scp"
    return 0
  fi

  if [[ "$value" =~ ^ssh://([^@]+)@([^/]+)/(.+)$ ]]; then
    repo_user="${BASH_REMATCH[1]}"
    repo_host="${BASH_REMATCH[2]}"
    repo_path="${BASH_REMATCH[3]}"
    repo_style="ssh"
    return 0
  fi

  die "--repo-url must be an SSH URL, for example git@github.com:ORG/REPO.git."
}

extract_repo_parts "$repo_url"

if [[ -z "$ssh_host_alias" ]]; then
  ssh_host_alias="amfico-${repo_host//./-}"
fi

[[ "$ssh_host_alias" =~ ^[A-Za-z0-9._-]+$ ]] || die "--ssh-host-alias contains unsafe characters."

if [[ "$repo_style" == "scp" ]]; then
  effective_repo_url="${repo_user}@${ssh_host_alias}:${repo_path}"
else
  effective_repo_url="ssh://${repo_user}@${ssh_host_alias}/${repo_path}"
fi

source_dir="${app_dir}/source"
amfico_script="${source_dir}/scripts/vps/amfico.sh"

ensure_base_tools() {
  if command -v git >/dev/null 2>&1 &&
    command -v ssh >/dev/null 2>&1 &&
    command -v ssh-keygen >/dev/null 2>&1 &&
    command -v ssh-keyscan >/dev/null 2>&1; then
    return 0
  fi

  command -v apt-get >/dev/null 2>&1 || die "Missing git/ssh tools and apt-get is unavailable."
  log "Installing git and SSH client"
  "${SUDO[@]}" apt-get update
  "${SUDO[@]}" apt-get install -y ca-certificates git openssh-client
}

ensure_ssh_key() {
  local ssh_dir
  ssh_dir="$(dirname "$ssh_key_path")"
  install -d -m 0700 "$ssh_dir"

  if [[ -f "$ssh_key_path" && -f "${ssh_key_path}.pub" ]]; then
    chmod 0600 "$ssh_key_path"
    chmod 0644 "${ssh_key_path}.pub"
    return 0
  fi

  [[ "$allow_keygen" == "true" ]] || die "Missing SSH key at ${ssh_key_path}."

  log "Generating deploy SSH key"
  ssh-keygen -t ed25519 -f "$ssh_key_path" -C "amfico-deploy-${deploy_user}@$(hostname)" -N "" >/dev/null
  chmod 0600 "$ssh_key_path"
  chmod 0644 "${ssh_key_path}.pub"
  generated_key="true"
}

write_ssh_config() {
  local ssh_dir ssh_config known_hosts tmp_config marker_start marker_end
  ssh_dir="$(dirname "$ssh_key_path")"
  ssh_config="${ssh_dir}/config"
  known_hosts="${ssh_dir}/known_hosts"
  marker_start="# >>> amfico ${ssh_host_alias}"
  marker_end="# <<< amfico ${ssh_host_alias}"

  install -d -m 0700 "$ssh_dir"
  touch "$known_hosts"
  chmod 0644 "$known_hosts"

  if ! ssh-keygen -F "$repo_host" -f "$known_hosts" >/dev/null 2>&1; then
    log "Adding ${repo_host} to SSH known_hosts"
    ssh-keyscan -H "$repo_host" >> "$known_hosts" 2>/dev/null ||
      die "Could not fetch SSH host key for ${repo_host}."
  fi

  tmp_config="$(mktemp)"
  if [[ -f "$ssh_config" ]]; then
    awk -v start="$marker_start" -v end="$marker_end" '
      $0 == start { skip = 1; next }
      $0 == end { skip = 0; next }
      !skip { print }
    ' "$ssh_config" > "$tmp_config"
  fi

  cat >> "$tmp_config" <<EOCONFIG
${marker_start}
Host ${ssh_host_alias}
  HostName ${repo_host}
  User ${repo_user}
  IdentityFile ${ssh_key_path}
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
${marker_end}
EOCONFIG

  mv "$tmp_config" "$ssh_config"
  chmod 0600 "$ssh_config"
}

print_deploy_key() {
  echo
  echo "Deploy public key for ${repo_url}:"
  cat "${ssh_key_path}.pub"
  echo
}

verify_repo_access() {
  log "Verifying private repository access"
  if git ls-remote "$effective_repo_url" >/dev/null 2>&1; then
    return 0
  fi

  print_deploy_key
  echo "Add this public key to the private repository Deploy keys, then run this installer again." >&2
  echo "Repository access check failed for: ${repo_url}" >&2
  exit 1
}

prepare_source_checkout() {
  log "Preparing private source checkout"
  "${SUDO[@]}" install -d -m 0755 "$app_dir"
  "${SUDO[@]}" chown "${deploy_user}:${deploy_user}" "$app_dir"

  if [[ ! -d "${source_dir}/.git" ]]; then
    rm -rf "$source_dir"
    git clone "$effective_repo_url" "$source_dir"
  else
    git -C "$source_dir" remote set-url origin "$effective_repo_url"
    git -C "$source_dir" fetch --prune origin
  fi

  git -C "$source_dir" checkout "$git_ref"
  git -C "$source_dir" pull --ff-only origin "$git_ref" 2>/dev/null || true
  [[ -f "$amfico_script" ]] || die "Missing ${amfico_script} in checked out source."
  chmod +x "$amfico_script"
}

generated_key="false"
ensure_base_tools
ensure_ssh_key
write_ssh_config

if [[ "$print_public_key" == "true" ]]; then
  print_deploy_key
  exit 0
fi

if [[ "$generated_key" == "true" ]]; then
  print_deploy_key
fi

verify_repo_access
prepare_source_checkout

exec "$amfico_script" "$command" "${manager_args[@]}" \
  --repo-url "$effective_repo_url" \
  --git-ref "$git_ref" \
  --app-dir "$app_dir"
