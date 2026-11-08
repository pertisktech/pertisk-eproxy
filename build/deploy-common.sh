# Shared deploy host parsing for build/deploy-*.sh
# DEPLOY_HOST=user@host overrides REMOTE_USER + REMOTE_HOST when set.

resolve_deploy_host() {
  if [ -n "${DEPLOY_HOST:-}" ]; then
    if [[ "$DEPLOY_HOST" != *@* ]]; then
      echo "DEPLOY_HOST must be user@host (got: $DEPLOY_HOST)" >&2
      return 1
    fi
    REMOTE_USER="${DEPLOY_HOST%%@*}"
    REMOTE_HOST="${DEPLOY_HOST#*@}"
    export REMOTE_USER REMOTE_HOST
  fi
}

deploy_ssh_target() {
  if [ -n "${DEPLOY_HOST:-}" ]; then
    echo "$DEPLOY_HOST"
  elif [ -n "${REMOTE_HOST:-}" ]; then
    echo "${REMOTE_USER:-root}@${REMOTE_HOST}"
  else
    return 1
  fi
}

# Detect remote package manager: rpm | deb
detect_remote_pkg_kind() {
  local target="${1:?ssh target required}"
  local ssh_opts="${2:-}"
  local kind
  # shellcheck disable=SC2086
  kind=$(ssh $ssh_opts "$target" 'if command -v rpm >/dev/null 2>&1 && { command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; }; then echo rpm; elif command -v dpkg >/dev/null 2>&1; then echo deb; else echo unknown; fi' 2>/dev/null) || {
    echo "Failed to detect package manager via SSH ($target)" >&2
    return 1
  }
  case "$kind" in
    rpm|deb) echo "$kind" ;;
    *)
      echo "Unsupported remote package manager on $target (set DEPLOY_PKG=rpm or deb)" >&2
      return 1
      ;;
  esac
}
