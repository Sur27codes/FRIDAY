import Testing
@testable import FridayCompanionKit
import Foundation

/// P2-M5V8.1-S2.1 — dedicated coverage for the response-selection-truth
/// fix: `realizerProviderSucceeded` (INFERENCE) is no longer conflated
/// with `realizerUsedModel`/`finalResponseSource` (SELECTION). A model
/// can produce a schema-valid candidate that is later semantically
/// rejected — that is a real, distinct state, generically tested here
/// with a scriptable fake provider, never a transcript-specific cheat.
@Suite struct FinalResponseSourceTests {
    private func context(family: ResponseFamily, wasSuccess: Bool, taskID: String = "task-1") -> ConversationContext {
        ConversationContext(
            interactionID: taskID, taskID: taskID, outcomeCode: "x", responseFamily: family, wasSuccess: wasSuccess,
            isVerifiedData: wasSuccess, needsClarification: family == .ambiguousIntent,
            isRetryable: DeterministicConversationContextCompiler.isRetryable(family), isFollowUpMeaningful: false, failureEvidence: nil
        )
    }

    private func outcomeResult(outcome: String, text: String, taskID: String) -> RuntimeTextResult {
        RuntimeTextResult(protocolVersion: 1, requestID: taskID, correlationID: taskID, taskID: taskID, outcome: outcome, text: text)
    }

    private func chatCompletionData(content: String) -> Data {
        let envelope = "{\"choices\":[{\"message\":{\"content\":\(String(data: try! JSONEncoder().encode(content), encoding: .utf8)!)}}]}"
        return envelope.data(using: .utf8)!
    }

    /// Reasoner always succeeds with a fixed, safe classification —
    /// isolates every test in this file to the REALIZER's selection
    /// behavior specifically, generically (no transcript dependency).
    private func alwaysSucceedingReasonerFake() -> FakeConversationModelRequesting {
        let fake = FakeConversationModelRequesting()
        fake.behavior = .success(chatCompletionData(content: """
        {"dialogueAct":"request","interactionMode":"actionRequest","uncertainty":0.1}
        """))
        return fake
    }

    // MARK: - §1/§8: the exact proven state shape, generically

    @Test func schemaValidCandidate_semanticallyRejected_recordsCorrectStateShape() {
        // A model realizer that always returns a WELL-FORMED but
        // ungrounded candidate ("Done.") for a genuine failure with an
        // unknown cause — schema-valid, semantically invalid, generic,
        // never transcript-specific.
        let realizerFake = FakeConversationModelRequesting()
        realizerFake.behavior = .success(chatCompletionData(content: "{\"text\":\"Done.\"}"))
        let reasonerFake = alwaysSucceedingReasonerFake()

        let config = ConversationModelConfig(endpoint: URL(string: "https://example.invalid")!, apiKey: "k", modelName: "m")
        let recorder = WakeDiagnosticsRecorder()
        let presenter = ConversationalResponsePresenter(
            reasoner: FallbackConversationReasoning(primary: ModelConversationReasoner(client: reasonerFake, config: config, diagnostics: recorder), secondary: DeterministicConversationReasoner()),
            naturalRealizer: FallbackNaturalResponseRealizing(primary: ModelNaturalResponseRealizer(client: realizerFake, config: config, diagnostics: recorder), secondary: DeterministicNaturalResponseRealizer()),
            diagnostics: recorder
        )
        let response = presenter.response(
            for: .success(outcomeResult(outcome: "EXECUTION_FAILED", text: "The action could not be completed.", taskID: "shape-1")),
            transcript: "Check the system.", acoustics: .unavailable, explicitUserStatements: []
        )

        let snapshot = recorder.snapshot()
        // Inference succeeded on both stages.
        #expect(snapshot.lastReasonerUsed == "model")
        #expect(snapshot.lastRealizerUsed == "model")
        // Candidate was schema-valid but semantically rejected.
        #expect(snapshot.lastSchemaValid == true)
        #expect(snapshot.lastSemanticGroundingValid == false)
        #expect(snapshot.lastResponseAccepted == false)
        // §3/§4 — the fix: final selection must show deterministic, NOT model.
        #expect(snapshot.lastFinalResponseSource == .deterministicFallback)
        // The user-visible text is NEVER the rejected candidate.
        #expect(response.text != "Done.")
        #expect(!response.text.localizedCaseInsensitiveContains("done"))
    }

    // MARK: - §9: the five distinguishable combo paths, all internally consistent

    @Test func path_modelModel_accepted() {
        let realizerFake = FakeConversationModelRequesting()
        realizerFake.behavior = .success(chatCompletionData(content: "{\"text\":\"That didn't go through.\"}"))
        let reasonerFake = alwaysSucceedingReasonerFake()
        let config = ConversationModelConfig(endpoint: URL(string: "https://example.invalid")!, apiKey: "k", modelName: "m")
        let recorder = WakeDiagnosticsRecorder()
        let presenter = ConversationalResponsePresenter(
            reasoner: FallbackConversationReasoning(primary: ModelConversationReasoner(client: reasonerFake, config: config, diagnostics: recorder), secondary: DeterministicConversationReasoner()),
            naturalRealizer: FallbackNaturalResponseRealizing(primary: ModelNaturalResponseRealizer(client: realizerFake, config: config, diagnostics: recorder), secondary: DeterministicNaturalResponseRealizer()),
            diagnostics: recorder
        )
        let response = presenter.response(
            for: .success(outcomeResult(outcome: "EXECUTION_FAILED", text: "The action could not be completed.", taskID: "path-1")),
            transcript: "Check the system.", acoustics: .unavailable, explicitUserStatements: []
        )
        #expect(response.text == "That didn't go through.")
        let snapshot = recorder.snapshot()
        #expect(snapshot.lastFinalResponseSource == .model)
        assertCombo(snapshot, reasonerExpected: true, realizerExpected: true)
    }

    @Test func path_deterministicModel_reasonerFellBack_realizerAccepted() {
        let realizerFake = FakeConversationModelRequesting()
        realizerFake.behavior = .success(chatCompletionData(content: "{\"text\":\"That didn't go through.\"}"))
        let reasonerFake = FakeConversationModelRequesting()
        reasonerFake.behavior = .failure(ConversationModelError.emptyResponse) // reasoner inference fails
        let config = ConversationModelConfig(endpoint: URL(string: "https://example.invalid")!, apiKey: "k", modelName: "m")
        let recorder = WakeDiagnosticsRecorder()
        let presenter = ConversationalResponsePresenter(
            reasoner: FallbackConversationReasoning(primary: ModelConversationReasoner(client: reasonerFake, config: config, diagnostics: recorder), secondary: DeterministicConversationReasoner()),
            naturalRealizer: FallbackNaturalResponseRealizing(primary: ModelNaturalResponseRealizer(client: realizerFake, config: config, diagnostics: recorder), secondary: DeterministicNaturalResponseRealizer()),
            diagnostics: recorder
        )
        _ = presenter.response(
            for: .success(outcomeResult(outcome: "EXECUTION_FAILED", text: "The action could not be completed.", taskID: "path-2")),
            transcript: "Check the system.", acoustics: .unavailable, explicitUserStatements: []
        )
        let snapshot = recorder.snapshot()
        #expect(snapshot.lastFinalResponseSource == .model, "the realizer's own candidate can still be accepted even though the reasoner fell back")
        assertCombo(snapshot, reasonerExpected: false, realizerExpected: true)
    }

    @Test func path_modelDeterministic_dueToProviderFailure() {
        let realizerFake = FakeConversationModelRequesting()
        realizerFake.behavior = .failure(ConversationModelError.emptyResponse) // realizer inference fails
        let reasonerFake = alwaysSucceedingReasonerFake()
        let config = ConversationModelConfig(endpoint: URL(string: "https://example.invalid")!, apiKey: "k", modelName: "m")
        let recorder = WakeDiagnosticsRecorder()
        let presenter = ConversationalResponsePresenter(
            reasoner: FallbackConversationReasoning(primary: ModelConversationReasoner(client: reasonerFake, config: config, diagnostics: recorder), secondary: DeterministicConversationReasoner()),
            naturalRealizer: FallbackNaturalResponseRealizing(primary: ModelNaturalResponseRealizer(client: realizerFake, config: config, diagnostics: recorder), secondary: DeterministicNaturalResponseRealizer()),
            diagnostics: recorder
        )
        _ = presenter.response(
            for: .success(outcomeResult(outcome: "EXECUTION_FAILED", text: "The action could not be completed.", taskID: "path-3")),
            transcript: "Check the system.", acoustics: .unavailable, explicitUserStatements: []
        )
        let snapshot = recorder.snapshot()
        #expect(snapshot.lastFinalResponseSource == .deterministicFallback)
        #expect(snapshot.lastRealizerUsed != "model", "provider itself failed at inference")
        assertCombo(snapshot, reasonerExpected: true, realizerExpected: false)
    }

    @Test func path_modelDeterministic_dueToSemanticRejection_distinctFromProviderFailure() {
        // The core distinction §4/§6 require: provider inference SUCCEEDED
        // here (unlike the previous test), yet the final combo must STILL
        // read realizer=DETERMINISTIC — for a completely different,
        // separately-diagnosable reason.
        let realizerFake = FakeConversationModelRequesting()
        realizerFake.behavior = .success(chatCompletionData(content: "{\"text\":\"All set.\"}"))
        let reasonerFake = alwaysSucceedingReasonerFake()
        let config = ConversationModelConfig(endpoint: URL(string: "https://example.invalid")!, apiKey: "k", modelName: "m")
        let recorder = WakeDiagnosticsRecorder()
        let presenter = ConversationalResponsePresenter(
            reasoner: FallbackConversationReasoning(primary: ModelConversationReasoner(client: reasonerFake, config: config, diagnostics: recorder), secondary: DeterministicConversationReasoner()),
            naturalRealizer: FallbackNaturalResponseRealizing(primary: ModelNaturalResponseRealizer(client: realizerFake, config: config, diagnostics: recorder), secondary: DeterministicNaturalResponseRealizer()),
            diagnostics: recorder
        )
        _ = presenter.response(
            for: .success(outcomeResult(outcome: "EXECUTION_FAILED", text: "The action could not be completed.", taskID: "path-4")),
            transcript: "Check the system.", acoustics: .unavailable, explicitUserStatements: []
        )
        let snapshot = recorder.snapshot()
        #expect(snapshot.lastRealizerUsed == "model", "provider inference DID succeed this time — the distinguishing fact")
        #expect(snapshot.lastFinalResponseSource == .deterministicFallback)
        #expect(snapshot.lastSemanticGroundingValid == false)
        assertCombo(snapshot, reasonerExpected: true, realizerExpected: false)
    }

    @Test func path_deterministicDeterministic_noProviderConfigured() {
        let recorder = WakeDiagnosticsRecorder()
        let presenter = ConversationalResponsePresenter.withModelProvider(config: .unconfigured, diagnostics: recorder)
        let response = presenter.response(
            for: .success(outcomeResult(outcome: "EXECUTION_FAILED", text: "The action could not be completed.", taskID: "path-5")),
            transcript: "Check the system.", acoustics: .unavailable, explicitUserStatements: []
        )
        #expect(!response.text.isEmpty)
        let snapshot = recorder.snapshot()
        #expect(snapshot.lastFinalResponseSource == .deterministicFallback)
        assertCombo(snapshot, reasonerExpected: false, realizerExpected: false)
    }

    private func assertCombo(_ snapshot: WakeDiagnosticsSnapshot, reasonerExpected: Bool, realizerExpected: Bool) {
        let reasonerUsedModel = snapshot.lastReasonerUsed == "model"
        let realizerUsedModel = snapshot.lastFinalResponseSource == .model
        #expect(reasonerUsedModel == reasonerExpected, "reasonerUsedModel")
        #expect(realizerUsedModel == realizerExpected, "realizerUsedModel (finalResponseSource-derived)")
    }
}
