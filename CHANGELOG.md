# Changelog

All notable changes to Loca are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

While the version stays below `1.0.0` the public surface — the XPC protocol, the
`config.json` schema, and the command-line flags — may change between minor
releases. `1.0.0` marks the point where the design document's scope is complete.

## [Unreleased]

### Added

- Bundled Caddy 2.11.4, pinned by version and by SHA-256 for both
  architectures, downloaded by `make vendor-caddy` and signed during bundling.
  The tarball is checksummed on download and deleted afterwards, so an
  unexpected binary is refused before it can be signed into the bundle.
- `CaddySupervisor`, which runs the bundled Caddy and applies domain changes as
  a config load on the admin API rather than a restart, so open connections
  survive. It probes `:80` and `:443` before launching and refuses with the name
  and pid of whoever holds them, and restarts an unexpected exit with
  exponential backoff capped at 30 seconds.
- `--apply-domains slug:port` and `--trust-ca` on the app binary.

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

[Unreleased]: https://github.com/jacksonmafra-umain/loca/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/jacksonmafra-umain/loca/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/jacksonmafra-umain/loca/releases/tag/v0.1.0
