import Foundation
import NaturalLanguage

/// Language routing for dictation and Opt+1: English, Dutch, a mix, or something else, per sentence.
/// Apple's on-device recogniser (NLLanguageRecognizer, constrained to English, Dutch and German) plus
/// short marker-word lists, so two-word Dutch replies and Dutch with English tech words route correctly.
///
/// `germanDrift` catches a cleanup or polish that half-translates Dutch (or English) into German
/// ("ik weet het niet" -> "ich weiß es nicht", "dat is ook goed" -> "das ist auch gut"). The whole-text
/// language check misses these when only a few words turn German, because the result still reads as Dutch.
enum DictationLanguage {
    enum Route: String, Sendable { case english, dutch, mixed, other }

    /// Words that are only Dutch (not English, not German).
    static let dutchMarkers: Set<String> = [
        "ik", "je", "jij", "jou", "jouw", "wij", "we", "ze", "zij", "hij", "het", "een", "de", "niet", "geen", "maar",
        "ook", "nog", "wel", "dat", "dit", "deze", "die", "zijn", "heb", "hebben", "heeft", "ben", "bent", "wordt",
        "worden", "kan", "kunnen", "moet", "moeten", "wil", "willen", "gaat", "gaan", "doen", "doe", "met", "voor",
        "van", "naar", "op", "uit", "bij", "om", "als", "dan", "toch", "even", "gewoon", "echt", "heel", "veel",
        "goed", "mooi", "leuk", "waarom", "wanneer", "hoe", "wat", "wie", "waar", "zo", "er", "hier", "daar", "nu",
        "straks", "morgen", "vandaag", "gisteren", "jullie", "mijn", "zijn", "haar", "onze", "ons", "alsjeblieft",
        "bedankt", "dank", "graag", "oké", "nou", "eigenlijk", "misschien", "zeker", "beetje", "omdat", "want",
        "dus", "of", "en", "te", "aan", "over", "zou", "zal", "weet", "zeg", "zegt", "kijk", "denk", "vind"
    ]

    /// Words that are German and neither Dutch nor everyday English.
    static let germanMarkers: Set<String> = [
        "ich", "nicht", "und", "ist", "sind", "auch", "wir", "sie", "aber", "jetzt", "schon", "sehr", "für", "über",
        "mit", "eine", "einen", "einem", "einer", "ein", "kein", "keine", "keinen", "werden", "wird", "wurde",
        "können", "kann", "muss", "müssen", "möchte", "bitte", "danke", "nur", "doch", "sich", "dann", "wenn",
        "weil", "oder", "dass", "daß", "habe", "haben", "hat", "gibt", "auf", "aus", "bei", "nach", "von",
        "vielleicht", "wirklich", "machen", "gemacht", "nein", "heute", "das", "der", "dem", "zu", "zum", "zur",
        "mein", "meine", "dein", "deine", "unser", "uns", "euch", "es", "ganz", "immer", "gerade", "etwas", "wo",
        "warum", "weiß", "wissen", "sagen", "sehen", "gehen", "kommen", "zeit", "eigentlich", "natürlich",
        "überhaupt", "trotzdem", "deshalb", "nicht", "schön", "gut", "noch", "mich", "dich", "ihm", "ihn", "ihr"
    ]

    /// German words that are also normal English: never counted for English sources.
    private static let englishHomographs: Set<String> = ["die", "was", "also", "so", "hat", "bitte", "gut", "es", "mit", "wo", "der"]

    static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "’" }).map(String.init)
    }

    /// One sentence: English, Dutch or other (German and the rest).
    static func sentenceLanguage(_ sentence: String) -> Route {
        let w = words(sentence)
        guard !w.isEmpty else { return .other }
        let dutch = w.filter(dutchMarkers.contains).count
        let german = w.filter { germanMarkers.contains($0) && !dutchMarkers.contains($0) }.count
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.english, .dutch, .german]
        recognizer.processString(sentence)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        let en = hypotheses[.english] ?? 0, nl = hypotheses[.dutch] ?? 0, de = hypotheses[.german] ?? 0
        // Short replies: markers decide ("ja dat klopt", "oké top").
        if w.count <= 3 {
            if dutch >= 1 && dutch >= german && nl >= en * 0.5 { return .dutch }
            if german >= 2 { return .other }
            return en >= max(nl, de) ? .english : (nl >= de ? .dutch : .other)
        }
        if dutch >= 2 && Double(dutch) / Double(w.count) >= 0.2 && nl >= 0.2 { return .dutch }
        if german >= 2 && de > nl && de > en { return .other }
        if en >= 0.6 { return .english }
        if nl >= 0.6 { return .dutch }
        return en >= nl && en >= de ? .english : (nl >= de ? .dutch : .other)
    }

    /// The whole text: English, Dutch, mixed (both have at least one sentence of 4+ words), or other.
    static func route(_ text: String) -> Route {
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !sentences.isEmpty else { return .other }
        var englishWords = 0, dutchWords = 0, otherWords = 0
        for s in sentences {
            let n = words(s).count
            switch sentenceLanguage(s) {
            case .english: englishWords += n
            case .dutch: dutchWords += n
            default: otherWords += n
            }
        }
        let total = max(1, englishWords + dutchWords + otherWords)
        if Double(englishWords) / Double(total) >= 0.85 { return .english }
        if Double(dutchWords) / Double(total) >= 0.85 { return .dutch }
        if englishWords >= 4 && dutchWords >= 4 { return .mixed }
        if englishWords >= dutchWords && englishWords >= otherWords { return .english }
        return dutchWords >= otherWords ? .dutch : .other
    }

    /// German-only marker count, leaving out words that are also Dutch (and English for an English source).
    static func germanCount(_ text: String, englishSource: Bool) -> Int {
        words(text).filter {
            germanMarkers.contains($0) && !dutchMarkers.contains($0) && !(englishSource && englishHomographs.contains($0))
        }.count + text.filter { $0 == "ß" }.count
    }

    /// True when the output brings in German the source did not have: at least two new German words
    /// (one for a source of under eight words), and the source was not German to begin with.
    static func germanDrift(source: String, output: String) -> Bool {
        let sourceWords = words(source)
        guard !sourceWords.isEmpty else { return false }
        let needed = sourceWords.count < 8 ? 1 : 2
        // Cheap exit before the per-sentence recogniser (about 1 ms a sentence, two thirds of the content
        // guard's time): whichever way the source routes, `added` below is one of these two counts.
        let addedIfEnglish = germanCount(output, englishSource: true) - germanCount(source, englishSource: true)
        let addedOtherwise = germanCount(output, englishSource: false) - germanCount(source, englishSource: false)
        guard max(addedIfEnglish, addedOtherwise) >= needed else { return false }
        let route = route(source)
        guard route != .other else { return false }   // German (or other) input: not our call.
        let english = route == .english
        let added = english ? addedIfEnglish : addedOtherwise
        guard added >= needed else { return false }
        // The output as a whole must look less like the source language than before.
        let outWords = words(output)
        let germanShare = Double(germanCount(output, englishSource: english)) / Double(max(1, outWords.count))
        return germanShare >= 0.08 || added >= 3
    }
}
