import Foundation
import Testing

@testable import LocaCore

@Suite("Validation")
struct ValidationTests {
    private let anywhere = URL(filePath: "/Users/me/code/app")

    @Test func acceptsAValidTriple() throws {
        try Validation.validate(slug: "app", port: 3000, folder: anywhere, existing: [])
    }

    @Test func rejectsAnInvalidSlug() {
        #expect(throws: ValidationError.invalidSlug("Bad Slug")) {
            try Validation.validate(slug: "Bad Slug", port: 3000, folder: anywhere, existing: [])
        }
    }

    @Test(arguments: [0, -1, 65536, 99999])
    func rejectsPortOutOfRange(port: Int) {
        #expect(throws: ValidationError.portOutOfRange(port)) {
            try Validation.validate(slug: "app", port: port, folder: anywhere, existing: [])
        }
    }

    @Test(arguments: [1, 80, 3000, 65535])
    func acceptsPortInRange(port: Int) throws {
        try Validation.validate(slug: "app", port: port, folder: anywhere, existing: [])
    }

    @Test func rejectsTraversal() {
        let folder = URL(filePath: "/Users/me/../etc")
        #expect(throws: ValidationError.folderTraversal(folder.path(percentEncoded: false))) {
            try Validation.validateFolder(folder)
        }
    }

    /// A folder arriving over XPC is a raw string, which is the only place a
    /// relative path can actually reach us — `URL(filePath:)` resolves one
    /// against the current directory before we ever see it.
    @Test func rejectsARelativePathString() {
        #expect(throws: ValidationError.folderNotAbsolute("code/app")) {
            try Validation.validateFolderPath("code/app")
        }
        #expect(throws: ValidationError.folderNotAbsolute("")) {
            try Validation.validateFolderPath("")
        }
        #expect(throws: ValidationError.folderTraversal("/a/../b")) {
            try Validation.validateFolderPath("/a/../b")
        }
    }

    /// Duplicate slugs cannot coexist: two projects would claim one domain.
    @Test func rejectsADuplicateSlug() {
        let existing = [Project(slug: "app", folder: anywhere, port: 3000)]
        #expect(throws: ValidationError.duplicateSlug("app")) {
            try Validation.validate(slug: "app", port: 4000, folder: anywhere, existing: existing)
        }
    }

    /// Two projects on the same port is allowed. The UI flags it; the model does
    /// not get to refuse a setup that may well be intentional.
    @Test func allowsADuplicatePort() throws {
        let existing = [Project(slug: "app", folder: anywhere, port: 3000)]
        try Validation.validate(slug: "other", port: 3000, folder: anywhere, existing: existing)
    }

    @Test func ignoresTheProjectBeingEdited() throws {
        let project = Project(slug: "app", folder: anywhere, port: 3000)
        try Validation.validate(
            slug: "app", port: 3001, folder: anywhere, existing: [project], ignoring: project.id)
    }

    @Test func acceptsAnAbsolutePathWithNoTraversal() throws {
        try Validation.validateFolder(URL(filePath: "/Users/me/code/my.app"))
        try Validation.validateFolder(URL(filePath: "/"))
    }

    /// A single dot is a no-op component, not traversal, and shows up in real
    /// paths often enough that rejecting it would be a nuisance.
    @Test func acceptsASingleDotComponent() throws {
        try Validation.validateFolder(URL(filePath: "/Users/me/./code"))
    }

    @Test func rejectsTraversalHiddenInTheMiddle() {
        let folder = URL(filePath: "/Users/me/code/../../../etc/resolver")
        #expect(throws: ValidationError.folderTraversal(folder.path(percentEncoded: false))) {
            try Validation.validateFolder(folder)
        }
    }
}
