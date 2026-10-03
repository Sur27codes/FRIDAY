import Testing
@testable import FridayCompanionKit

/// P2-M4 §12 — pure unit tests for the entire set of transformations
/// ever applied to spoken text before it reaches `RuntimeClient`.
@Suite struct TranscriptValidationTests {

    @Test func trimsLeadingAndTrailingWhitespace() {
        let result = TranscriptValidation.validate("  check system status  \n")
        #expect(result == .success("check system status"))
    }

    @Test func preservesInteriorWordingExactly_noRewriting() {
        // §12: "do not silently rewrite semantic meaning" — casing,
        // punctuation, and interior spacing are all preserved verbatim.
        let result = TranscriptValidation.validate("Create a Note saying:  buy milk!!")
        #expect(result == .success("Create a Note saying:  buy milk!!"))
    }

    @Test func emptyString_rejected() {
        #expect(TranscriptValidation.validate("") == .failure(.empty))
    }

    @Test func whitespaceOnly_rejected() {
        #expect(TranscriptValidation.validate("   \n\t  ") == .failure(.empty))
    }

    @Test func exactlyMaxLength_accepted() {
        let text = String(repeating: "a", count: TranscriptValidation.maxLength)
        #expect(TranscriptValidation.validate(text) == .success(text))
    }

    @Test func overMaxLength_rejected() {
        let text = String(repeating: "a", count: TranscriptValidation.maxLength + 1)
        #expect(TranscriptValidation.validate(text) == .failure(.tooLong(actual: TranscriptValidation.maxLength + 1, max: TranscriptValidation.maxLength)))
    }

    @Test func lengthCheckedAfterTrimming_notBeforeIt() {
        // A transcript that's only over-length because of padding
        // whitespace should be accepted once trimmed.
        let padded = String(repeating: " ", count: 50) + String(repeating: "a", count: TranscriptValidation.maxLength) + String(repeating: " ", count: 50)
        #expect(TranscriptValidation.validate(padded) == .success(String(repeating: "a", count: TranscriptValidation.maxLength)))
    }
}
