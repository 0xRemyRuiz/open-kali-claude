# open-kali-claude

A standalone, headless **Kali Linux** container that runs the **opencode** HTTP
API backed by **Claude**, with **Claude Code** also installed. The opencode
server is exposed over HTTP so you can:

- **send it instructions** (create sessions, send prompts) over a REST API, and
- **watch, in realtime, everything it is doing** via a Server-Sent-Events stream.

Authentication to Claude is done with an **OAuth login from a shell inside the
container** (Claude Pro/Max), and is **persisted in a Docker volume** so you only
log in once.

```
┌─ your host ──────────────────────────────────────────────┐
│  ./okc.sh run / connect / stop / clean                    │
│                                                           │
│   http://127.0.0.1:4096  ──────────┐                      │
│                                     ▼                      │
│   ┌─ container: kali-rolling ───────────────────────────┐ │
│   │  opencode serve --hostname 0.0.0.0 --port 4096       │ │
│   │  @anthropic-ai/claude-code (the `claude` CLI)        │ │
│   │  full Kali headless toolset                          │ │
│   │  auth.json  ◄── volume: open-kali-claude-auth        │ │
│   └──────────────────────────────────────────────────────┘│
└───────────────────────────────────────────────────────────┘
```

## Requirements

- Docker (Engine 20.10+), with the **daemon running** and your user able to run
  `docker` (in the `docker` group, or via rootless Docker). On a systemd host:
  `sudo systemctl enable --now docker` and `sudo usermod -aG docker "$USER"`
  (then start a new login shell). Nothing else — Node, opencode and Claude Code
  are installed **inside** the image.
- A Claude subscription (Pro/Max) for the OAuth login, or an `ANTHROPIC_API_KEY`.

## Quick start

```bash
cp .env.example .env        # optional: pick your model, etc.
./okc.sh run                # builds the image on first run, then starts the server
./okc.sh connect            # opens a shell in the container
#   then, inside the container, sign in to Claude once:
opencode auth login         # choose Anthropic → Claude Pro/Max (OAuth), paste the code
exit                        # the server keeps running
```

> **First build is large.** The default image installs the full `kali-linux-headless`
> toolset (several GB). To build a lean image instead, set
> `KALI_METAPACKAGE=kali-linux-core` (or `none`) before the first `run`/`build`
> — see [Customizing the build](#customizing-the-build).

Check it is alive:

```bash
curl http://127.0.0.1:4096/global/health
```

## The `okc.sh` script

All commands are **idempotent** — safe to run repeatedly.

| Command | What it does |
|---|---|
| `./okc.sh run` | Build the image if missing, create the volume if missing, and start the container. No-op if already running; starts the existing container if it was only stopped. |
| `./okc.sh connect` | Ensure the container is running (same as `run`), then drop you into an interactive shell inside it. The server keeps running when you exit. |
| `./okc.sh stop` | Stop the running container. The image and the auth volume are **kept**. |
| `./okc.sh clean [--yes]` | **After confirmation**, remove the container, the image, and the volume (this deletes your saved opencode auth). `--yes` skips the prompt. |
| `./okc.sh status` | Show container state/health, whether the image/volume exist, bind address, and selected model. |
| `./okc.sh logs [-f]` | Show the opencode server logs (`-f` to follow — another realtime view of what it is doing). |
| `./okc.sh restart` | Recreate the container so changed env (model, port, etc.) takes effect. The auth volume is kept. |
| `./okc.sh build [--no-cache]` | (Re)build the image. |
| `./okc.sh help` | Full usage (synopsis, commands, examples, env vars). |

Run `./okc.sh help` (or `./okc.sh` with no arguments) to print the usage at any time.

### Running the container directly (without `okc.sh`)

`okc.sh` is a thin convenience wrapper around Docker. If you prefer to run the
container yourself, these are the equivalent commands:

```bash
# 1. Build the image from the repo root. Change the toolset with a build arg:
#    --build-arg KALI_METAPACKAGE=kali-linux-core   (or =none for base only)
docker build -t open-kali-claude:latest .

# 2. Create the persistent auth volume once.
docker volume create open-kali-claude-auth

# 3. Start the server. It binds 0.0.0.0 inside the container; publishing to
#    127.0.0.1 keeps the API reachable only from this host. Model/provider come
#    from the -e vars (change the -p mapping too if you change OPENCODE_PORT).
docker run -d --name open-kali-claude --restart unless-stopped --init \
  -p 127.0.0.1:4096:4096 \
  -v open-kali-claude-auth:/root/.local/share/opencode \
  -e OPENCODE_PROVIDER=anthropic -e OPENCODE_MODEL=claude-sonnet-4-5 \
  open-kali-claude:latest

# 4. Open a shell inside it (to run `opencode auth login`, use tools, etc.).
docker exec -it -w /work open-kali-claude /bin/bash

# Follow logs / stop / remove everything.
docker logs -f open-kali-claude
docker stop open-kali-claude
docker rm -f open-kali-claude && docker volume rm open-kali-claude-auth
```

## Authenticating (OAuth, persisted)

The OAuth flow is interactive, so it is done from a shell in the container:

```bash
./okc.sh connect
# inside the container:
opencode auth login
#   → select "Anthropic"
#   → select the Claude Pro/Max (OAuth) method
#   → open the printed URL in your browser, authorize, paste the code back
opencode auth list          # confirm it worked
```

The credentials are written to `/root/.local/share/opencode/auth.json`, which is
the **`open-kali-claude-auth` volume** — so the login survives `stop`, `run`, and
even recreating the container. It is only deleted by `./okc.sh clean`.

If the already-running server does not immediately pick up a brand-new login,
`./okc.sh restart` forces it to re-read the credentials.

**Prefer an API key?** Set `ANTHROPIC_API_KEY` in your shell or in `.env`; it is
forwarded into the container and used automatically, no `auth login` needed.

## Choosing the model

The model always comes from environment variables and is applied on every start
(it is never baked into the image or the volume). opencode uses a
`provider/model` string:

- `OPENCODE_PROVIDER` (default `anthropic`) + `OPENCODE_MODEL` (default
  `claude-sonnet-4-5`) are combined into `anthropic/claude-sonnet-4-5`.
- If `OPENCODE_MODEL` already contains a `/` it is used verbatim
  (e.g. `OPENCODE_MODEL=anthropic/claude-opus-4-5`).
- `OPENCODE_SMALL_MODEL` optionally sets a cheaper model for minor tasks.

See exactly which models your login can use:

```bash
./okc.sh connect   # then:
opencode models anthropic
```

Change the model and apply it:

```bash
OPENCODE_MODEL=claude-opus-4-5 ./okc.sh restart
# or set it in .env and run ./okc.sh restart
```

## Driving the API

Full interactive API reference (OpenAPI) is served by the container:

```bash
curl http://127.0.0.1:4096/doc
```

Common endpoints:

```bash
# Is it up?
curl http://127.0.0.1:4096/global/health

# Realtime event stream — everything the agent does (tools, messages, state).
# The first event is "server.connected", then live bus events.
curl -N http://127.0.0.1:4096/event

# Create a session, then send it a prompt (see /doc for exact request bodies).
curl -X POST http://127.0.0.1:4096/session -H 'content-type: application/json' -d '{}'
```

Keep `curl -N http://127.0.0.1:4096/event` open in one terminal while you send a
prompt in another to see the agent's actions stream in live.

## Security notes

- The opencode API can **run arbitrary commands and tools** in the container. By
  default the port is published to **`127.0.0.1` only**. Do not bind it to a
  routable interface unless you set `OPENCODE_SERVER_PASSWORD` and accept the risk.
- The container runs as root with the Kali toolset but **without** `--privileged`
  and with Docker's default capabilities. Some tools may need extra capabilities
  (e.g. `--cap-add=NET_ADMIN`); add them to the `docker run` in `okc.sh` if needed.
- `/work` inside the container is ephemeral unless you set `OKC_WORKDIR` to
  bind-mount a host directory — which gives the agent read/write access to those
  host files.

## Customizing the build

Build-time options (pass as environment variables to `./okc.sh build` or the
first `./okc.sh run`, or set in `.env`):

| Variable | Default | Meaning |
|---|---|---|
| `KALI_METAPACKAGE` | `kali-linux-headless` | Kali toolset: `kali-linux-headless`, `kali-linux-core`, or `none`. |
| `NODE_MAJOR` | `22` | Node.js major version (NodeSource). |
| `OPENCODE_VERSION` | `latest` | npm version of `opencode-ai`. |
| `CLAUDE_CODE_VERSION` | `latest` | npm version of `@anthropic-ai/claude-code`. |

```bash
# Lean, fast image with only the essential Kali tools:
KALI_METAPACKAGE=kali-linux-core ./okc.sh build
```

## Configuration reference

All knobs live in `.env.example`. The script-side infra knobs are
`OKC_IMAGE`, `OKC_CONTAINER`, `OKC_VOLUME`, `OKC_BIND_HOST`, `OKC_SHELL`,
`OKC_WORKDIR`, and `OKC_ENV_FILE` (path to the env file, default `./.env`).

## Files

| File | Purpose |
|---|---|
| `okc.sh` | The `run`/`connect`/`stop`/`clean` manager. |
| `Dockerfile` | Kali + Node + opencode + Claude Code image. |
| `entrypoint.sh` | Writes `opencode.json` from env, then runs `opencode serve`. |
| `.env.example` | Documented configuration template. |
