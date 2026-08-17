#!/usr/bin/env bash
# Connects the media services to each other over their APIs.
#
# This is the step every popular *arr compose repo leaves to the user, and
# the one Buildarr used to automate before it was abandoned in 2024.
# Recyclarr and Configarr deliberately scope themselves to quality profiles
# and do not do this.
#
# Everything is idempotent: each call checks for an existing entry by name
# first, so re-running setup.sh is a no-op rather than a pile of duplicates.

_arr() {  # method port apikey path [json]
    local method="$1" port="$2" key="$3" path="$4" body="${5:-}"
    if [ -n "$body" ]; then
        curl -fsS --max-time 20 -X "$method" \
            -H "X-Api-Key: $key" -H "Content-Type: application/json" \
            -d "$body" "http://localhost:${port}${path}" 2>/dev/null
    else
        curl -fsS --max-time 20 -X "$method" \
            -H "X-Api-Key: $key" \
            "http://localhost:${port}${path}" 2>/dev/null
    fi
}

# True when a named entry already exists at the given collection endpoint.
_arr_has() {  # port apikey path name
    _arr GET "$1" "$2" "$3" | python3 -c '
import sys, json
try:
    items = json.load(sys.stdin)
except Exception:
    sys.exit(1)
name = sys.argv[1].lower()
sys.exit(0 if any(str(i.get("name","")).lower() == name for i in items) else 1)
' "$4" 2>/dev/null
}

# ── qBittorrent as the download client for Sonarr and Radarr ───────────
_wire_download_client() {  # port apikey apiver category
    local port="$1" key="$2" ver="$3" cat="$4"

    if _arr_has "$port" "$key" "/api/${ver}/downloadclient" "qBittorrent"; then
        ok "download client already set"
        return 0
    fi

    # Container name, not localhost: these talk to each other over the
    # `homepilot` network, where the host's port mapping doesn't apply.
    local body
    body=$(cat <<JSON
{
  "enable": true,
  "protocol": "torrent",
  "priority": 1,
  "name": "qBittorrent",
  "implementation": "QBittorrent",
  "configContract": "QBittorrentSettings",
  "fields": [
    {"name": "host",     "value": "homepilot-qbittorrent"},
    {"name": "port",     "value": 8081},
    {"name": "username", "value": "admin"},
    {"name": "password", "value": "${QBITTORRENT_PASSWORD}"},
    {"name": "category", "value": "${cat}"}
  ]
}
JSON
)
    if _arr POST "$port" "$key" "/api/${ver}/downloadclient" "$body" >/dev/null; then
        ok "qBittorrent wired as download client (category: ${cat})"
    else
        warn "could not add qBittorrent as a download client on port ${port}"
    fi
}

# ── Root folders ───────────────────────────────────────────────────────
_wire_root_folder() {  # port apikey apiver path
    local port="$1" key="$2" ver="$3" path="$4"
    local existing
    existing=$(_arr GET "$port" "$key" "/api/${ver}/rootfolder" || echo "[]")
    case "$existing" in
        *"\"$path\""*) ok "root folder already set (${path})"; return 0 ;;
    esac
    if _arr POST "$port" "$key" "/api/${ver}/rootfolder" "{\"path\":\"${path}\"}" >/dev/null; then
        ok "root folder ${path}"
    else
        warn "could not add root folder ${path} on port ${port}"
    fi
}

# ── Register the arrs with Prowlarr ────────────────────────────────────
# Once registered, Prowlarr pushes every indexer into them and re-syncs
# whenever indexers change — so indexers only ever get added in one place.
_wire_prowlarr_app() {  # appname implementation arrport arrkey
    local name="$1" impl="$2" arrport="$3" arrkey="$4"

    if _arr_has "$PROWLARR_PORT" "$PROWLARR_API_KEY" "/api/v1/applications" "$name"; then
        ok "${name} already registered with Prowlarr"
        return 0
    fi

    # Container hostnames are lowercase; the implementation name is not.
    local host
    host="homepilot-$(printf '%s' "$impl" | tr '[:upper:]' '[:lower:]')"

    local body
    body=$(cat <<JSON
{
  "name": "${name}",
  "syncLevel": "fullSync",
  "implementation": "${impl}",
  "configContract": "${impl}Settings",
  "fields": [
    {"name": "prowlarrUrl", "value": "http://homepilot-prowlarr:9696"},
    {"name": "baseUrl",     "value": "http://${host}:${arrport}"},
    {"name": "apiKey",      "value": "${arrkey}"}
  ]
}
JSON
)
    if _arr POST "$PROWLARR_PORT" "$PROWLARR_API_KEY" "/api/v1/applications" "$body" >/dev/null; then
        ok "${name} registered with Prowlarr (full sync)"
    else
        warn "could not register ${name} with Prowlarr"
    fi
}

hp_wire_all() {
    _wire_download_client "$SONARR_PORT" "$SONARR_API_KEY" v3 tv
    _wire_download_client "$RADARR_PORT" "$RADARR_API_KEY" v3 movies

    _wire_root_folder "$SONARR_PORT" "$SONARR_API_KEY" v3 /data/media/tv
    _wire_root_folder "$RADARR_PORT" "$RADARR_API_KEY" v3 /data/media/movies

    _wire_prowlarr_app Sonarr Sonarr "8989" "$SONARR_API_KEY"
    _wire_prowlarr_app Radarr Radarr "7878" "$RADARR_API_KEY"

    say ""
    say "  Indexers are intentionally not configured — add them in Prowlarr"
    say "  and it pushes them to Sonarr and Radarr for you."
}
