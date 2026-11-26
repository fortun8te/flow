import Foundation

/// Repeated contexts need one model evaluation, with scores restored to caller order.
/// Keys use UTF-8 bytes: canonically equivalent Swift strings can tokenize differently.
enum ContextScoreBatch {
    static func score(_ texts: [String], evaluate: ([String]) -> [Float]) -> [Float] {
        guard !texts.isEmpty else { return [] }
        var indices: [Data: Int] = [:]
        var unique: [String] = []
        var order: [Int] = []
        order.reserveCapacity(texts.count)
        for text in texts {
            let key = Data(text.utf8)
            if let index = indices[key] {
                order.append(index)
            } else {
                indices[key] = unique.count
                order.append(unique.count)
                unique.append(text)
            }
        }
        let scores = evaluate(unique)
        guard scores.count == unique.count else { return Array(repeating: .nan, count: texts.count) }
        return order.map { scores[$0] }
    }
}
