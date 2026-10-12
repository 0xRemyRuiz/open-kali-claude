#!/usr/bin/env bash
# Container entrypoint for open-kali-claude.
#
# Responsibilities:
#   1. (Re)generate opencode.json from environment variables on every start, so
#      the model/provider always comes from env (never baked into the image or
#      the persisted volume).
#   2. Launch `opencode serve` bound to all interfaces so the API is reachable
#      from the host via the published port.
#
# Auth is NOT written here: `opencode auth login` stores it in the data dir
# (/root/.local/share/opencode/auth.json), which is backed by a Docker volume.
set -euo pipefail

log() { printf '[entrypoint] %s\n' "$*" >&2; }

CONFIG_DIR="${XDG_CONFIG_HOME:-/root/.config}/opencode"
CONFIG_FILE="${CONFIG_DIR}/opencode.json"
mkdir -p "${CONFIG_DIR}"

# Build the opencode model string in "provider/model" form. If OPENCODE_MODEL
# already contains a "/", it is treated as a full "provider/model" and used
# as-is; otherwise it is combined with OPENCODE_PROVIDER.
provider="${OPENCODE_PROVIDER:-anthropic}"
model="${OPENCODE_MODEL:-claude-sonnet-4-5}"
if [[ "${model}" == */* ]]; then
  full_model="${model}"
else
  full_model="${provider}/${model}"
fi

# Optional lightweight model (title generation, etc.). Same provider/model rule.
small_model=""
if [[ -n "${OPENCODE_SMALL_MODEL:-}" ]]; then
  if [[ "${OPENCODE_SMALL_MODEL}" == */* ]]; then
    small_model="${OPENCODE_SMALL_MODEL}"
  else
    small_model="${provider}/${OPENCODE_SMALL_MODEL}"
  fi
fi

# Write opencode.json (jq keeps the quoting correct).
jq -n --arg model "${full_model}" --arg small "${small_model}" '
  {"$schema": "https://opencode.ai/config.json", "model": $model}
  + (if $small != "" then {"small_model": $small} else {} end)
' > "${CONFIG_FILE}"

log "wrote ${CONFIG_FILE}:"
sed 's/^/[entrypoint]   /' "${CONFIG_FILE}" >&2
log "data dir: ${OPENCODE_DATA:-/root/.local/share/opencode}"
if [[ -f "${OPENCODE_DATA:-/root/.local/share/opencode}/auth.json" ]]; then
  log "auth.json found (provider credentials present)."
else
  log "no auth.json yet -> run 'opencode auth login' via the 'connect' shell."
fi

case "${1:-serve}" in
  serve)
    host="${OPENCODE_HOSTNAME:-0.0.0.0}"
    port="${OPENCODE_PORT:-4096}"
    log "starting: opencode serve --hostname ${host} --port ${port}"
    exec opencode serve --hostname "${host}" --port "${port}"
    ;;
  *)
    # Allow running an arbitrary command (e.g. a shell) through the entrypoint.
    exec "$@"
    ;;
esac
