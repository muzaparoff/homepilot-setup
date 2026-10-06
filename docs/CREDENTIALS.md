# What Shellpocket needs, and where to find it

For people who already run a homelab and just want the app connected.
If you used `./setup.sh`, all of this was handled for you and printed at
the end of the run — this page is for everyone else.

Shellpocket asks for one server address during onboarding, then each tab
asks for its own credentials the first time you open it.

---

## Server address

Just the host, no scheme and no port:

```
192.168.1.50        or        homeserver.local
```

Every tab pre-fills its URL from this, so getting it right once saves
typing it four more times.

---

## Per service

### Dockge — Stacks tab
**Default port 5001** · Username and password

Set when you first open Dockge's own web UI and create the admin account.
There is no default; if you've forgotten it, delete `data/dockge/` and
Dockge will ask you to create the account again.

### qBittorrent — Torrents tab
**Default port 8081** · Username and password

Default username is `admin`. Since 4.6.1 qBittorrent generates a random
password on every start until a permanent one is set, and prints it only
to the container log:

```bash
docker logs <qbittorrent-container> 2>&1 | grep -i "temporary password"
```

Set a permanent one in the WebUI under **Tools → Options → Web UI**,
otherwise it changes on every restart and the app loses access.

> Shellpocket defaults to **8080**, the linuxserver image's own default, and
> tries **8081** automatically if 8080 doesn't answer. Any other port: set
> it in the app under Settings → Services & Ports.

### Sonarr — Media → TV Shows
**Default port 8989** · API key

**Settings → General → Security → API Key**

### Radarr — Media → Movies
**Default port 7878** · API key

**Settings → General → Security → API Key**

### Prowlarr — Media → Search
**Default port 9696** · API key

**Settings → General → Security → API Key**

> All three also accept the key via environment variable —
> `SONARR__AUTH__APIKEY`, `RADARR__AUTH__APIKEY`, `PROWLARR__AUTH__APIKEY`
> — which lets you decide the key rather than read it back out. Useful if
> you're automating your own setup.

> The Search tab also reads your qBittorrent categories and default save
> path, so configure the Torrents tab first for the best experience.

### Prometheus — Metrics tab
**Default port 9090** · No authentication

Shellpocket runs four queries. The first three are standard node-exporter:

| Card | Query |
|---|---|
| CPU | `100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)` |
| Memory | `(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100` |
| Disk | `node_filesystem_avail_bytes{mountpoint="/"}`, or `host_filesystem_avail_bytes{mount="raid"}` if you publish it |
| Containers | `container_running`, or cAdvisor's `container_last_seen` |

Each card tries a specific query first and falls back to the portable one,
so a bespoke series wins where you have one. If a card shows `—`, run its
query in Prometheus directly — you're most likely missing an exporter.

### Grafana — Metrics tab
**Default port 3000** · Admin user and password

Shellpocket lists your dashboards by calling `/api/search`. Most Grafana
installs require authentication for that, in which case the app shows a
single **Open Grafana** link instead and you browse in the embedded
browser, signing in once.

Grafana must also allow embedding, or dashboards render as a blank frame:

```ini
[security]
allow_embedding = true
```

or `GF_SECURITY_ALLOW_EMBEDDING=true` as an environment variable.

### SSH — Terminal tab
**Default port 22** · Username and password, or an ed25519 private key

Nothing Shellpocket-specific. The same credentials also power SFTP browsing
in the iOS Files app.

---

## Quick check

From a machine on the same network, before opening the app:

```bash
HOST=192.168.1.50
curl -s "http://$HOST:9090/-/healthy"                          # Prometheus
curl -s "http://$HOST:3000/api/health"                         # Grafana
curl -s -o /dev/null -w '%{http_code}\n' "http://$HOST:5001/"  # Dockge
curl -s -H "X-Api-Key: $KEY" "http://$HOST:8989/api/v3/system/status"  # Sonarr
```

Anything that fails here will fail in the app too, and it's much easier
to debug from a terminal than from a phone.
