import CryptoKit
import DialectoLiveFixtures
import Foundation
import Testing

@testable import DialectoLive

/// The Swift end of the contract: the release the Dialecto server's own test rebuilds
/// byte for byte is read, verified and hashed with no help from the server code.
struct ContractTests {
    @Test func theContractManifestVerifiesAgainstTheTestKey() throws {
        let (_, publicText) = try ContractFixture.testKey()
        let configuration = try LiveConfiguration.make(
            channel: "production", publicKeys: [publicText], builtAt: nil, baseURL: nil, onError: nil
        ).get()

        let manifest = try Data(contentsOf: ContractFixture.directory.appendingPathComponent("manifest.json"))
        let payload = try LiveClient.parse(manifest: manifest, config: configuration)

        #expect(payload.sequence == 7)
        #expect(payload.release == "rel_swiftfixture0001")
        #expect(payload.entries.map(\.locale) == ["de", "en", "zh-Hans"])
        #expect(payload.entries.allSatisfy { $0.format == "xcstrings" && $0.catalog == "localizable" })
    }

    @Test func everyPayloadMatchesItsManifestHashAndReadsAsFlatText() throws {
        let (_, publicText) = try ContractFixture.testKey()
        let configuration = try LiveConfiguration.make(
            channel: "production", publicKeys: [publicText], builtAt: nil, baseURL: nil, onError: nil
        ).get()
        let manifest = try Data(contentsOf: ContractFixture.directory.appendingPathComponent("manifest.json"))
        let payload = try LiveClient.parse(manifest: manifest, config: configuration)

        for entry in payload.entries {
            let data = try Data(contentsOf: ContractFixture.directory.appendingPathComponent("localizable/\(entry.locale).json"))
            #expect(LiveClient.sha256Hex(data) == entry.sha256)
            #expect(data.count == entry.bytes)
            let values = try LiveClient.parseFile(data)
            #expect(values["export.button"] != nil)
            #expect(values["scenes.count"] == nil)  // plural: left out
            #expect(values["app.identifier"] == nil)  // not to translate: left out
        }
    }

    @Test func aStrangersKeyDoesNotVerifyIt() throws {
        let stranger = ManifestVerifier.keyScheme + FixtureRelease.base64url(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        let configuration = try LiveConfiguration.make(
            channel: "production", publicKeys: [stranger], builtAt: nil, baseURL: nil, onError: nil
        ).get()
        let manifest = try Data(contentsOf: ContractFixture.directory.appendingPathComponent("manifest.json"))

        #expect(throws: DialectoLiveError.self) { try LiveClient.parse(manifest: manifest, config: configuration) }
    }
}

struct PlaceholderTests {
    @Test func argumentsAreThePositionedTypes() {
        #expect(PrintfPlaceholders.arguments(in: "%@ has %lld items (100%%)") == ["1$@", "2$lld"])
        #expect(PrintfPlaceholders.arguments(in: "%2$@ and %1$@") == ["2$@", "1$@"])
        #expect(PrintfPlaceholders.arguments(in: "%#@items@ left") == ["#@items@"])
        #expect(PrintfPlaceholders.arguments(in: "plain 100%%") == [])
        #expect(PrintfPlaceholders.arguments(in: "%.2f of %5d") == ["1$f", "2$d"])
    }

    @Test func starsAndUnparsedPercentsAreTokensLikeTheServers() {
        #expect(PrintfPlaceholders.arguments(in: "%*d") == ["1$*", "2$d"])
        #expect(PrintfPlaceholders.arguments(in: "%.*f") == ["1$*", "2$f"])
        #expect(PrintfPlaceholders.arguments(in: "%*.*f %@") == ["1$*", "2$*", "3$f", "4$@"])
        #expect(PrintfPlaceholders.arguments(in: "50% off") == ["1$o"])
        #expect(PrintfPlaceholders.arguments(in: "%y") == ["?%y"])
        #expect(PrintfPlaceholders.arguments(in: "ends with %") == ["?%"])
        // Positional stars and any other malformed sequence are tokens spelled as written.
        #expect(PrintfPlaceholders.arguments(in: "%*1$d") == ["?%*1$d"])
        #expect(PrintfPlaceholders.arguments(in: "%.*2$f x") == ["?%.*2$f"])
        #expect(!PrintfPlaceholders.same("%*1$d", "%*2$d"))
        #expect(!PrintfPlaceholders.same("%d", "%*1$d"))
        #expect(!PrintfPlaceholders.same("Hello", "Hallo %*1$d"))
        #expect(PrintfPlaceholders.same("%*1$d", "x %*1$d"))
        #expect(!PrintfPlaceholders.same("%d", "%*d"))
        #expect(!PrintfPlaceholders.same("%*d", "%d"))
        #expect(!PrintfPlaceholders.same("Hello", "Hallo %y"))
    }

    @Test func reorderingIsTheSameTokensAndAChangedTypeIsNot() {
        #expect(PrintfPlaceholders.same("%@ has %lld", "%2$lld in %1$@"))
        #expect(PrintfPlaceholders.same("Hello", "Hallo"))
        #expect(!PrintfPlaceholders.same("Hello %@", "Hallo %d"))
        #expect(!PrintfPlaceholders.same("Hello %@", "Hallo"))
        #expect(!PrintfPlaceholders.same("Hello", "Hallo %@"))
    }
}

struct Base64URLTests {
    @Test func decodesWithoutPaddingAndRefusesThePaddedAndTheStandardAlphabet() {
        #expect(Base64URL.decode("aGk") == Data("hi".utf8))
        #expect(Base64URL.decode("_-8") == Data([0xFF, 0xEF]))
        #expect(Base64URL.decode("aGk=") == nil)
        #expect(Base64URL.decode("/+8") == nil)
        #expect(Base64URL.decode("a") == nil)
    }
}

struct LocaleTests {
    private let available = ["de", "en", "pt-BR", "zh-Hans"]

    @Test func theSystemsLongTagFindsTheCatalogsName() {
        #expect(LocaleMatching.chain(for: "zh-Hans-DE", available: available) == ["zh-Hans"])
        #expect(LocaleMatching.chain(for: "pt_BR", available: available) == ["pt-BR"])
        #expect(LocaleMatching.chain(for: "de-AT", available: available) == ["de"])
        #expect(LocaleMatching.chain(for: "fr", available: available) == [])
    }

    @Test func aRegionThatIsThereComesBeforeItsLanguage() {
        #expect(LocaleMatching.chain(for: "de-AT", available: ["de", "de-AT"]) == ["de-AT", "de"])
        #expect(LocaleMatching.chain(for: "PT-br", available: ["pt", "pt-BR"]) == ["pt-BR", "pt"])
    }
}

struct SnapshotTests {
    @Test func aTableMatchesACatalogByItsSlugOrItsFolderPath() {
        var snapshot = LiveSnapshot(chain: ["de"])
        snapshot.catalogs["app-localizable"] = ["de": ["a": "A"]]
        snapshot.catalogs["menus"] = ["de": ["m": "M"]]

        #expect(snapshot.value(key: "a", table: nil) == "A")
        #expect(snapshot.value(key: "a", table: "Localizable") == "A")
        #expect(snapshot.value(key: "m", table: "Menus") == "M")
        #expect(snapshot.value(key: "m", table: nil) == nil)
        #expect(snapshot.value(key: "m", table: nil, anyTable: true) == "M")
        #expect(snapshot.value(key: "a", table: "Menus") == nil)
    }

    @Test func slugsFollowTheServersRule() {
        #expect(LiveSnapshot.slug("Localizable") == "localizable")
        #expect(LiveSnapshot.slug("App/Localizable") == "app-localizable")
        #expect(LiveSnapshot.slug("InfoPlist") == "infoplist")
        #expect(LiveSnapshot.slug("..") == "catalog")
    }
}
