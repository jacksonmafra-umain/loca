# Loca

Local HTTPS domains for macOS. Drop a project folder in, and it gets
`https://projeto1.test` — trusted certificate, wildcard subdomains, proxied to
whatever port it runs on.

It also starts and stops your dev servers, and shows you which process is
holding which port.

```
https://projeto1.test        →  127.0.0.1:2020
https://api.projeto1.test    →  127.0.0.1:2020   (same certificate, no extra setup)
https://projeto2.test        →  127.0.0.1:2021
```

## How it works, in four lines

- **`.test`** is reserved by RFC 6761 and can never resolve publicly, so
  nothing you register here can collide with a real domain. (`.local` collides
  with mDNS; `.dev` is a real gTLD with preloaded HSTS.)
- **A resolver entry** at `/etc/resolver/test` sends every `.test` lookup to a
  DNS responder on `127.0.0.1:53531`, which answers everything with loopback.
  That is why subdomains work at any depth without being registered.
- **A bundled Caddy** holds ports 80 and 443 and reverse-proxies each domain to
  its port, issuing certificates from a local authority. Enabling a domain is a
  config load, not a restart, so open connections survive.
- **One `launchd` agent per project** runs your dev server in your login
  session — which is what gives it your `PATH`, your nvm, and your Keychain.

Only one component runs as root: a helper daemon that binds the two privileged
ports and owns the resolver file. The GUI, the port inspector, and your servers
all run as you.

## Requirements

- macOS 14 or later
- Xcode 26 or later (for the Swift 6 toolchain)
- A code-signing identity. Any Apple Development certificate works:

  ```
  security find-identity -v -p codesigning
  ```

  The build picks the first one it finds. To choose another:

  ```
  make app SIGN_ID="Apple Development: you (XXXXXXXXXX)"
  ```

Loca is **not notarized**. It is signed with a local development certificate
and the source is public, which means you build it yourself. That is a
deliberate trade: notarization is weeks of work that is not the product.

## Build and install

```
make vendor-caddy     # downloads Caddy 2.11.4 and verifies its SHA-256
make app              # assembles and signs build/Loca.app
make install          # copies it to /Applications and launches it
```

`vendor-caddy` pins both the version and the checksum, so your build is
byte-identical to anyone else's. A download that does not match is refused
rather than used.

The app has to live in `/Applications`: `SMAppService` will not register a root
daemon from a folder you can write to without authenticating.

## First run

Three steps, once, in the app's Setup pane. Each one is also a shell command,
if you would rather.

**1. Install the helper.** macOS registers it, then asks you to enable it in
**System Settings › General › Login Items**. It will not start until you do.

```
/Applications/Loca.app/Contents/MacOS/LocaApp --register-helper
```

**2. Install the resolver entry.** This writes `/etc/resolver/test`.

```
/Applications/Loca.app/Contents/MacOS/LocaApp --install-resolver
```

If you already have an `/etc/resolver/test` that Loca did not write, it is
copied to `test.loca-backup-<timestamp>` first and the path reported. Nothing
is overwritten.

**3. Trust the certificate authority.** macOS asks for your password.

```
/Applications/Loca.app/Contents/MacOS/LocaApp --trust-ca
```

Trust goes in **your** keychain, not the System one, so it applies to your user
account rather than the whole machine. That is both the smaller claim and the
only one that works: a daemon cannot obtain the authorization to write System
keychain trust settings, and you cannot write that keychain without root.

Add a domain before this step — the authority does not exist until Caddy has
issued its first certificate.

### Firefox needs one more setting

Firefox does not use the macOS keychain. Until you set this, `.test` sites show
a certificate warning in Firefox while working everywhere else:

1. Open `about:config`
2. Set `security.enterprise_roots.enabled` to `true`

## Adding a domain

Drop a folder onto the Domains pane. Loca reads it and proposes:

| It reads | For |
| --- | --- |
| `.env`, `.env.local` | a `PORT=` line |
| `package.json` | `scripts.dev` or `scripts.start`, and a `--port` flag inside it |
| the lockfile | whether to say `pnpm`, `yarn`, `bun run`, or `npm run` |
| `vite.config.*` | `server.port`, else Vite's default |
| `next.config.*` | Next's default |
| `docker-compose.yml` | the first published port, and `docker compose up` |

It shows you which files each value came from, and cross-checks the port
against what is actually listening — so a guess the machine agrees with is
visibly different from a guess it cannot confirm.

## Troubleshooting

**Something else is on port 80 or 443.** Another Caddy, nginx, Herd, or a
container publishing 443. The helper refuses to start and names the process and
pid rather than failing with a bind error that explains nothing. Check with:

```
/Applications/Loca.app/Contents/MacOS/LocaApp --diagnostics
```

**A domain shows "registered, but nothing is listening".** That is Loca's own
page, not an error: the domain resolves and the proxy is working, but nothing
holds the port yet. Start the project's server.

**The runner will not work for a project in `~/Downloads`.** Or `~/Documents`,
`~/Desktop`, or iCloud Drive. macOS guards those folders, and a `launchd` agent
has no window to show a consent prompt in — so it is never asked and never
granted. It cannot even resolve its own working directory, which shows up in
the log as `getcwd: ... Operation not permitted`. Loca warns when you add such
a folder. Move the project somewhere else, or grant the permission by hand.

**A command that keeps crashing.** launchd relaunches a failing command about
every ten seconds, indefinitely — its throttle is pacing, not protection. Loca
marks the project unstable after three relaunches in a minute and offers to
stop it and turn restarting off. The log says why it is failing.

**Certificate warnings after they were working.** Trust may have been revoked
by hand in Keychain Access. The Setup pane evaluates the certificate rather
than just looking for it, so it will say so — re-trust from there.

**The helper says "version mismatch".** An app update changed the XPC protocol
and the old daemon is still loaded. Reinstall it:

```
/Applications/Loca.app/Contents/MacOS/LocaApp --unregister-helper
/Applications/Loca.app/Contents/MacOS/LocaApp --register-helper
```

**Your old `/etc/hosts` entries.** Loca detects `.local` entries and lists them
during setup, and then leaves them completely alone. `/etc/hosts` is shared
with everything else on the machine, and silently rewriting it is not something
this app should do.

## Uninstall

```
make uninstall
```

That removes the runner agents, the certificate trust, the resolver entry, the
helper's state, and the helper itself — reporting each step, and attempting all
of them even if one fails.

It deliberately leaves your domain list
(`~/Library/Application Support/dev.loca/config.json`), the runner logs
(`~/Library/Logs/dev.loca/`), and your project folders. Then drag
`/Applications/Loca.app` to the Trash.

## Command-line reference

Every setup and troubleshooting step is available without the UI.

| Flag | Does |
| --- | --- |
| `--register-helper` | registers the privileged helper |
| `--unregister-helper` | removes it |
| `--helper-status` | not registered / requires approval / enabled |
| `--bundle-info` | which bundle `SMAppService` is looking at, and what is in it |
| `--diagnostics` | helper version, DNS, resolver, who holds 80 and 443, Caddy |
| `--install-resolver` | writes `/etc/resolver/test` |
| `--remove-resolver` | removes it and restores any backup |
| `--trust-ca` | trusts the local authority in your keychain |
| `--apply-domains slug:port,…` | pushes domains to the proxy without the UI |
| `--start-runner <slug>` | starts a project's server |
| `--stop-runner <slug>` | stops it, tearing down the process group |
| `--runner-status <slug>` | running / stopped / not loaded, with the last exit |
| `--inspect` | the port table, with containers resolved |
| `--uninstall` | reverses everything above |

## Development

```
make test    # the LocaCore test suite, no root and no Caddy needed
make app     # build and sign
make run     # build, sign, and launch from build/
```

The code is three targets:

- **`LocaCore`** — a pure library with every piece of logic worth testing:
  models, validation, Caddyfile and plist generation, the `lsof`, `launchctl`
  and Docker parsers, project detection, and a DNS wire codec. It imports
  nothing but Foundation, so its tests run anywhere without root, a Keychain
  prompt, or a Caddy binary.
- **`LocaHelper`** — the root daemon. XPC gated on a code-signing requirement
  derived from its own signature, the DNS responder, the resolver file, and
  Caddy supervision.
- **`LocaApp`** — the unsandboxed SwiftUI app.

There is no Xcode project. The bundle is assembled by the `Makefile`, which
keeps every step readable and runnable from a shell and leaves nothing in a
binary project file that cannot be reviewed in a diff.

## Licence

MIT.
