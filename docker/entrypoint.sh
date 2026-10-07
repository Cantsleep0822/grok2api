#!/bin/sh
set -eu

umask 077

quality_guard_dir=/var/lib/grok2api-quality-guard
mkdir -p "${quality_guard_dir}"
chown grok2api:grok2api "${quality_guard_dir}"
chmod 0700 "${quality_guard_dir}"

resolve_config_source() {
  source_path="${GROK2API_CONFIG_SOURCE:-/run/grok2api/config.yaml}"
  if [ -f "${source_path}" ]; then
    printf '%s' "${source_path}"
    return 0
  fi
  if [ -f /etc/secrets/config.yaml ]; then
    printf '%s' /etc/secrets/config.yaml
    return 0
  fi
  echo "missing config: ${source_path}" >&2
  echo "mount config.yaml to /run/grok2api/config.yaml or /etc/secrets/config.yaml" >&2
  return 1
}

read_tunnel_token() {
  if [ -n "${TUNNEL_TOKEN:-}" ]; then
    printf '%s' "${TUNNEL_TOKEN}"
    return 0
  fi
  if [ -n "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]; then
    printf '%s' "${CLOUDFLARE_TUNNEL_TOKEN}"
    return 0
  fi
  token_file="${TUNNEL_TOKEN_FILE:-${CLOUDFLARE_TUNNEL_TOKEN_FILE:-}}"
  if [ -z "${token_file}" ] && [ -f /etc/secrets/TUNNEL_TOKEN ]; then
    token_file=/etc/secrets/TUNNEL_TOKEN
  fi
  if [ -n "${token_file}" ] && [ -f "${token_file}" ]; then
    tr -d '\r\n' < "${token_file}"
    return 0
  fi
  return 1
}

validate_port() {
  port="$1"
  case "${port}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "${port}" -ge 1 ] && [ "${port}" -le 65535 ]
}

config_source="$(resolve_config_source)"
cp "${config_source}" /app/config.yaml
chown grok2api:grok2api /app/config.yaml
chmod 0600 /app/config.yaml

listen_port="${PORT:-8000}"
if ! validate_port "${listen_port}"; then
  echo "invalid PORT: ${listen_port}" >&2
  exit 1
fi
set -- "$@" --listen "0.0.0.0:${listen_port}"

if token="$(read_tunnel_token)" && [ -n "${token}" ]; then
  if [ ! -x /usr/local/bin/cloudflared ]; then
    echo "cloudflared is not installed in this image" >&2
    exit 1
  fi
  protocol="${TUNNEL_TRANSPORT_PROTOCOL:-http2}"
  echo "cloudflared: enabled protocol=${protocol} origin=http://127.0.0.1:${listen_port}" >&2
  echo "cloudflared: set the published application Service URL to http://127.0.0.1:${listen_port}" >&2
  (
    export TUNNEL_TOKEN="${token}"
    unset CLOUDFLARE_TUNNEL_TOKEN
    while :; do
      su-exec grok2api:grok2api /usr/local/bin/cloudflared \
        tunnel --no-autoupdate --protocol "${protocol}" run \
        || echo "cloudflared: exited, retrying in 3s" >&2
      sleep 3
    done
  ) &
fi

exec su-exec grok2api:grok2api "$@"
