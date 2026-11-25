import Foundation
import Testing
@testable import Voice

@Suite("Local meeting model cache")
struct RebuildMeetingModelCacheTests {
    @Test("Requires all model metadata and a nonempty weight file")
    func singleFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!Qwen3Polisher.isCompleteLocalModel(at: dir))
        for name in ["config.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"] {
            try Data([1]).write(to: dir.appendingPathComponent(name))
        }
        #expect(Qwen3Polisher.isCompleteLocalModel(at: dir))
    }

    @Test("Refuses incomplete and unsafe indexed shards")
    func indexedFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["config.json", "tokenizer.json", "tokenizer_config.json"] {
            try Data([1]).write(to: dir.appendingPathComponent(name))
        }
        let index = dir.appendingPathComponent("model.safetensors.index.json")
        try Data(#"{"weight_map":{"x":"part.safetensors"}}"#.utf8).write(to: index)
        #expect(!Qwen3Polisher.isCompleteLocalModel(at: dir))
        try Data([1]).write(to: dir.appendingPathComponent("part.safetensors"))
        #expect(Qwen3Polisher.isCompleteLocalModel(at: dir))
        try Data(#"{"weight_map":{"x":"../part.safetensors"}}"#.utf8).write(to: index)
        #expect(!Qwen3Polisher.isCompleteLocalModel(at: dir))
    }
}
