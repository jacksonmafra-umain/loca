import Foundation

public enum ConfigStoreError: Error, Equatable, Sendable {
    /// Written by a newer build. Refused rather than misread, so a downgrade
    /// cannot quietly drop fields it does not know about.
    case unsupportedVersion(Int)
}

/// Reads and writes the single persisted file.
///
/// The write is a temporary file plus a rename, which is atomic on APFS: a
/// crash mid-write leaves the previous config intact rather than a truncated
/// one. The helper never uses this type — configuration reaches root over XPC,
/// field by field, so a user-writable file is never parsed with privilege.
public struct ConfigStore: Sendable {
    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    public init(paths: Paths = Paths()) {
        self.init(file: paths.configFile)
    }

    public func load() throws -> LocaConfig {
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else {
            return LocaConfig()
        }
        let config = try JSONDecoder().decode(LocaConfig.self, from: Data(contentsOf: file))
        guard config.version <= LocaConfig.currentVersion else {
            throw ConfigStoreError.unsupportedVersion(config.version)
        }
        return config
    }

    public func save(_ config: LocaConfig) throws {
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        // A user may well open this file, so keep it readable and its diffs small.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(config)

        let temporary = directory.appending(path: ".config-\(UUID().uuidString).json")
        do {
            try data.write(to: temporary)
            // replaceItemAt removes the temporary file as part of the swap, so a
            // successful save leaves nothing behind.
            _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}
