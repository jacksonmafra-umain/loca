import Foundation
import Testing

@testable import LocaCore

@Suite("DomainPayload")
struct DomainPayloadTests {
    private let projects = [
        Project(slug: "projeto1", folder: URL(filePath: "/Users/me/code/p1"), port: 2020),
        Project(
            slug: "projeto2", folder: URL(filePath: "/Users/me/code/p2"), port: 2021,
            enabled: false),
    ]

    @Test func theWireShapeRoundTripsEveryFieldTheHelperNeeds() throws {
        let decoded = try DomainPayload.decode(DomainPayload.encode(projects))
        #expect(decoded.map(\.slug) == ["projeto1", "projeto2"])
        #expect(decoded.map(\.port) == [2020, 2021])
        #expect(decoded.map(\.enabled) == [true, false])
        #expect(decoded.map { $0.folder.path(percentEncoded: false) }
            == ["/Users/me/code/p1", "/Users/me/code/p2"])
    }

    /// The helper proxies domains. It has no business knowing which UUID the
    /// app filed a project under, or what command the user runs.
    @Test func theIdentifierAndRunnerNeverCrossTheBoundary() {
        var withRunner = projects[0]
        withRunner.runner = Runner(command: "pnpm dev")
        let encoded = DomainPayload.encode([withRunner])
        #expect(encoded[0]["id"] == nil)
        #expect(encoded[0]["runner"] == nil)
        #expect(Set(encoded[0].keys) == ["slug", "port", "folder", "enabled"])
    }

    @Test func everyValueIsPropertyListCompatible() throws {
        let encoded = DomainPayload.encode(projects)
        #expect(PropertyListSerialization.propertyList(encoded, isValidFor: .xml))
    }

    // MARK: - Rejection at the privileged boundary

    @Test func aPortOutOfRangeIsRejected() {
        let payload: [[String: NSObject]] = [
            [
                "slug": "app" as NSString, "port": NSNumber(value: 0),
                "folder": "/Users/me" as NSString, "enabled": NSNumber(value: true),
            ]
        ]
        #expect(throws: ValidationError.portOutOfRange(0)) {
            _ = try DomainPayload.decode(payload)
        }
    }

    @Test func anInvalidSlugIsRejected() {
        let payload: [[String: NSObject]] = [
            [
                "slug": "Bad Slug" as NSString, "port": NSNumber(value: 3000),
                "folder": "/Users/me" as NSString, "enabled": NSNumber(value: true),
            ]
        ]
        #expect(throws: ValidationError.invalidSlug("Bad Slug")) {
            _ = try DomainPayload.decode(payload)
        }
    }

    @Test func aTraversingFolderIsRejected() {
        let payload: [[String: NSObject]] = [
            [
                "slug": "app" as NSString, "port": NSNumber(value: 3000),
                "folder": "/a/../b" as NSString, "enabled": NSNumber(value: true),
            ]
        ]
        #expect(throws: ValidationError.folderTraversal("/a/../b")) {
            _ = try DomainPayload.decode(payload)
        }
    }

    @Test func aRelativeFolderIsRejected() {
        let payload: [[String: NSObject]] = [
            [
                "slug": "app" as NSString, "port": NSNumber(value: 3000),
                "folder": "code/app" as NSString, "enabled": NSNumber(value: true),
            ]
        ]
        #expect(throws: ValidationError.folderNotAbsolute("code/app")) {
            _ = try DomainPayload.decode(payload)
        }
    }

    @Test func aMissingFieldIsRejectedRatherThanDefaulted() {
        #expect(throws: ValidationError.invalidSlug("<missing>")) {
            _ = try DomainPayload.decode([["port": NSNumber(value: 3000)]])
        }
        #expect(throws: ValidationError.portOutOfRange(0)) {
            _ = try DomainPayload.decode([["slug": "app" as NSString]])
        }
        #expect(throws: ValidationError.folderNotAbsolute("<missing>")) {
            _ = try DomainPayload.decode([
                ["slug": "app" as NSString, "port": NSNumber(value: 3000)]
            ])
        }
    }

    /// Two entries claiming one domain would generate a Caddyfile Caddy
    /// refuses, so it is caught here with a useful error instead.
    @Test func aDuplicateSlugInOnePayloadIsRejected() {
        let entry: [String: NSObject] = [
            "slug": "app" as NSString, "port": NSNumber(value: 3000),
            "folder": "/Users/me" as NSString, "enabled": NSNumber(value: true),
        ]
        #expect(throws: ValidationError.duplicateSlug("app")) {
            _ = try DomainPayload.decode([entry, entry])
        }
    }

    @Test func anEmptyPayloadIsValidAndMeansNoDomains() throws {
        #expect(try DomainPayload.decode([]).isEmpty)
    }

    /// `enabled` defaults to true, since an entry that reached the helper at
    /// all is one the app means to serve.
    @Test func aMissingEnabledFlagDefaultsToTrue() throws {
        let payload: [[String: NSObject]] = [
            [
                "slug": "app" as NSString, "port": NSNumber(value: 3000),
                "folder": "/Users/me" as NSString,
            ]
        ]
        #expect(try DomainPayload.decode(payload)[0].enabled)
    }
}

@Suite("CaddyAdminRequest")
struct CaddyAdminRequestTests {
    @Test func theLoadRequestIsExactlyWhatCaddyExpects() {
        let request = CaddyAdminRequest.load(caddyfile: "example.test {\n}\n")
        #expect(request.method == "POST")
        #expect(request.path == "/load")
        #expect(request.contentType == "text/caddyfile")
        #expect(String(decoding: request.body, as: UTF8.self) == "example.test {\n}\n")
    }

    @Test func theURLTargetsLoopbackOnly() {
        let request = CaddyAdminRequest.load(caddyfile: "")
        #expect(request.urlString == "http://127.0.0.1:2019/load")
        #expect(request.url != nil)
    }

    @Test func theAddressIsInjectableForTesting() {
        let request = CaddyAdminRequest.load(caddyfile: "", address: "127.0.0.1:9999")
        #expect(request.urlString == "http://127.0.0.1:9999/load")
    }

    @Test func aGeneratedCaddyfileSurvivesAsTheBody() {
        let caddyfile = CaddyfileBuilder.build(projects: [
            Project(slug: "projeto1", folder: URL(filePath: "/tmp/p1"), port: 2020)
        ])
        let request = CaddyAdminRequest.load(caddyfile: caddyfile)
        #expect(String(decoding: request.body, as: UTF8.self) == caddyfile)
    }
}

@Suite("Helper protocol constants")
struct HelperProtocolConstantsTests {
    @Test func theMachServiceMatchesTheHelperLabel() {
        #expect(locaHelperMachServiceName == "dev.loca.helper")
        #expect(locaHelperMachServiceName == Paths.helperLabel)
    }

    /// Deliberately not pinned to a literal. The version is meant to change
    /// whenever the protocol does, so asserting the current number would just
    /// be a tripwire that fires on every intentional bump.
    @Test func theProtocolVersionIsPositive() {
        #expect(locaHelperProtocolVersion >= 1)
    }
}
