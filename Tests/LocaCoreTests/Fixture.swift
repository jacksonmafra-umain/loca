import Foundation
import Testing

/// Loads a file from `Tests/LocaCoreTests/Fixtures`, which SwiftPM copies into
/// the test bundle.
///
/// Every parser in `LocaCore` reads output produced by something outside our
/// control — `lsof`, `launchctl`, the Docker API — so its tests run against
/// captured real output rather than a hand-written idea of what that output
/// looks like.
enum Fixture {
    static func url(_ name: String) throws -> URL {
        let base = try #require(
            Bundle.module.url(forResource: "Fixtures", withExtension: nil),
            "the Fixtures directory is missing from the test bundle")
        return base.appending(path: name)
    }

    static func text(_ name: String) throws -> String {
        try String(contentsOf: try url(name), encoding: .utf8)
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: try url(name))
    }
}
