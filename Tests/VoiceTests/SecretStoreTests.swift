import Foundation
import KeychainAccess
import Testing
@testable import Voice

@Suite("API keys live in the Keychain, not UserDefaults")
struct SecretStoreTests {
    /// A throwaway Keychain service and defaults suite, so the real ones are never touched.
    private func makeStore() -> (SecretStore, UserDefaults, String) {
        let suite = "flow.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let service = "com.example.flow.voice.keys.tests.\(UUID().uuidString)"
        var store = SecretStore(keychain: Keychain(service: service))
        store.defaults = defaults
        return (store, defaults, suite)
    }

    @Test("Writing a key stores it in the Keychain and leaves nothing in UserDefaults")
    func writeGoesToKeychain() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite); try? store.keychain.removeAll() }
        store.write(.cerebras, "test-key-placeholder-1234")
        #expect(store.read(.cerebras) == "test-key-placeholder-1234")
        #expect(defaults.string(forKey: SecretName.cerebras.legacyDefaultsKey) == nil)
    }

    @Test("An old key in UserDefaults moves to the Keychain on first read and is removed")
    func legacyValueMigrates() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite); try? store.keychain.removeAll() }
        defaults.set("nvapi-legacy-value", forKey: SecretName.nvidia.legacyDefaultsKey)
        #expect(store.read(.nvidia) == "nvapi-legacy-value")
        #expect(defaults.string(forKey: SecretName.nvidia.legacyDefaultsKey) == nil)
        // Still there on the next read, now from the Keychain.
        #expect(store.read(.nvidia) == "nvapi-legacy-value")
    }

    @Test("Clearing a key removes it everywhere")
    func emptyWriteClears() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite); try? store.keychain.removeAll() }
        defaults.set("gsk-legacy", forKey: SecretName.groq.legacyDefaultsKey)
        store.write(.groq, "   ")
        #expect(store.read(.groq) == "")
        #expect(defaults.string(forKey: SecretName.groq.legacyDefaultsKey) == nil)
    }

    @Test("Each provider has its own slot")
    func slotsAreSeparate() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite); try? store.keychain.removeAll() }
        store.write(.hyperbolic, "hyp-1")
        store.write(.nvidia, "nv-1")
        #expect(store.read(.hyperbolic) == "hyp-1")
        #expect(store.read(.nvidia) == "nv-1")
        #expect(store.read(.groq) == "")
    }
}

@Suite("Style cards never send writing samples to a cloud model")
struct StyleCardPrivacyTests {
    @Test("Extraction refuses in every setting and sends nothing")
    func extractionRefuses() async {
        let sample = StyleCardService.WritingSample(text: "A sentence of my own writing for the card test.", context: "mixed")
        UserDefaults.standard.set(true, forKey: "voice.allowCloudPolishing")
        defer { UserDefaults.standard.removeObject(forKey: "voice.allowCloudPolishing") }
        await #expect(throws: StyleCardError.self) {
            try await StyleCardService.shared.extractCard(from: [sample, sample, sample, sample, sample, sample, sample, sample])
        }
    }
}
