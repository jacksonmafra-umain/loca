import Testing

@testable import LocaCore

@Suite("Slug")
struct SlugTests {
    @Test(
        arguments: [
            ("Projeto 1", "projeto-1"),
            ("My_App", "my-app"),
            ("São Paulo", "sao-paulo"),
            ("  --weird--  ", "weird"),
            ("", "project"),
            ("...", "project"),
            ("ALLCAPS", "allcaps"),
            ("já-ok", "ja-ok"),
            ("a  b   c", "a-b-c"),
            ("api.v2", "api-v2"),
        ])
    func slugifyNormalizes(input: String, expected: String) {
        #expect(Slug.slugify(input) == expected)
    }

    @Test func slugifyIsIdempotent() {
        for raw in ["Projeto 1", "São Paulo", "...", "a  b"] {
            let once = Slug.slugify(raw)
            #expect(Slug.slugify(once) == once)
        }
    }

    @Test func uniqueAppendsCounter() {
        #expect(Slug.unique("api", taken: []) == "api")
        #expect(Slug.unique("api", taken: ["api"]) == "api-2")
        #expect(Slug.unique("api", taken: ["api", "api-2"]) == "api-3")
        #expect(Slug.unique("api", taken: ["api", "api-2", "api-3"]) == "api-4")
    }

    @Test func uniqueNormalizesItsCandidateFirst() {
        #expect(Slug.unique("My App", taken: ["my-app"]) == "my-app-2")
    }

    @Test func isValidAcceptsOnlyWhatSlugifyWouldLeaveAlone() {
        #expect(Slug.isValid("projeto-1"))
        #expect(Slug.isValid("api"))
        #expect(Slug.isValid("a1"))
        #expect(!Slug.isValid("Projeto"))
        #expect(!Slug.isValid("pro jeto"))
        #expect(!Slug.isValid("-x"))
        #expect(!Slug.isValid("x-"))
        #expect(!Slug.isValid("a--b"))
        #expect(!Slug.isValid("são"))
        #expect(!Slug.isValid(""))
    }

    /// A slug becomes the leftmost DNS label, so it has to survive as one.
    @Test func slugifyStaysWithinTheDNSLabelLimit() {
        let long = String(repeating: "ab ", count: 40)
        #expect(Slug.slugify(long).count <= 63)
        #expect(Slug.isValid(Slug.slugify(long)))
    }
}
