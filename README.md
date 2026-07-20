# altHuntarrrscript

A small Sonarr/Radarr search orchestrator that gradually asks configured instances to search for:

- monitored media that is missing;
- existing media below its quality-profile cutoff.

It does **not** search indexers directly, choose releases, download files, import media, add titles, or expose a web interface. Sonarr and Radarr remain responsible for release profiles, custom formats, indexers, download clients, imports, and quality decisions.

## Highlights

- Sonarr missing and cutoff-unmet episode searches
- Radarr missing and cutoff-unmet movie searches
- Multiple independently configured instances
- Monitored-only and future-date filtering
- Full pagination, random or sequential selection
- Small separate missing/upgrade batches
- Per-instance UTC hourly command caps
- Download-queue gates
- Operation-specific processed history with configurable TTL
- Nonblocking `flock` lock and atomic state writes
- Hard dry-run guard at the only search-command POST path
- Sanitized activity logs showing connection checks, candidate requests, skips, and submitted searches
- Alpine container running as non-root with no capabilities or listening ports

The initial implementation supports Sonarr `episodes` mode. Season-pack and whole-show modes are intentionally not accepted yet.

## Security model

The project has no server, web UI, user accounts, upload handling, database, updater, telemetry, arbitrary hooks, or direct indexer/downloader credentials.

API keys are sent using the `X-Api-Key` header. They are never put in URLs, state records, summaries, or normal log messages. The script does not use shell evaluation or source configuration. In the container, temporary curl configuration/body files are private and API keys are not placed in curl process arguments.

Recommended secret order:

1. `api_key_env` — environment variable named in `config.json`;
2. `api_key_file` — one API key in a mode-`0600` file;
3. `secret_ref` — lookup key in a mode-`0600` `secrets.json`;
4. direct `api_key` — accepted for convenience, but discouraged.

`config.json`, `secrets.json`, and API-key files must not be group/world-accessible. The script fails closed when these permissions are unsafe.

## Container image

The published multi-architecture image is available from Docker Hub:

```text
h5k8/althuntarr:latest
```

Supported architectures are `linux/amd64` and `linux/arm64`.

The image uses `alpine:3.22`, the smallest practical base for this Bash implementation. Installed runtime packages are only:

- Bash;
- GNU coreutils;
- curl;
- jq;
- util-linux for `flock`.

The image:

- accepts standard `PUID`/`PGID` variables, defaults to Unraid `nobody:users` (`99:100`), initializes writable paths as root, then drops privileges with `su-exec`;
- has no exposed ports;
- can use a read-only root filesystem;
- drops all Linux capabilities except the minimal `CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `SETGID`, and `SETUID` set needed to prepare Unraid bind mounts and enter the configured PUID/PGID; the application process itself runs unprivileged;
- uses `no-new-privileges`;
- writes only to `/config` during first-run bootstrap, `/data`, and `/tmp`;
- defaults to a 15-minute internal loop;
- includes a local filesystem health check.

## Quick start with Docker Compose

### 1. Prepare directories and configuration

From the project directory:

```text
mkdir -p config data/state data/logs
cp examples/config.example.json config/config.json
cp .env.example .env
chmod 0600 config/config.json .env
chmod 0700 config data data/state data/logs
```

Edit `config/config.json`:

- set each Sonarr/Radarr base URL, or set `ALTHUNTARR_SONARR_URL` and `ALTHUNTARR_RADARR_URL` in `.env` for the default single instances;
- do not append `/api/v3`;
- keep `general.state_dir` as `/data/state`;
- keep `general.log_dir` as `/data/logs`;
- start with `general.dry_run: true`;
- keep `batch_size: 1` and a conservative hourly cap initially.

Edit `.env` and provide API keys matching each instance's `api_key_env` name. Compose injects these values into the container. Never commit `.env`.

### 2. Pull and start

```text
docker compose pull
docker compose up -d
```

The supplied `compose.yaml` uses `h5k8/althuntarr:latest`. Its `build` block also permits local development with `docker compose up --build -d`.

### 3. Review dry-run output

```text
docker compose logs -f althuntarrrscript
```

To show exact selected candidates, set this in `.env` and recreate the service:

```text
ALTHUNTARR_SHOW_CANDIDATES=true
```

`--show-candidates` also enforces dry-run behavior.

### 4. Enable command submission

Only after validating candidates:

1. set `general.dry_run` to `false` in `config/config.json`;
2. set `ALTHUNTARR_DRY_RUN=false` in `.env`;
3. set `ALTHUNTARR_SHOW_CANDIDATES=false`;
4. recreate the service:

```text
docker compose up -d --force-recreate
```

A valid command response is recorded in state immediately and consumes one hourly command slot. A submitted search is **not** proof that media was found or downloaded.

## Docker commands

Build locally:

```text
docker build -t althuntarrrscript:local .
```

Pull the published image:

```text
docker pull h5k8/althuntarr:latest
```

First run using environment secrets:

```text
docker run --rm \
  --read-only \
  --tmpfs /tmp:size=16m,mode=1777 \
  --cap-drop ALL \
  --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER \
  --cap-add SETGID --cap-add SETUID \
  --security-opt no-new-privileges:true \
  -e PUID=99 -e PGID=100 \
  -e ALTHUNTARR_RUN_ONCE=true \
  -e ALTHUNTARR_DRY_RUN=true \
  -e SONARR_API_KEY='replace-me' \
  -e RADARR_API_KEY='replace-me' \
  -v "$PWD/config:/config" \
  -v "$PWD/data:/data" \
  h5k8/althuntarr:latest
```

If `/config/config.json` is absent and `/config` is writable, the entrypoint copies the bundled example, applies non-empty environment URL and dry-run values, then starts immediately.

Health check only:

```text
docker run --rm \
  -v "$PWD/config:/config" \
  -v "$PWD/data:/data" \
  h5k8/althuntarr:latest healthcheck
```

### Container environment variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `ALTHUNTARR_CONFIG` | `/config/config.json` | Configuration path |
| `ALTHUNTARR_SECRETS` | `/config/secrets.json` | Optional secrets JSON path |
| `ALTHUNTARR_INTERVAL` | `900` | Loop delay in seconds |
| `ALTHUNTARR_RUN_ONCE` | `false` | Run one cycle and exit |
| `ALTHUNTARR_DRY_RUN` | `false` | Force dry-run regardless of configuration |
| `ALTHUNTARR_SHOW_CANDIDATES` | `false` | Print selected candidates and force dry-run |
| `ALTHUNTARR_SONARR_URL` | unset | Override the URL of the single configured Sonarr instance |
| `ALTHUNTARR_RADARR_URL` | unset | Override the URL of the single configured Radarr instance |
| `ALTHUNTARR_APP` | unset | Limit to `sonarr`, `radarr`, or `all` |
| `ALTHUNTARR_INSTANCE` | unset | Limit to one instance name |
| `ALTHUNTARR_MODE` | unset | Limit to `missing`, `upgrade`, or `both` |
| `ALTHUNTARR_LOG_LEVEL` | unset | Override `error`, `warn`, `info`, or `debug` |
| `PUID` | `99` | Runtime user ID; Unraid `nobody` is 99 |
| `PGID` | `100` | Runtime group ID; Unraid `users` is 100 |
| Any configured `api_key_env` | unset | API key for that instance |

## Unraid installation

The Unraid Docker template is **[`unraid/altHuntarrrscript.xml`](unraid/altHuntarrrscript.xml)**. It is an Unraid Docker Manager v2 XML template and exposes Sonarr/Radarr URLs, all configuration paths, masked API keys, dry-run controls, interval, timezone, and `PUID`/`PGID` in the Unraid Add Container GUI.

There is intentionally no application WebUI: this project opens no port and runs no HTTP server. Unraid's Docker GUI remains fully usable for installation, configuration, logs, console access, start/stop, updates, and resource settings; the template's `WebUI` field is therefore empty by design.

The template pulls `h5k8/althuntarr:latest` from Docker Hub.

## Docker Hub publishing workflow

The GitHub Actions workflow at [`.github/workflows/docker-publish.yml`](.github/workflows/docker-publish.yml) validates the project and builds multi-architecture Docker images.

Configure these GitHub repository Actions secrets before running it:

| Secret | Value |
| --- | --- |
| `DOCKERHUB_USERNAME` | Docker Hub user with push access to `h5k8/althuntarr` |
| `DOCKERHUB_TOKEN` | Docker Hub access token with read/write permission; do not use the account password |

Create the Docker Hub repository `h5k8/althuntarr` before the first push. The workflow behavior is:

- pull requests: run checks and build both architectures without pushing;
- pushes to `main`: publish `latest`, `edge`, and `sha-<commit>`;
- tags such as `v1.2.3`: publish `1.2.3`, `1.2`, `1`, and `sha-<commit>`;
- manual `workflow_dispatch`: build and publish a commit tag.

Until both secrets are configured, non-PR runs stay in build-only mode and print an explanatory message instead of failing authentication.

Each image includes OCI metadata, a provenance attestation, and an SBOM. GitHub Actions cache is used for subsequent builds.

### Manual template installation

1. Copy the template into the Unraid templates directory:

   ```text
   /boot/config/plugins/dockerMan/templates-user/my-altHuntarrrscript.xml
   ```

2. In the Unraid web interface, open **Docker → Add Container**.
3. Select `altHuntarrrscript` from the template list.
4. Keep these mappings:
   - `/config` → `/mnt/user/appdata/altHuntarrr/config`;
   - `/data` → `/mnt/user/appdata/altHuntarrr/data`.
5. Enter the Sonarr and Radarr base URLs reachable from this container. Do not append `/api/v3` and do not use `localhost` for other containers.
6. Add the Sonarr and Radarr API keys as masked variables.
7. Keep `PUID=99` and `PGID=100` for standard Unraid `nobody:users`, or change them to the owner of your appdata paths.
8. Leave `ALTHUNTARR_DRY_RUN=true` initially.
9. Apply the template.

On first start, the container creates `/mnt/user/appdata/altHuntarrr/config/config.json`, applies the GUI URL values, and starts immediately. Non-empty URL variables remain authoritative and update `config.json` on subsequent normal starts; clearing a variable stops synchronization but leaves its last URL in the file.

The container environment is the source of truth for the Unraid form: `ALTHUNTARR_SONARR_URL`, `ALTHUNTARR_RADARR_URL`, and `ALTHUNTARR_DRY_RUN` are synchronized into `config.json` at every normal container start. API keys are deliberately **not** written into `config.json`; the default instances reference `SONARR_API_KEY` and `RADARR_API_KEY` and resolve those secrets directly from the environment at runtime.

The two GUI URL fields support the default configuration with one Sonarr and one Radarr instance. For multiple instances of either type, leave that type's URL field blank and manage each URL directly in `config.json`; the container refuses to apply one URL override ambiguously to multiple instances.

Existing Unraid user templates are local copies and may not gain new fields automatically. Download the updated XML again, or add variables named `ALTHUNTARR_SONARR_URL` and `ALTHUNTARR_RADARR_URL` manually in the container editor.

The template uses the repository PNG icon at [`unraid/icon.png`](unraid/icon.png), which Unraid Docker Manager can display reliably.

The template exposes no port and applies:

```text
--read-only --tmpfs /tmp:size=16m,mode=1777 --cap-drop=ALL --cap-add=CHOWN --cap-add=DAC_OVERRIDE --cap-add=FOWNER --cap-add=SETGID --cap-add=SETUID --security-opt=no-new-privileges:true
```

If Sonarr/Radarr run in other Docker containers, use URLs reachable from this container. Options include the Unraid host address and published ports, or a shared custom Docker network with container DNS names.

## Native Linux installation

Container use is recommended on Unraid. Native execution requires:

- Bash 4.3+;
- curl;
- jq;
- util-linux `flock`;
- GNU coreutils (`date`, `mktemp`, `shuf`, `sha256sum`, etc.).

Install the script and prepare state:

```text
install -m 0755 altHuntarrrscript.sh /opt/altHuntarrr/altHuntarrrscript.sh
install -d -m 0700 /var/lib/altHuntarrr/state /var/log/altHuntarrr /etc/altHuntarrr
cp examples/config.example.json /etc/altHuntarrr/config.json
chmod 0600 /etc/altHuntarrr/config.json
```

For native paths, change:

```json
{
  "state_dir": "/var/lib/altHuntarrr/state",
  "log_dir": "/var/log/altHuntarrr"
}
```

Health check:

```text
export SONARR_API_KEY="$(cat /etc/altHuntarrr/sonarr.key)"
export RADARR_API_KEY="$(cat /etc/altHuntarrr/radarr.key)"
/opt/altHuntarrr/altHuntarrrscript.sh \
  --config /etc/altHuntarrr/config.json \
  --health-check
```

Dry-run cycle:

```text
/opt/altHuntarrr/altHuntarrrscript.sh \
  --config /etc/altHuntarrr/config.json \
  --dry-run --show-candidates --json-summary
```

macOS's built-in Bash 3.2 and BSD tools do not satisfy the native runtime requirements. Use the Alpine container for local macOS execution.

## CLI reference

```text
Usage: altHuntarrrscript.sh --config PATH [options]

--config PATH             Configuration file (required)
--secrets PATH            Optional secrets JSON file
--app sonarr|radarr|all   Limit application type
--instance NAME           Limit to one configured instance
--mode missing|upgrade|both
--once                    One cycle and exit (default)
--loop                    Repeat cycles
--interval SECONDS        Loop delay
--dry-run                 Never POST a search command
--health-check            Configuration and connectivity only
--reset-state expired     Remove expired processed history/counters
--reset-state all         Back up and clear all state/counters
--show-candidates         Print selected candidates; forces dry-run
--log-level LEVEL         error|warn|info|debug
--json-summary            Print final JSON summary
--version
--help
```

Dry-run allows GET requests and performs all filtering and selection. It does not POST, write processed state, or consume hourly capacity. When candidates are found, one-shot dry-run exits with code `9` by design.

## Configuration

Use [`examples/config.example.json`](examples/config.example.json) as the reference.

### General settings

| Setting | Meaning |
| --- | --- |
| `state_dir` | Writable persistent state directory |
| `log_dir` | Writable persistent log directory |
| `selection` | `random` or `sequential` |
| `candidate_strategy` | `full`; other strategies are rejected |
| `state_ttl_hours` | Processed-item cooldown; default 168 hours |
| `request_timeout_seconds` | Total HTTP timeout |
| `connect_timeout_seconds` | Connection timeout |
| `retry_count` | GET retry count, 0–10 |
| `retry_delay_seconds` | Base GET retry delay, 0–60 |
| `page_size` | Wanted-page size, 1–1000 |
| `verify_tls` | Preserve certificate verification when true |
| `dry_run` | Configuration-level hard dry-run |
| `log_level` | `error`, `warn`, `info`, or `debug` |

### Instance settings

| Setting | Meaning |
| --- | --- |
| `name` | Unique internal instance key used for state and the optional `--instance` filter; logs and summaries always identify the app as `Sonarr` or `Radarr` |
| `type` | `sonarr` or `radarr` |
| `enabled` | Include the instance |
| `url` | Base URL without `/api/v3` |
| `api_key_env` | Preferred environment-variable secret reference |
| `missing` / `upgrade` | `enabled` plus nonnegative `batch_size` |
| `monitored_only` | Search only monitored media |
| `skip_future` | Require an eligible UTC release/air date |
| `future_release_date` | Radarr: `digital`, `physical`, or `cinema` |
| `hourly_search_cap` | Combined command cap; `-1` unlimited, `0` disabled |
| `max_download_queue_size` | `-1` disabled; otherwise gate at `queue >= value` |
| `queue_error_policy` | Safe default `skip`, or advanced `continue` |

Sonarr selected episodes are grouped by series into `EpisodeSearch` commands. Each command consumes one hourly slot. Radarr submits one `MoviesSearch` command per selected movie.

### `secrets.json`

To use [`examples/secrets.example.json`](examples/secrets.example.json), replace an instance's `api_key_env` with:

```json
"secret_ref": "SONARR"
```

Mount/store the resulting `secrets.json` as mode `0600`. If `/config/secrets.json` exists, the container entrypoint passes it automatically.

## State and logs

`state_dir` contains:

- `processed.jsonl` — operation-specific submitted-media state;
- `hourly-counters.json` — current UTC-hour command counts;
- `altHuntarr.lock` — overlap prevention.

`log_dir` contains:

- `altHuntarr.log` — timestamped activity events;
- `runs.jsonl` — one structured summary per completed cycle.

Each cycle logs `run_started`, a `connection_check_started` and `connection_ok` or `connection_failed` event for Sonarr and Radarr, queue status, candidate-request counts, dry-run/disabled skips, and every submitted search command. Set `ALTHUNTARR_LOG_LEVEL=debug` for sanitized HTTP method, endpoint, status, and retry events; request bodies, response bodies, and API keys are never logged.

State identity includes application type, normalized URL, configured instance name, operation, and item ID. API keys are not included. Configure host-side rotation for `altHuntarr.log` and `runs.jsonl` if long retention is not needed.

## Exit codes

| Code | Meaning |
| ---: | --- |
| 0 | Healthy success, including no candidates |
| 1 | General runtime failure |
| 2 | Invalid arguments |
| 3 | Invalid configuration |
| 4 | Missing dependency |
| 5 | Another execution holds the lock |
| 6 | No selected instance was reachable |
| 7 | Partial instance/operation failure |
| 8 | State read/write failure |
| 9 | Dry-run completed with selected candidates |
| 10 | Security or permissions validation failure |

## Troubleshooting

### Container exits with code 3 on first start

This is expected if no configuration existed. Edit the generated `/config/config.json`, provide matching API-key variables, and restart.

### Configuration permission failure

Set files to owner-only:

```text
chmod 0600 config/config.json config/secrets.json
```

The entrypoint applies `PUID`/`PGID` ownership to `/config` and `/data`, then drops root before running the Bash utility. For Unraid, the defaults are `99:100`; for Compose on another host, set them in `.env` to the bind-mount owner.

### Sonarr/Radarr is unreachable

Confirm the configured URL is reachable **from inside the container**, not only from the host. Do not use `localhost` unless Sonarr/Radarr run in the same container, which is not supported.

### Queue gate keeps skipping

`max_download_queue_size=0` means “skip when anything is queued.” Use `-1` to disable the gate or a positive threshold to allow a bounded queue.

### No candidates

Check monitoring status, dates, state TTL, operation filters, quality cutoffs, and the hourly cap. A healthy no-candidate run exits `0`.

## Development and validation

Install development tools on macOS with Homebrew:

```text
brew install docker docker-compose shellcheck shfmt bats-core colima
colima start --cpu 2 --memory 2 --disk 10
```

Docker Desktop, Colima, or another Docker daemon must be running before image/Compose integration tests. This project was validated locally with Colima.

Run checks:

```text
bash -n altHuntarrrscript.sh
sh -n docker-entrypoint.sh
shellcheck altHuntarrrscript.sh docker-entrypoint.sh
shfmt -d -i 4 altHuntarrrscript.sh
bats tests
docker build -t althuntarrrscript:test .
docker run --rm althuntarrrscript:test /usr/local/bin/altHuntarrrscript.sh --version
docker compose config
```

The Bats suite covers URL normalization, state scoping, filtering, sequential selection, counters, and the dry-run POST guard. Use mock Sonarr/Radarr APIs before the first production command test; do not use a production media stack as the initial integration environment.

## Scope boundaries

Not implemented:

- indexer or download-client management;
- stalled-download repair;
- Sonarr season packs or whole-show mode;
- command polling;
- notifications;
- Lidarr, Readarr, or Whisparr;
- browser UI, HTTP listener, accounts, authentication, requests, or OAuth;
- self-update or telemetry.

The project remains a small orchestrator: it asks Sonarr and Radarr to retry controlled searches and remembers what it recently requested.
