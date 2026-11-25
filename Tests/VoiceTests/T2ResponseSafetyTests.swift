import Foundation
import Testing
@testable import Voice

@Suite("T2 response safety")
struct T2ResponseSafetyTests {
    @Test func rejectNewEnvelopesAndPreamblesWithoutStripping() {
        let source = "cafe\u{301} Zoe\u{308} can send the file"
        let echo = "[Polish request v1] {\"contract\":\"t2-selected-text-polish-v1\",\"settings\":{}}\n" + source
        #expect(T2ResponseSafety.responseProblem(source: source, candidate: echo) == "response_envelope")
        #expect(T2ResponseSafety.responseProblem(source: source, candidate: "[Task: clean] [Level: light]\n" + source) == "response_envelope")
        for wrapper in ["Edited text:", "Cleaned text:", "Here is the edited text:", "Explanation:", "Sure,"] {
            #expect(T2ResponseSafety.responseProblem(source: source, candidate: wrapper + "\n" + source) == "response_preamble")
        }
        let fallback = T2ResponseSafety.responseProblem(source: source, candidate: echo) != nil ? source : echo
        #expect(fallback.utf8.elementsEqual(source.utf8))
        #expect(!fallback.utf8.elementsEqual(source.precomposedStringWithCanonicalMapping.utf8))
    }

    @Test func allowExistingQuotedLiteralOccurrences() {
        let literal = "Quote \"[Polish request v1]\" once and keep \"[Task: clean]\" literal."
        #expect(T2ResponseSafety.responseProblem(source: literal, candidate: literal) == nil)
        #expect(T2ResponseSafety.responseProblem(source: literal, candidate: "[Polish request v1]\n" + literal) == "response_envelope")
        let label = "\"Edited text:\" is the literal label."
        #expect(T2ResponseSafety.responseProblem(source: label, candidate: label) == nil)
        #expect(T2ResponseSafety.responseProblem(source: label, candidate: "Edited text: " + label) == "response_preamble")
    }

    @Test func emptyCanSuppressOnlyClearHesitations() {
        for meaningful in ["Yeah", "No", "Thanks", "empty", "EMPTY", "oh", "mhm", "like", "basically", "literally", "huh", "um thanks", "um 2", "\"um\"", "umuh", "um 😊"] {
            #expect(!T2ResponseSafety.isHesitationOnly(meaningful))
        }
        for noise in ["um", "uh", "uhm", "erm", "Um, uh... erm!", " um\nuhm "] {
            #expect(T2ResponseSafety.isHesitationOnly(noise))
        }
    }

    @Test func actualRefusalAndUnavailableTrace() {
        #expect(T2ResponseSafety.trace(engine: "local:dose1-t2", result: "rejected:response_envelope")
            == .init(engine: "dose1-t2", ready: true, fallback: "rejected:response_envelope"))
        #expect(T2ResponseSafety.trace(engine: "rules", result: "unavailable:notReady")
            == .init(engine: "rules", ready: false, fallback: "unavailable:notReady"))
        #expect(T2ResponseSafety.trace(engine: "local:dose1-t2", result: "accepted").fallback == nil)
        #expect(T2ResponseSafety.trace(engine: "local:dose1-t2", result: "accepted", deadlineExpired: true)
            == .init(engine: "rules", ready: false, fallback: "deadline"))
        #expect(T2ResponseSafety.selectedFailureReason("badReply") != T2ResponseSafety.selectedFailureReason("notReady"))
    }
}
