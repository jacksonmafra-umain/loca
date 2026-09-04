# Loca — Local HTTPS Domains for macOS

Design document. Date: 2026-09-04. Status: approved, pending implementation plan.

## Problem

Several projects run locally on different ports (`127.0.0.1:2020`, `:2021`, `:2022`).
Reaching them means remembering port numbers, and none of them have HTTPS, so any
browser feature gated behind a secure context is unavailable. The current workaround is
hand-edited `/etc/hosts` entries under a `.local` TLD, which collides with mDNS/Bonjour
and gives no TLS and no wildcard subdomains.

Goal: `https://projeto1.test`, `https://projeto2.test`, `https://projeto3.test` — each
proxied to its own local port, with trusted certificates, managed from a native macOS
GUI. The same GUI starts and stops the project servers and shows which processes hold
which ports.

## Scope

In scope:

- Register a project as folder + port + domain slug.
- Enable or disable each domain without restarting the proxy.
- Trusted HTTPS for every domain, including wildcard subdomains.
- Start and stop each project's dev server from the GUI, with optional autostart at login.
- Live list of listening TCP ports with the owning process, including Docker containers.

Out of scope:

- Publicly resolvable domains and public certificates (a `.test` TLD cannot have them).
- Sharing configuration through the project repository (a versioned `.loca.json`) —
  considered and deferred.
- Notarized distribution, DMG packaging, and auto-update. The app is signed with a local
  Development certificate; the source is public and third parties build it themselves.
- Managing the pre-existing hand-written `/etc/hosts` entries. The app warns about them
  once and does not touch them.

## Decisions

| Decision | Choice | Reason |
| --- | --- | --- |
| GUI stack | SwiftUI, menu bar item plus main window | `SMAppService`, Keychain trust, and process inspection are all first-party APIs; no extra runtime |
| TLD | `.test` | Reserved by RFC 6761, never resolvable publicly, no collision. `.dev` is a real gTLD with preloaded HSTS and `.local` collides with mDNS |
| TLS and proxy | Bundled Caddy binary | `tls internal` issues per-domain certificates from a local CA, and `caddy trust` installs it. WebSocket, SSE, and HTTP/2 work out of the box, which Vite HMR and Next dev require |
| DNS | Minimal DNS responder inside the privileged helper | `/etc/resolver/test` accepts a custom port, so no privileged port and no second bundled binary. Wildcard resolution is free |
| Project supervision | One `launchd` agent per project | launchd provides supervision, crash restart, and autostart natively, and `bootout` kills the whole process group |
| Port inspector | Read plus actions, Docker-aware | Published container ports all appear as `com.docker.backend` under `lsof`; container names require the Docker socket |
| Folder role | Source of detection | The app proposes port and command by reading the project's own files instead of asking for them |
| Distribution | Development-signed, source public | Notarization is weeks of work that is not the product |

## Architecture

```
LocaApp (SwiftUI, user session)        menu bar + window. Nothing privileged.
   | XPC
LocaHelper (launchd daemon, root)      the only privileged component, installed via SMAppService
   |-- DNS responder on 127.0.0.1:53531 (in-process, Network.framework)
   |       A -> 127.0.0.1, AAAA -> ::1, anything else -> empty NOERROR
   |-- /etc/resolver/test               (writes and removes)
   |-- Caddy (bundled binary)           supervised child, binds :80 and :443
   \-- Caddy root CA in the System keychain (installs and removes)

launchd agents, one per project         not children of the app or the helper
   ~/Library/LaunchAgents/dev.loca.run.<slug>.plist  in domain gui/$UID
```

### One privileged component

Ports below 1024 require root on macOS, so Caddy runs under the helper. Everything else —
GUI, port inspector, project servers — runs as the logged-in user. Killing the user's own
process needs no privilege; the inspector escalates to the helper only when the target
process belongs to another uid.

### Reload without restart

Caddy runs with its admin API bound to `127.0.0.1:2019`. Enabling or disabling a domain is
a config POST rather than a restart, so open connections survive. Only the helper talks to
the admin API.

### Project servers live in the user domain

Dev servers need the graphical session, the login environment, and the user's Keychain. An
agent in `gui/$UID` has all three; a root daemon has none of them. It is also what makes
`RunAtLoad` mean "at my login".

### The helper trusts nobody

The helper validates the caller's code signature through the XPC audit token, and never
reads the user-writable `config.json` as root. Configuration arrives over XPC field by
field and is validated: slug charset, port range 1-65535, folder path with no traversal.
Without this, any local process could ask a root daemon to write `/etc/resolver` and proxy
arbitrary domains.

### Testable core

All logic lives in a pure `LocaCore` Swift package: models, Caddyfile generation, plist
generation, `lsof` parsing, project detection, DNS packet codec. The helper and the GUI are
thin shells over it. This is what keeps the test suite runnable without root or Keychain
access.

## Data model

```swift
struct Project: Codable, Identifiable {
  let id: UUID
  var slug: String        // "projeto1" -> projeto1.test
  var folder: URL
  var port: Int
  var enabled: Bool       // domain active in the proxy
  var runner: Runner?     // nil means the user starts the server themselves
}

struct Runner: Codable {
  var command: String     // "pnpm dev"
  var autoStart: Bool     // RunAtLoad
  var keepAlive: Bool     // restart on crash
}
```

Stored at `~/Library/Application Support/dev.loca/config.json`, written atomically
(temporary file plus rename), carrying a `version` field for migration.

Derived state — PID, port occupancy, run status, health — is never persisted. It is
recomputed by polling.

## Flows

### Registering a domain

1. The user drops a folder onto the window. The slug is derived from the folder name
   (lowercased, kebab-cased, made unique).
2. The detector reads `package.json` scripts, `docker-compose.yml`, `.env` (`PORT=`),
   `vite.config.*`, and `next.config.*`, and proposes a port and a command.
3. The proposal is cross-checked against the inspector: if the port is already listening,
   the owning process is shown, confirming the guess before saving.
4. Saving sends the configuration over XPC. The helper rewrites the Caddyfile — one site
   block per enabled domain, addressed as `projeto1.test, *.projeto1.test` so subdomains
   share the block, with `tls internal` — and POSTs a reload. The internal CA issues the
   wildcard certificate alongside the apex one.
5. On the very first run, the helper installs the Caddy root CA into the System keychain.
   This is one authentication prompt, once.

### Play, stop, autostart

- Play writes `~/Library/LaunchAgents/dev.loca.run.<slug>.plist` and runs
  `launchctl bootstrap gui/$UID <plist>`, or `launchctl kickstart -k` when already loaded.
- `ProgramArguments` is `/bin/zsh -lc "<command>"`. The login shell is what resolves nvm
  and `PATH`; a GUI-spawned process inherits neither.
- `WorkingDirectory` is the project folder. Standard output and error go to
  `~/Library/Logs/dev.loca/<slug>.log`.
- `keepAlive` maps to `KeepAlive: {SuccessfulExit: false}`; `autoStart` maps to
  `RunAtLoad: true`.
- Stop is `launchctl bootout`, which tears down the entire process group. This is what
  prevents the orphaned child that keeps holding the port after its parent is killed.
- Status comes from `launchctl print gui/$UID/dev.loca.run.<slug>`, which yields the PID
  and the last exit status. The detail panel tails the log file.

### Port inspector

- `lsof -nP -iTCP -sTCP:LISTEN` polled every 2 seconds while the tab is visible, and not
  polled at all when it is hidden.
- Docker resolution through `GET /containers/json` on `/var/run/docker.sock`, mapping
  published ports to container name and image. Degrades silently when the socket is absent.
- Ports are cross-referenced with `Project.port` to fill in the domain column.
- Actions: reveal the folder, create a domain for this port, and kill the process
  (SIGTERM, then SIGKILL after 5 seconds, behind a confirmation).

## Failure modes

- **Port 80 or 443 already bound** by another Caddy, nginx, a container publishing 443, or
  Herd. The helper detects this at startup and reports which process holds the port. A
  silent failure here costs an afternoon.
- **A pre-existing `/etc/resolver/test`** is never overwritten blindly: it is detected,
  backed up, and reported.
- **Firefox ignores the System keychain.** It keeps its own trust store, so the Caddy CA is
  untrusted there until `security.enterprise_roots.enabled` is set. Onboarding must say so,
  otherwise it reads as an app bug.
- **Runner crash loop.** A broken command plus `KeepAlive` makes launchd restart forever;
  its 10-second throttle is not enough protection. The app counts restarts (3 within 60
  seconds), marks the project unstable, and offers to disable the runner.
- **Nothing listening upstream.** Caddy's `handle_errors` serves a page saying the domain
  is registered but no process is listening on the port, with a play action.
- Folder moved or deleted; duplicate slug rejected at save; two projects on the same port
  allowed but flagged; CA trust revoked by hand, detected and offered for reinstall; helper
  version skew handled by an XPC version handshake; Caddy exiting restarted with
  exponential backoff; the DNS listener re-armed after sleep and wake.

## Testing

Runnable anywhere, against `LocaCore`:

- Snapshot tests for generated Caddyfile and generated launchd plist.
- Fixture project folders (Next, Vite, Compose, bare `.env`) mapped to the expected
  detected port and command.
- Fixture `lsof` output mapped to expected inspector rows.
- DNS packet encode and decode round-trip, including the TCP fallback path.
- An unsigned XPC client must be rejected.

Local only, run by hand:

- `dig @127.0.0.1 -p 53531 anything.projeto1.test` answers `127.0.0.1`.
- `curl -sI https://projeto1.test` returns a response with a trusted certificate.

## Milestones

Each milestone is useful on its own.

| # | Deliverable | Verification |
| --- | --- | --- |
| 0 | `LocaCore` package, no UI | `swift test` passes |
| 1 | Helper, XPC, DNS responder, `/etc/resolver` | `dig` answers `127.0.0.1` |
| 2 | Bundled Caddy, config reload, CA trust | `curl https://x.test` returns 200 |
| 3 | SwiftUI window: list, add, enable, disable | a domain toggles from the UI |
| 4 | Runner: play, stop, autostart, logs | a server starts from the UI and survives app quit |
| 5 | Inspector: `lsof`, Docker, actions | the list distinguishes node from a container |
| 6 | Menu bar item, README with build and signing steps | a third party clones and builds |

The name `Loca` and the bundle identifier `dev.loca` are placeholders.
