import Foundation

/// Reads `/etc/hosts` — and only ever reads it.
///
/// The design document deferred migrating these entries because "`/etc/hosts`
/// is shared with everything else on the machine, and silently rewriting it is
/// not a thing this app should do without a much more careful design". That is
/// right, and the careful design turns out to be: **do not write it at all.**
///
/// Everything the issue actually wants — noticing the old workaround, and
/// replacing it — can be done without touching the file. Loca creates the
/// `.test` domain, then shows the exact line that has become redundant and the
/// exact command to remove it. The user decides. A tool that edits a file every
/// other tool on the machine also edits, on its own initiative, is a tool you
/// cannot trust with root.
public enum HostsFile {
    public static let path = "/etc/hosts"

    /// One non-comment line.
    public struct Entry: Equatable, Sendable {
        public var address: String
        public var names: [String]
        /// 1-based, so it can be quoted to the user as "line 12".
        public var lineNumber: Int
        public var rawLine: String

        public init(address: String, names: [String], lineNumber: Int, rawLine: String) {
            self.address = address
            self.names = names
            self.lineNumber = lineNumber
            self.rawLine = rawLine
        }

        /// Only loopback entries are Loca's business.
        ///
        /// A `.local` name pointed at a LAN address is a different thing
        /// entirely — a device on the network, or a colleague's machine — and
        /// offering to replace it with a loopback domain would be wrong.
        public var isLoopback: Bool {
            address == "127.0.0.1" || address == "::1"
        }
    }

    /// A group of `.local` names Loca can replace with a single domain.
    public struct Candidate: Equatable, Sendable {
        /// The label a `.test` domain would use.
        public var base: String
        /// Every `.local` name this would replace.
        public var names: [String]
        /// The lines those names came from.
        public var lineNumbers: [Int]

        public init(base: String, names: [String], lineNumbers: [Int]) {
            self.base = base
            self.names = names
            self.lineNumbers = lineNumbers
        }

        /// What registering `base` would give, so the trade is visible.
        ///
        /// This is the part worth showing: Loca's wildcard means one domain
        /// covers a whole family. Four hand-written hosts names collapse into
        /// one registration, and any subdomain nobody thought of yet works too.
        public var replacements: [String] {
            names.map { name in
                name.replacingOccurrences(of: ".local", with: ".test")
            }
        }
    }

    // MARK: - Parsing

    public static func parse(_ contents: String) -> [Entry] {
        var entries: [Entry] = []

        for (index, line) in contents.split(
            separator: "\n", omittingEmptySubsequences: false
        ).enumerated() {
            let raw = String(line)

            // A commented-out line is skipped by looking at its start, not by
            // splitting on "#": `split` drops the empty leading component, so
            // "# 127.0.0.1 app.local" would come back looking like a live
            // entry with the marker quietly removed.
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#") else { continue }

            // A trailing comment is legal, and the names before it still count.
            let withoutComment =
                trimmed.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
            let fields = withoutComment.split(whereSeparator: \.isWhitespace).map(String.init)

            guard fields.count >= 2 else { continue }
            entries.append(
                Entry(
                    address: fields[0],
                    names: Array(fields.dropFirst()),
                    lineNumber: index + 1,
                    rawLine: raw))
        }

        return entries
    }

    public static func read() -> [Entry] {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return parse(contents)
    }

    // MARK: - Candidates

    /// Groups loopback `.local` names by the label a `.test` domain would use.
    ///
    /// `admin.linshare.local`, `user.linshare.local`, and `linshare.local` all
    /// become one candidate for `linshare`, because that single registration
    /// covers all three.
    public static func candidates(in entries: [Entry]) -> [Candidate] {
        var names: [String: [String]] = [:]
        var lines: [String: Set<Int>] = [:]

        for entry in entries where entry.isLoopback {
            for name in entry.names where name.hasSuffix(".local") {
                guard let base = baseLabel(of: name) else { continue }
                names[base, default: []].append(name)
                lines[base, default: []].insert(entry.lineNumber)
            }
        }

        return names.keys.sorted().map { base in
            Candidate(
                base: base,
                names: names[base]?.sorted() ?? [],
                lineNumbers: (lines[base] ?? []).sorted())
        }
    }

    public static func candidates(in contents: String) -> [Candidate] {
        candidates(in: parse(contents))
    }

    /// The label immediately before `.local`.
    ///
    /// `admin.linshare.local` and `linshare.local` share `linshare`, which is
    /// the whole reason one Loca domain can replace both.
    static func baseLabel(of name: String) -> String? {
        let labels = name.split(separator: ".").map(String.init)
        guard labels.count >= 2, labels.last == "local" else { return nil }

        let base = labels[labels.count - 2]
        let slug = Slug.slugify(base)
        return Slug.isValid(slug) ? slug : nil
    }

    // MARK: - Removal instructions, never removal

    /// The lines a candidate's names appear on, for showing the user what is
    /// now redundant.
    public static func lines(_ numbers: [Int], in entries: [Entry]) -> [Entry] {
        entries.filter { numbers.contains($0.lineNumber) }
    }

    /// The command a user would run themselves.
    ///
    /// Loca prints it and never runs it. `sudo` is the user's to type, on a
    /// file that belongs to the whole machine.
    public static var editCommand: String {
        "sudo nano \(path)"
    }
}
