# Loca — Local HTTPS Domains Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a macOS app that maps `https://<slug>.test` to a local port with trusted TLS, starts and stops each project's dev server, and shows which processes hold which ports.

**Architecture:** One SwiftPM package with three targets. `LocaCore` is a pure library holding every piece of logic worth testing (models, Caddyfile and plist generation, `lsof` and `launchctl` parsing, project detection, DNS packet codec, validation). `LocaHelper` is a root launchd daemon — the only privileged component — exposing a validated XPC surface, answering DNS on `127.0.0.1:53531`, owning `/etc/resolver/test`, and supervising a bundled Caddy. `LocaApp` is an unsandboxed SwiftUI app (menu bar item plus window) that talks to the helper over XPC and manages one `launchd` agent per project in `gui/$UID`. A `Makefile` assembles and codesigns `Loca.app`, so the whole build is CLI-driven and reproducible by a third party.

**Tech Stack:** Swift 6.3, SwiftPM, SwiftUI, Network.framework (DNS listener), NSXPCConnection, ServiceManagement (`SMAppService`), Security.framework (code-signature validation, keychain trust), Caddy 2 (bundled binary, admin API on `127.0.0.1:2019`), `launchctl`, `lsof`, Docker Engine API over `/var/run/docker.sock`.

**Spec:** `docs/superpowers/specs/2026-09-04-loca-local-domains-design.md`

**Repository:** `https://github.com/jacksonmafra-umain/loca` — public. One GitHub issue per milestone, one branch and one pull request per milestone, targeting `main`. `main` is never committed to directly and never merged into locally; every merge happens through a reviewed pull request. All issues and pull requests carry labels and are assigned to `jacksonmafra-umain`.

## Global Constraints

- TLD is `.test`, verbatim. Never `.local`, never `.dev`.
- Bundle identifier prefix `dev.loca`. Helper mach service `dev.loca.helper`. Runner agent labels `dev.loca.run.<slug>`.
- DNS responder binds `127.0.0.1:53531` only. Never a privileged port.
- Caddy admin API on `127.0.0.1:2019`. Only the helper may talk to it.
- Config lives at `~/Library/Application Support/dev.loca/config.json`, written atomically (temp file plus rename), carrying a `version` field.
- Runner logs live at `~/Library/Logs/dev.loca/<slug>.log`.
- Runner agent plists live at `~/Library/LaunchAgents/dev.loca.run.<slug>.plist`, bootstrapped into `gui/$UID`.
- Derived state (PID, port occupancy, run status, health) is never persisted.
- The helper never reads the user-writable `config.json`. Configuration arrives over XPC field by field and is validated: slug charset, port range 1–65535, folder path with no traversal.
- `LocaCore` must not import ServiceManagement, Security, Network, or SwiftUI. It must compile and test on any machine without root.
- App is unsandboxed (it shells out to `lsof`, `launchctl`, and reads the Docker socket).
- Signed with `Apple Development: Jackson Mafra (6L9VF66ZX7)`. No notarization, no DMG, no auto-update.
- Every commit is a microcommit: one focused change, self-contained, buildable, written in English, with no assistant attribution.
- Deployment target macOS 14.0 (`SMAppService.daemon` needs 13.0; 14.0 buys current SwiftUI).

---

## File Structure

```
Package.swift                          SwiftPM manifest, three targets plus test target
Makefile                               app bundle assembly, codesign, caddy vendoring
README.md                              build, sign, install, uninstall, Firefox caveat
.gitignore                             .build, vendor/caddy, *.app

Sources/LocaCore/
  Models.swift                         Project, Runner, LocaConfig
  Slug.swift                           slugify, uniqueSlug, isValidSlug
  Validation.swift                     ValidationError, ProjectDraft validation
  Paths.swift                          every well-known path, injectable roots
  ConfigStore.swift                    atomic load/save of LocaConfig
  CaddyfileBuilder.swift               [Project] -> Caddyfile text
  LaunchAgentPlist.swift               Project + Runner -> plist XML
  LaunchctlStatus.swift                parse `launchctl print` output
  RestartTracker.swift                 crash-loop detection, 3 restarts in 60s
  LsofParser.swift                     parse `lsof -nP -iTCP -sTCP:LISTEN`
  DockerPortMapper.swift               Docker /containers/json JSON -> port owners
  ProjectDetector.swift                folder -> proposed port and command
  DNSMessage.swift                     DNS wire-format decode and encode
  DNSResponder.swift                   pure request -> response policy
  ResolverFile.swift                   /etc/resolver/test content
  HelperProtocol.swift                 @objc XPC protocol, shared by helper and app
  CaddyAdmin.swift                     admin API request description, no networking

Sources/LocaHelper/
  main.swift                           daemon entry, signal handling, run loop
  XPCListener.swift                    NSXPCListener, audit-token code-signature check
  HelperService.swift                  HelperProtocol implementation
  DNSListener.swift                    Network.framework UDP + TCP on 127.0.0.1:53531
  ResolverInstaller.swift              write, back up, remove /etc/resolver/test
  CaddySupervisor.swift                spawn, restart with backoff, reload via admin API
  CATrust.swift                        install and verify Caddy root CA in System keychain
  PortProbe.swift                      is :80 / :443 already bound, and by whom

Sources/LocaApp/
  LocaAppMain.swift                    @main App, menu bar extra plus window
  HelperClient.swift                   XPC client, version handshake, SMAppService install
  AppStore.swift                       observable app state, owns LocaConfig
  RunnerController.swift               launchctl bootstrap/bootout/kickstart/print
  InspectorController.swift            lsof polling plus Docker enrichment
  DockerSocketClient.swift             HTTP over unix socket
  LogTailer.swift                      tail the runner log file
  Views/ProjectListView.swift          list, toggle, add via drop
  Views/ProjectDetailView.swift        detail, runner controls, log tail
  Views/AddProjectSheet.swift          folder drop, detection proposal, conflict warning
  Views/InspectorView.swift            port table, actions
  Views/OnboardingView.swift           helper install, CA trust, Firefox and hosts warnings
  Views/MenuBarView.swift              menu bar content

Resources/
  dev.loca.helper.plist                embedded LaunchDaemon plist
  LocaApp.entitlements                 app entitlements
  Info.plist                           app Info.plist

Tests/LocaCoreTests/
  SlugTests.swift  ValidationTests.swift  ConfigStoreTests.swift
  CaddyfileBuilderTests.swift  LaunchAgentPlistTests.swift
  LaunchctlStatusTests.swift  RestartTrackerTests.swift
  LsofParserTests.swift  DockerPortMapperTests.swift
  ProjectDetectorTests.swift  DNSMessageTests.swift  DNSResponderTests.swift
  ResolverFileTests.swift
  Fixtures/                            lsof output, launchctl output, docker JSON,
                                       and project folders: next/, vite/, compose/, dotenv/
```

---

# Milestone 0 — `LocaCore`

GitHub issue: "Milestone 0 — LocaCore: pure, testable logic". Branch `feat/m0-locacore`. Verification: `swift test` passes.

### Task 0.1: Package skeleton

**Files:**
- Create: `Package.swift`, `.gitignore`, `Sources/LocaCore/LocaCore.swift`, `Tests/LocaCoreTests/SmokeTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: module `LocaCore`, test target `LocaCoreTests`, `public enum LocaCoreVersion { public static let current = 1 }`.

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Loca",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LocaCore", targets: ["LocaCore"]),
        .executable(name: "LocaHelper", targets: ["LocaHelper"]),
        .executable(name: "LocaApp", targets: ["LocaApp"]),
    ],
    targets: [
        .target(name: "LocaCore"),
        .executableTarget(name: "LocaHelper", dependencies: ["LocaCore"]),
        .executableTarget(name: "LocaApp", dependencies: ["LocaCore"]),
        .testTarget(name: "LocaCoreTests", dependencies: ["LocaCore"], resources: [.copy("Fixtures")]),
    ]
)
```

The `LocaHelper` and `LocaApp` targets are declared now and filled in later milestones; each needs a placeholder `main.swift` so the package resolves.

- [ ] **Step 2: Write the smoke test, run it, see it fail, implement `LocaCoreVersion`, run it again**

Run: `swift test 2>&1 | tail -5`. Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "chore: scaffold SwiftPM package with LocaCore, helper, and app targets"
```

### Task 0.2: Models

**Files:**
- Create: `Sources/LocaCore/Models.swift`, `Tests/LocaCoreTests/ModelsTests.swift`

**Interfaces:**
- Produces:

```swift
public struct Runner: Codable, Hashable, Sendable {
    public var command: String
    public var autoStart: Bool
    public var keepAlive: Bool
    public init(command: String, autoStart: Bool = false, keepAlive: Bool = true)
}

public struct Project: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var slug: String
    public var folder: URL
    public var port: Int
    public var enabled: Bool
    public var runner: Runner?
    public init(id: UUID = UUID(), slug: String, folder: URL, port: Int, enabled: Bool = true, runner: Runner? = nil)
    public var domain: String { "\(slug).test" }
    public var wildcardDomain: String { "*.\(slug).test" }
    public var agentLabel: String { "dev.loca.run.\(slug)" }
}

public struct LocaConfig: Codable, Hashable, Sendable {
    public static let currentVersion = 1
    public var version: Int
    public var projects: [Project]
    public init(version: Int = LocaConfig.currentVersion, projects: [Project] = [])
}
```

- [ ] **Step 1: Write the round-trip and derived-property tests**

```swift
@Test func projectRoundTripsThroughJSON() throws {
    let project = Project(slug: "projeto1", folder: URL(filePath: "/tmp/p1"), port: 2020,
                          runner: Runner(command: "pnpm dev", autoStart: true, keepAlive: true))
    let data = try JSONEncoder().encode(project)
    let decoded = try JSONDecoder().decode(Project.self, from: data)
    #expect(decoded == project)
}

@Test func derivedNamesFollowTheSpec() {
    let project = Project(slug: "projeto1", folder: URL(filePath: "/tmp/p1"), port: 2020)
    #expect(project.domain == "projeto1.test")
    #expect(project.wildcardDomain == "*.projeto1.test")
    #expect(project.agentLabel == "dev.loca.run.projeto1")
}

@Test func configDefaultsToCurrentVersion() {
    #expect(LocaConfig().version == 1)
}
```

- [ ] **Step 2: Run, see it fail; implement `Models.swift`; run again — PASS**
- [ ] **Step 3: Commit** — `feat: add Project, Runner, and LocaConfig models`

### Task 0.3: Slug derivation

**Files:**
- Create: `Sources/LocaCore/Slug.swift`, `Tests/LocaCoreTests/SlugTests.swift`

**Interfaces:**
- Produces:

```swift
public enum Slug {
    public static func slugify(_ raw: String) -> String
    public static func isValid(_ slug: String) -> Bool
    public static func unique(_ candidate: String, taken: Set<String>) -> String
}
```

Rules: lowercase, kebab-case, ASCII letters/digits/hyphen only, diacritics folded, runs of invalid characters collapse to a single hyphen, leading and trailing hyphens trimmed, empty result becomes `"project"`, `unique` appends `-2`, `-3`, … until free.

- [ ] **Step 1: Write the tests**

```swift
@Test(arguments: [
    ("Projeto 1", "projeto-1"), ("My_App", "my-app"), ("São Paulo", "sao-paulo"),
    ("  --weird--  ", "weird"), ("", "project"), ("...", "project"), ("ALLCAPS", "allcaps"),
])
func slugifyNormalizes(input: String, expected: String) {
    #expect(Slug.slugify(input) == expected)
}

@Test func uniqueAppendsCounter() {
    #expect(Slug.unique("api", taken: []) == "api")
    #expect(Slug.unique("api", taken: ["api"]) == "api-2")
    #expect(Slug.unique("api", taken: ["api", "api-2"]) == "api-3")
}

@Test func isValidRejectsWhatSlugifyWouldChange() {
    #expect(Slug.isValid("projeto-1"))
    #expect(!Slug.isValid("Projeto"))
    #expect(!Slug.isValid("pro jeto"))
    #expect(!Slug.isValid("-x"))
    #expect(!Slug.isValid(""))
}
```

- [ ] **Step 2: Run, fail, implement, run — PASS**
- [ ] **Step 3: Commit** — `feat: derive and validate domain slugs`

### Task 0.4: Validation

**Files:**
- Create: `Sources/LocaCore/Validation.swift`, `Tests/LocaCoreTests/ValidationTests.swift`

**Interfaces:**
- Produces:

```swift
public enum ValidationError: Error, Equatable, Sendable {
    case invalidSlug(String)
    case duplicateSlug(String)
    case portOutOfRange(Int)
    case folderNotAbsolute(String)
    case folderTraversal(String)
}

public enum Validation {
    public static let portRange = 1...65535
    public static func validate(slug: String, port: Int, folder: URL, existing: [Project],
                                ignoring id: UUID? = nil) throws
    public static func validateFolder(_ folder: URL) throws
    public static func validateFolderPath(_ path: String) throws
}
```

The real gate is `validateFolderPath`, on the string. `URL(filePath:)` resolves a relative path against the current directory, so by the time a folder is a URL it is always absolute — but a folder arriving over XPC is a raw string, and that is exactly where a relative or traversing path has to be refused. `validateFolder` delegates to it.

It rejects relative paths and any path whose components contain `..`. Port must be `1...65535`. Duplicate slug is rejected; two projects on the same port are allowed (the UI flags them, the model does not reject them).

- [ ] **Step 1: Write the tests**

```swift
private let anywhere = URL(filePath: "/Users/me/code/app")

@Test func acceptsAValidTriple() throws {
    try Validation.validate(slug: "app", port: 3000, folder: anywhere, existing: [])
}

@Test func rejectsPortOutOfRange() {
    #expect(throws: ValidationError.portOutOfRange(0)) {
        try Validation.validate(slug: "app", port: 0, folder: anywhere, existing: [])
    }
    #expect(throws: ValidationError.portOutOfRange(65536)) {
        try Validation.validate(slug: "app", port: 65536, folder: anywhere, existing: [])
    }
}

@Test func rejectsTraversalAndRelativePaths() {
    #expect(throws: ValidationError.folderTraversal("/Users/me/../etc")) {
        try Validation.validateFolder(URL(filePath: "/Users/me/../etc"))
    }
    #expect(throws: ValidationError.folderNotAbsolute("code/app")) {
        try Validation.validateFolder(URL(filePath: "code/app", relativeTo: nil))
    }
}

@Test func rejectsDuplicateSlugButAllowsDuplicatePort() throws {
    let existing = [Project(slug: "app", folder: anywhere, port: 3000)]
    #expect(throws: ValidationError.duplicateSlug("app")) {
        try Validation.validate(slug: "app", port: 4000, folder: anywhere, existing: existing)
    }
    try Validation.validate(slug: "other", port: 3000, folder: anywhere, existing: existing)
}

@Test func ignoresTheProjectBeingEdited() throws {
    let project = Project(slug: "app", folder: anywhere, port: 3000)
    try Validation.validate(slug: "app", port: 3001, folder: anywhere,
                            existing: [project], ignoring: project.id)
}
```

- [ ] **Step 2: Run, fail, implement, run — PASS**
- [ ] **Step 3: Commit** — `feat: validate slug, port, and folder before persisting`

### Task 0.5: Paths

**Files:**
- Create: `Sources/LocaCore/Paths.swift`, `Tests/LocaCoreTests/PathsTests.swift`

**Interfaces:**
- Produces:

```swift
public struct Paths: Sendable {
    public let home: URL
    public init(home: URL = URL(filePath: NSHomeDirectory()))
    public var supportDirectory: URL      // ~/Library/Application Support/dev.loca
    public var configFile: URL            // .../config.json
    public var logDirectory: URL          // ~/Library/Logs/dev.loca
    public func runnerLog(slug: String) -> URL
    public var launchAgentsDirectory: URL // ~/Library/LaunchAgents
    public func runnerPlist(slug: String) -> URL

    public static let resolverFile = URL(filePath: "/etc/resolver/test")
    public static let helperStateDirectory = URL(filePath: "/Library/Application Support/dev.loca")
    public static let caddyfile = helperStateDirectory.appending(path: "Caddyfile")
    public static let caddyDataDirectory = helperStateDirectory.appending(path: "caddy-data")
    public static let dnsPort: UInt16 = 53531
    public static let caddyAdmin = "127.0.0.1:2019"
}
```

Every path is derived from an injectable `home`, which is what lets the tests assert exact strings without touching the real home directory.

- [ ] **Step 1: Write the tests asserting each exact path against `home = /Users/test`**
- [ ] **Step 2: Run, fail, implement, run — PASS**
- [ ] **Step 3: Commit** — `feat: centralize well-known file paths`

### Task 0.6: Atomic config store

**Files:**
- Create: `Sources/LocaCore/ConfigStore.swift`, `Tests/LocaCoreTests/ConfigStoreTests.swift`

**Interfaces:**
- Produces:

```swift
public struct ConfigStore: Sendable {
    public init(file: URL)
    public func load() throws -> LocaConfig       // missing file -> empty config
    public func save(_ config: LocaConfig) throws // temp file plus rename
}

public enum ConfigStoreError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
}
```

`load` returns `LocaConfig()` when the file does not exist, creates the parent directory on `save`, encodes with sorted keys and pretty printing so diffs stay readable, and rejects a `version` greater than `LocaConfig.currentVersion`.

- [ ] **Step 1: Write the tests**

Cover: missing file yields an empty config; save then load round-trips; the temporary file is gone after `save`; a future `version` throws `unsupportedVersion`; saving into a non-existent directory creates it. Use a unique temporary directory per test and remove it afterwards.

- [ ] **Step 2: Run, fail, implement, run — PASS**
- [ ] **Step 3: Commit** — `feat: load and atomically save the project config`

### Task 0.7: Caddyfile generation

**Files:**
- Create: `Sources/LocaCore/CaddyfileBuilder.swift`, `Tests/LocaCoreTests/CaddyfileBuilderTests.swift`

**Interfaces:**
- Produces:

```swift
public enum CaddyfileBuilder {
    public static func build(projects: [Project],
                             adminAddress: String = Paths.caddyAdmin,
                             dataDirectory: URL = Paths.caddyDataDirectory) -> String
}
```

Only `enabled` projects get a site block. Blocks are emitted in slug order so the output is stable and diffable. Each block addresses the apex and the wildcard together, uses `tls internal`, reverse-proxies to `127.0.0.1:<port>`, and installs a `handle_errors` block that explains an unreachable upstream. Exact expected output for one enabled project on port 2020:

```
{
	admin 127.0.0.1:2019
	storage file_system {
		root "/Library/Application Support/dev.loca/caddy-data"
	}
}

projeto1.test, *.projeto1.test {
	tls internal
	reverse_proxy 127.0.0.1:2020

	handle_errors {
		respond "Loca: projeto1.test is registered, but nothing is listening on 127.0.0.1:2020." {err.status_code}
	}
}
```

Two details the output has to get right: the storage root lives under "Application Support", so it needs quoting or Caddy reads the spaces as argument separators; and inside `handle_errors` the Caddyfile shorthand for the status to pass through is `{err.status_code}`.

- [ ] **Step 1: Write the snapshot tests**

Cover: the exact string above for a single enabled project; a disabled project produces no block; two projects are emitted in slug order; zero enabled projects still produce a valid global block and nothing else.

- [ ] **Step 2: Run, fail, implement, run — PASS**
- [ ] **Step 3: Commit** — `feat: generate the Caddyfile from enabled projects`

### Task 0.8: launchd agent plist generation

**Files:**
- Create: `Sources/LocaCore/LaunchAgentPlist.swift`, `Tests/LocaCoreTests/LaunchAgentPlistTests.swift`

**Interfaces:**
- Produces:

```swift
public enum LaunchAgentPlist {
    public static func dictionary(for project: Project, runner: Runner, paths: Paths) -> [String: Any]
    public static func data(for project: Project, runner: Runner, paths: Paths) throws -> Data
}

public enum LaunchAgentPlistError: Error, Equatable, Sendable { case missingRunner }
```

The dictionary is exactly:

- `Label` = `dev.loca.run.<slug>`
- `ProgramArguments` = `["/bin/zsh", "-lc", runner.command]` — the login shell is what resolves nvm and `PATH`
- `WorkingDirectory` = the project folder path
- `StandardOutPath` = `StandardErrorPath` = `~/Library/Logs/dev.loca/<slug>.log`
- `RunAtLoad` = `runner.autoStart`
- `KeepAlive` = `["SuccessfulExit": false]` when `runner.keepAlive`, otherwise the key is absent
- `ProcessType` = `"Interactive"`
- `EnvironmentVariables` = `["LOCA_SLUG": slug, "PORT": String(port)]`

`data` serializes as an XML plist.

- [ ] **Step 1: Write the tests** — assert every key above for `keepAlive` true and false, and that `data` decodes back to the same dictionary via `PropertyListSerialization`.
- [ ] **Step 2: Run, fail, implement, run — PASS**
- [ ] **Step 3: Commit** — `feat: generate the per-project launchd agent plist`

### Task 0.9: `launchctl print` parsing

**Files:**
- Create: `Sources/LocaCore/LaunchctlStatus.swift`, `Tests/LocaCoreTests/LaunchctlStatusTests.swift`
- Create fixtures: `Tests/LocaCoreTests/Fixtures/launchctl-running.txt`, `launchctl-exited.txt`, `launchctl-notfound.txt`

**Interfaces:**
- Produces:

```swift
public struct LaunchctlStatus: Equatable, Sendable {
    public enum State: Equatable, Sendable { case running(pid: Int32), notRunning, notLoaded }
    public var state: State
    public var lastExitStatus: Int32?
    public var runs: Int?
}

public enum LaunchctlStatusParser {
    public static func parse(_ output: String, exitCode: Int32) -> LaunchctlStatus
}
```

A non-zero `exitCode` (or output containing `Could not find service`) means `.notLoaded`. Otherwise `pid = N` yields `.running`, its absence yields `.notRunning`, and `runs = N` is captured when present.

The exit status key differs by OS release: macOS 26 prints `last exit code = N` where earlier releases printed `last exit status = N`. Accept both, or the status panel goes silently blank after an OS update. There is a fourth fixture, `launchctl-legacy-exit-status.txt`, covering the older spelling.

Key lookup must be anchored to a whole line. The printed block carries dozens of other `key = value` pairs, and a substring match reads `spid = 999` as the service's own pid.

- [ ] **Step 1: Capture the fixtures from a real `launchctl print` — including a throwaway agent bootstrapped to exit non-zero, then booted out — and write the tests against them**
- [ ] **Step 2: Run, fail, implement, run — PASS**
- [ ] **Step 3: Commit** — `feat: parse launchctl print into a run status`

### Task 0.10: Crash-loop detection

**Files:**
- Create: `Sources/LocaCore/RestartTracker.swift`, `Tests/LocaCoreTests/RestartTrackerTests.swift`

**Interfaces:**
- Produces:

```swift
public struct RestartTracker: Sendable {
    public init(threshold: Int = 3, window: TimeInterval = 60)
    public mutating func record(at time: Date) -> Bool   // true once the project is unstable
    public mutating func reset()
    public var isUnstable: Bool { get }
}
```

`record` drops timestamps older than `window` before counting, so three restarts inside 60 seconds trip it and three spread over 90 seconds do not. Time is injected, never read from the clock, which is what makes the test deterministic.

- [ ] **Step 1: Write the tests** — three restarts in 10 seconds trips at the third; three restarts 40 seconds apart never trip; `reset` clears the state.
- [ ] **Step 2: Run, fail, implement, run — PASS**
- [ ] **Step 3: Commit** — `feat: flag a runner as unstable after 3 restarts in 60s`

### Task 0.11: `lsof` parsing

**Files:**
- Create: `Sources/LocaCore/LsofParser.swift`, `Tests/LocaCoreTests/LsofParserTests.swift`
- Create fixture: `Tests/LocaCoreTests/Fixtures/lsof-listen.txt`

**Interfaces:**
- Produces:

```swift
public struct ListeningPort: Equatable, Identifiable, Sendable {
    public var id: String { "\(port)-\(pid)-\(family.rawValue)" }
    public enum Family: String, Sendable { case ipv4, ipv6 }
    public var command: String
    public var pid: Int32
    public var user: String
    public var port: Int
    public var address: String
    public var family: Family
    public var isDockerBackend: Bool  // command == "com.docker.backend"
}

public enum LsofParser {
    public static let arguments = ["+c", "0", "-nP", "-iTCP", "-sTCP:LISTEN"]
    public static func parse(_ output: String) -> [ListeningPort]
}
```

`+c 0` is not optional. Without it `lsof` truncates the COMMAND column to nine characters, `com.docker.backend` arrives as `com.docke`, and every container row goes unrecognized — which would quietly defeat milestone 5. Because `+c 0` also makes that column's width vary with the longest process name on the machine, no parsing may depend on column positions: fields are read by index after splitting on whitespace, which is safe because `lsof` escapes a space inside a name as `\x20`. That escape has to be decoded, or the name reaches the UI looking like a parser bug.

The address is split on its last colon, the only separator that handles `*:3000`, `127.0.0.1:3000`, and `[::1]:8099` alike.

The fixture must contain: a `node` process on `*:3000` (IPv4), the same process on IPv6, an exact duplicate row, a `com.docker.backend` line on `*:5432`, a bracketed IPv6 address, a command name with an escaped space, and a non-LISTEN row. Parsing skips the header, ignores rows without `(LISTEN)`, deduplicates identical rows, and sorts by port then pid.

- [ ] **Step 1: Write the fixture and the tests** — assert the exact row count, that the docker row sets `isDockerBackend`, that IPv6 addresses parse, and that the header is skipped.
- [ ] **Step 2: Run, fail, implement, run — PASS**
- [ ] **Step 3: Commit** — `feat: parse lsof listening sockets into typed rows`

### Task 0.12: Docker port mapping

**Files:**
- Create: `Sources/LocaCore/DockerPortMapper.swift`, `Tests/LocaCoreTests/DockerPortMapperTests.swift`
- Create fixture: `Tests/LocaCoreTests/Fixtures/docker-containers.json`

**Interfaces:**
- Produces:

```swift
public struct DockerContainerPort: Equatable, Sendable {
    public var containerName: String
    public var image: String
    public var publicPort: Int
    public var privatePort: Int
}

public enum DockerPortMapper {
    public static func decode(_ data: Data) throws -> [DockerContainerPort]
    public static func enrich(_ ports: [ListeningPort],
                              with containers: [DockerContainerPort]) -> [InspectorRow]
}

public struct InspectorRow: Equatable, Identifiable, Sendable {
    public var id: String
    public var port: Int
    public var owner: String          // container name, or the lsof command
    public var detail: String?        // image and private port, or nil
    public var pid: Int32
    public var isContainer: Bool
    public var domain: String?        // filled by the caller from Project.port
}
```

`decode` reads the Docker `/containers/json` shape (`Names` array with a leading slash, `Image`, `Ports` with `PublicPort` and `PrivatePort`), skipping entries with no `PublicPort`. `enrich` replaces a `com.docker.backend` owner with the matching container name and leaves every other row's owner alone; an unmatched docker row keeps `com.docker.backend`.

- [ ] **Step 1: Write the fixture (two containers, one without a published port) and the tests**
- [ ] **Step 2: Run, fail, implement, run — PASS**
- [ ] **Step 3: Commit** — `feat: resolve Docker-published ports to container names`

### Task 0.13: Project detection

**Files:**
- Create: `Sources/LocaCore/ProjectDetector.swift`, `Tests/LocaCoreTests/ProjectDetectorTests.swift`
- Create fixtures: `Tests/LocaCoreTests/Fixtures/Projects/next/`, `vite/`, `compose/`, `node-start/`, `bare/`

**Interfaces:**
- Produces:

```swift
public struct DetectionResult: Equatable, Sendable {
    public var port: Int?
    public var command: String?
    public var sources: [String]      // human-readable, e.g. ["package.json scripts.dev", ".env PORT"]
    public var packageManager: String?
}

public enum ProjectDetector {
    public static func detect(folder: URL) -> DetectionResult
}
```

Detection order, first hit wins per field, and every consulted file that contributed is appended to `sources`:

1. `.env`, `.env.local` — a `PORT=<n>` line gives the port.
2. `package.json` — `scripts.dev` else `scripts.start` gives the command, prefixed by the package manager inferred from the lockfile (`pnpm-lock.yaml` → `pnpm`, `yarn.lock` → `yarn`, `bun.lockb` → `bun`, otherwise `npm run`). A `--port <n>` or `-p <n>` inside the script gives the port.
3. `vite.config.*` — `server: { port: <n> }` gives the port; the Vite default 5173 is used when the key is absent but the file exists.
4. `next.config.*` — the Next default 3000 is used when no other port was found.
5. `docker-compose.yml` / `docker-compose.yaml` / `compose.yml` — the first `"<public>:<private>"` published port gives the port, and the command becomes `docker compose up`.

Fixture folders and their expected results:

| Fixture | Contents | Expected port | Expected command |
| --- | --- | --- | --- |
| `next/` | `package.json` with `scripts.dev = "next dev"`, `next.config.js`, `pnpm-lock.yaml` | 3000 | `pnpm dev` |
| `vite/` | `package.json` with `scripts.dev = "vite"`, `vite.config.ts` with `port: 5174`, `yarn.lock` | 5174 | `yarn dev` |
| `compose/` | `docker-compose.yml` publishing `"8080:80"` | 8080 | `docker compose up` |
| `node-start/` | `package.json` with `scripts.start = "node server.js"`, no lockfile | `nil` | `npm run start` |
| `bare/` | an empty folder | `nil` | `nil` |

The `.env` cases are built in a temporary folder by the test rather than committed. A real `.env` in the repository is a file nobody should have to think about, and tooling tends to treat it as a secret — this repository's own permission rules refuse to write one.

- [ ] **Step 1: Create the five fixture folders with exactly those contents**
- [ ] **Step 2: Write one test per fixture asserting port, command, and that `sources` is non-empty where a value was found, plus temporary-folder tests for `.env`, `.env.local`, a commented-out `PORT`, quoted values, the three port-flag spellings, each lockfile, and a malformed `package.json` that must not stop compose from being consulted**
- [ ] **Step 3: Run, fail, implement, run — PASS**
- [ ] **Step 4: Commit** — `feat: propose port and command by reading project files`

### Task 0.14: DNS wire format

**Files:**
- Create: `Sources/LocaCore/DNSMessage.swift`, `Tests/LocaCoreTests/DNSMessageTests.swift`

**Interfaces:**
- Produces:

```swift
public struct DNSQuestion: Equatable, Sendable {
    public var name: String            // "app.projeto1.test", no trailing dot
    public var type: DNSRecordType
    public var klass: UInt16           // 1 = IN
}

/// `other` keeps the wire number rather than collapsing to zero, so a
/// response can echo the question exactly as it was asked.
public enum DNSRecordType: Equatable, Hashable, Sendable {
    case a, aaaa
    case other(UInt16)
    public init(rawValue: UInt16)
    public var rawValue: UInt16
}

public struct DNSMessage: Equatable, Sendable {
    public var id: UInt16
    public var isQuery: Bool
    public var recursionDesired: Bool
    public var questions: [DNSQuestion]
    public var answers: [DNSAnswer]
    public var responseCode: UInt8     // 0 = NOERROR, 3 = NXDOMAIN, 4 = NOTIMP
}

public struct DNSAnswer: Equatable, Sendable {
    public var name: String
    public var type: DNSRecordType
    public var ttl: UInt32
    public var data: Data              // 4 bytes for A, 16 for AAAA
}

public enum DNSCodecError: Error, Equatable, Sendable {
    case truncated, unsupportedLabelLength, compressionPointerUnsupported
}

public enum DNSCodec {
    public static func decode(_ data: Data) throws -> DNSMessage
    public static func encode(_ message: DNSMessage) -> Data
    public static func prefixedForTCP(_ payload: Data) -> Data      // 2-byte big-endian length
    public static func stripTCPPrefix(_ data: Data) throws -> Data
}
```

The encoder writes the question section back verbatim (labels, no compression) and writes answers with a pointer-free name, which keeps the codec small and every resolver happy. Queries carrying a compression pointer in the question section are rejected rather than mis-parsed.

- [ ] **Step 1: Write the tests**

Cover: decode a hand-built A query for `projeto1.test` and assert id, question name, and type; encode-then-decode round-trips a response holding one A answer of `127.0.0.1`; the same for an AAAA answer of `::1`; a truncated buffer throws `.truncated`; a label length of 64 throws `.unsupportedLabelLength`; a `0xC0` pointer byte throws `.compressionPointerUnsupported`; `stripTCPPrefix(prefixedForTCP(x)) == x`; `stripTCPPrefix` on a short buffer throws `.truncated`.

Build the query bytes by hand in the test, so decoding is exercised against real wire layout rather than against our own encoder. Watch the flag layout while doing it: RD sits in the *high* flags byte and RCODE in the low one, so a standard query is `0x0100` — writing it the other way round sets RCODE to 1 and the test fails against correct code.

- [ ] **Step 2: Run, fail, implement, run — PASS**
- [ ] **Step 3: Commit** — `feat: encode and decode DNS messages for the local responder`

### Task 0.15: DNS answer policy

**Files:**
- Create: `Sources/LocaCore/DNSResponder.swift`, `Tests/LocaCoreTests/DNSResponderTests.swift`

**Interfaces:**
- Produces:

```swift
public enum DNSResponder {
    public static let ttl: UInt32 = 60
    public static func respond(to query: DNSMessage) -> DNSMessage
}
```

Policy, straight from the spec: an `A` question is answered `127.0.0.1`; an `AAAA` question is answered `::1`; anything else is an empty `NOERROR`, never `NXDOMAIN`, because a negative answer would let the resolver fall through to the next nameserver. A message that is not a query, or that carries no question, comes back as `NOTIMP` (code 4). The response echoes the query's id and question section.

- [ ] **Step 1: Write the tests** — one per branch, asserting the answer bytes are exactly `[127,0,0,1]` and the 16 bytes of `::1`.
- [ ] **Step 2: Run, fail, implement, run — PASS**
- [ ] **Step 3: Commit** — `feat: answer A with 127.0.0.1, AAAA with ::1, everything else empty`

### Task 0.16: Resolver file content

**Files:**
- Create: `Sources/LocaCore/ResolverFile.swift`, `Tests/LocaCoreTests/ResolverFileTests.swift`

**Interfaces:**
- Produces:

```swift
public enum ResolverFile {
    public static let marker = "# managed by Loca (dev.loca)"
    public static func content(port: UInt16 = Paths.dnsPort) -> String
    public static func isManagedByLoca(_ content: String) -> Bool
}
```

Content is exactly:

```
# managed by Loca (dev.loca)
nameserver 127.0.0.1
port 53531
```

The marker is what lets the helper tell its own file from a hand-written one it must back up instead of overwrite.

- [ ] **Step 1: Write the tests** — exact string for the default port and for a custom port; `isManagedByLoca` true for our own content, false for a bare `nameserver 127.0.0.1`.
- [ ] **Step 2: Run, fail, implement, run — PASS**
- [ ] **Step 3: Commit** — `feat: render the /etc/resolver/test payload with an ownership marker`

### Task 0.17: XPC protocol and admin request description

**Files:**
- Create: `Sources/LocaCore/HelperProtocol.swift`, `Sources/LocaCore/CaddyAdmin.swift`
- Create: `Tests/LocaCoreTests/CaddyAdminTests.swift`

**Interfaces:**
- Produces:

```swift
public let locaHelperMachServiceName = "dev.loca.helper"
public let locaHelperProtocolVersion = 1

@objc public protocol LocaHelperProtocol {
    func helperVersion(reply: @escaping (Int, String) -> Void)         // protocol version, build string
    func installDNSResolver(reply: @escaping (Bool, String?) -> Void)  // ok, backup path or error
    func removeDNSResolver(reply: @escaping (Bool, String?) -> Void)
    func applyDomains(_ payload: [[String: NSObject]], reply: @escaping (Bool, String?) -> Void)
    func trustCertificateAuthority(reply: @escaping (Bool, String?) -> Void)
    func certificateAuthorityIsTrusted(reply: @escaping (Bool) -> Void)
    func diagnostics(reply: @escaping ([String: NSObject]) -> Void)
    func uninstall(reply: @escaping (Bool, String?) -> Void)
}

public enum DomainPayload {
    public static func encode(_ projects: [Project]) -> [[String: NSObject]]
    public static func decode(_ payload: [[String: NSObject]]) throws -> [Project]
}
```

`applyDomains` is the only path by which configuration reaches root, and `DomainPayload.decode` runs `Validation` on every field before the helper acts on it. `Project.id` and `runner` are deliberately absent from the payload: the helper has no business knowing them.

```swift
public struct CaddyAdminRequest: Equatable, Sendable {
    public var method: String          // "POST"
    public var path: String            // "/load"
    public var contentType: String     // "text/caddyfile"
    public var body: Data
    public static func load(caddyfile: String) -> CaddyAdminRequest
    public var urlString: String        // "http://127.0.0.1:2019/load"
}
```

- [ ] **Step 1: Write the tests** — `DomainPayload` round-trips slug, port, and enabled; a payload with port `0` throws `ValidationError.portOutOfRange`; a payload with slug `"Bad Slug"` throws `.invalidSlug`; a payload with folder `"/a/../b"` throws `.folderTraversal`; `CaddyAdminRequest.load` produces the exact method, path, content type, and URL.
- [ ] **Step 2: Run, fail, implement, run — PASS**
- [ ] **Step 3: Commit** — `feat: define the XPC surface and the Caddy admin request`

### Task 0.18: Close out milestone 0

- [ ] **Step 1: Run the whole suite** — `swift test 2>&1 | tail -20`. Expected: every test passes, zero failures.
- [ ] **Step 2: Confirm `LocaCore` stayed pure** — `! grep -rE 'import (SwiftUI|ServiceManagement|Security|Network)' Sources/LocaCore/`. Expected: no matches.
- [ ] **Step 3: Open the pull request**

```bash
git push -u origin feat/m0-locacore
gh pr create --base main --title "Milestone 0 — LocaCore" \
  --body "Closes #<issue>. Pure, testable logic: models, validation, Caddyfile and plist generation, lsof/launchctl/Docker parsing, project detection, DNS codec. \`swift test\` passes." \
  --label "milestone-0,core,enhancement" --assignee jacksonmafra-umain
```

---

# Milestone 1 — Helper, XPC, DNS, `/etc/resolver`

GitHub issue: "Milestone 1 — privileged helper: XPC, DNS responder, /etc/resolver/test". Branch `feat/m1-helper`. Verification: `dig @127.0.0.1 -p 53531 anything.projeto1.test` answers `127.0.0.1`.

This milestone also builds the minimum app bundle, because `SMAppService.daemon` can only be called from inside a bundled, signed app.

### Task 1.1: App bundle assembly and signing

**Files:**
- Create: `Makefile`, `Resources/Info.plist`, `Resources/LocaApp.entitlements`, `Resources/dev.loca.helper.plist`
- Create: `Sources/LocaApp/LocaAppMain.swift` (placeholder window), `Sources/LocaHelper/main.swift` (placeholder)

**Interfaces:**
- Produces: `make app` yielding a signed `build/Loca.app`; `make test` running `swift test`; `make install`/`make uninstall`.

The bundle layout `SMAppService` requires:

```
Loca.app/Contents/Info.plist
Loca.app/Contents/MacOS/LocaApp
Loca.app/Contents/MacOS/LocaHelper
Loca.app/Contents/Library/LaunchDaemons/dev.loca.helper.plist
Loca.app/Contents/Resources/caddy               (milestone 2)
```

`Resources/dev.loca.helper.plist` is exactly:

- `Label` = `dev.loca.helper`
- `BundleProgram` = `Contents/MacOS/LocaHelper`
- `MachServices` = `["dev.loca.helper": true]`
- `AssociatedBundleIdentifiers` = `["dev.loca"]`
- `KeepAlive` = `true`
- `StandardOutPath` = `StandardErrorPath` = `/var/log/dev.loca.helper.log`

`Resources/Info.plist` sets `CFBundleIdentifier` = `dev.loca`, `CFBundleExecutable` = `LocaApp`, `LSMinimumSystemVersion` = `14.0`, `LSUIElement` = `false`, and a `SMPrivilegedExecutables`-free modern layout (that key belongs to the deprecated `SMJobBless` path and must not be present).

The entitlements file is deliberately near-empty — the app is unsandboxed. It carries only `com.apple.security.get-task-allow` for a Development build.

Signing, in the Makefile, helper first then the app, because the outer signature must cover the inner one:

```bash
codesign --force --options runtime --timestamp=none \
  --sign "$(SIGN_ID)" build/Loca.app/Contents/MacOS/LocaHelper
codesign --force --options runtime --timestamp=none \
  --entitlements Resources/LocaApp.entitlements \
  --sign "$(SIGN_ID)" build/Loca.app
```

- [ ] **Step 1: Write the Makefile, the three resource files, and both placeholder mains**
- [ ] **Step 2: Build** — `make app`. Expected: `build/Loca.app` exists.
- [ ] **Step 3: Verify the signature** — `codesign -dv --verbose=4 build/Loca.app 2>&1 | grep -E 'Identifier|TeamIdentifier'`. Expected: `Identifier=dev.loca`.
- [ ] **Step 4: Verify the daemon plist is embedded and well-formed** — `plutil -lint build/Loca.app/Contents/Library/LaunchDaemons/dev.loca.helper.plist`. Expected: `OK`.
- [ ] **Step 5: Commit** — `build: assemble and codesign the Loca.app bundle`

### Task 1.2: XPC listener with audit-token verification

**Files:**
- Create: `Sources/LocaHelper/XPCListener.swift`, `Sources/LocaHelper/HelperService.swift`
- Modify: `Sources/LocaHelper/main.swift`

**Interfaces:**
- Consumes: `locaHelperMachServiceName`, `LocaHelperProtocol`, `DomainPayload` (Task 0.17).
- Produces: `final class XPCListener: NSObject, NSXPCListenerDelegate`, `final class HelperService: NSObject, LocaHelperProtocol`.

Use `NSXPCConnection.setCodeSigningRequirement(_:)`, public since macOS 13. Do **not** read the audit token by hand: that needs KVC on a private property, and a pid-based alternative has a window in which the pid could be reused between the check and the call that trusts it.

```swift
func listener(_ listener: NSXPCListener,
              shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
    guard let requirement else { return false }   // fail closed
    connection.setCodeSigningRequirement(requirement)
    connection.exportedInterface = NSXPCInterface(with: LocaHelperProtocol.self)
    connection.exportedObject = service
    connection.resume()
    return true
}
```

The call returns nothing. Enforcement is the system's: it invalidates the connection before any message reaches the exported object, so a client that does not match never gets to call a method even though this returned `true`.

The requirement is derived from the helper's *own* signature — "signed by whoever signed me" — rather than hardcoded. That is both the exact property wanted and the only form that lets a third party build this repository without editing a team identifier into the source. Read it with `SecCodeCopySelf`, `SecCodeCopyStaticCode`, and `SecCodeCopySigningInformation`, then take `kSecCodeInfoTeamIdentifier`:

```
identifier "dev.loca" and anchor apple generic and certificate leaf[subject.OU] = "<own team>"
```

Two traps. The team identifier is the certificate's **OU** field, *not* the value in parentheses in an `Apple Development: name (XXXXXXXXXX)` common name — on this machine those are `9N8ZC32DMP` and `6L9VF66ZX7` respectively, and the wrong one produces a requirement that silently never matches. And because the setter reports nothing back, compile the requirement string with `SecRequirementCreateWithString` at startup, so a typo becomes a log line rather than a daemon that refuses everyone for no visible reason. No team identifier at all — an unsigned or ad-hoc build — must refuse every connection: a root daemon that cannot tell who is calling has no business accepting anyone.

- [ ] **Step 1: Write `XPCListener.swift` and a `HelperService` that implements only `helperVersion` and `diagnostics`**
- [ ] **Step 2: Wire `main.swift`** — create the listener, `resume()`, then `RunLoop.main.run()`. Handle `SIGTERM` by tearing down and exiting 0.
- [ ] **Step 3: Add command-line flags to the app binary** — `--register-helper`, `--unregister-helper`, `--helper-status`, `--bundle-info`, `--install-resolver`, `--remove-resolver`, `--diagnostics`, handled in `App.init()`.

`SMAppService` only registers a daemon when called from inside the signed bundle, so registration has to go through the app binary. Flags make install, uninstall, and every verification in this milestone a shell command rather than a button to click. Note that `CommandLineMode` runs before the main run loop, so the async `HelperClient` cannot be used there — awaiting on the main actor from a blocked main thread deadlocks. It needs its own blocking XPC path over a semaphore.

- [ ] **Step 4: Register the helper** — `/Applications/Loca.app/Contents/MacOS/LocaApp --register-helper`

Three things about registration that are not obvious:

- The app has to be in `/Applications` and the daemon must be approved once by the user in System Settings > General > Login Items. Until then `status` is `requiresApproval`.
- `register()` **throws** `"Operation not permitted"` on that normal not-yet-approved path — launchd refuses to bootstrap a disallowed job. Check the status afterwards and report an error only when the status did not move, or a working install looks like a failure.
- On macOS 26, `status` before any registration is `.notFound`, not `.notRegistered`. `.notFound` also means "plist missing or invalid", so it is three conditions wearing one name — which is what `--bundle-info` exists to separate.

- [ ] **Step 5: Verify it is running** — `pgrep -fl LocaHelper` shows a process, and `/var/log/dev.loca.helper.log` ends with `helper listening on dev.loca.helper`.

After changing helper code, launchd keeps the old binary alive under `KeepAlive`. `--unregister-helper` then `--register-helper` reloads it; the register can fail transiently right after the unregister, so retry once.

- [ ] **Step 6: Verify the client gate accepts our own app** — `--diagnostics` returns a report. An unsigned client's rejection is in the manual list at the end of this plan.
- [ ] **Step 7: Commit** — `feat: accept only code-signature-verified XPC clients in the helper`

### Task 1.3: DNS listener on `127.0.0.1:53531`

**Files:**
- Create: `Sources/LocaHelper/DNSListener.swift`
- Modify: `Sources/LocaHelper/main.swift`

**Interfaces:**
- Consumes: `DNSCodec`, `DNSResponder`, `Paths.dnsPort` (Tasks 0.14, 0.15).
- Produces: `final class DNSListener { init(port: UInt16); func start() throws; func stop() }`.

Two `NWListener`s on loopback port 53531, one UDP and one TCP. UDP handles one datagram per connection; TCP reads the 2-byte length prefix, then the payload, then replies with a prefixed response and keeps the connection open for a second query. Both paths run the bytes through `DNSCodec.decode`, `DNSResponder.respond`, `DNSCodec.encode`. A decode failure is logged and dropped, never crashed on — a malformed packet from any local process must not take down a root daemon.

Two mistakes here fail in ways that read as success, so they are worth stating outright:

1. **Pass the port to the initializer:** `NWListener(using: parameters, on: port)`. Setting `parameters.requiredLocalEndpoint` does *not* bind a listener's port — the listener comes up on an ephemeral port while every log line still reports the port that was asked for. Restrict the interface with `parameters.requiredInterfaceType = .loopback`, and log `listener.port`, never the requested value, so a listener can never claim a port it is not on.
2. **Do not cancel a UDP flow right after sending.** `send(completion: .idempotent)` is asynchronous, and cancelling immediately drops the reply. Cancel inside a `.contentProcessed` completion instead. Skipping this produces the most misleading failure available: the listener reports ready, `dig +tcp` answers correctly, and plain UDP queries time out.

Sleep and wake: observe `NWListener.stateUpdateHandler`; on `.failed`, or on a `.cancelled` that `stop()` did not ask for, re-arm after a 1-second delay with exponential backoff capped at 30 seconds. This is what the spec means by "the DNS listener re-armed after sleep and wake".

- [ ] **Step 1: Write `DNSListener.swift`**
- [ ] **Step 2: Start it from `main.swift` before the run loop**
- [ ] **Step 3: Build and reinstall the helper** — `make app && make reinstall-helper`
- [ ] **Step 4: Verify UDP** — `dig @127.0.0.1 -p 53531 anything.projeto1.test +short`. Expected: `127.0.0.1`.
- [ ] **Step 5: Verify AAAA** — `dig @127.0.0.1 -p 53531 AAAA x.projeto1.test +short`. Expected: `::1`.
- [ ] **Step 6: Verify TCP** — `dig +tcp @127.0.0.1 -p 53531 x.projeto1.test +short`. Expected: `127.0.0.1`.
- [ ] **Step 7: Verify an MX question is an empty NOERROR** — `dig @127.0.0.1 -p 53531 MX x.projeto1.test`. Expected: `status: NOERROR`, `ANSWER: 0`.
- [ ] **Step 8: Commit** — `feat: answer DNS for .test on 127.0.0.1:53531 over UDP and TCP`

### Task 1.4: `/etc/resolver/test` installation

**Files:**
- Create: `Sources/LocaHelper/ResolverInstaller.swift`
- Modify: `Sources/LocaHelper/HelperService.swift`

**Files (revised):**
- Create: `Sources/LocaCore/ResolverInstaller.swift`, `Tests/LocaCoreTests/ResolverInstallerTests.swift`
- Create: `Sources/LocaHelper/ResolverInstaller.swift` — a thin `SystemResolver` binding to the real path
- Modify: `Sources/LocaHelper/HelperService.swift`

**Interfaces:**
- Consumes: `ResolverFile`, `Paths.resolverDirectory` (Task 0.16).
- Produces:

```swift
public struct ResolverInstaller: Sendable {
    public init(directory: URL = Paths.resolverDirectory, fileName: String = "test")
    public var file: URL { get }
    public struct Status: Equatable, Sendable {
        public var exists: Bool
        public var managedByLoca: Bool
        public var content: String?
        public var backups: [String]
    }
    @discardableResult
    public func install(port: UInt16 = Paths.dnsPort, now: Date = Date()) throws -> String?
    public func remove() throws
    public func status() -> Status
}

public enum ResolverInstallerError: Error, Equatable, Sendable {
    case notManagedByLoca(String)
}
```

This belongs in `LocaCore` with the directory as a parameter, not in the helper against a hardcoded `/etc/resolver`. The ownership rule is one branch, and getting it wrong destroys someone's existing dnsmasq configuration in a way they discover days later — so it has to be testable without root.

`install` creates the directory with mode `0755` when absent. A file the marker does not claim is copied to `<directory>/test.loca-backup-<timestamp>` and the path returned so the app can report it; a file that is already ours is rewritten in place with no backup, since piling up copies of something reproducible is just clutter. The written file is `0644`. `remove` unlinks only a file the marker proves is ours — anything else throws `.notManagedByLoca` — then restores the most recent backup. Uninstall undoes what Loca did, never what it found.

The timestamp must be fixed-width and colon-free (`yyyy-MM-dd'T'HHmmss'Z'`, UTC, POSIX locale), because the most recent backup is picked by lexical order.

- [ ] **Step 1: Write `ResolverInstaller.swift` in `LocaCore` and its tests** — cover: a foreign file is backed up and preserved; our own is rewritten with no backup; `remove` refuses a file it does not own and leaves it intact; `remove` restores the most recent backup; `remove` on an absent file is harmless; the file is `0644`; timestamps sort chronologically.
- [ ] **Step 2: Add the `SystemResolver` binding and wire `installDNSResolver` / `removeDNSResolver` in `HelperService`**
- [ ] **Step 3: Reload the helper** — `make app`, `ditto build/Loca.app /Applications/Loca.app`, then `--unregister-helper` and `--register-helper`.
- [ ] **Step 4: Install the resolver** — `--install-resolver`. Expected: `installed /etc/resolver/test`, and `cat /etc/resolver/test` shows the marker, `nameserver 127.0.0.1`, and `port 53531` at mode 644.
- [ ] **Step 5: Verify macOS picked it up** — `scutil --dns`. Expected: a resolver entry with `domain : test`, `nameserver[0] : 127.0.0.1`, `port : 53531`.
- [ ] **Step 6: Verify end to end without an explicit server** — `dscacheutil -q host -a name whatever.projeto1.test`. Expected: `ip_address: 127.0.0.1` and `ipv6_address: ::1`. Also `ping -c 1 deep.sub.anything.test`, which must resolve to `127.0.0.1` — that is wildcard resolution at arbitrary depth, for free.
- [ ] **Step 7: Commit** — `feat: install and remove /etc/resolver/test, backing up a foreign file`

### Task 1.5: Port probe and diagnostics

**Files:**
- Create: `Sources/LocaHelper/PortProbe.swift`
- Modify: `Sources/LocaHelper/HelperService.swift`

**Interfaces:**
- Consumes: `LsofParser`, `LsofParser.arguments` (Task 0.11).
- Produces: `enum PortProbe { static func owner(ofPort:) -> ListeningPort?; static func describeOwner(ofPort:) -> String? }`, a small `enum Shell`, and a `diagnostics` reply carrying `helperVersion`, `helperBuild`, `dnsPort`, `dnsListening`, `resolverExists`, `resolverManagedByLoca`, and — only when the port is actually held — `port80Owner` and `port443Owner`.

`PortProbe` runs `/usr/sbin/lsof +c 0 -nP -iTCP:<port> -sTCP:LISTEN` (absolute path: the helper's `PATH` is launchd's, not a shell's) and feeds the output to `LsofParser`. It reports `"<command> (pid <n>)"`, not a boolean: "something is on 443" sends the user hunting, while "nginx (pid 812) is on 443" ends the search.

`Shell` must read both pipes *before* `waitUntilExit`. `lsof` on a busy machine produces enough output to fill a pipe buffer, and a child blocked on a full pipe against a parent sitting in `waitUntilExit` hangs forever.

- [ ] **Step 1: Write `PortProbe.swift` and fill in `diagnostics`**
- [ ] **Step 2: Reload the helper and read the report** — `--diagnostics`. Expected: `dnsListening: 1` (which also proves the `lsof` path works against a real socket, as root), `resolverExists: 1`, `resolverManagedByLoca: 1`, and no `port80Owner`/`port443Owner` keys while those ports are free.
- [ ] **Step 3: Verify an occupied port is named** — requires root to bind 443, so it belongs in the manual list: `sudo python3 -m http.server 443`, then `--diagnostics` must show `port443Owner: Python (pid …)`. Stop the server afterwards.
- [ ] **Step 4: Commit** — `feat: report which process holds :80 and :443 in helper diagnostics`

### Task 1.6: Close out milestone 1

- [ ] **Step 1: `swift test`** — Expected: still green.
- [ ] **Step 2: Re-run the four `dig` checks from Task 1.3 and the `scutil` check from Task 1.4**
- [ ] **Step 3: Open the pull request**

```bash
git push -u origin feat/m1-helper
gh pr create --base main --title "Milestone 1 — privileged helper, XPC, DNS, resolver" \
  --body "Closes #<issue>. Root daemon with signature-verified XPC, DNS responder on 127.0.0.1:53531 (UDP and TCP), /etc/resolver/test with backup of a foreign file, and :80/:443 ownership diagnostics. Verified with dig, scutil, and dscacheutil." \
  --label "milestone-1,helper,dns,enhancement" --assignee jacksonmafra-umain
```

---

# Milestone 2 — Caddy, reload, CA trust

GitHub issue: "Milestone 2 — bundled Caddy, config reload, CA trust". Branch `feat/m2-caddy`. Verification: `curl -sI https://<slug>.test` returns a response over a trusted certificate.

### Task 2.1: Vendor the Caddy binary

**Files:**
- Modify: `Makefile`, `.gitignore`, `README.md`

**Interfaces:**
- Produces: `make vendor-caddy` downloading a pinned Caddy release for the host architecture into `vendor/caddy`, verified against a pinned SHA-256, and `make app` copying it to `Contents/Resources/caddy`.

The binary is not committed. The Makefile pins `CADDY_VERSION` and both architecture checksums, so a third party's build is byte-identical to ours. The vendored binary is signed ad-hoc during bundling (`codesign --force --sign "$(SIGN_ID)"`) because an unsigned Mach-O inside a signed bundle invalidates the outer signature.

- [ ] **Step 1: Add `CADDY_VERSION`, the two checksums, and the `vendor-caddy` target**
- [ ] **Step 2: Run it** — `make vendor-caddy && vendor/caddy version`. Expected: the pinned version prints.
- [ ] **Step 3: Verify the checksum gate** — corrupt one byte of `vendor/caddy`, re-run `make vendor-caddy`, and confirm it refuses. Restore.
- [ ] **Step 4: Verify the bundle** — `make app && codesign -v build/Loca.app`. Expected: no output, exit 0.
- [ ] **Step 5: Commit** — `build: vendor a pinned, checksum-verified Caddy binary`

### Task 2.2: Caddy supervision

**Files:**
- Create: `Sources/LocaHelper/CaddySupervisor.swift`
- Modify: `Sources/LocaHelper/main.swift`, `Sources/LocaHelper/HelperService.swift`

**Interfaces:**
- Consumes: `CaddyfileBuilder`, `CaddyAdminRequest`, `Paths.caddyfile`, `Paths.caddyDataDirectory`, `PortProbe`.
- Produces:

```swift
final class CaddySupervisor {
    init(binary: URL, caddyfile: URL, dataDirectory: URL)
    func start() throws            // refuses when :80 or :443 is held by someone else
    func stop()
    func reload(caddyfile: String) throws
    var isRunning: Bool { get }
    var lastExitStatus: Int32? { get }
}

enum CaddySupervisorError: Error {
    case portHeld(port: Int, by: String, pid: Int32)
    case adminRequestFailed(status: Int, body: String)
    case binaryMissing
}
```

`start` probes 80 and 443 first and throws `.portHeld` naming the process, rather than letting Caddy fail with an opaque bind error. It launches `caddy run --config <path> --adapter caddyfile` with `XDG_DATA_HOME` and `XDG_CONFIG_HOME` pointed at `Paths.caddyDataDirectory`, so the internal CA lands somewhere the helper owns. A `terminationHandler` restarts the process with exponential backoff (1, 2, 4, 8, 16, 30 seconds, capped) unless `stop` asked for the exit.

`reload` writes the Caddyfile atomically, then POSTs it to `http://127.0.0.1:2019/load` with `Content-Type: text/caddyfile`. A non-2xx response throws `.adminRequestFailed` carrying Caddy's own error body, which is the only useful thing to show the user when a generated config is rejected. Open connections survive, because this is a config load and not a restart.

- [ ] **Step 1: Write `CaddySupervisor.swift`**
- [ ] **Step 2: Wire `applyDomains`** — decode and validate the payload via `DomainPayload.decode`, build the Caddyfile via `CaddyfileBuilder.build`, then `reload`. Start the supervisor lazily on the first `applyDomains`.
- [ ] **Step 3: Build and reinstall**
- [ ] **Step 4: Verify Caddy came up** — `sudo lsof -nP -iTCP:443 -sTCP:LISTEN`. Expected: a `caddy` row.
- [ ] **Step 5: Verify the config landed** — `curl -s http://127.0.0.1:2019/config/ | head -c 200`. Expected: JSON containing `projeto1.test`.
- [ ] **Step 6: Verify a reload does not restart** — note Caddy's pid, apply a second domain, and confirm the pid is unchanged.
- [ ] **Step 7: Commit** — `feat: supervise Caddy and reload its config over the admin API`

### Task 2.3: CA trust

**Files:**
- Create: `Sources/LocaHelper/CATrust.swift`
- Modify: `Sources/LocaHelper/HelperService.swift`

**Interfaces:**
- Produces:

```swift
enum CATrust {
    static func rootCertificatePath(dataDirectory: URL) -> URL
    static func install(binary: URL, dataDirectory: URL) throws
    static func isTrusted(dataDirectory: URL) -> Bool
    static func untrust(dataDirectory: URL) throws
}
```

`install` runs `caddy trust --address 127.0.0.1:2019` as root, which puts the internal root into the System keychain. `isTrusted` reads the root certificate from `<dataDirectory>/caddy/pki/authorities/local/root.crt`, builds a `SecCertificate`, and evaluates it with `SecTrustEvaluateWithError` against a basic X.509 policy — this is what detects trust the user revoked by hand, so the app can offer to reinstall instead of failing mysteriously. `untrust` runs `caddy untrust` and is called from `uninstall`.

- [ ] **Step 1: Write `CATrust.swift` and wire `trustCertificateAuthority` / `certificateAuthorityIsTrusted`**
- [ ] **Step 2: Build and reinstall**
- [ ] **Step 3: Trust the CA** — trigger it from the app placeholder. Expected: exactly one authentication prompt.
- [ ] **Step 4: Verify the keychain** — `security find-certificate -a -c "Caddy Local Authority" /Library/Keychains/System.keychain | head -5`. Expected: a match.
- [ ] **Step 5: Verify HTTPS end to end** — `curl -sI https://projeto1.test` with something listening on the mapped port. Expected: `HTTP/2 200` and no certificate warning.
- [ ] **Step 6: Verify the unreachable-upstream page** — stop the upstream, then `curl -s https://projeto1.test`. Expected: the `handle_errors` text naming the slug and port.
- [ ] **Step 7: Verify wildcard subdomains** — `curl -sI https://api.projeto1.test`. Expected: the same trusted response.
- [ ] **Step 8: Commit** — `feat: install and verify the Caddy root CA in the System keychain`

### Task 2.4: Close out milestone 2

- [ ] **Step 1: `swift test`** — Expected: green.
- [ ] **Step 2: Re-run the curl checks from Task 2.3**
- [ ] **Step 3: Open the pull request**

```bash
git push -u origin feat/m2-caddy
gh pr create --base main --title "Milestone 2 — bundled Caddy, reload, CA trust" \
  --body "Closes #<issue>. Pinned checksum-verified Caddy binary, supervised with backoff, config applied over the admin API without restarting, internal root CA trusted in the System keychain. Verified: curl over trusted TLS on both the apex and a wildcard subdomain." \
  --label "milestone-2,caddy,tls,enhancement" --assignee jacksonmafra-umain
```

---

# Milestone 3 — SwiftUI window

GitHub issue: "Milestone 3 — SwiftUI window: list, add, enable, disable". Branch `feat/m3-window`. Verification: a domain toggles from the UI and `curl` reflects it.

### Task 3.1: Helper client with a version handshake

**Files:**
- Create: `Sources/LocaApp/HelperClient.swift`
- Modify: `Sources/LocaApp/LocaAppMain.swift`

**Interfaces:**
- Consumes: `LocaHelperProtocol`, `locaHelperMachServiceName`, `locaHelperProtocolVersion`, `DomainPayload`.
- Produces:

```swift
@MainActor @Observable final class HelperClient {
    enum State: Equatable { case notInstalled, requiresApproval, installed, versionSkew(Int), unreachable(String) }
    var state: State { get }
    func register() throws            // SMAppService.daemon(plistName:).register()
    func unregister() async throws
    func refreshState() async
    func applyDomains(_ projects: [Project]) async throws
    func installResolver() async throws -> String?
    func trustCA() async throws
    func caIsTrusted() async -> Bool
    func diagnostics() async -> [String: Any]
}
```

`refreshState` maps `SMAppService.Status` to `State`, then calls `helperVersion` and reports `.versionSkew` when the helper's protocol version differs from `locaHelperProtocolVersion` — the spec calls for this handshake, and it is what turns a confusing XPC failure after an update into an actionable "reinstall the helper". Every XPC call is wrapped in a continuation with both an `interruptionHandler` and an `invalidationHandler` that resume it, so a dead helper surfaces as a thrown error rather than a hung `await`.

- [ ] **Step 1: Write `HelperClient.swift`**
- [ ] **Step 2: Build** — `make app`
- [ ] **Step 3: Verify** — launch the app, and confirm the placeholder window shows `installed` after approval and the helper's version string.
- [ ] **Step 4: Commit** — `feat: connect the app to the helper with a version handshake`

### Task 3.2: App store

**Files:**
- Create: `Sources/LocaApp/AppStore.swift`

**Interfaces:**
- Consumes: `ConfigStore`, `LocaConfig`, `Project`, `Validation`, `Slug`, `Paths`.
- Produces:

```swift
@MainActor @Observable final class AppStore {
    var projects: [Project] { get }
    var lastError: String?
    init(paths: Paths = Paths(), helper: HelperClient)
    func load()
    func add(folder: URL, slug: String, port: Int, runner: Runner?) async throws
    func update(_ project: Project) async throws
    func remove(_ project: Project) async throws
    func setEnabled(_ enabled: Bool, for project: Project) async throws
    func suggestedSlug(for folder: URL) -> String
    func portConflicts(for project: Project) -> [Project]
}
```

Every mutation validates, saves the config, then pushes the enabled set to the helper via `applyDomains`. Order matters: a failed `applyDomains` rolls the in-memory change back and surfaces `lastError`, so the UI never shows a domain as enabled that the proxy does not actually serve.

- [ ] **Step 1: Write `AppStore.swift`**
- [ ] **Step 2: Build** — `make app`
- [ ] **Step 3: Commit** — `feat: hold project state and sync it to the helper`

### Task 3.3: Project list and add sheet

**Files:**
- Create: `Sources/LocaApp/Views/ProjectListView.swift`, `Sources/LocaApp/Views/AddProjectSheet.swift`
- Modify: `Sources/LocaApp/LocaAppMain.swift`

**Interfaces:**
- Consumes: `AppStore`, `ProjectDetector`, `InspectorController` (for the port cross-check; until milestone 5 lands, call `LsofParser` directly through a small `PortLookup` helper in `InspectorController.swift`).
- Produces: `struct ProjectListView: View`, `struct AddProjectSheet: View`.

`ProjectListView` is a `List` of projects showing slug, domain as a clickable link, port, an enable toggle, and a port-conflict badge when `portConflicts` is non-empty. It accepts a folder drop via `.dropDestination(for: URL.self)`, which opens `AddProjectSheet`.

`AddProjectSheet` shows the dropped folder, a slug field prefilled from `Slug.slugify` and made unique, a port field prefilled from `ProjectDetector`, the detection `sources` as explanatory text, an optional runner command prefilled from detection, and — the step the spec asks for — a live cross-check line reading either "Port 2020 is already in use by node (pid 4711), which matches your project" or "Nothing is listening on port 2020 yet". Save is disabled while `Validation` throws, with the specific reason shown inline.

- [ ] **Step 1: Write both views and mount `ProjectListView` as the main window**
- [ ] **Step 2: Build** — `make app`
- [ ] **Step 3: Verify by hand** — drop a real project folder, confirm the slug, port, and command are proposed and the cross-check line is right, save, and confirm the row appears.
- [ ] **Step 4: Verify the toggle reaches the proxy** — toggle the domain off, then `curl -sI https://<slug>.test`. Expected: it fails to connect. Toggle on, curl again. Expected: a response.
- [ ] **Step 5: Verify a duplicate slug is refused** — try to add the same slug twice, confirm the inline error.
- [ ] **Step 6: Commit** — `feat: list, add, enable, and disable domains from the window`

### Task 3.4: Onboarding

**Files:**
- Create: `Sources/LocaApp/Views/OnboardingView.swift`
- Modify: `Sources/LocaApp/LocaAppMain.swift`

**Interfaces:**
- Consumes: `HelperClient`, `Paths`.
- Produces: `struct OnboardingView: View`.

Four gated steps, each showing its own state and a retry action: install the helper, install `/etc/resolver/test` (reporting the backup path when one was made), trust the CA (warning that this is one authentication prompt, once), and a final checks panel. The panel carries the two warnings the spec insists on, because both read as app bugs otherwise:

- Firefox keeps its own trust store, so `https://<slug>.test` stays untrusted there until `security.enterprise_roots.enabled` is set to `true` in `about:config`.
- Existing `.local` entries in `/etc/hosts` are detected and listed, with a plain statement that Loca will not touch them and that `.local` collides with mDNS.

It also surfaces `port80Owner` and `port443Owner` from `diagnostics` when either is held by something that is not our Caddy.

- [ ] **Step 1: Write `OnboardingView.swift` and show it when any gate is unmet**
- [ ] **Step 2: Build** — `make app`
- [ ] **Step 3: Verify** — with a `.local` line present in `/etc/hosts`, confirm the warning lists it; with something else on 443, confirm the owner is named.
- [ ] **Step 4: Commit** — `feat: gate first run behind helper, resolver, and CA trust onboarding`

### Task 3.5: Close out milestone 3

- [ ] **Step 1: `swift test`** — Expected: green.
- [ ] **Step 2: Re-run the toggle verification from Task 3.3**
- [ ] **Step 3: Open the pull request**

```bash
git push -u origin feat/m3-window
gh pr create --base main --title "Milestone 3 — SwiftUI window and onboarding" \
  --body "Closes #<issue>. Project list with enable toggles and port-conflict badges, folder-drop add sheet with detection and a live port cross-check, and onboarding gating helper install, resolver, and CA trust — including the Firefox and /etc/hosts warnings. Verified: toggling a domain changes what curl gets." \
  --label "milestone-3,ui,enhancement" --assignee jacksonmafra-umain
```

---

# Milestone 4 — Runner

GitHub issue: "Milestone 4 — runner: play, stop, autostart, logs". Branch `feat/m4-runner`. Verification: a dev server starts from the UI and survives quitting the app.

### Task 4.1: Runner controller

**Files:**
- Create: `Sources/LocaApp/RunnerController.swift`

**Interfaces:**
- Consumes: `LaunchAgentPlist`, `LaunchctlStatusParser`, `RestartTracker`, `Paths`.
- Produces:

```swift
@MainActor @Observable final class RunnerController {
    init(paths: Paths = Paths())
    func status(for project: Project) -> LaunchctlStatus
    func start(_ project: Project) throws        // write plist, bootstrap or kickstart
    func stop(_ project: Project) throws         // bootout
    func restart(_ project: Project) throws      // kickstart -k
    func removeAgent(_ project: Project) throws
    func refreshAll(_ projects: [Project])
    var statuses: [UUID: LaunchctlStatus] { get }
    var unstable: Set<UUID> { get }
}

enum RunnerError: Error {
    case missingRunner
    case launchctlFailed(command: String, status: Int32, output: String)
}
```

Command mapping, exactly as the spec lays out:

- `start` writes `~/Library/LaunchAgents/dev.loca.run.<slug>.plist`, then runs `launchctl bootstrap gui/$UID <plist>`; when the label is already loaded it runs `launchctl kickstart -k gui/$UID/dev.loca.run.<slug>` instead.
- `stop` runs `launchctl bootout gui/$UID/dev.loca.run.<slug>`, which tears down the whole process group. This is the difference between stopping a server and leaving an orphan holding the port.
- `status` runs `launchctl print gui/$UID/dev.loca.run.<slug>` and parses it with `LaunchctlStatusParser`.

`refreshAll` polls every 3 seconds while the window is visible, feeds each observed pid change into that project's `RestartTracker`, and adds the project to `unstable` once the tracker trips. A pid *change* is the signal, because `launchctl` reports no restart count worth keying on.

Split the mechanics out into a non-isolated `RunnerAgent`, the way `SystemResolver` is split from `ResolverInstaller`. The controller is `@MainActor` and exists to drive a UI, but the same `launchctl` calls are needed from the command line, which runs before the main actor has an executor.

**macOS will not let an agent work in a protected folder.** `~/Downloads`, `~/Documents`, `~/Desktop`, and iCloud Drive are guarded by TCC, and a `launchd` agent has no window to show a consent prompt in — so it is never asked and never granted. It cannot even resolve its own working directory there:

```
shell-init: error retrieving current directory: getcwd:
cannot access parent directories: Operation not permitted
```

The server may limp along or fail outright depending on whether it touches the filesystem, and the cause is invisible either way. Add `ProtectedFolder` to `LocaCore` (pure, so it is testable) and warn in the add sheet and the detail pane. Warn, never reject: a user who has granted the permission, or whose server never reads a file, is entitled to carry on.

- [ ] **Step 1: Write `RunnerAgent.swift`, then `RunnerController.swift` over it**
- [ ] **Step 2: Add `ProtectedFolder` to `LocaCore` with tests** — cover each guarded directory, ordinary locations, a similarly named sibling (`~/Downloads2` is not inside `~/Downloads`), and another user's home.
- [ ] **Step 3: Add `--start-runner`, `--stop-runner`, and `--runner-status` to the app binary**, looking the project up in the saved config so a runner started from a shell uses exactly the command the UI would. This is what makes the milestone verifiable without clicking.
- [ ] **Step 4: Build** — `make app`
- [ ] **Step 5: Commit** — `feat: drive per-project launchd agents from the app`

### Task 4.2: Detail panel, log tail, crash-loop offer

**Files:**
- Create: `Sources/LocaApp/Views/ProjectDetailView.swift`, `Sources/LocaApp/LogTailer.swift`
- Modify: `Sources/LocaApp/Views/ProjectListView.swift`

**Interfaces:**
- Consumes: `RunnerController`, `AppStore`, `Paths.runnerLog(slug:)`.
- Produces: `struct ProjectDetailView: View`, `@MainActor @Observable final class LogTailer`.

`LogTailer` opens the log file, seeks to the last 64 KB, publishes those lines, then follows appends using a `DispatchSource` file-system-object source on the descriptor, reopening on rename or truncation. It stops when the view disappears — an unbounded tail on a hidden view is a slow leak.

`ProjectDetailView` shows the run status and pid, play/stop/restart buttons, `autoStart` and `keepAlive` toggles that persist through `AppStore.update`, the command field, the last exit status when non-zero, and the live log. When the project is in `RunnerController.unstable`, a banner reads that the command restarted three times in a minute and offers a single button that stops the runner and clears `autoStart`.

- [ ] **Step 1: Write `LogTailer.swift`**
- [ ] **Step 2: Write `ProjectDetailView.swift` and wire selection from the list**
- [ ] **Step 3: Build** — `make app`
- [ ] **Step 4: Verify play** — press play on a real project and confirm the status turns running with a pid, the log fills, and `curl -sI https://<slug>.test` returns 200.
- [ ] **Step 5: Verify survival** — quit the app, then `launchctl print gui/$UID/dev.loca.run.<slug> | grep -E 'state|pid'`. Expected: still running. Relaunch the app and confirm it reports running.
- [ ] **Step 6: Verify stop kills the group** — press stop, then confirm `lsof -nP -iTCP:<port> -sTCP:LISTEN` is empty.
- [ ] **Step 7: Verify autostart** — enable `autoStart`, log out and back in, and confirm the server is running.
- [ ] **Step 8: Verify the crash-loop banner** — set the command to `exit 1`, enable `keepAlive`, press play, and confirm the banner appears within about a minute and its button stops the runner.
- [ ] **Step 9: Commit** — `feat: run, stop, and monitor project servers with live logs`

### Task 4.3: Close out milestone 4

- [ ] **Step 1: `swift test`** — Expected: green.
- [ ] **Step 2: Re-run the survival and crash-loop verifications**
- [ ] **Step 3: Open the pull request**

```bash
git push -u origin feat/m4-runner
gh pr create --base main --title "Milestone 4 — project runner" \
  --body "Closes #<issue>. One launchd agent per project in gui/\$UID: play, stop via bootout (whole process group), restart, autostart at login, keepAlive, live log tail, and a crash-loop banner after 3 restarts in 60s. Verified: a server started from the UI survives quitting the app." \
  --label "milestone-4,runner,launchd,enhancement" --assignee jacksonmafra-umain
```

---

# Milestone 5 — Port inspector

GitHub issue: "Milestone 5 — port inspector with Docker awareness". Branch `feat/m5-inspector`. Verification: the list distinguishes a node process from a container.

### Task 5.1: Docker socket client

**Files:**
- Create: `Sources/LocaApp/DockerSocketClient.swift`

**Interfaces:**
- Consumes: `DockerPortMapper.decode`.
- Produces:

```swift
struct DockerSocketClient: Sendable {
    init(socket: URL = URL(filePath: "/var/run/docker.sock"))
    func containers() async -> [DockerContainerPort]   // empty when the socket is absent
}
```

A minimal HTTP/1.1 `GET /containers/json` over an `AF_UNIX` stream socket: connect, write the request with `Connection: close`, read to EOF, split on the header terminator, and hand the body to `DockerPortMapper.decode`. Chunked responses are handled by de-chunking when `Transfer-Encoding: chunked` is present. Every failure path returns an empty array, because the spec requires this to degrade silently when Docker is not installed — a missing socket is the normal case, not an error worth showing.

- [ ] **Step 1: Write `DockerSocketClient.swift`**
- [ ] **Step 2: Build** — `make app`
- [ ] **Step 3: Verify with Docker running** — start `docker run -d -p 5432:5432 postgres:16`, and confirm the client returns that container. Stop it.
- [ ] **Step 4: Verify without Docker** — `sudo mv /var/run/docker.sock /var/run/docker.sock.off` (or simply stop Docker), confirm the inspector still renders and shows no error, then restore.
- [ ] **Step 5: Commit** — `feat: read published container ports from the Docker socket`

### Task 5.2: Inspector controller and view

**Files:**
- Create: `Sources/LocaApp/InspectorController.swift`, `Sources/LocaApp/Views/InspectorView.swift`
- Modify: `Sources/LocaApp/LocaAppMain.swift`

**Interfaces:**
- Consumes: `LsofParser`, `DockerPortMapper.enrich`, `DockerSocketClient`, `AppStore.projects`.
- Produces:

```swift
@MainActor @Observable final class InspectorController {
    var rows: [InspectorRow] { get }
    var isPolling: Bool { get }
    func startPolling()    // every 2 seconds
    func stopPolling()
    func refresh() async
    func revealFolder(_ row: InspectorRow)
    func kill(_ row: InspectorRow) async throws   // SIGTERM, then SIGKILL after 5s
}

enum InspectorError: Error { case notPermitted(pid: Int32), stillAlive(pid: Int32) }
```

`refresh` runs `lsof -nP -iTCP -sTCP:LISTEN`, enriches with Docker, then fills each row's `domain` by matching `Project.port`. Polling runs every 2 seconds and only while the tab is visible — `stopPolling` on disappear is not an optimization, it is the difference between an idle app and one that spawns `lsof` forever.

`kill` sends `SIGTERM`, waits up to 5 seconds, then `SIGKILL`. When the target's uid is not ours it escalates through the helper rather than failing; killing our own process needs no privilege, which is why the helper is only involved in the other case. It never uses a modal dialog that could block the run loop — confirmation is an inline SwiftUI `confirmationDialog`.

`InspectorView` is a `Table` with columns for port, owner, detail, pid, and domain, a badge distinguishing a container row from a plain process, a filter field, and a row context menu offering reveal, "create a domain for this port" (which opens `AddProjectSheet` prefilled), and kill behind the confirmation.

- [ ] **Step 1: Write `InspectorController.swift`**
- [ ] **Step 2: Write `InspectorView.swift` and add it as a second tab**
- [ ] **Step 3: Build** — `make app`
- [ ] **Step 4: Verify the distinction** — with both a `node` server and `docker run -d -p 5432:5432 postgres:16` running, confirm the node row shows `node` and the container row shows the container name and image, not `com.docker.backend`.
- [ ] **Step 5: Verify the domain column** — confirm a registered project's port shows its domain.
- [ ] **Step 6: Verify polling stops** — switch to the projects tab and confirm no further `lsof` processes spawn (`sudo fs_usage -f exec | grep lsof`, or simply watch Activity Monitor).
- [ ] **Step 7: Verify kill** — kill a throwaway `python3 -m http.server 8099` from the inspector and confirm the row disappears.
- [ ] **Step 8: Verify "create a domain for this port"** — confirm the add sheet opens prefilled with that port.
- [ ] **Step 9: Commit** — `feat: inspect listening ports with Docker awareness and row actions`

### Task 5.3: Close out milestone 5

- [ ] **Step 1: `swift test`** — Expected: green.
- [ ] **Step 2: Re-run the node-versus-container verification**
- [ ] **Step 3: Open the pull request**

```bash
git push -u origin feat/m5-inspector
gh pr create --base main --title "Milestone 5 — port inspector" \
  --body "Closes #<issue>. Listening ports polled every 2s only while visible, Docker-published ports resolved to container names through the socket (degrading silently when absent), the domain column cross-referenced with registered projects, and row actions: reveal, create a domain for this port, and kill (SIGTERM then SIGKILL). Verified: node and a container render distinctly." \
  --label "milestone-5,inspector,docker,enhancement" --assignee jacksonmafra-umain
```

---

# Milestone 6 — Menu bar and README

GitHub issue: "Milestone 6 — menu bar item and build documentation". Branch `feat/m6-menubar`. Verification: a third party clones the repository and builds it.

### Task 6.1: Menu bar item

**Files:**
- Create: `Sources/LocaApp/Views/MenuBarView.swift`
- Modify: `Sources/LocaApp/LocaAppMain.swift`

**Interfaces:**
- Consumes: `AppStore`, `RunnerController`, `HelperClient`.
- Produces: `struct MenuBarView: View`.

A `MenuBarExtra` listing every project with a status dot (running, stopped, unstable, domain disabled), a click that opens `https://<slug>.test`, a submenu per project offering play, stop, and toggle domain, then a divider and: open the main window, helper status, and quit. The window becomes closable without quitting the app, which is what makes a menu bar item worth having.

- [ ] **Step 1: Write `MenuBarView.swift` and add the `MenuBarExtra` scene**
- [ ] **Step 2: Build** — `make app`
- [ ] **Step 3: Verify** — confirm the icon appears, the status dots match the window, play and stop work from the menu, closing the window leaves the app running, and Quit exits.
- [ ] **Step 4: Commit** — `feat: add a menu bar item with per-project status and actions`

### Task 6.2: README and uninstall

**Files:**
- Create: `README.md`
- Modify: `Makefile`

**Interfaces:**
- Produces: `make uninstall` removing the helper, the resolver file, the CA trust, and every runner agent.

The README covers, in this order: what Loca does and the four-line summary of how; requirements (macOS 14, Xcode 26, an Apple Development signing identity); `make vendor-caddy && make app && make install`; how to point `SIGN_ID` at your own identity, including how to find it with `security find-identity -v -p codesigning`; the three authentication prompts and what each is for; the Firefox `security.enterprise_roots.enabled` caveat; the `.local`-in-`/etc/hosts` note; `make uninstall` and what it removes; troubleshooting for the failure modes the spec enumerates (`:80`/`:443` already bound, a pre-existing `/etc/resolver/test`, revoked CA trust, a runner crash loop, nothing listening upstream); and a statement that the app is Development-signed and not notarized, so a third party builds it themselves.

- [ ] **Step 1: Write `README.md`**
- [ ] **Step 2: Add the `uninstall` target**, driving a `--uninstall` flag on the app binary.

Order matters. Runner agents go first: one left loaded keeps a server running with nothing remaining to stop it. Certificate trust goes next, and from the app's own session, since it lives in the user's keychain and only the user can remove it — the same reason the helper could not install it. Then the helper's state (resolver file and state directory), and the daemon last, because every step above needs it alive. Attempt every step even after one fails, and report each: a half-removed install is worse than a fully removed one with a complaint attached.

Leave the domain list, the runner logs, and the project folders, and say so. Somebody uninstalling to fix a problem should not lose the record of what they had registered.

- [ ] **Step 3: Verify the clean-room build** — clone the repository into a fresh directory, run `make vendor-caddy && make test && make app`, and confirm it succeeds with no manual step the README does not mention.
- [ ] **Step 4: Verify uninstall** — run `make uninstall`, then confirm: `/etc/resolver/` no longer holds `test`, `scutil --dns` no longer lists the domain, `security dump-trust-settings` no longer shows the Caddy authority (and still shows anything unrelated the user had trusted), `/Library/Application Support/dev.loca` is gone, no `dev.loca.run.*` plists remain, `--helper-status` reports not registered, and `config.json` and the logs survive.
- [ ] **Step 5: Reinstall afterwards**, so the machine is left working. The certificate step prompts for a password again, since the uninstall removed the old authority along with Caddy's storage.
- [ ] **Step 6: Commit** — `docs: document building, signing, installing, and uninstalling Loca`

### Task 6.3: Close out milestone 6

- [ ] **Step 1: `swift test`** — Expected: green.
- [ ] **Step 2: Re-run the clean-room build**
- [ ] **Step 3: Open the pull request**

```bash
git push -u origin feat/m6-menubar
gh pr create --base main --title "Milestone 6 — menu bar item and documentation" \
  --body "Closes #<issue>. MenuBarExtra with per-project status and actions, the window closable without quitting, README covering build/sign/install/uninstall plus the Firefox and /etc/hosts caveats and every failure mode from the spec, and a \`make uninstall\` that reverses everything. Verified: a clean clone builds with no undocumented step." \
  --label "milestone-6,ui,documentation,enhancement" --assignee jacksonmafra-umain
```

---

## Deferred, tracked as issues but out of scope

These come straight from the spec's "out of scope" and "failure modes" sections. Each gets a GitHub issue labeled `deferred` so it is recorded rather than forgotten:

- A versioned `.loca.json` in the project repository, for sharing configuration with a team.
- Notarization, DMG packaging, and auto-update.
- Managing the user's pre-existing hand-written `/etc/hosts` entries (the app warns once and never touches them).
- Detecting a folder that was moved or deleted after registration, and offering to relocate it.

## Manual verification that no test can cover

Recorded here so it is run deliberately at the end, not assumed:

- An XPC client that is unsigned, or signed by another team, is rejected. Build a tiny throwaway client, sign it ad-hoc, connect to `dev.loca.helper`, and confirm the connection is refused and the helper logs the rejection.
- A port already held is named in diagnostics: `sudo python3 -m http.server 443`, then `--diagnostics` shows `port443Owner: Python (pid …)`.
- A hand-written `/etc/resolver/test` is backed up rather than overwritten on the real `/etc`: `sudo tee /etc/resolver/test <<< "nameserver 9.9.9.9"`, then `--install-resolver`, then `ls /etc/resolver/` shows a `test.loca-backup-*` file. (The logic itself is covered by `ResolverInstallerTests` against a temporary directory; this only confirms the real path.)
- `curl -sI https://projeto1.test` returns a response over a trusted certificate.
- The DNS listener still answers after a sleep and wake cycle.
- Caddy is restarted with backoff after `sudo pkill -f 'caddy run'`.

Already verified in this session, against the running daemon: `dig` answers `127.0.0.1` for A and `::1` for AAAA over both UDP and TCP, `MX` comes back `NOERROR` with zero answers, `scutil --dns` lists the `test` domain on `127.0.0.1:53531`, and `ping deep.sub.anything.test` resolves without an explicit server.
