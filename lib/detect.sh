#!/usr/bin/env bash
# Container runtime detection.
#
# Sets, on success:
#   HP_CLI         the CLI to drive, e.g. "docker"
#   HP_ENGINE      what's actually serving the API: docker | podman
#   HP_FLAVOUR     human label for the summary, e.g. "Podman (via docker CLI)"
#   HP_COMPOSE     the compose command, e.g. "docker compose"
#   HP_MOUNT_SOCK  socket path for Dockge to bind-mount (see below)
#
# Written for macOS's bash 3.2 — no associative arrays, no ${var,,}.

# ── Why the engine matters more than the CLI ──────────────────────────
# On macOS the CLI name tells you nothing. Podman installs a `docker`
# shim, and a genuine Docker client will happily talk to Podman's API —
# `docker version` then reports "Podman Engine" under Server. Verified on
# a Mac mini running Docker client 29.4 against Podman Engine 5.7.
#
# It matters because the socket a *container* must bind-mount differs:
#   Docker Desktop / OrbStack / Colima → /var/run/docker.sock
#   Podman                             → /run/podman/podman.sock
# The host-side socket that the CLI uses (often a path under
# /var/folders/... for Podman) is NOT mountable into a container. So we
# ask the server what engine it is and hardcode the correct in-VM path.

# NB: capture first, match second. Callers run under `set -o pipefail`, and
# `cmd | grep -q` is a trap there: grep exits as soon as it matches, the
# producer takes SIGPIPE, and the pipeline reports failure *because* the
# match succeeded. That silently mis-detected Podman as Docker.
_hp_engine_of() {
    local out
    out=$("$1" version 2>/dev/null || true)
    case "$out" in
        *"Podman Engine"*|*"podman engine"*) printf 'podman\n'; return ;;
    esac
    if [ "$1" = "podman" ]; then
        printf 'podman\n'
    else
        printf 'docker\n'
    fi
}

_hp_mount_sock_for() {
    case "$1" in
        podman) printf '/run/podman/podman.sock\n' ;;
        *)      printf '/var/run/docker.sock\n' ;;
    esac
}

_hp_flavour_for() {
    local cli="$1" engine="$2" ctx
    if [ "$engine" = "podman" ]; then
        if [ "$cli" = "docker" ]; then
            printf 'Podman (via docker CLI)\n'
        else
            printf 'Podman\n'
        fi
        return
    fi
    ctx=$(docker context show 2>/dev/null)
    case "$ctx" in
        orbstack*) printf 'OrbStack\n'; return ;;
        colima*)   printf 'Colima\n';   return ;;
    esac
    local platform
    platform=$(docker version --format '{{.Server.Platform.Name}}' 2>/dev/null || true)
    case "$platform" in
        *Desktop*|*desktop*) printf 'Docker Desktop\n' ;;
        *)                   printf 'Docker\n' ;;
    esac
}

# Compose v2 is a CLI subcommand; older installs ship a separate binary.
_hp_compose_for() {
    local cli="$1"
    if "$cli" compose version >/dev/null 2>&1; then
        printf '%s compose\n' "$cli"
    elif command -v "${cli}-compose" >/dev/null 2>&1; then
        printf '%s-compose\n' "$cli"
    elif command -v docker-compose >/dev/null 2>&1; then
        printf 'docker-compose\n'
    else
        return 1
    fi
}

# Prefer whichever CLI actually reaches a running engine. A machine can
# have both installed with only one started, and picking the stopped one
# fails several confusing steps later.
hp_detect_runtime() {
    local cli
    for cli in docker podman; do
        command -v "$cli" >/dev/null 2>&1 || continue
        "$cli" info >/dev/null 2>&1 || continue

        HP_CLI="$cli"
        HP_ENGINE=$(_hp_engine_of "$cli")
        HP_MOUNT_SOCK=$(_hp_mount_sock_for "$HP_ENGINE")
        HP_FLAVOUR=$(_hp_flavour_for "$cli" "$HP_ENGINE")
        HP_COMPOSE=$(_hp_compose_for "$cli") || {
            echo "$cli is running but Compose is missing." >&2
            if [ "$cli" = "podman" ]; then
                echo "Try: brew install podman-compose" >&2
            else
                echo "Install Docker Compose v2, or use OrbStack, which bundles it." >&2
            fi
            return 1
        }
        return 0
    done

    # Distinguish "not installed" from "installed but not started" — the
    # fixes differ completely, and the second is by far the more common.
    if command -v docker >/dev/null 2>&1; then
        echo "Docker is installed but not responding." >&2
        echo "Start Docker Desktop or OrbStack, then re-run this script." >&2
    elif command -v podman >/dev/null 2>&1; then
        echo "Podman is installed but not responding." >&2
        echo "Try: podman machine start" >&2
    else
        echo "No container runtime found." >&2
        echo "" >&2
        echo "Install one of these, then re-run:" >&2
        echo "  OrbStack        brew install --cask orbstack     (lightest on a Mac mini)" >&2
        echo "  Docker Desktop  brew install --cask docker" >&2
        echo "  Podman          brew install podman && podman machine init && podman machine start" >&2
    fi
    return 1
}

# Confirm the socket we intend to mount is actually usable from inside a
# container, with the same flags the Dockge service will run with.
#
# On Podman the socket is srw-rw---- root:root, and rootless userns maps
# container-root to an unprivileged user in the VM. Measured on Podman
# Engine 5.7 / macOS: a plain root container gets EACCES, `--user 0:0`
# alone is still denied, and only `--privileged` succeeds. That is why
# compose.podman.yaml adds both.
hp_verify_mount_sock() {
    local extra=""
    [ "$HP_ENGINE" = "podman" ] && extra="--privileged --user 0:0"

    # shellcheck disable=SC2086  # $extra is intentionally word-split
    "$HP_CLI" run --rm $extra \
        -v "${HP_MOUNT_SOCK}:/var/run/docker.sock:ro" \
        --entrypoint /bin/sh \
        alpine:3.20 -c '[ -S /var/run/docker.sock ]' >/dev/null 2>&1
}
