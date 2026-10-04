# HomePilot server setup

One command to stand up the services [HomePilot](https://apps.apple.com/app/homepilot) connects to,
on a Mac mini or any machine with a container runtime — configured so the
app works without you copying a single API key.

```bash
git clone https://github.com/muzaparoff/homepilot-setup
cd homepilot-setup
./setup.sh
```

That's the core stack: container management and metrics. Add the media
services with `./setup.sh --with-media`, and push notifications with
`./setup.sh --with-notifications` (needs an Apple-issued key first — see
[Push notifications](#push-notifications) below).

Already have a server? You probably don't need this — see
[docs/CREDENTIALS.md](docs/CREDENTIALS.md), which lists what HomePilot
expects on each port and exactly where to find each credential in the
service's own UI.

---

## What it runs

| Service | Port | What HomePilot uses it for |
|---|---|---|
| Dockge | 5001 | Stacks tab — start, stop and restart containers |
| Prometheus | 9090 | Metrics tab — the four KPI cards |
| Grafana | 3000 | Metrics tab — embedded dashboards |
| node-exporter | 9100 | CPU, memory and disk metrics |
| container-exporter | 9101 | Per-container state |

With `--with-media`:

| Service | Port | Tab |
|---|---|---|
| qBittorrent | 8081 | Torrents |
| Sonarr | 8989 | Media → TV Shows |
| Radarr | 7878 | Media → Movies |
| Prowlarr | 9696 | Media → Search |

With `--with-notifications`:

| Service | Port | What it does |
|---|---|---|
| Notifier | 8899 | Pushes torrent-finished / CPU-RAID / service-down alerts to the app |

Ports match HomePilot's built-in defaults, so there is nothing to change
in the app. Override any of them in `.env`. One exception: HomePilot
itself defaults to port 8080 for qBittorrent (the linuxserver image's own
stock default) and automatically tries 8081 if that fails — this kit
still installs qBittorrent on 8081 as shown above, and the app's fallback
probe covers the difference either way.

## What the setup actually does

Most compose collections stop at "the containers are running". This one
goes further, because that last step is where a first *arr setup usually
falls over:

- **Detects your runtime.** Docker Desktop, OrbStack, Colima or Podman.
  It asks the API server which engine it is rather than trusting the CLI
  name — on macOS a `docker` command may well be talking to Podman, and
  the two need different socket paths mounted into Dockge.
- **Generates the API keys before first boot.** Sonarr, Radarr and
  Prowlarr accept their key via `SONARR__AUTH__APIKEY` and friends, so the
  setup picks the keys rather than starting the apps and scraping them
  back out. That's what makes the whole thing re-runnable.
- **Sets the qBittorrent password.** Since 4.6.1 qBittorrent generates a
  random one into its log on every start until you set a permanent one.
  The setup writes a PBKDF2 hash in before first boot instead.
- **Wires the services together.** qBittorrent is registered as the
  download client in Sonarr and Radarr with matching categories, root
  folders are created, and both are registered in Prowlarr with full sync —
  so indexers get added in one place and pushed everywhere.
- **Uses a hardlink-safe layout.** `torrents/` and `media/` are siblings
  under a single mount, so imports are hardlinks rather than full copies.
  Splitting them across mounts is the single most common first-setup
  mistake: every import silently doubles your disk use.

Re-running is safe. Existing secrets are preserved, and each wiring step
checks for what it would create before creating it.

## What the metrics mean on a Mac

On macOS every container runs inside a Linux VM, so `node-exporter`
reports **the VM**, not macOS. CPU and memory track real work closely
enough to be useful; the Disk card shows the VM's virtual disk, not your
Mac's SSD or an attached array.

If you have a RAID or external volume you want on that card, publish a
`host_filesystem_avail_bytes{mount="raid"}` series from the host — a
textfile collector on a cron is enough. HomePilot prefers that series
when it exists and falls back to the VM's root filesystem when it
doesn't.

The Containers card uses `container_running` from `container-exporter`,
a small stdlib-only exporter in [`exporter/`](exporter/). It replaces
cAdvisor deliberately: cAdvisor reads cgroups, and under rootless Podman
the container cgroups live in a user slice it can't enumerate, so it
reports a single `id="/"` series and nothing else. Querying the
Docker-compatible API instead behaves the same on every engine.

## Push notifications

Only needed for `--with-notifications`. Nothing in this step can be
generated for you — it comes from an Apple-issued key tied to your own
developer account:

1. [App Store Connect → Agreements](https://appstoreconnect.apple.com/agreements) —
   accept any pending agreement first. While one is pending, Apple blocks
   the APIs the next step needs.
2. [developer.apple.com → Certificates, Identifiers & Profiles → Keys](https://developer.apple.com/account/resources/authkeys/list) →
   "+" → check **Apple Push Notifications service (APNs)** → register →
   download the `.p8`. This download only works once — if you lose it,
   you revoke the key and make a new one, you can't re-download it.
3. Save it as `stacks/notifier/apns-key.p8`.
4. Set `APNS_KEY_ID` and `APNS_TEAM_ID` in `.env` (both from the portal
   page you were just on).
5. `./setup.sh --with-notifications`.
6. In HomePilot: Settings → Notifications → enable. The screen shows a
   registration error directly if the container can't be reached.

The container only ever talks to your own phone's device token — no
third-party push relay sees your data.

## Everyday use

```bash
./setup.sh                        # start, or re-apply config
./setup.sh --with-media           # include the media services
./setup.sh --with-notifications   # include push notifications
./setup.sh --down                 # stop everything, keep data and .env
```

Credentials are printed at the end of every run and stored in `.env`
(mode 600, gitignored).

## Requirements

- macOS or Linux
- A container runtime: [OrbStack](https://orbstack.dev) is lightest on a
  Mac mini; Docker Desktop, Colima and Podman all work
- `curl` and `python3` — both already on macOS

## Troubleshooting

**"No container runtime found"** — install one of the above and start it.
The script distinguishes "not installed" from "installed but not running",
since the fixes differ.

**"a test container could NOT read the socket"** — Dockge will start but
show no stacks. Open an issue with the output of `docker version`, which
identifies the engine behind the CLI.

**A port is already in use** — change it in `.env` and re-run, then set
the matching port in HomePilot under Settings → Services & Ports.

## Licence

MIT. Not affiliated with Dockge, qBittorrent, Sonarr, Radarr or Prowlarr.
