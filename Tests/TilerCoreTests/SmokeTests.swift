import Testing
@testable import TilerCore

@Test func versionIsSet() {
    #expect(!TilerCore.version.isEmpty)
}
