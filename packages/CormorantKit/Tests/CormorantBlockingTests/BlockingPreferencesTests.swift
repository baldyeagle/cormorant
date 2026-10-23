import Foundation
import Testing
@testable import CormorantBlocking

@Suite("BlockingPreferences")
struct BlockingPreferencesTests {
    @Test func normalizeLowercasesAndStripsOneWWW() {
        #expect(BlockingPreferences.normalize(host: "WWW.Example.COM") == "example.com")
        #expect(BlockingPreferences.normalize(host: "www.www.example.com") == "www.example.com")
        #expect(BlockingPreferences.normalize(host: "sub.example.com") == "sub.example.com")
        #expect(BlockingPreferences.normalize(host: "wwwexample.com") == "wwwexample.com")
        #expect(BlockingPreferences.normalize(host: "example.com.") == "example.com")
    }

    @Test func defaultsBlockEverywhereWithAllLists() {
        let preferences = BlockingPreferences.default
        #expect(preferences.isEnabled)
        #expect(preferences.enabledSources == FilterListSource.defaultSet)
        #expect(preferences.isBlocking(host: "example.com"))
        #expect(preferences.isBlocking(host: nil))
    }

    @Test func perHostToggle() {
        var preferences = BlockingPreferences()
        preferences.setBlocking(false, host: "www.Example.com")
        #expect(preferences.disabledHosts == ["example.com"])
        #expect(!preferences.isBlocking(host: "example.com"))
        #expect(!preferences.isBlocking(host: "WWW.EXAMPLE.COM"))
        #expect(preferences.isBlocking(host: "other.com"))
        #expect(preferences.isBlocking(host: "sub.example.com"))
        #expect(preferences.isBlocking(host: nil))

        preferences.setBlocking(true, host: "example.com")
        #expect(preferences.disabledHosts.isEmpty)
        #expect(preferences.isBlocking(host: "www.example.com"))
    }

    @Test func globalSwitchWins() {
        var preferences = BlockingPreferences(isEnabled: false)
        #expect(!preferences.isBlocking(host: nil))
        #expect(!preferences.isBlocking(host: "example.com"))
        preferences.setBlocking(true, host: "example.com")
        #expect(!preferences.isBlocking(host: "example.com"))
    }

    @Test func roundTripsThroughCodable() throws {
        var preferences = BlockingPreferences(enabledSources: [.easyList])
        preferences.setBlocking(false, host: "news.example")
        let decoded = try JSONDecoder().decode(BlockingPreferences.self, from: JSONEncoder().encode(preferences))
        #expect(decoded == preferences)
    }
}
