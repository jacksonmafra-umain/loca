import Testing

@testable import LocaCore

@Test func coreVersionIsExposed() {
    #expect(LocaCoreVersion.current == 1)
}
