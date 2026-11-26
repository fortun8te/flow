import Foundation

/// User-edited catalog numbers must fit both Swift integers and timer APIs.
/// Invalid values retain the documented defaults instead of trapping during a
/// dictation or silently becoming a negative/zero request timeout.
struct CleanupRuntimeLimits: Equatable, Sendable {
    let timeoutBase: Double
    let timeoutPerWord: Double
    let timeoutMax: Double
    let coldWait: Double
    let idleStop: Double
    let contextSize: Int

    init(_ row: [String: Any]) {
        func number(_ key: String, default fallback: Double, allowsZero: Bool = false) -> Double {
            guard let value = (row[key] as? NSNumber)?.doubleValue,
                  value.isFinite, value <= Double(Int32.max),
                  allowsZero ? value >= 0 : value > 0 else { return fallback }
            return value
        }
        timeoutBase = number("timeoutBase", default: 3, allowsZero: true)
        timeoutPerWord = number("timeoutPerWord", default: 0.12, allowsZero: true)
        timeoutMax = number("timeoutMax", default: 25)
        coldWait = number("coldWait", default: 1.5, allowsZero: true)
        idleStop = number("idleStop", default: 900)
        if let number = (row["contextSize"] as? NSNumber)?.doubleValue,
           let size = Int(exactly: number), size > 0 {
            contextSize = size
        } else { contextSize = 8192 }
    }

    static func weightBytes(_ value: Any?) -> Int64? {
        guard let number = (value as? NSNumber)?.doubleValue,
              let bytes = Int64(exactly: number), bytes > 0 else { return nil }
        return bytes
    }
}
