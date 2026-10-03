import Testing
@testable import FridayCompanionKit
import Foundation

/// P2-M5V9-B.3C.3 — real Cartesia REST evidence showed a streaming WAV:
/// RIFF declared size == 0xFFFFFFFF (unknown-length sentinel), which the
/// B.3C.2 parser correctly refused to interpret as "read 4GB" but also
/// had no resolution rule for the `data` chunk carrying the same
/// sentinel — every real response failed as "truncated chunk (data)".
/// These are exactly the mission's own lettered fixtures (A–J).
@Suite struct PremiumVoiceV9B3C3Tests {
    // MARK: - Byte-builder helpers (same shapes as PremiumVoiceV9B3C2Tests)

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
    private func chunkHeader(_ fourCC: String, size: UInt32) -> Data {
        var c = Data(fourCC.utf8)
        c.append(le32(size))
        return c
    }
    private func chunk(_ fourCC: String, _ payload: Data) -> Data {
        var c = chunkHeader(fourCC, size: UInt32(payload.count))
        c.append(payload)
        if payload.count % 2 == 1 { c.append(0) }
        return c
    }

    /// 4 arbitrary Int16LE samples per "frame group" — kept small and
    /// exactly divisible by a mono 16-bit blockAlign (2 bytes/frame).
    private let samplePCM = Data([0x01, 0x00, 0x02, 0x00, 0xFF, 0xFF, 0x00, 0x80, 0x10, 0x00, 0x20, 0x00]) // 12 bytes = 6 mono Int16 frames

    /// Builds a raw RIFF/WAVE byte sequence with full manual control over
    /// the RIFF chunk's OWN declared size and the `data` chunk's declared
    /// size — both independently settable to `UInt32.max` to reproduce
    /// the real, live Cartesia streaming-WAV shape byte-for-byte.
    private func buildStreamingWAV(riffDeclaredSize: UInt32?, fmtPayload: Data, dataDeclaredSize: UInt32?, pcm: Data, extraDataChunk: (size: UInt32, payload: Data)? = nil) -> Data {
        var body = Data("WAVE".utf8)
        body.append(chunk("fmt ", fmtPayload))
        body.append(chunkHeader("data", size: dataDeclaredSize ?? UInt32(pcm.count)))
        body.append(pcm)
        if let extra = extraDataChunk {
            body.append(chunkHeader("data", size: extra.size))
            body.append(extra.payload)
        }
        var file = Data("RIFF".utf8)
        file.append(le32(riffDeclaredSize ?? UInt32(body.count)))
        file.append(body)
        return file
    }

    // MARK: - A. RIFF size = UInt32.max, data finite, valid PCM → PASS

    @Test func caseA_riffSentinel_dataFinite_validPCM_passes() {
        let wav = buildStreamingWAV(riffDeclaredSize: .max, fmtPayload: fmt16(), dataDeclaredSize: nil, pcm: samplePCM)
        switch WAVContainerParser.extractPCM16LEMono(wav, expectedSampleRate: 44100) {
        case .success(let parsed): #expect(parsed.pcm == samplePCM)
        case .failure(let f): Issue.record("RIFF's own sentinel must be irrelevant to parsing — it is never read/enforced, got \(f)")
        }
    }

    // MARK: - B. RIFF size = UInt32.max, data size = UInt32.max, valid PCM to EOF → PASS

    @Test func caseB_riffSentinel_dataSentinel_validPCMToEOF_passes() {
        let wav = buildStreamingWAV(riffDeclaredSize: .max, fmtPayload: fmt16(), dataDeclaredSize: .max, pcm: samplePCM)
        switch WAVContainerParser.extractPCM16LEMono(wav, expectedSampleRate: 44100) {
        case .success(let parsed):
            #expect(parsed.pcm == samplePCM)
            #expect(parsed.pcm.count == samplePCM.count)
        case .failure(let f): Issue.record("the exact real Cartesia shape (both sentinels) must resolve, got \(f)")
        }
    }

    // MARK: - C. normal finite RIFF/data sizes still pass

    @Test func caseC_normalFiniteSizes_stillPasses() {
        let wav = buildStreamingWAV(riffDeclaredSize: nil, fmtPayload: fmt16(), dataDeclaredSize: nil, pcm: samplePCM)
        switch WAVContainerParser.extractPCM16LEMono(wav, expectedSampleRate: 44100) {
        case .success(let parsed): #expect(parsed.pcm == samplePCM)
        case .failure(let f): Issue.record("an ordinary, fully-finite WAV must be completely unaffected by streaming support, got \(f)")
        }
    }

    // MARK: - D. finite data size larger than actual body must FAIL truncated

    @Test func caseD_finiteDataSizeLargerThanBody_failsTruncated_notSilentlyAccepted() {
        let wav = buildStreamingWAV(riffDeclaredSize: nil, fmtPayload: fmt16(), dataDeclaredSize: 1_000_000, pcm: samplePCM)
        switch WAVContainerParser.parse(wav) {
        case .failure(.truncatedChunk(let fourCC)): #expect(fourCC == "data")
        case .failure(let other): Issue.record("expected .truncatedChunk, got \(other)")
        case .success: Issue.record("a finite declared size that exceeds the actual buffer must NEVER be silently accepted — streaming support must not weaken this")
        }
    }

    // MARK: - E. UInt32.max data size where data is not terminal → FAIL

    @Test func caseE_sentinelDataNotActuallyTerminal_fails() {
        // A finite `data` chunk is fully walked first; a SECOND chunk
        // named `data` then claims the sentinel. Two `data` declarations
        // in one file is inherently malformed, and it proves the second
        // one (if trusted) would NOT have been the file's true terminal
        // audio chunk — reject rather than guess which one is real.
        var body = Data("WAVE".utf8)
        body.append(chunk("fmt ", fmt16()))
        body.append(chunk("data", Data([1, 2, 3, 4]))) // first, finite `data`
        body.append(chunkHeader("data", size: .max)) // second `data`, claiming the sentinel
        body.append(samplePCM)
        var wav = Data("RIFF".utf8)
        wav.append(le32(UInt32(body.count)))
        wav.append(body)

        switch WAVContainerParser.parse(wav) {
        case .failure(.truncatedChunk(let fourCC)): #expect(fourCC == "data")
        case .failure(let other): Issue.record("expected .truncatedChunk, got \(other)")
        case .success: Issue.record("a data chunk claiming the sentinel must NOT be trusted as terminal when another data chunk already exists")
        }
    }

    // MARK: - F. streaming PCM byte count not divisible by blockAlign must FAIL

    @Test func caseF_streamingPCMNotBlockAligned_fails() {
        // mono 16-bit => blockAlign 2; 5 trailing bytes can never form
        // whole frames, so a genuine stream would never legitimately end
        // here — likely a body cut off mid-sample.
        let misaligned = Data([1, 2, 3, 4, 5])
        let wav = buildStreamingWAV(riffDeclaredSize: .max, fmtPayload: fmt16(), dataDeclaredSize: .max, pcm: misaligned)
        switch WAVContainerParser.extractPCM16LEMono(wav, expectedSampleRate: 44100) {
        case .failure(.truncatedChunk(let fourCC)): #expect(fourCC == "data")
        case .failure(let other): Issue.record("expected .truncatedChunk for a non-block-aligned streaming payload, got \(other)")
        case .success: Issue.record("a streaming payload not divisible by blockAlign must never be silently accepted")
        }
    }

    @Test func blockAlignCheck_isScopedToStreamingOnly_ordinaryFiniteOddSizeUntouched() {
        // The blockAlign check must NOT apply to an ordinary, finite,
        // provider-declared data size — only to the streaming-resolved
        // case. An odd-length finite `data` chunk (unusual but not what
        // this milestone is about) must still parse via the pre-existing
        // path, unaffected.
        let oddPCM = Data([1, 2, 3])
        let wav = buildStreamingWAV(riffDeclaredSize: nil, fmtPayload: fmt16(), dataDeclaredSize: UInt32(oddPCM.count), pcm: oddPCM)
        switch WAVContainerParser.parse(wav) {
        case .success(let parsed): #expect(parsed.pcm == oddPCM)
        case .failure(let f): Issue.record("an ordinary finite data chunk must be unaffected by the streaming-only blockAlign check, got \(f)")
        }
    }

    // MARK: - G. streaming sentinel with unsupported codec must FAIL

    @Test func caseG_streamingSentinel_unsupportedCodec_fails() {
        let wav = buildStreamingWAV(riffDeclaredSize: .max, fmtPayload: fmt16(formatCode: 6), dataDeclaredSize: .max, pcm: samplePCM) // 6 = A-law
        switch WAVContainerParser.parse(wav) {
        case .failure(.unsupportedCodec(let code)): #expect(code == 6)
        case .failure(let other): Issue.record("expected .unsupportedCodec, got \(other)")
        case .success: Issue.record("a non-PCM codec must be rejected even when the container uses the streaming sentinel")
        }
    }

    // MARK: - H. streaming sentinel with wrong sample rate must FAIL

    @Test func caseH_streamingSentinel_wrongSampleRate_fails() {
        let wav = buildStreamingWAV(riffDeclaredSize: .max, fmtPayload: fmt16(sampleRate: 22050), dataDeclaredSize: .max, pcm: samplePCM)
        switch WAVContainerParser.extractPCM16LEMono(wav, expectedSampleRate: 44100) {
        case .failure(.unsupportedSampleRate(let rate)): #expect(rate == 22050)
        case .failure(let other): Issue.record("expected .unsupportedSampleRate, got \(other)")
        case .success: Issue.record("wrong sample rate must be rejected even with a streaming-resolved data chunk")
        }
    }

    // MARK: - I. streaming sentinel with stereo must FAIL

    @Test func caseI_streamingSentinel_stereo_fails() {
        let wav = buildStreamingWAV(riffDeclaredSize: .max, fmtPayload: fmt16(channels: 2), dataDeclaredSize: .max, pcm: samplePCM)
        switch WAVContainerParser.extractPCM16LEMono(wav, expectedSampleRate: 44100) {
        case .failure(.unsupportedChannelCount(let count)): #expect(count == 2)
        case .failure(let other): Issue.record("expected .unsupportedChannelCount, got \(other)")
        case .success: Issue.record("stereo must be rejected even with a streaming-resolved data chunk")
        }
    }

    // MARK: - J. realistic Cartesia-style fixture: RIFF max, fmt, data max, PCM to EOF → MUST PASS

    @Test func caseJ_realisticCartesiaStreamingFixture_mustPass() {
        // Byte-for-byte the shape the owner's real Cartesia REST response
        // showed: `52 49 46 46 ff ff ff ff 57 41 56 45` (RIFF <0xFFFFFFFF> WAVE).
        let wav = buildStreamingWAV(riffDeclaredSize: .max, fmtPayload: fmt16(), dataDeclaredSize: .max, pcm: samplePCM)
        #expect(wav.prefix(12) == Data([0x52, 0x49, 0x46, 0x46, 0xFF, 0xFF, 0xFF, 0xFF, 0x57, 0x41, 0x56, 0x45]), "fixture must reproduce the exact observed byte pattern")
        switch WAVContainerParser.extractPCM16LEMono(wav, expectedSampleRate: 44100) {
        case .success(let parsed):
            #expect(parsed.pcm == samplePCM)
            #expect(parsed.format.sampleRate == 44100)
            #expect(parsed.format.channelCount == 1)
            #expect(parsed.format.bitsPerSample == 16)
        case .failure(let f): Issue.record("the real, live Cartesia response shape MUST parse successfully, got \(f)")
        }
    }

    // MARK: - Regression: an ancillary chunk claiming the sentinel is still refused (§3)

    @Test func nonDataChunkClaimingSentinel_stillRejected() {
        var body = Data("WAVE".utf8)
        body.append(chunkHeader("JUNK", size: .max)) // an ancillary chunk claiming unknown length — never proven safe
        body.append(Data(repeating: 0, count: 8))
        body.append(chunk("fmt ", fmt16()))
        body.append(chunk("data", samplePCM))
        var wav = Data("RIFF".utf8)
        wav.append(le32(UInt32(body.count)))
        wav.append(body)

        switch WAVContainerParser.walkChunks(wav) {
        case .failure(.truncatedChunk(let fourCC)): #expect(fourCC == "JUNK")
        case .failure(let other): Issue.record("expected .truncatedChunk, got \(other)")
        case .success: Issue.record("an ancillary (non-data) chunk claiming the unknown-length sentinel has no proven-safe resolution and must be rejected")
        }
    }

    // MARK: - Diagnostic evidence: isStreamingResolved surfaces correctly

    @Test func walkChunks_marksStreamingResolvedChunkCorrectly() {
        let wav = buildStreamingWAV(riffDeclaredSize: .max, fmtPayload: fmt16(), dataDeclaredSize: .max, pcm: samplePCM)
        switch WAVContainerParser.walkChunks(wav) {
        case .success(let chunks):
            guard let dataChunk = chunks.first(where: { $0.fourCC == "data" }) else { Issue.record("expected a data chunk"); return }
            #expect(dataChunk.isStreamingResolved == true)
            #expect(dataChunk.declaredSize == samplePCM.count)
            let fmtChunk = chunks.first(where: { $0.fourCC == "fmt " })
            #expect(fmtChunk?.isStreamingResolved == false)
        case .failure(let f): Issue.record("expected success, got \(f)")
        }
    }
}
