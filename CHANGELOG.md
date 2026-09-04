# Changelog

All notable changes to Loca are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The public surface is the XPC protocol, the `config.json` schema, and the
command-line flags. It changed freely below `1.0.0`; from `1.0.0` on, a
breaking change to any of the three means a major version.

## [Unreleased]

### Added

- Detection of a project folder that moved or was deleted, with a badge on the
  row, a count in the banner, and an offer to locate it again. The domain keeps
  working — the proxy only needs a port — so nothing else on screen would hint
  at it.
- The runner now refuses to start when the folder is gone, naming the path.
  Starting anyway produced a working-directory failure in the log that named
  the symptom rather than the cause, and restart-on-crash then retried it every
  ten seconds indefinitely.

## [1.0.0] — 2026-09-04

The design document's scope is complete. Everything it set out to build works,
and the public surface — the XPC protocol, the `config.json` schema, and the
command-line flags — is now stable under semantic versioning.

### Added

- A menu bar item with a status marker and a submenu per project: open the
  address, enable or disable the domain, and start, stop, or restart the
  server. This is what makes closing the window sensible — with a way back and
  the actions a click away, the window becomes one view of the app rather than
  the app itself.
- `make uninstall`, which reverses everything Loca installed: runner agents
  first (one left loaded would keep a server running with nothing to stop it),
  then certificate trust, then the helper's state, then the daemon. Every step
  is attempted even after an earlier one fails, and each is reported. It
  deliberately leaves the domain list, the runner logs, and the project
  folders.
- A README covering the design, the build and signing steps, the three
  first-run steps with a shell equivalent for each, how domain detection
  works, and troubleshooting for every failure mode the design document
  enumerates.

### Fixed

- The window's close, minimise, and zoom buttons clipped the top of every pane.
  The title bar is now hidden, which is what the layout wanted, and each pane
  starts below a shared inset.

## [0.6.0] — 2026-09-04

You can see which process is holding which port, containers included.

### Added

- The port inspector: every listening TCP port with the process that owns it,
  polled every two seconds while the tab is visible and not at all otherwise.
  Docker-published ports are resolved to their container name and image
  through the Docker socket, which is the whole point — under `lsof` they all
  belong to `com.docker.backend` with one shared pid. Degrades silently on a
  machine without Docker.
- The domain column, cross-referencing each port with the registered projects,
  and row actions: open, reveal the working folder, copy the pid, create a
  domain for this port, and stop the process (SIGTERM, then SIGKILL five
  seconds later, behind a confirmation).
- `--inspect` on the app binary, which prints the same table.

## [0.5.0] — 2026-09-04

Loca starts and stops your dev servers.

### Added

- The project runner: one `launchd` agent per project in `gui/$UID`, with
  start, stop, restart, start-at-login, restart-on-crash, and a live log tail.
  Stop is `bootout`, which tears down the whole process group — killing the
  parent alone routinely leaves a child holding the port.
- Crash-loop detection. A broken command with restart-on-crash relaunches about
  every ten seconds forever, which is launchd's throttle rather than
  protection; three relaunches within a minute marks the project unstable and
  offers the one action that ends it.
- A warning when a project folder sits inside `~/Downloads`, `~/Documents`,
  `~/Desktop`, or iCloud Drive. macOS guards those, and a `launchd` agent has
  no window to show a consent prompt in, so it cannot even resolve its own
  working directory there. A warning and never a rejection.
- `--start-runner`, `--stop-runner`, and `--runner-status` on the app binary,
  which look the project up in the saved config so a runner started from a
  shell uses exactly the command the UI would.

## [0.4.0] — 2026-09-04

There is a window.

### Added

- The main window: a list of registered domains with enable toggles, port
  conflict badges, and a detail pane; a folder-drop add sheet that shows which
  files each proposed value came from and cross-checks the port against what is
  actually listening; and a setup pane gating helper, resolver, and certificate
  trust.
- A five-colour palette with semantic roles, resolved per appearance so the
  window follows the system rather than committing to one look. Layout is a
  recessed navigation column, a content pane of cards, and a bottom action bar
  with one primary action.
- Both warnings the design document insists on, in the setup pane: Firefox
  keeps its own trust store and needs `security.enterprise_roots.enabled`, and
  any `.local` entries in `/etc/hosts` are listed with a plain statement that
  Loca will not touch them.

### Fixed

- The app crashed on launch with a dispatch assertion. A `mapValues` closure
  written inline inside a `@MainActor` type inherited that isolation, so Swift
  inserted an isolation check into it — and XPC delivers reply blocks on a
  background queue, where the check fails. It compiled cleanly and died at
  runtime.

## [0.3.0] — 2026-09-04

Trusted HTTPS. `https://<slug>.test` works in the browser, wildcard subdomains
included.

### Added

- Bundled Caddy 2.11.4, pinned by version and by SHA-256 for both
  architectures, downloaded by `make vendor-caddy` and signed during bundling.
  The tarball is checksummed on download and deleted afterwards, so an
  unexpected binary is refused before it can be signed into the bundle.
- `CaddySupervisor`. Domain changes are applied as a config load on the admin
  API rather than a restart, so open connections survive — enabling a domain
  must not interrupt a download or a websocket someone is using. It probes
  `:80` and `:443` before launching and refuses with the name and pid of
  whoever holds them, because Caddy's own bind error names nothing, and it
  restarts an unexpected exit with exponential backoff capped at 30 seconds.
- Certificates for the apex and the wildcard from Caddy's internal CA, issued
  from one site block so subdomains work with no further configuration.
- A `handle_errors` page that names the domain and the port when nothing is
  listening upstream, instead of a bare 502.
- Trust for Caddy's root certificate, installed in the user's keychain by the
  app. The helper exports the certificate and the app installs and evaluates
  the trust, because neither can do both: a daemon cannot obtain the
  authorization to write System keychain trust settings, and the user cannot
  write that keychain at all. Scoping trust to one user rather than the whole
  machine is also the smaller and more appropriate claim for a development
  tool.
- `--apply-domains slug:port` and `--trust-ca` on the app binary.

### Changed

- **XPC protocol version 2.** `trustCertificateAuthority` and
  `certificateAuthorityIsTrusted` are replaced by `certificateAuthorityRoot`.
  The helper can neither install user-domain trust nor observe it, so
  diagnostics now report `caRootIssued` and leave the trust verdict to the app.
- Caddy runs with `HOME`, `XDG_DATA_HOME`, and `XDG_CONFIG_HOME` pointing at
  the helper-owned data directory. A launchd daemon has no `HOME`, and Caddy
  otherwise warns that assets will land relative to a working directory of `/`.

## [0.2.0] — 2026-09-04

The privileged helper. `.test` names resolve on this machine.

### Added

- `LocaHelper`, a root LaunchDaemon installed through `SMAppService`. It is the
  only privileged component.
- A DNS responder on `127.0.0.1:53531`, over UDP and TCP, answering `A` with
  `127.0.0.1`, `AAAA` with `::1`, and anything else with an empty `NOERROR` —
  never `NXDOMAIN`, which would let the resolver fall through to another
  nameserver. Listeners re-arm with backoff after a failure or an unrequested
  cancellation, which is what covers sleep and wake.
- `/etc/resolver/test` management. A pre-existing file that Loca did not write
  is moved to a timestamped backup and the path reported, never overwritten;
  removal unlinks only a file Loca's own marker claims, then restores the most
  recent backup.
- An XPC surface gated on `NSXPCConnection.setCodeSigningRequirement`, with the
  requirement derived from the helper's own signature — "signed by whoever
  signed me". It fails closed: an unsigned build establishes no team, so it
  refuses every client.
- Diagnostics that name the process holding `:80` and `:443`, rather than
  reporting a boolean.
- A `Makefile` that assembles and signs `Loca.app` with no Xcode project, and
  command-line flags on the app binary — `--register-helper`,
  `--unregister-helper`, `--helper-status`, `--bundle-info`,
  `--install-resolver`, `--remove-resolver`, `--diagnostics` — which make every
  install and verification step a shell command.

### Fixed

- The DNS listener bound an ephemeral port while reporting the one it had been
  asked for. `requiredLocalEndpoint` does not bind an `NWListener`'s port; the
  port now goes to the initializer and the log prints `listener.port`.
- A UDP reply was dropped because the flow was cancelled straight after
  `send(completion: .idempotent)`, which is asynchronous. The cancel now waits
  for `.contentProcessed`.

## [0.1.0] — 2026-09-04

`LocaCore`: everything worth testing, with no UI and nothing privileged. 171
tests, runnable on any machine without root, a Keychain prompt, or a Caddy
binary.

### Added

- `Project`, `Runner`, and `LocaConfig`, with the folder stored as a plain path
  so `config.json` stays readable. Derived state — pid, port occupancy, run
  status — is deliberately absent and recomputed by polling.
- Slug derivation and validation: lowercase, kebab-case, diacritics folded,
  uniqueness, and the 63-character DNS label limit.
- Validation of slug, port range, and folder path, with the folder gate on the
  path string because that is where an untrusted value actually arrives.
- An atomic config store: temporary file plus rename, with a version gate that
  refuses a file written by a newer build rather than misreading it.
- Caddyfile generation — enabled projects only, in slug order, apex and
  wildcard sharing one site block, with a `handle_errors` page that names the
  domain and port instead of serving a bare 502.
- launchd agent plist generation, running the command through `/bin/zsh -lc` so
  nvm and `PATH` resolve.
- Parsers for `lsof` listening sockets, `launchctl print` status, and the Docker
  `/containers/json` response, each tested against captured real output.
- Project detection from `.env`, `package.json`, Vite and Next configs, and
  compose files, reporting which file each proposed value came from.
- A DNS wire codec with TCP length framing, which throws on every malformed
  input rather than trapping.
- Crash-loop detection: three restarts within 60 seconds marks a runner
  unstable.

[Unreleased]: https://github.com/jacksonmafra-umain/loca/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/jacksonmafra-umain/loca/compare/v0.6.0...v1.0.0
[0.6.0]: https://github.com/jacksonmafra-umain/loca/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/jacksonmafra-umain/loca/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/jacksonmafra-umain/loca/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/jacksonmafra-umain/loca/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/jacksonmafra-umain/loca/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/jacksonmafra-umain/loca/releases/tag/v0.1.0
