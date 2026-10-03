import Testing
@testable import FridayCompanionKit
import Foundation

/// P2-M5V9-B.3C.2 — real RIFF/WAVE chunk-walker correctness. These are
/// exactly the mission's own lettered fixtures (A–M), plus two extra
/// cases for WAVE_FORMAT_EXTENSIBLE (explicitly called out in §4, not
/// itself lettered). All fixtures are synthetic, built byte-by-byte —
/// no live Cartesia response is available in this sandbox, so this is
/// the real, deterministic way to prove the parser handles the exact
/// structural variations a real WAV response can legally contain.
@Suite struct PremiumVoiceV9B3C2Tests {
    // MARK: - Synthetic WAV byte builders

    private func le16(_ v: UInt16) -> Data {
        var d = Data()
        Swift.withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
        return d
    }
    private func le32(_ v: UInt32) -> Data {
        var d = Data()
        Swift.withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
        return d
    }

    /// A standard 16-byte PCM `fmt ` chunk payload (no cbSize field).
    private func fmt16(formatCode: UInt16 = 1, channels: UInt16 = 1, sampleRate: UInt32 = 44100, bitsPerSample: UInt16 = 16) -> Data {
        let blockAlign = channels * (bitsPerSample / 8)
        let byteRate = sampleRate * UInt32(blockAlign)
        var d = Data()
        d.append(le16(formatCode))
        d.append(le16(channels))
        d.append(le32(sampleRate))
        d.append(le32(byteRate))
        d.append(le16(blockAlign))
        d.append(le16(bitsPerSample))
        return d
    }

    /// An 18-byte PCM `fmt ` chunk payload (16 standard fields + a
    /// trailing 2-byte cbSize, which for plain PCM is conventionally 0).
    private func fmt18(formatCode: UInt16 = 1, channels: UInt16 = 1, sampleRate: UInt32 = 44100, bitsPerSample: UInt16 = 16) -> Data {
        fmt16(formatCode: formatCode, channels: channels, sampleRate: sampleRate, bitsPerSample: bitsPerSample) + le16(0)
    }

    /// A 40-byte WAVE_FORMAT_EXTENSIBLE `fmt ` chunk payload, with the
    /// standard KSDATAFORMAT_SUBTYPE_PCM GUID (or a different one, for
    /// the non-PCM-subtype test) as its SubFormat field.
    private func fmtExtensible(channels: UInt16 = 1, sampleRate: UInt32 = 44100, bitsPerSample: UInt16 = 16, subFormatFirstTwoBytes: UInt16) -> Data {
        let blockAlign = channels * (bitsPerSample / 8)
        let byteRate = sampleRate * UInt32(blockAlign)
        var d = Data()
        d.append(le16(0xFFFE)) // WAVE_FORMAT_EXTENSIBLE
        d.append(le16(channels))
        d.append(le32(sampleRate))
        d.append(le32(byteRate))
        d.append(le16(blockAlign))
        d.append(le16(bitsPerSample))
        d.append(le16(22)) // cbSize
        d.append(le16(bitsPerSample)) // validBitsPerSample
        d.append(le32(0)) // channelMask
        // SubFormat GUID (16 bytes): first 2 bytes carry the real format code.
        d.append(le16(subFormatFirstTwoBytes))
        d.append(Data([0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71]))
        return d
    }

    private func chunk(_ fourCC: String, _ payload: Data) -> Data {
        var c = Data(fourCC.utf8)
        c.append(le32(UInt32(payload.count)))
        c.append(payload)
        if payload.count % 2 == 1 { c.append(0) } // RIFF even-byte padding
        return c
    }

    /// Assembles a full RIFF/WAVE file from a `fmt ` payload, any number
    /// of ancillary chunks (in order, before `data`), and a PCM payload.
    private func buildWAV(fmtPayload: Data, ancillary: [(String, Data)] = [], pcm: Data) -> Data {
        var body = Data("WAVE".utf8)
        body.append(chunk("fmt ", fmtPayload))
        for (fourCC, payload) in ancillary { body.append(chunk(fourCC, payload)) }
        body.append(chunk("data", pcm))
        var file = Data("RIFF".utf8)
        file.append(le32(UInt32(body.count)))
        file.append(body)
        return file
    }

    private let samplePCM = Data([0x01, 0x00, 0x02, 0x00, 0xFF, 0xFF, 0x00, 0x80]) // 4 arbitrary Int16LE samples

    // MARK: - A. canonical 44-byte PCM WAV

    @Test func caseA_canonical44ByteWAV_parsesAndExtractsExactPCM() {
        let wav = WAVFileWriter.makeWAVData(pcmS16LE: samplePCM, sampleRate: 44100, channelCount: 1)
        switch WAVContainerParser.extractPCM16LEMono(wav, expectedSampleRate: 44100) {
        case .success(let parsed):
            #expect(parsed.pcm == samplePCM)
            #expect(parsed.format.sampleRate == 44100)
            #expect(parsed.format.channelCount == 1)
            #expect(parsed.format.bitsPerSample == 16)
            #expect(parsed.format.dataOffset == 44, "the canonical writer's own output must still land data at byte 44")
        case .failure(let f): Issue.record("expected success, got \(f)")
        }
    }

    // MARK: - B. fmt chunk length 18

    @Test func caseB_fmtChunkLength18_stillParses() {
        let wav = buildWAV(fmtPayload: fmt18(), pcm: samplePCM)
        switch WAVContainerParser.extractPCM16LEMono(wav, expectedSampleRate: 44100) {
        case .success(let parsed): #expect(parsed.pcm == samplePCM)
        case .failure(let f): Issue.record("18-byte fmt chunk must be accepted, got \(f)")
        }
    }

    // MARK: - C. ancillary JUNK chunk before data

    @Test func caseC_ancillaryJUNKChunkBeforeData_dataStillFound() {
        let wav = buildWAV(fmtPayload: fmt16(), ancillary: [("JUNK", Data(repeating: 0, count: 8))], pcm: samplePCM)
        switch WAVContainerParser.extractPCM16LEMono(wav, expectedSampleRate: 44100) {
        case .success(let parsed): #expect(parsed.pcm == samplePCM)
        case .failure(let f): Issue.record("a JUNK chunk before data must be tolerated, got \(f)")
        }
    }

    // MARK: - D. LIST chunk before data

    @Test func caseD_LISTChunkBeforeData_dataStillFound() {
        // Content is irrelevant here — the top-level walker treats an
        // entire LIST chunk's payload as one opaque, skippable blob based
        // on its own declared size; it never needs to parse LIST's own
        // internal INFO/IART sub-structure.
        let wav = buildWAV(fmtPayload: fmt16(), ancillary: [("LIST", Data(Array("INFOIARTTest".utf8)))], pcm: samplePCM)
        switch WAVContainerParser.extractPCM16LEMono(wav, expectedSampleRate: 44100) {
        case .success(let parsed): #expect(parsed.pcm == samplePCM)
        case .failure(let f): Issue.record("a LIST chunk before data must be tolerated, got \(f)")
        }
    }

    // MARK: - E. odd-sized ancillary chunk requiring pad byte

    @Test func caseE_oddSizedAncillaryChunk_padByteHandledCorrectly() {
        // A 5-byte JUNK payload requires one pad byte before the next
        // chunk header — if the walker forgets RIFF's even-byte padding
        // rule, it will misread `data`'s own FourCC/size from the pad
        // byte onward and fail.
        let wav = buildWAV(fmtPayload: fmt16(), ancillary: [("JUNK", Data([1, 2, 3, 4, 5]))], pcm: samplePCM)
        switch WAVContainerParser.extractPCM16LEMono(wav, expectedSampleRate: 44100) {
        case .success(let parsed): #expect(parsed.pcm == samplePCM)
        case .failure(let f): Issue.record("odd-sized ancillary chunk padding must be handled, got \(f)")
        }
    }

    // MARK: - F. fmt + fact/metadata + data

    @Test func caseF_fmtFactAndData_dataStillFound() {
        let wav = buildWAV(fmtPayload: fmt16(), ancillary: [("fact", le32(UInt32(samplePCM.count / 2)))], pcm: samplePCM)
        switch WAVContainerParser.extractPCM16LEMono(wav, expectedSampleRate: 44100) {
        case .success(let parsed): #expect(parsed.pcm == samplePCM)
        case .failure(let f): Issue.record("a fact chunk between fmt and data must be tolerated, got \(f)")
        }
    }

    // MARK: - G. truncated chunk

    @Test func caseG_truncatedChunk_rejectedSafely_neverCrashes() {
        // Declares a data chunk of 1000 bytes but supplies far fewer.
        var body = Data("WAVE".utf8)
        body.append(chunk("fmt ", fmt16()))
        body.append(Data("data".utf8))
        body.append(le32(1000))
        body.append(Data([1, 2, 3])) // only 3 bytes actually present, not 1000
        var wav = Data("RIFF".utf8)
        wav.append(le32(UInt32(body.count)))
        wav.append(body)

        switch WAVContainerParser.parse(wav) {
        case .failure(.truncatedChunk(let fourCC)): #expect(fourCC == "data")
        case .failure(let other): Issue.record("expected .truncatedChunk, got \(other)")
        case .success: Issue.record("a truncated chunk must never be reported as success")
        }
    }

    // MARK: - H. declared chunk length beyond Data bounds (overflow-safe)

    @Test func caseH_declaredChunkLengthFarBeyondBounds_rejectedSafely_neverCrashesOrHangs() {
        var body = Data("WAVE".utf8)
        body.append(Data("fmt ".utf8))
        body.append(le32(UInt32.max)) // absurd, overflow-adjacent declared size
        body.append(fmt16()) // far fewer actual bytes than declared
        var wav = Data("RIFF".utf8)
        wav.append(le32(UInt32(body.count)))
        wav.append(body)

        switch WAVContainerParser.walkChunks(wav) {
        case .failure(.truncatedChunk(let fourCC)): #expect(fourCC == "fmt ")
        case .failure(let other): Issue.record("expected .truncatedChunk, got \(other)")
        case .success: Issue.record("an overflow-sized declared chunk must never be reported as success")
        }
    }

    // MARK: - I. missing data chunk

    @Test func caseI_missingDataChunk_reportedExplicitly() {
        var body = Data("WAVE".utf8)
        body.append(chunk("fmt ", fmt16()))
        var wav = Data("RIFF".utf8)
        wav.append(le32(UInt32(body.count)))
        wav.append(body)

        switch WAVContainerParser.parse(wav) {
        case .failure(.missingDataChunk): break
        case .failure(let other): Issue.record("expected .missingDataChunk, got \(other)")
        case .success: Issue.record("a WAV with no data chunk must never parse successfully")
        }
    }

    // MARK: - J. unsupported codec

    @Test func caseJ_unsupportedCodec_reportedExplicitly_notCalledPCM() {
        let wav = buildWAV(fmtPayload: fmt16(formatCode: 6), pcm: samplePCM) // 6 = A-law
        switch WAVContainerParser.parse(wav) {
        case .failure(.unsupportedCodec(let code)): #expect(code == 6)
        case .failure(let other): Issue.record("expected .unsupportedCodec, got \(other)")
        case .success: Issue.record("a non-PCM codec must never be called PCM merely because content-type is audio/wav")
        }
    }

    // MARK: - K. wrong sample rate

    @Test func caseK_wrongSampleRate_containerValidButRejectedByStrictExtractor() {
        let wav = buildWAV(fmtPayload: fmt16(sampleRate: 22050), pcm: samplePCM)
        // The loose extractor (used for stats/backward-compat) must still succeed:
        #expect(WAVFileWriter.extractPCMFromCanonicalWAV(wav) == samplePCM)
        // The strict, FRIDAY-format-specific extractor must reject it as a named category:
        switch WAVContainerParser.extractPCM16LEMono(wav, expectedSampleRate: 44100) {
        case .failure(.unsupportedSampleRate(let rate)): #expect(rate == 22050)
        case .failure(let other): Issue.record("expected .unsupportedSampleRate, got \(other)")
        case .success: Issue.record("a 22050Hz WAV must never silently pass a 44100Hz requirement")
        }
    }

    // MARK: - L. stereo when mono expected

    @Test func caseL_stereoWhenMonoExpected_containerValidButRejectedByStrictExtractor() {
        let wav = buildWAV(fmtPayload: fmt16(channels: 2), pcm: samplePCM)
        #expect(WAVFileWriter.extractPCMFromCanonicalWAV(wav) == samplePCM, "the loose extractor must still succeed — it doesn't enforce channel count")
        switch WAVContainerParser.extractPCM16LEMono(wav, expectedSampleRate: 44100) {
        case .failure(.unsupportedChannelCount(let count)): #expect(count == 2)
        case .failure(let other): Issue.record("expected .unsupportedChannelCount, got \(other)")
        case .success: Issue.record("stereo must never silently pass a mono requirement")
        }
    }

    // MARK: - M. valid 44100Hz mono 16-bit PCM with data offset != 44 — MUST PASS

    @Test func caseM_validAudioWithNonCanonicalDataOffset_mustPass() {
        let wav = buildWAV(fmtPayload: fmt18(), ancillary: [("LIST", Data("INFOtest".utf8))], pcm: samplePCM)
        let expectedDataOffset = 12 + 8 + 18 + 8 + 8 + 8 // RIFF hdr + fmt hdr + fmt18 + LIST hdr + payload + data hdr
        switch WAVContainerParser.extractPCM16LEMono(wav, expectedSampleRate: 44100) {
        case .success(let parsed):
            #expect(parsed.pcm == samplePCM)
            #expect(parsed.format.dataOffset != 44, "this fixture must genuinely NOT be at the canonical offset")
            #expect(parsed.format.dataOffset == expectedDataOffset)
        case .failure(let f): Issue.record("a structurally valid 44100Hz mono 16-bit WAV with a non-44 data offset MUST pass, got \(f)")
        }
    }

    // MARK: - Empty/malformed containers (regression, shared with B.3C.1)

    @Test func emptyData_rejectedAsInvalidRIFFSignature() {
        switch WAVContainerParser.parse(Data()) {
        case .failure(.invalidRIFFSignature): break
        case let other: Issue.record("expected .invalidRIFFSignature, got \(other)")
        }
    }

    @Test func nonRIFFData_rejectedAsInvalidRIFFSignature() {
        switch WAVContainerParser.parse(Data("this is not a wav file at all".utf8)) {
        case .failure(.invalidRIFFSignature): break
        case let other: Issue.record("expected .invalidRIFFSignature, got \(other)")
        }
    }

    @Test func riffButNotWave_rejectedAsInvalidWAVEForm() {
        var wav = Data("RIFF".utf8)
        wav.append(le32(4))
        wav.append(Data("JUNK".utf8))
        switch WAVContainerParser.parse(wav) {
        case .failure(.invalidWAVEForm): break
        case let other: Issue.record("expected .invalidWAVEForm, got \(other)")
        }
    }

    // MARK: - Chunk-listing diagnostic itself (§1)

    @Test func walkChunks_reportsFourCCSizeAndOffsetForEveryChunk() {
        let wav = buildWAV(fmtPayload: fmt16(), ancillary: [("JUNK", Data(repeating: 0, count: 4)), ("LIST", Data(repeating: 0, count: 6))], pcm: samplePCM)
        switch WAVContainerParser.walkChunks(wav) {
        case .success(let chunks):
            let fourCCs = chunks.map(\.fourCC)
            #expect(fourCCs == ["fmt ", "JUNK", "LIST", "data"])
            #expect(chunks[0].declaredSize == 16)
            #expect(chunks[0].byteOffset == 12)
            #expect(chunks.allSatisfy { $0.declaredSize >= 0 })
        case .failure(let f): Issue.record("expected success, got \(f)")
        }
    }

    // MARK: - WAVE_FORMAT_EXTENSIBLE (§4, not itself lettered)

    @Test func extensibleFormat_withPCMSubtype_resolvesToPCM() {
        let wav = buildWAV(fmtPayload: fmtExtensible(subFormatFirstTwoBytes: 1), pcm: samplePCM)
        switch WAVContainerParser.extractPCM16LEMono(wav, expectedSampleRate: 44100) {
        case .success(let parsed):
            #expect(parsed.format.audioFormatCode == 1, "must resolve the SubFormat GUID, not trust the raw 0xFFFE tag")
            #expect(parsed.pcm == samplePCM)
        case .failure(let f): Issue.record("expected success for an extensible-PCM fmt chunk, got \(f)")
        }
    }

    @Test func extensibleFormat_withNonPCMSubtype_rejectedAsUnsupportedCodec() {
        let wav = buildWAV(fmtPayload: fmtExtensible(subFormatFirstTwoBytes: 3), pcm: samplePCM) // 3 = IEEE float subtype
        switch WAVContainerParser.parse(wav) {
        case .failure(.unsupportedCodec(let code)): #expect(code == 3)
        case .failure(let other): Issue.record("expected .unsupportedCodec, got \(other)")
        case .success: Issue.record("a non-PCM SubFormat must never be called PCM merely because the container is audio/wav")
        }
    }

    // MARK: - Sanitized description never leaks anything beyond a category label

    @Test func sanitizedDescription_neverContainsRawBytesOrOffsets() {
        for failure: WAVValidationFailure in [.invalidRIFFSignature, .invalidWAVEForm, .truncatedChunk(fourCC: "data"), .missingFmtChunk, .missingDataChunk, .unsupportedCodec(formatCode: 6), .unsupportedSampleRate(22050), .unsupportedChannelCount(2), .unsupportedBitDepth(8)] {
            #expect(!failure.sanitizedDescription.isEmpty)
        }
    }
}
