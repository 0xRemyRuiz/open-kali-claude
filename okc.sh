#!/usr/bin/env bash
#
# okc.sh — manage the open-kali-claude container: a headless Kali box running
#          the opencode HTTP API (an AI agent server) backed by Claude.
#
# Run `./okc.sh help` for full usage. Every command is idempotent, and config is
# read from the environment, a local .env file, or sane defaults (.env.example).
set -euo pipefail

# --------------------------------------------------------------------------- #
# Location / config
# --------------------------------------------------------------------------- #
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ENV_FILE="${OKC_ENV_FILE:-${SCRIPT_DIR}/.env}"

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_dim=$'\033[2m'; c_rst=$'\033[0m'
[[ -t 1 ]] || { c_red=; c_grn=; c_ylw=; c_dim=; c_rst=; }

log()  { printf '%s>>%s %s\n'   "${c_grn}" "${c_rst}" "$*"; }
warn() { printf '%s>>%s %s\n'   "${c_ylw}" "${c_rst}" "$*" >&2; }
err()  { printf '%serror:%s %s\n' "${c_red}" "${c_rst}" "$*" >&2; }
die()  { err "$*"; exit 1; }

# Read a KEY=VALUE from .env without executing it (last match wins, quotes
# stripped). Used only for the infra knobs the script itself needs.
env_file_get() {
  local key="$1" line val
  [[ -f "${ENV_FILE}" ]] || return 0
  line="$(grep -E "^[[:space:]]*${key}=" "${ENV_FILE}" 2>/dev/null | tail -n1)" || true
  [[ -n "${line}" ]] || return 0
  val="${line#*=}"
  val="${val%\"}"; val="${val#\"}"
  val="${val%\'}"; val="${val#\'}"
  printf '%s' "${val}"
}

# Resolve a value: shell environment > .env file > default.
resolve() {
  local name="$1" def="${2-}" v
  v="${!name:-}"
  [[ -n "${v}" ]] || v="$(env_file_get "${name}")"
  [[ -n "${v}" ]] || v="${def}"
  printf '%s' "${v}"
}

# Infra knobs (script side).
IMAGE="$(resolve OKC_IMAGE     'open-kali-claude:latest')"
CONTAINER="$(resolve OKC_CONTAINER 'open-kali-claude')"
VOLUME="$(resolve OKC_VOLUME    'open-kali-claude-auth')"
BIND_HOST="$(resolve OKC_BIND_HOST '127.0.0.1')"
SHELL_BIN="$(resolve OKC_SHELL  '/bin/bash')"
WORKDIR_HOST="$(resolve OKC_WORKDIR '')"

# App knobs (resolved here so the published port always matches the served port,
# and so defaults are consistent regardless of where they come from).
PORT="$(resolve OPENCODE_PORT '4096')"
PROVIDER="$(resolve OPENCODE_PROVIDER 'anthropic')"
MODEL="$(resolve OPENCODE_MODEL 'claude-sonnet-4-5')"
SMALL_MODEL="$(resolve OPENCODE_SMALL_MODEL '')"

# --------------------------------------------------------------------------- #
# Docker helpers
# --------------------------------------------------------------------------- #
need_docker() {
  command -v docker >/dev/null 2>&1 || die "docker is not installed or not on PATH."
  docker info >/dev/null 2>&1 || die "cannot talk to the Docker daemon (is it running? do you have permission?)."
}

image_exists()     { docker image inspect "${IMAGE}" >/dev/null 2>&1; }
container_exists() { docker container inspect "${CONTAINER}" >/dev/null 2>&1; }
volume_exists()    { docker volume inspect "${VOLUME}" >/dev/null 2>&1; }
container_running() {
  [[ "$(docker container inspect -f '{{.State.Running}}' "${CONTAINER}" 2>/dev/null || echo false)" == "true" ]]
}

# Build-arg list: only forward what the user explicitly set (otherwise the
# Dockerfile defaults, incl. KALI_METAPACKAGE=kali-linux-headless, apply).
build_arg_list() {
  local a v
  for a in KALI_METAPACKAGE NODE_MAJOR OPENCODE_VERSION CLAUDE_CODE_VERSION; do
    v="$(resolve "${a}" '')"
    [[ -n "${v}" ]] && printf -- '--build-arg\n%s=%s\n' "${a}" "${v}"
  done
}

do_build() {
  local extra=("$@") mapfile_args=()
  while IFS= read -r line; do [[ -n "${line}" ]] && mapfile_args+=("${line}"); done < <(build_arg_list)
  log "Building image ${IMAGE} ${c_dim}(context: ${SCRIPT_DIR})${c_rst}"
  [[ ${#mapfile_args[@]} -gt 0 ]] && log "build args: ${mapfile_args[*]}"
  docker build "${extra[@]}" "${mapfile_args[@]}" -t "${IMAGE}" "${SCRIPT_DIR}"
}

ensure_image()  { image_exists || do_build; }
ensure_volume() { volume_exists || { log "Creating volume ${VOLUME}"; docker volume create "${VOLUME}" >/dev/null; }; }

# Environment passed into the container at `docker run`.
run_env_args() {
  # 1) whole .env file (app vars live here), if present
  [[ -f "${ENV_FILE}" ]] && printf -- '--env-file\n%s\n' "${ENV_FILE}"
  # 2) resolved app knobs win over the file so port/model stay consistent
  printf -- '-e\nOPENCODE_PORT=%s\n'     "${PORT}"
  printf -- '-e\nOPENCODE_PROVIDER=%s\n' "${PROVIDER}"
  printf -- '-e\nOPENCODE_MODEL=%s\n'    "${MODEL}"
  [[ -n "${SMALL_MODEL}" ]] && printf -- '-e\nOPENCODE_SMALL_MODEL=%s\n' "${SMALL_MODEL}"
  # 3) forward selected secrets/options from the current shell, if set
  local v
  for v in ANTHROPIC_API_KEY OPENCODE_SERVER_PASSWORD OPENCODE_SERVER_USERNAME; do
    [[ -n "${!v:-}" ]] && printf -- '-e\n%s\n' "${v}"   # value taken from host env
  done
}

# --------------------------------------------------------------------------- #
# Commands
# --------------------------------------------------------------------------- #
cmd_run() {
  need_docker
  ensure_image
  ensure_volume

  if container_running; then
    log "Already running."
  elif container_exists; then
    log "Starting existing container ${CONTAINER}..."
    docker start "${CONTAINER}" >/dev/null
  else
    log "Creating and starting ${CONTAINER}..."
    local env_args=() workdir_args=()
    while IFS= read -r line; do [[ -n "${line}" ]] && env_args+=("${line}"); done < <(run_env_args)

    if [[ -n "${WORKDIR_HOST}" ]]; then
      [[ -d "${WORKDIR_HOST}" ]] || die "OKC_WORKDIR '${WORKDIR_HOST}' is not a directory."
      workdir_args=(-v "$(cd "${WORKDIR_HOST}" && pwd):/work")
      warn "Bind-mounting ${WORKDIR_HOST} -> /work (the agent can read/write these host files)."
    fi

    docker run -d \
      --name "${CONTAINER}" \
      --restart unless-stopped \
      --init \
      -p "${BIND_HOST}:${PORT}:${PORT}" \
      -v "${VOLUME}:/root/.local/share/opencode" \
      "${workdir_args[@]}" \
      "${env_args[@]}" \
      "${IMAGE}" >/dev/null
  fi
  echo
  cmd_status
  echo
  log "API:    ${c_dim}http://${BIND_HOST}:${PORT}${c_rst}  (health: /global/health, realtime events: /event)"
  log "Next:   ${c_dim}./okc.sh connect${c_rst}  then  ${c_dim}opencode auth login${c_rst}  to sign in to Claude (OAuth)."
}

cmd_connect() {
  cmd_run
  echo
  if ! [[ -t 0 && -t 1 ]]; then
    die "connect needs an interactive terminal (stdin/stdout must be a TTY)."
  fi
  cat <<EOF

${c_grn}Opening a shell in ${CONTAINER}.${c_rst} The server keeps running after you exit.
Useful inside the container:
  ${c_dim}opencode auth login${c_rst}     sign in to Claude via OAuth (persisted in the volume)
  ${c_dim}opencode auth list${c_rst}      show authenticated providers
  ${c_dim}opencode models anthropic${c_rst}  list models available to your login
  ${c_dim}claude${c_rst}                  the Claude Code CLI is installed too

EOF
  exec docker exec -it -w /work "${CONTAINER}" "${SHELL_BIN}"
}

cmd_stop() {
  need_docker
  if container_running; then
    log "Stopping ${CONTAINER}..."
    docker stop "${CONTAINER}" >/dev/null
    log "Stopped. Image and volume kept — './okc.sh run' to start again."
  else
    log "Not running (nothing to stop)."
  fi
}

# Recreate the container (not just stop/start) so changes to the model, port or
# other env take effect. All persistent state is in the volume, so this is safe.
cmd_restart() {
  need_docker
  if container_exists; then
    log "Recreating container to apply current configuration (volume is kept)..."
    docker rm -f "${CONTAINER}" >/dev/null
  fi
  cmd_run
}

cmd_build() { need_docker; do_build "$@"; }

cmd_clean() {
  need_docker
  local assume_yes=0 arg
  for arg in "$@"; do
    case "${arg}" in
      -y|--yes|--force) assume_yes=1 ;;
      *) die "unknown option for clean: ${arg}" ;;
    esac
  done
  [[ "$(resolve OKC_ASSUME_YES '')" == "1" ]] && assume_yes=1

  echo "This will permanently remove:"
  printf '  container  %-28s %s\n' "${CONTAINER}" "$(container_exists && echo '(present)' || echo '(absent)')"
  printf '  image      %-28s %s\n' "${IMAGE}"     "$(image_exists     && echo '(present)' || echo '(absent)')"
  printf '  volume     %-28s %s\n' "${VOLUME}"    "$(volume_exists    && echo "${c_red}(present — your opencode auth lives here)${c_rst}" || echo '(absent)')"
  echo

  if [[ "${assume_yes}" != "1" ]]; then
    [[ -t 0 ]] || die "refusing to clean without a TTY; pass --yes to confirm."
    local ans
    read -r -p "Type 'yes' to confirm: " ans
    [[ "${ans}" == "yes" ]] || { log "Aborted — nothing removed."; return 0; }
  fi

  if container_exists; then log "Removing container ${CONTAINER}..."; docker rm -f "${CONTAINER}" >/dev/null; fi
  if image_exists;     then log "Removing image ${IMAGE}...";       docker rmi -f "${IMAGE}"     >/dev/null; fi
  if volume_exists;    then log "Removing volume ${VOLUME}...";     docker volume rm "${VOLUME}" >/dev/null; fi
  log "Clean complete."
}

cmd_status() {
  need_docker
  local state health
  if container_exists; then
    state="$(docker container inspect -f '{{.State.Status}}' "${CONTAINER}" 2>/dev/null || echo unknown)"
    health="$(docker container inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' "${CONTAINER}" 2>/dev/null || echo n/a)"
  else
    state="not created"; health="n/a"
  fi
  printf '  container : %s  %s(state: %s, health: %s)%s\n' "${CONTAINER}" "${c_dim}" "${state}" "${health}" "${c_rst}"
  printf '  image     : %s  %s(%s)%s\n' "${IMAGE}"  "${c_dim}" "$(image_exists  && echo built   || echo 'not built')"  "${c_rst}"
  printf '  volume    : %s  %s(%s)%s\n' "${VOLUME}" "${c_dim}" "$(volume_exists && echo present || echo absent)"       "${c_rst}"
  printf '  bind      : %s  %smodel: %s/%s%s\n' "${BIND_HOST}:${PORT}" "${c_dim}" "${PROVIDER}" "${MODEL}" "${c_rst}"
}

cmd_logs() {
  need_docker
  container_exists || die "container ${CONTAINER} does not exist (run './okc.sh run' first)."
  docker logs "$@" "${CONTAINER}"
}

usage() {
  cat <<'EOF'
open-kali-claude — a headless Kali container running the opencode HTTP API (Claude).

Usage: ./okc.sh <command> [options]

Commands:
  run                 Build the image if needed, create the volume, and start the
                      server. Idempotent: no-op if already running; starts the
                      existing container if it was only stopped.
  connect             Ensure it is running, then open a shell inside the container.
                      Run `opencode auth login` here the first time (OAuth).
  stop                Stop the server. The image and the auth volume are kept.
  clean [--yes]       Remove the container, image and volume (asks to confirm;
                      --yes skips the prompt). This deletes the saved opencode auth.
  restart             Recreate the container so changed env (model, port, ...)
                      takes effect. The auth volume is kept.
  status              Show container state/health, image, volume, bind and model.
  logs [-f]           Show the server logs (-f follows them — realtime activity).
  build [--no-cache]  (Re)build the image.
  help                Show this help.

Examples:
  ./okc.sh run                              # first run builds the image too
  ./okc.sh connect                          # then, inside: opencode auth login
  curl http://127.0.0.1:4096/global/health  # check the API is up
  curl -N http://127.0.0.1:4096/event       # stream what the agent is doing (SSE)
  OPENCODE_MODEL=claude-opus-4-5 ./okc.sh restart
  KALI_METAPACKAGE=kali-linux-core ./okc.sh build     # smaller/faster image
  ./okc.sh clean --yes

Configuration (environment variables, also read from ./.env):
  OPENCODE_PROVIDER     model provider                 (default: anthropic)
  OPENCODE_MODEL        model id, or provider/model    (default: claude-sonnet-4-5)
  OPENCODE_SMALL_MODEL  cheaper model for minor tasks  (optional)
  OPENCODE_PORT         host + server port             (default: 4096)
  OKC_BIND_HOST         host interface to publish on   (default: 127.0.0.1)
  OKC_WORKDIR           host dir to bind-mount at /work (optional)
  ANTHROPIC_API_KEY     use an API key instead of OAuth (optional)
  KALI_METAPACKAGE      build: kali-linux-headless | kali-linux-core | none

The opencode API (http://<bind>:<port>) serves REST + an SSE stream at /event.
See README.md, or `curl http://127.0.0.1:4096/doc` for the full API spec.
EOF
}

# --------------------------------------------------------------------------- #
# Dispatch
# --------------------------------------------------------------------------- #
cmd="${1:-help}"; shift || true
case "${cmd}" in
  run)       cmd_run "$@" ;;
  connect|shell) cmd_connect "$@" ;;
  stop)      cmd_stop "$@" ;;
  restart)   cmd_restart "$@" ;;
  clean)     cmd_clean "$@" ;;
  build)     cmd_build "$@" ;;
  status|ps) cmd_status "$@" ;;
  logs)      cmd_logs "$@" ;;
  help|-h|--help) usage ;;
  *) err "unknown command: ${cmd}"; echo; usage; exit 2 ;;
esac
