#!/usr/bin/env bash
# .env creation and secret generation.
#
# Everything here is idempotent. Re-running setup.sh must not rotate a key
# that services are already using — that would silently break the wiring
# and, worse, the copy of the key already stored in the app.

hp_random_hex() {
    local bytes="${1:-16}"
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex "$bytes"
    else
        # macOS always has openssl, but don't hard-fail if it's missing.
        LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c $((bytes * 2))
        echo
    fi
}

# Alphanumeric only, on purpose: these land in .env, in shell variables and
# in a qBittorrent config file. Punctuation buys little entropy here and
# invites a quoting bug in exactly the places that are hardest to debug.
hp_random_password() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 24 | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 20
        echo
    else
        LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20
        echo
    fi
}

_hp_env_get() {   # key file
    grep -E "^$1=" "$2" 2>/dev/null | head -1 | cut -d= -f2-
}

_hp_env_set() {   # key value file
    local key="$1" val="$2" file="$3" tmp="$3.tmp.$$"
    if grep -qE "^${key}=" "$file" 2>/dev/null; then
        awk -v k="$key" -v v="$val" '
            index($0, k "=") == 1 { print k "=" v; next }
            { print }
        ' "$file" > "$tmp"
    else
        cp "$file" "$tmp"
        printf '%s=%s\n' "$key" "$val" >> "$tmp"
    fi
    mv "$tmp" "$file"
}

# Fill a key only when it has no value yet, so existing secrets survive.
_hp_env_fill() { # key generator-output file
    local key="$1" val="$2" file="$3"
    local current
    current=$(_hp_env_get "$key" "$file")
    [ -n "$current" ] && return 0
    _hp_env_set "$key" "$val" "$file"
    HP_GENERATED="${HP_GENERATED}${key} "
}

# Creates .env if absent, then fills any blank secret. Returns with
# HP_GENERATED listing whatever was newly created, for the summary.
hp_prepare_env() {
    local root="$1"
    local env_file="$root/.env"
    local example="$root/.env.example"

    HP_GENERATED=""

    if [ ! -f "$env_file" ]; then
        cp "$example" "$env_file"
        chmod 600 "$env_file"
        echo "  created .env"
    else
        echo "  .env already exists — keeping existing values"
    fi

    # Host identity. Container files are written as this user, so getting
    # it wrong shows up much later as permission errors on import.
    [ -z "$(_hp_env_get PUID "$env_file")" ] && _hp_env_set PUID "$(id -u)" "$env_file"
    [ -z "$(_hp_env_get PGID "$env_file")" ] && _hp_env_set PGID "$(id -g)" "$env_file"

    local tz
    tz=$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||')
    [ -n "$tz" ] && _hp_env_set TZ "$tz" "$env_file"

    _hp_env_fill GRAFANA_ADMIN_PASSWORD "$(hp_random_password)" "$env_file"
    _hp_env_fill QBITTORRENT_PASSWORD   "$(hp_random_password)" "$env_file"
    _hp_env_fill SONARR_API_KEY         "$(hp_random_hex 16)"   "$env_file"
    _hp_env_fill RADARR_API_KEY         "$(hp_random_hex 16)"   "$env_file"
    _hp_env_fill PROWLARR_API_KEY       "$(hp_random_hex 16)"   "$env_file"

    chmod 600 "$env_file"
}

# qBittorrent 4.6.1+ generates a random WebUI password on every start and
# prints it only to the container log, regenerating it until a permanent
# one is set. That makes unattended setup impossible — and it's the step
# every auto-wiring attempt trips over.
#
# So write the password in before first boot. qBittorrent stores it as
# PBKDF2-HMAC-SHA512, 100k iterations, 64-byte key, 16-byte salt, both
# halves base64 inside @ByteArray(salt:hash).
hp_seed_qbittorrent_conf() {
    local root="$1"
    local conf_dir="${HOMEPILOT_DATA}/qbittorrent/qBittorrent"
    local conf="${conf_dir}/qBittorrent.conf"

    # Never clobber an existing config — the user may have changed things
    # in the WebUI, and the password in .env would then be stale anyway.
    if [ -f "$conf" ]; then
        echo "  qBittorrent.conf exists — leaving it alone"
        return 0
    fi

    mkdir -p "$conf_dir"
    QB_PASSWORD="$QBITTORRENT_PASSWORD" python3 - "$conf" <<'PY'
import base64, hashlib, os, sys

password = os.environ["QB_PASSWORD"].encode()
salt = os.urandom(16)
digest = hashlib.pbkdf2_hmac("sha512", password, salt, 100_000, dklen=64)
encoded = f"@ByteArray({base64.b64encode(salt).decode()}:{base64.b64encode(digest).decode()})"

with open(sys.argv[1], "w") as fh:
    fh.write(
        "[Preferences]\n"
        "WebUI\\Username=admin\n"
        f"WebUI\\Password_PBKDF2=\"{encoded}\"\n"
        # HomePilot is a native client and sends neither Origin nor Referer,
        # which qBittorrent's CSRF check treats as same-site. Host header
        # validation stays on; this only relaxes the domain allowlist so the
        # LAN IP works without editing anything.
        "WebUI\\HostHeaderValidation=false\n"
        "WebUI\\CSRFProtection=false\n"
        "Downloads\\SavePath=/data/torrents/\n"
    )
PY
    chmod 600 "$conf"
    echo "  seeded qBittorrent.conf with the generated password"
}

# Record what the runtime detection found, so compose and any later
# re-run agree on the socket without re-detecting.
hp_record_runtime() {
    local root="$1"
    _hp_env_set CONTAINER_SOCK "$HP_MOUNT_SOCK" "$root/.env"
}
