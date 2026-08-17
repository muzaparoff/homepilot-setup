#!/usr/bin/env bash
# HomePilot server setup.
#
#   ./setup.sh                 core stack: Dockge, Prometheus, Grafana
#   ./setup.sh --with-media    also *arr + qBittorrent, wired together
#   ./setup.sh --down          stop everything (keeps data and .env)
#
# Safe to re-run. Existing secrets are preserved, so a second run will not
# rotate a key that a running service — or your phone — already holds.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# shellcheck source=lib/detect.sh
. "$ROOT/lib/detect.sh"
# shellcheck source=lib/env.sh
. "$ROOT/lib/env.sh"

WITH_MEDIA=0
ACTION="up"

while [ $# -gt 0 ]; do
    case "$1" in
        --with-media) WITH_MEDIA=1 ;;
        --down)       ACTION="down" ;;
        -h|--help)
            sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Try: $0 --help" >&2
            exit 1 ;;
    esac
    shift
done

say()  { printf '%s\n' "$*"; }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }

# ── 1. Runtime ─────────────────────────────────────────────────────────
step "Detecting container runtime"
hp_detect_runtime || exit 1
ok "$HP_FLAVOUR"
say "    compose : $HP_COMPOSE"
say "    socket  : $HP_MOUNT_SOCK"

# ── Compose invocation ─────────────────────────────────────────────────
# HP_COMPOSE may be two words ("docker compose"), so it is deliberately
# unquoted at the call sites below.
COMPOSE_FILES="-f stacks/core/compose.yaml"
if [ "$HP_ENGINE" = "podman" ]; then
    COMPOSE_FILES="$COMPOSE_FILES -f stacks/core/compose.podman.yaml"
fi
if [ "$WITH_MEDIA" = "1" ]; then
    COMPOSE_FILES="$COMPOSE_FILES -f stacks/media/compose.yaml"
fi

# shellcheck disable=SC2086
compose() { $HP_COMPOSE --project-directory "$ROOT" $COMPOSE_FILES "$@"; }

if [ "$ACTION" = "down" ]; then
    step "Stopping"
    compose down
    ok "stopped — data and .env kept"
    exit 0
fi

# ── 2. Configuration ───────────────────────────────────────────────────
step "Preparing configuration"
hp_prepare_env "$ROOT"
hp_record_runtime "$ROOT"
if [ -n "${HP_GENERATED:-}" ]; then
    ok "generated: ${HP_GENERATED}"
else
    ok "reusing existing secrets"
fi

# shellcheck source=/dev/null
set -a; . "$ROOT/.env"; set +a

# ── 3. Directories ─────────────────────────────────────────────────────
# Created up front so the containers don't create them as root, which on
# Podman lands them owned by a user you can't easily delete afterwards.
step "Creating directories"
mkdir -p "${HOMEPILOT_DATA}"/{dockge,stacks}
if [ "$WITH_MEDIA" = "1" ]; then
    # One tree, so imports hardlink instead of copying. See .env.example.
    mkdir -p "${HOMEPILOT_DATA}"/{sonarr,radarr,prowlarr,qbittorrent}
    mkdir -p "${MEDIA_ROOT}"/torrents/{tv,movies}
    mkdir -p "${MEDIA_ROOT}"/media/{tv,movies}
fi
ok "under ${HOMEPILOT_DATA}"

if [ "$WITH_MEDIA" = "1" ]; then
    hp_seed_qbittorrent_conf "$ROOT"
fi

# ── 4. Socket check ────────────────────────────────────────────────────
# Cheap, and it turns an obscure Dockge failure into a clear message.
step "Checking the container socket is usable"
if hp_verify_mount_sock; then
    ok "a container can reach ${HP_MOUNT_SOCK}"
else
    warn "a test container could NOT read ${HP_MOUNT_SOCK}"
    warn "Dockge will start but show no stacks."
    warn "Report this with the output of: $HP_CLI version"
fi

# ── 5. Start ───────────────────────────────────────────────────────────
step "Starting containers"
compose up -d
ok "containers started"

# Compose recreates a container when its *spec* changes, not when the
# contents of a bind-mounted file change. Prometheus and Grafana both read
# config from mounts, so on a re-run after editing them they would happily
# keep serving the old config. Restarting is cheap and always correct.
compose restart prometheus grafana >/dev/null 2>&1 || true
ok "reloaded Prometheus and Grafana config"

# ── 6. Wait for readiness ──────────────────────────────────────────────
wait_for() { # name url timeout
    local name="$1" url="$2" timeout="${3:-90}" waited=0
    printf '  waiting for %s' "$name"
    while [ "$waited" -lt "$timeout" ]; do
        if curl -fsS --max-time 2 "$url" >/dev/null 2>&1; then
            printf ' \033[32mready\033[0m\n'
            return 0
        fi
        printf '.'
        sleep 2
        waited=$((waited + 2))
    done
    printf ' \033[33mtimed out\033[0m\n'
    return 1
}

step "Waiting for services"
wait_for "Prometheus" "http://localhost:${PROMETHEUS_PORT}/-/healthy" 90 || true
wait_for "Grafana"    "http://localhost:${GRAFANA_PORT}/api/health"    90 || true
wait_for "Dockge"     "http://localhost:${DOCKGE_PORT}/"               90 || true

if [ "$WITH_MEDIA" = "1" ]; then
    wait_for "qBittorrent" "http://localhost:${QBITTORRENT_PORT}/" 120 || true
    wait_for "Sonarr"   "http://localhost:${SONARR_PORT}/ping"   180 || true
    wait_for "Radarr"   "http://localhost:${RADARR_PORT}/ping"   180 || true
    wait_for "Prowlarr" "http://localhost:${PROWLARR_PORT}/ping" 180 || true

    # shellcheck source=lib/wire.sh
    . "$ROOT/lib/wire.sh"
    step "Wiring services together"
    hp_wire_all
fi

# ── 7. Summary ─────────────────────────────────────────────────────────
LAN_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "127.0.0.1")

step "Done"
cat <<EOF

  Open HomePilot and enter this as your server address:

      ${LAN_IP}

  Then each tab asks for its own credentials:

    Stacks  (Dockge)     http://${LAN_IP}:${DOCKGE_PORT}
                         Create the admin account on first visit —
                         Dockge sets its own password, not this script.

    Metrics (Prometheus) http://${LAN_IP}:${PROMETHEUS_PORT}
            (Grafana)    http://${LAN_IP}:${GRAFANA_PORT}
                         user: ${GRAFANA_ADMIN_USER}
                         pass: ${GRAFANA_ADMIN_PASSWORD}
EOF

if [ "$WITH_MEDIA" = "1" ]; then
cat <<EOF

    Torrents (qBittorrent) http://${LAN_IP}:${QBITTORRENT_PORT}
                         user: admin
                         pass: ${QBITTORRENT_PASSWORD}

    Media   Sonarr   http://${LAN_IP}:${SONARR_PORT}    key: ${SONARR_API_KEY}
            Radarr   http://${LAN_IP}:${RADARR_PORT}    key: ${RADARR_API_KEY}
            Prowlarr http://${LAN_IP}:${PROWLARR_PORT}  key: ${PROWLARR_API_KEY}

    Indexers are not configured — add them in Prowlarr and it pushes
    them to Sonarr and Radarr automatically.
EOF
fi

cat <<EOF

  These values are in .env (mode 600, gitignored). Re-run this script
  any time; it won't rotate anything that already exists.

EOF
