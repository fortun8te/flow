import Foundation

/// Wispr writes American spelling. Parakeet often hears British forms ("colours", "realise").
/// This swaps the common ones, keeping the speaker's capitalisation.
enum AmericanSpelling {
    static let settingKey = "flow.americanSpelling"
    static var enabled: Bool { UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true }

    private static let stems: [(String, String)] = [
        ("colour", "color"), ("favour", "favor"), ("flavour", "flavor"), ("honour", "honor"),
        ("humour", "humor"), ("labour", "labor"), ("neighbour", "neighbor"), ("behaviour", "behavior"),
        ("rumour", "rumor"), ("harbour", "harbor"), ("armour", "armor"), ("vapour", "vapor"),
        ("endeavour", "endeavor"), ("savour", "savor"), ("parlour", "parlor"),
        ("centre", "center"), ("theatre", "theater"), ("metre", "meter"), ("litre", "liter"), ("fibre", "fiber"),
        ("organis", "organiz"), ("realis", "realiz"), ("recognis", "recogniz"), ("apologis", "apologiz"),
        ("prioritis", "prioritiz"), ("optimis", "optimiz"), ("customis", "customiz"), ("minimis", "minimiz"),
        ("maximis", "maximiz"), ("summaris", "summariz"), ("emphasis", "emphasiz"), ("finalis", "finaliz"),
        ("visualis", "visualiz"), ("categoris", "categoriz"), ("personalis", "personaliz"), ("normalis", "normaliz"),
        ("standardis", "standardiz"), ("synchronis", "synchroniz"), ("utilis", "utiliz"), ("criticis", "criticiz"),
        ("analys", "analyz"), ("paralys", "paralyz"),
        ("defence", "defense"), ("licence", "license"), ("offence", "offense"),
        ("catalogue", "catalog"), ("dialogue", "dialog"), ("grey", "gray"),
        ("aluminium", "aluminum"), ("programme", "program"), ("tyre", "tire"), ("cheque", "check"),
        ("jewellery", "jewelry"), ("plough", "plow"), ("sceptic", "skeptic"),
    ]
    /// Endings each stem may carry; "colour" also matches "colours", "coloured", "colourful".
    private static let endings = "(s|ed|ing|er|ers|ful|fully|less|able|ation|ations|e|es|ly|ist|ists|ite|ites|al|ally|hood|hoods)?"
    /// Stems that are only safe as whole words, so "emphasis" and "analysis" survive.
    private static let wholeWordOnly: Set<String> = ["grey", "tyre", "cheque", "programme", "emphasis", "analys", "paralys"]

    private static let patterns: [(NSRegularExpression, String)] = stems.compactMap { british, american in
        let tail: String
        if wholeWordOnly.contains(british) {
            tail = british == "emphasis" ? "(e|es|ed|ing)" : british == "analys" || british == "paralys" ? "(e|es|ed|ing)" : "(s)?"
        } else { tail = endings }
        guard let regex = try? NSRegularExpression(pattern: "\\b(\(british))\(tail)\\b", options: [.caseInsensitive]) else { return nil }
        return (regex, american)
    }

    static func apply(_ text: String) -> String {
        guard enabled, !text.isEmpty else { return text }
        var result = text
        for (regex, american) in patterns {
            let ns = result as NSString
            var output = ""
            var last = 0
            for match in regex.matches(in: result, range: NSRange(location: 0, length: ns.length)) {
                output += ns.substring(with: NSRange(location: last, length: match.range.location - last))
                let stem = ns.substring(with: match.range(at: 1))
                let tailRange = match.range(at: 2)
                let tail = tailRange.location == NSNotFound ? "" : ns.substring(with: tailRange)
                output += matchCase(american, like: stem) + tail
                last = match.range.location + match.range.length
            }
            output += ns.substring(from: last)
            result = output
        }
        return result
    }

    private static func matchCase(_ word: String, like original: String) -> String {
        if original == original.uppercased(), original.count > 1 { return word.uppercased() }
        if let first = original.first, first.isUppercase { return word.prefix(1).uppercased() + word.dropFirst() }
        return word
    }
}
