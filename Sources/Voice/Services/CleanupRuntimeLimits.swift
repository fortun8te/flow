import Foundation
import CoreFoundation

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
            guard let value = Self.numericValue(row[key])?.doubleValue,
                  value.isFinite, value <= Double(Int32.max),
                  allowsZero ? value >= 0 : value > 0 else { return fallback }
            return value
        }
        timeoutBase = number("timeoutBase", default: 3, allowsZero: true)
        timeoutPerWord = number("timeoutPerWord", default: 0.12, allowsZero: true)
        timeoutMax = number("timeoutMax", default: 25)
        coldWait = number("coldWait", default: 1.5, allowsZero: true)
        idleStop = number("idleStop", default: 900)
        // llama-server parses -c through an int handler (std::stoi). A value
        // fitting Swift's 64-bit Int can still make the server refuse startup.
        if let number = Self.numericValue(row["contextSize"])?.doubleValue,
           let size = Int32(exactly: number), size > 0 {
            contextSize = Int(size)
        } else { contextSize = 8192 }
    }

    static func weightBytes(_ value: Any?) -> Int64? {
        guard let number = numericValue(value) else { return nil }
        // Read integral NSNumber values without passing through Double,
        // which rounds integers above 2^53 and can turn Int64.max invalid.
        if let bytes = Int64(number.stringValue) { return bytes > 0 ? bytes : nil }
        guard let bytes = Int64(exactly: number.doubleValue), bytes > 0,
              number.decimalValue == Decimal(bytes) else { return nil }
        return bytes
    }

    private static func numericValue(_ value: Any?) -> NSNumber? {
        // JSONSerialization represents true/false as NSNumber too. A Swift
        // Bool cast is insufficient because numeric 0 and 1 also bridge to it.
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number
    }
}
