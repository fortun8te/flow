import Foundation
import Testing
@testable import Voice

/// Dictation cleanup routes by length between T4 step 918 and T5 v3c on one server (22 Nov 2026).
@Suite("Dictation adapter routing by length (built, shipped off)")
struct DictationRoutingTests {
    @Test("Shipped: routing is off, so T5 v3c cleans every length and one adapter is loaded")
    func shippedDefaultIsV3cEverywhere() {
        #expect(!DictationRouting.enabled)
        for words in [3, 60, 300] {
            #expect(DictationRouting.choose(words: words, pinned: nil, v3cInstalled: true) == .v3c)
        }
        #expect(DictationRouting.served(pinned: nil, v3cInstalled: true) == [.v3c])
        #expect(DictationRouting.choose(words: 300, pinned: .t4, v3cInstalled: true) == .t4)
    }

    @Test("Short and medium dictations use T4 step 918; long ones use T5 v3c")
    func routesByWordCount() {
        #expect(DictationRouting.adapter(words: 1) == .t4)
        #expect(DictationRouting.adapter(words: DictationRouting.longWords - 1) == .t4)
        #expect(DictationRouting.adapter(words: DictationRouting.longWords) == .v3c)
        #expect(DictationRouting.adapter(words: 600) == .v3c)
        #expect(DictationRouting.words("one two\nthree\tfour  five") == 5)
    }

    @Test("A pinned adapter wins over routing; without the T5 file everything uses step 918")
    func pinnedAdapterWins() {
        let long = DictationRouting.longWords + 10
        #expect(DictationRouting.choose(words: long, pinned: nil, v3cInstalled: true, routing: true) == .v3c)
        #expect(DictationRouting.choose(words: 12, pinned: nil, v3cInstalled: true, routing: true) == .t4)
        #expect(DictationRouting.choose(words: long, pinned: .t4, v3cInstalled: true, routing: true) == .t4)
        #expect(DictationRouting.choose(words: 12, pinned: .v3c, v3cInstalled: true, routing: true) == .v3c)
        #expect(DictationRouting.choose(words: long, pinned: nil, v3cInstalled: false, routing: true) == .t4)
        #expect(DictationRouting.choose(words: long, pinned: .v3c, v3cInstalled: false, routing: true) == .t4)
        // Routing keeps both adapters on one server (no second model); a pin loads just one.
        #expect(DictationRouting.served(pinned: nil, v3cInstalled: true, routing: true) == [.v3c, .t4])
        #expect(DictationRouting.served(pinned: .t4, v3cInstalled: true, routing: true) == [.t4])
        #expect(DictationRouting.served(pinned: .v3c, v3cInstalled: true, routing: true) == [.v3c])
        #expect(DictationRouting.served(pinned: nil, v3cInstalled: false, routing: true) == [.t4])
    }

    @Test("Each request turns on exactly one adapter; quick polish turns every dictation adapter off")
    func loraScalesPickOneAdapter() {
        func scales(_ list: [[String: Any]]) -> [Int: Double] {
            Dictionary(uniqueKeysWithValues: list.map { ($0["id"] as! Int, Double("\($0["scale"]!)")!) })
        }
        let served: [WhisperNowTunedPolisher.DictationAdapter] = [.v3c, .t4]
        #expect(scales(WhisperNowTunedPolisher.loraScales(served: served, adapter: .t4, quickLoaded: true))
                == [0: 0, 1: 1, 2: 0])
        #expect(scales(WhisperNowTunedPolisher.loraScales(served: served, adapter: .v3c, quickLoaded: false))
                == [0: 1, 1: 0])
        #expect(scales(WhisperNowTunedPolisher.loraScales(served: served, adapter: nil, quickLoaded: true))
                == [0: 0, 1: 0, 2: 1])
        // A single served adapter keeps the old two-id layout for quick polish.
        #expect(scales(WhisperNowTunedPolisher.loraScales(served: [.v3c], adapter: nil, quickLoaded: true))
                == [0: 0, 1: 1])
    }
}
