// Package orchestrator is the M7 Runtime: the smallest sequencer that
// coordinates the already-independently-verified M1-M6 components into
// one real end-to-end execution path. It is not a new source of
// authority (M7 brief §3) — grep-verifiable facts back that claim:
//   - This package never imports friday/policy-engine, friday/policytoken,
//     or friday/capability-bus (see go.mod and the isolation test) — it
//     cannot mint a token or call a capability adapter function even by
//     accident.
//   - Every field written into an authorization request or an Execution
//     Envelope that is security-relevant (risk, capability_id,
//     arguments, verification method, cancellation semantics) is read
//     verbatim from the durably-stored IR snapshot the Intent
//     Compiler/M2 validator already produced — this package never
//     recomputes or overrides any of them from user text or from its
//     own judgment.
//   - Task state only ever changes through store.TransitionTask, which
//     independently enforces K.2 legality — this package cannot "mutate
//     task status ad hoc" even if a bug tried to, because there is no
//     other write path to a task's state.
package orchestrator

import (
	"context"
	"fmt"
	"time"

	"friday/cognitive-core/intentcompiler"
	"friday/cognitive-core/planner"
	"friday/cognitive-core/textrequest"
	"friday/ir"
	"friday/runtime-store/store"
	"friday/runtime/reqcontext"
	"friday/runtime/response"
	"friday/runtime/wireclient"
	"friday/runtime/worldmodel"
)

// Config wires the Orchestrator to the real, already-running processes
// and durable store. No field here is a shortcut around any of them.
// WorkspaceRoot is informational only (M8's World Model "approved-
// workspace" entity, §7) — the Runtime never touches the filesystem
// itself; only capabilitybusd does, unchanged since M3.
type Config struct {
	Store         *store.Store
	PolicyClient  *wireclient.PolicyClient
	BusClient     *wireclient.BusClient
	WorkspaceRoot string
}

// Orchestrator holds a fixed reference point for what M1's AAL model
// calls device_trusted_session (see HandleTextRequest's doc comment on
// assurance factors) — the instant this process started, not something
// recomputed or extended per request.
type Orchestrator struct {
	store         *store.Store
	policyClient  *wireclient.PolicyClient
	busClient     *wireclient.BusClient
	workspaceRoot string
	startedAt     time.Time
}

func New(cfg Config) *Orchestrator {
	return &Orchestrator{
		store: cfg.Store, policyClient: cfg.PolicyClient, busClient: cfg.BusClient,
		workspaceRoot: cfg.WorkspaceRoot, startedAt: time.Now().UTC(),
	}
}

// WorldModel returns the current M8 World Model snapshot (FR-WORLD-001) —
// see the worldmodel package doc for why this is a pure, live projection
// rather than a separate, potentially-stale copy of state.
func (o *Orchestrator) WorldModel(ctx context.Context, taskID string) []worldmodel.Entity {
	return worldmodel.Snapshot(ctx, worldmodel.Config{
		WorkspaceRoot: o.workspaceRoot, PolicyClient: o.policyClient, BusClient: o.busClient,
	}, o.store, taskID)
}

// verificationMethodDataClassification is hand-synced with
// capability-bus/internal/registry's DataClassification field — the same
// disclosed "duplicated across modules" tradeoff already accepted for
// RiskLevel/AAL types (ir/types.go) and cognitive-core's capability
// templates (intentcompiler/compiler.go). Only used for the durable IR
// snapshot's own data_classification column (M6 brief §4), never for a
// security decision.
var dataClassification = map[string]string{
	"system.get_status":     "INTERNAL",
	"workspace.create_note": "PERSONAL",
}

// HandleTextRequest runs the complete M7 spine (§8/§15/§16) for one
// TextRequest: Compile -> ir.Validate -> CreatePlan -> durable task ->
// live Policy Engine RPC -> Execution Envelope -> live Capability Bus RPC
// -> verification -> durable terminal state -> audit -> response. No
// step is skipped in this path (M7 brief §15's "no steps may be skipped
// in the production M7 path").
func (o *Orchestrator) HandleTextRequest(ctx context.Context, req textrequest.TextRequest, taskID string) response.Response {
	corrID := req.CorrelationID
	o.audit(ctx, store.AuditEvent{CorrelationID: corrID, Actor: req.Actor, EventType: store.EventIntentReceived, Sensitivity: store.SensitivityInternal})

	raw, cerr := intentcompiler.Compile(req)
	if cerr != nil {
		o.audit(ctx, store.AuditEvent{CorrelationID: corrID, Actor: req.Actor, EventType: store.EventIRCompiled,
			ResultStatus: "REJECTED", Sensitivity: store.SensitivityInternal,
			Payload: map[string]interface{}{"reason": string(cerr.Code)}})
		return responseForCompileError(cerr)
	}

	// ---- Durable idempotency check, BEFORE any task/IR record is
	// written (M7 brief §9/§22/§23). Checked this early — not just
	// before dispatch — so that a genuine retry (same idempotency key:
	// same correlation_id + capability + arguments, however the caller
	// arrived at it, including reusing the same request_id) is recognized
	// and short-circuited before creating a second Task/IRSnapshot row
	// for what is logically the same unit of work, rather than only
	// being caught right before Dispatch. Found during M7 E2E testing:
	// checking only right before dispatch let two CreateTask/
	// SaveIRSnapshot calls for the same logical retry both attempt to
	// write, which is wasted work at best and, when a caller's retry
	// legitimately reuses the same request_id (a common, valid retry
	// pattern), collided on ir_snapshots' ir_id primary key and
	// surfaced as an internal error instead of a clean duplicate
	// response — fixed by moving the check here.
	argsDigest := mustDigest(raw.Content.Parameters)
	idemRec, created, idemErr := o.store.RegisterIdempotency(ctx, raw.Idempotency.IdempotencyKey, taskID, raw.Goal.Type, argsDigest)
	if idemErr != nil {
		return response.InvalidTextRequest(taskID)
	}
	if !created {
		return o.respondForExistingIdempotentTask(ctx, idemRec)
	}

	// ---- CREATED: durable task + IR snapshot exist ----
	if err := o.store.CreateTask(ctx, store.Task{
		TaskID: taskID, CorrelationID: corrID, Actor: req.Actor,
		CapabilityID: raw.Goal.Type, IRID: raw.IRID, IdempotencyKey: raw.Idempotency.IdempotencyKey,
	}); err != nil {
		// Durable-first principle (M7 brief §9): if we cannot even
		// persist the task record, we have not touched anything else yet
		// — fail closed before any authorization or dispatch is attempted.
		//
		// P2-M4R: this branch MUST resolve the idempotency record it just
		// created via RegisterIdempotency above, exactly like every other
		// failure branch in this function does — a real production bug
		// (found via a real voice-submitted "check system status" request
		// whose CorrelationID was empty, failing CreateTask's required-field
		// check) left this one branch as the sole place that didn't, which
		// permanently orphaned the PENDING record: every subsequent request
		// for the same idempotency key read that still-PENDING row forever
		// and was misclassified as DUPLICATE_REQUEST, with no way to ever
		// recover short of manual database surgery
		// (see store.RepairOrphanedIdempotencyRecords for the one-time
		// repair of records already written before this fix).
		o.store.CompleteIdempotency(ctx, raw.Idempotency.IdempotencyKey)
		return response.InternalError(taskID)
	}
	if err := o.store.SaveIRSnapshot(ctx, store.IRSnapshot{
		IRID: raw.IRID, TaskID: taskID, CapabilityID: raw.Goal.Type, RiskLevel: raw.Risk.Level,
		Reversible: raw.Effects.Reversible, Arguments: raw.Content.Parameters,
		ArgumentsDigest: argsDigest, DataClassification: dataClassification[raw.Goal.Type],
	}); err != nil {
		o.store.TransitionTask(ctx, taskID, store.StateFailed)
		o.store.CompleteIdempotency(ctx, raw.Idempotency.IdempotencyKey)
		return response.InternalError(taskID)
	}
	o.audit(ctx, store.AuditEvent{CorrelationID: corrID, TaskID: taskID, Actor: req.Actor, EventType: store.EventIRCompiled, ResultStatus: "OK", Sensitivity: store.SensitivityInternal})

	// ---- CREATED -> VALIDATED (or -> FAILED) ----
	validated, verr := ir.Validate(raw, ir.Phase1Registry())
	if verr != nil {
		o.store.TransitionTask(ctx, taskID, store.StateFailed)
		o.audit(ctx, store.AuditEvent{CorrelationID: corrID, TaskID: taskID, Actor: req.Actor, EventType: store.EventIRValidated,
			ResultStatus: "REJECTED", Sensitivity: store.SensitivityInternal,
			Payload: map[string]interface{}{"stage": string(verr.Stage), "category": string(verr.Category), "field": verr.Field}})
		o.auditTaskFailed(ctx, corrID, taskID, req.Actor, "IR_VALIDATION_FAILED")
		o.store.CompleteIdempotency(ctx, raw.Idempotency.IdempotencyKey)
		return response.IRValidationFailed(taskID)
	}
	o.store.TransitionTask(ctx, taskID, store.StateValidated)
	o.audit(ctx, store.AuditEvent{CorrelationID: corrID, TaskID: taskID, Actor: req.Actor, EventType: store.EventIRValidated, ResultStatus: "OK", Sensitivity: store.SensitivityInternal})

	// ---- Context Compiler + Context Firewall (M8: FR-CONTEXT-001/002) ----
	// Compile assembles the bounded context from exactly the validated IR
	// (see reqcontext's doc comment for why its own function signature
	// structurally excludes any broader "context universe"). Firewall then
	// trims Arguments to exactly this capability's own declared allowed-
	// key set — real, load-bearing filtering: everything built from here
	// on (the Execution Envelope's ValidatedArguments, the Bus's own
	// DevSeedIR call) reads from ctxObj, never from raw.Content.Parameters
	// directly, so anything the firewall would exclude is structurally
	// unreachable downstream, not merely absent by convention.
	ctxObj := reqcontext.Compile(*validated, taskID, req.RequestID, argsDigest)
	ctxObj = reqcontext.Firewall(ctxObj, allowedArgKeysFor(raw.Goal.Type))
	o.audit(ctx, store.AuditEvent{CorrelationID: corrID, TaskID: taskID, Actor: req.Actor, EventType: store.EventContextCompiled, ResultStatus: "OK", Sensitivity: store.SensitivityInternal})

	// ---- VALIDATED -> PLANNED ----
	if o.isCancelled(ctx, taskID) {
		return o.finalizeCancellation(ctx, corrID, taskID, req.Actor, raw.Idempotency.IdempotencyKey)
	}
	plan, perr := planner.CreatePlan(*validated, taskID, false)
	if perr != nil {
		o.store.TransitionTask(ctx, taskID, store.StateFailed)
		o.auditTaskFailed(ctx, corrID, taskID, req.Actor, "PLAN_FAILED")
		o.store.CompleteIdempotency(ctx, raw.Idempotency.IdempotencyKey)
		return response.InternalError(taskID)
	}
	o.store.TransitionTask(ctx, taskID, store.StatePlanned)
	o.audit(ctx, store.AuditEvent{CorrelationID: corrID, TaskID: taskID, Actor: req.Actor, EventType: store.EventPlanCreated, ResultStatus: "OK", Sensitivity: store.SensitivityInternal})
	_ = plan // single-step Phase-1 plan; capability_id already carried on raw.Goal.Type, used below

	// ---- PLANNED -> AWAITING_AUTHORIZATION ----
	if o.isCancelled(ctx, taskID) {
		return o.finalizeCancellation(ctx, corrID, taskID, req.Actor, raw.Idempotency.IdempotencyKey)
	}
	o.store.TransitionTask(ctx, taskID, store.StateAwaitingAuthorization)

	evalResp, evalErr := o.policyClient.EvaluateAuthorization(ctx, wireclient.EvaluateRequest{
		RequestID: req.RequestID, CorrelationID: corrID, TaskID: taskID, IRID: raw.IRID,
		Actor: req.Actor, Capability: raw.Goal.Type, CapabilityVersion: "1.0.0",
		Purpose: "", Risk: string(raw.Risk.Level), ArgumentsDigest: argsDigest,
		AssuranceFactors:        o.assuranceFactors(),
		AutonomyLevelConfigured: 0, SimulatorVerified: false,
		TaskCancelled: o.isCancelled(ctx, taskID),
	})
	if evalErr != nil {
		// Policy Engine unreachable: fail closed, task stays at
		// AWAITING_AUTHORIZATION (M7 brief §43 — "not ready" is not
		// permission to bypass; a later retry can still succeed once the
		// process is back). Deliberately NOT completed here: this is a
		// transient infrastructure failure, not a definitive decision —
		// the idempotency record stays PENDING so a genuine retry with
		// the same key can still succeed once the Policy Engine returns,
		// consistent with M7 brief §11's "do not retry policy denial as
		// though it were a network failure" read in reverse (a real
		// network/availability failure IS retry-eligible; an actual
		// DENY, below, is not).
		o.audit(ctx, store.AuditEvent{CorrelationID: corrID, TaskID: taskID, Actor: req.Actor, EventType: store.EventPolicyEvaluated,
			ResultStatus: "UNAVAILABLE", Sensitivity: store.SensitivityInternal})
		return response.PolicyUnavailable(taskID)
	}
	o.store.SavePolicyDecision(ctx, store.PolicyDecision{
		TaskID: taskID, Decision: evalResp.Decision, RequiredAAL: evalResp.RequiredAAL, Reason: evalResp.Reason,
		TokenID: tokenID(evalResp), TokenExpiresAt: tokenExpiry(evalResp),
	})
	o.audit(ctx, store.AuditEvent{CorrelationID: corrID, TaskID: taskID, Actor: req.Actor, EventType: store.EventPolicyEvaluated,
		ResultStatus: evalResp.Decision, Sensitivity: store.SensitivityInternal})

	if evalResp.Decision != "ALLOW" {
		o.store.TransitionTask(ctx, taskID, store.StateFailed)
		o.auditTaskFailed(ctx, corrID, taskID, req.Actor, "POLICY_"+evalResp.Decision)
		o.store.CompleteIdempotency(ctx, raw.Idempotency.IdempotencyKey) // definitive decision, not transient — see the PolicyUnavailable branch above for the contrast
		if evalResp.Decision == "CONFIRM" || evalResp.Decision == "STRONG_AUTH_REQUIRED" {
			return response.PolicyRequiresMoreAssurance(taskID)
		}
		return response.PolicyDenied(taskID)
	}

	// Race between authorization and a stop request (STOP-002): if a
	// cancellation was recorded while Evaluate() was in flight, the
	// freshly-issued token is discarded unused — never transitions to
	// AUTHORIZED.
	if o.isCancelled(ctx, taskID) {
		o.audit(ctx, store.AuditEvent{CorrelationID: corrID, TaskID: taskID, Actor: req.Actor, EventType: store.EventPolicyEvaluated,
			ResultStatus: "ALLOW_DISCARDED_UNUSED", Sensitivity: store.SensitivityInternal})
		return o.finalizeCancellation(ctx, corrID, taskID, req.Actor, raw.Idempotency.IdempotencyKey)
	}

	// ---- AWAITING_AUTHORIZATION -> AUTHORIZED ----
	o.store.TransitionTask(ctx, taskID, store.StateAuthorized)
	o.audit(ctx, store.AuditEvent{CorrelationID: corrID, TaskID: taskID, Actor: req.Actor, EventType: store.EventCapabilityAuthorized, ResultStatus: "OK", Sensitivity: store.SensitivityInternal})

	// ---- AUTHORIZED -> RUNNING (idempotency was already registered up
	// front, immediately after Compile succeeded — see above) ----
	o.store.TransitionTask(ctx, taskID, store.StateRunning)
	invID, _ := o.store.StartInvocation(ctx, taskID, raw.Goal.Type)
	o.audit(ctx, store.AuditEvent{CorrelationID: corrID, TaskID: taskID, Actor: req.Actor, EventType: store.EventCapabilityStarted, ResultStatus: "OK", Sensitivity: store.SensitivityInternal})

	// Keep the real Capability Bus process's own in-memory IRStore/
	// TaskStore in sync with what this Runtime has durably decided (see
	// wireclient's doc comment on DevSeedIR/DevSeedTask for why this is
	// the real production mechanism, not a test shortcut). Seeded from
	// ctxObj.Arguments (post-Firewall), never raw.Content.Parameters
	// directly — the Context Firewall's filtering is load-bearing here,
	// not decorative.
	if err := o.busClient.DevSeedIR(ctx, wireclient.DevSeedIRRequest{IRID: raw.IRID, CapabilityID: raw.Goal.Type, Arguments: ctxObj.Arguments}); err != nil {
		return o.busUnavailable(ctx, corrID, taskID, req.Actor, invID)
	}
	if err := o.busClient.DevSeedTask(ctx, wireclient.DevSeedTaskRequest{TaskID: taskID, State: "AUTHORIZED"}); err != nil {
		return o.busUnavailable(ctx, corrID, taskID, req.Actor, invID)
	}

	dispatchResp, dispatchErr := o.busClient.Dispatch(ctx, wireclient.DispatchRequest{Envelope: buildEnvelope(req, taskID, ctxObj, raw.IRVersion, evalResp)})
	if dispatchErr != nil {
		return o.busUnavailable(ctx, corrID, taskID, req.Actor, invID)
	}
	o.store.CompleteInvocation(ctx, invID, store.OutcomeExecuted) // EXECUTED != SUCCEEDED — see below
	o.audit(ctx, store.AuditEvent{CorrelationID: corrID, TaskID: taskID, Actor: req.Actor, EventType: store.EventCapabilityCompleted, ResultStatus: "EXECUTED", Sensitivity: store.SensitivityInternal})

	// ---- RUNNING -> VERIFYING ----
	o.store.TransitionTask(ctx, taskID, store.StateVerifying)
	verID, _ := o.store.StartVerification(ctx, taskID, raw.Verification.Method)
	o.audit(ctx, store.AuditEvent{CorrelationID: corrID, TaskID: taskID, Actor: req.Actor, EventType: store.EventVerificationStarted, ResultStatus: "OK", Sensitivity: store.SensitivityInternal})

	// The Bus already ran the capability-level verification internally
	// (M3: Execute then Verify, one Dispatch call) — this Runtime reads
	// that result rather than re-implementing verification a second time.
	success := dispatchResp.Outcome.Verified && dispatchResp.Outcome.Success
	if !success {
		o.store.CompleteVerification(ctx, verID, store.VerificationFailed, dispatchResp.Outcome.Executed)
		o.audit(ctx, store.AuditEvent{CorrelationID: corrID, TaskID: taskID, Actor: req.Actor, EventType: store.EventVerificationCompleted, ResultStatus: "FAILED", Sensitivity: store.SensitivityInternal})
		o.store.TransitionTask(ctx, taskID, store.StateFailed)
		o.auditTaskFailed(ctx, corrID, taskID, req.Actor, "VERIFICATION_FAILED")
		o.store.CompleteIdempotency(ctx, raw.Idempotency.IdempotencyKey)
		return response.VerificationFailed(taskID)
	}

	// A stop requested during the (synchronous, non-preemptible per M7
	// brief §19/§2) Dispatch call: the side effect may already have
	// happened by the time we learn about it. No capability in the
	// approved Phase-1 registry declares a compensation action (R.1), so
	// per PHASE-1-EMERGENCY-STOP-TEST-SPEC.md §4's own flowchart ("does
	// the capability declare a compensation action? NO ->
	// requires_manual_review directly"), the honest, contract-consistent
	// outcome is requires_manual_review — never a false "cancelled,
	// nothing happened" claim (§387/STOP-011).
	if o.isCancelled(ctx, taskID) {
		o.store.CompleteVerification(ctx, verID, store.VerificationSucceeded, true)
		o.audit(ctx, store.AuditEvent{CorrelationID: corrID, TaskID: taskID, Actor: req.Actor, EventType: store.EventVerificationCompleted, ResultStatus: "SUCCEEDED", Sensitivity: store.SensitivityInternal})
		o.store.TransitionTask(ctx, taskID, store.StateRequiresManualReview)
		o.audit(ctx, store.AuditEvent{CorrelationID: corrID, TaskID: taskID, Actor: req.Actor, EventType: store.EventTaskRequiresManualReview, ResultStatus: "OK", Sensitivity: store.SensitivityInternal})
		o.store.CompleteIdempotency(ctx, raw.Idempotency.IdempotencyKey)
		return response.RequiresManualReview(taskID)
	}

	// ---- VERIFYING -> SUCCEEDED ----
	o.store.CompleteVerification(ctx, verID, store.VerificationSucceeded, true)
	o.audit(ctx, store.AuditEvent{CorrelationID: corrID, TaskID: taskID, Actor: req.Actor, EventType: store.EventVerificationCompleted, ResultStatus: "SUCCEEDED", Sensitivity: store.SensitivityInternal})

	// transitionErr is now checked, not discarded (found while wiring the
	// M8 Response Validation Gate below): previously this call's result
	// was ignored and a success response was returned unconditionally
	// even if the durable transition itself failed. The gate makes that
	// implicit assumption a real, enforced check.
	transitionErr := o.store.TransitionTask(ctx, taskID, store.StateSucceeded)
	claim := response.Claim{VerificationRequired: raw.Verification.Required, VerificationConfirmed: true, PersistenceOK: transitionErr == nil}
	if transitionErr == nil {
		claim.TaskState = store.StateSucceeded
		o.audit(ctx, store.AuditEvent{CorrelationID: corrID, TaskID: taskID, Actor: req.Actor, EventType: store.EventTaskSucceeded, ResultStatus: "OK", Sensitivity: store.SensitivityInternal})
	} else {
		if t, err := o.store.GetTask(ctx, taskID); err == nil {
			claim.TaskState = t.State
		}
		o.auditTaskFailed(ctx, corrID, taskID, req.Actor, "PERSISTENCE_FAILED_AFTER_VERIFIED_SUCCESS")
	}
	o.store.CompleteIdempotency(ctx, raw.Idempotency.IdempotencyKey)

	// ---- Response Validation Gate (M8: FR-KNOW-002 / NFR-KNOW-001) ----
	// The candidate success response is only emitted if the gate
	// independently confirms every fact it asserts against the durable
	// record — including, now, that the transition to SUCCEEDED itself
	// actually persisted, not merely that this function believes it did.
	return response.ValidateSuccessClaim(responseForSuccess(taskID, raw), claim)
}

// busUnavailable deliberately does NOT complete the idempotency record —
// same transient-infrastructure reasoning as the PolicyUnavailable branch
// in HandleTextRequest above: the Capability Bus being unreachable is not
// a definitive decision about the request, so a genuine retry with the
// same idempotency key can still succeed once the Bus process is back.
func (o *Orchestrator) busUnavailable(ctx context.Context, corrID, taskID, actor, invID string) response.Response {
	o.store.CompleteInvocation(ctx, invID, store.OutcomeExecutionFailed)
	o.audit(ctx, store.AuditEvent{CorrelationID: corrID, TaskID: taskID, Actor: actor, EventType: store.EventCapabilityCompleted, ResultStatus: "UNAVAILABLE", Sensitivity: store.SensitivityInternal})
	o.store.TransitionTask(ctx, taskID, store.StateFailed)
	o.auditTaskFailed(ctx, corrID, taskID, actor, "CAPABILITY_BUS_UNAVAILABLE")
	return response.CapabilityUnavailable(taskID)
}

func (o *Orchestrator) auditTaskFailed(ctx context.Context, corrID, taskID, actor, reason string) {
	o.audit(ctx, store.AuditEvent{CorrelationID: corrID, TaskID: taskID, Actor: actor, EventType: store.EventTaskFailed, ResultStatus: reason, Sensitivity: store.SensitivityInternal})
}

func (o *Orchestrator) audit(ctx context.Context, ev store.AuditEvent) {
	// Audit-append failure is intentionally non-fatal to the request
	// outcome already decided (the task's durable state transition is
	// the authoritative record; the audit log is a best-effort parallel
	// trail) — but never silent: a production Runtime would log this via
	// the minimal Phase-1 observability path (M7 brief §47). Not
	// implemented here beyond the return-value contract, disclosed as a
	// carried limitation in the traceability report.
	_, _ = o.store.AppendAuditEvent(ctx, ev)
}

func (o *Orchestrator) isCancelled(ctx context.Context, taskID string) bool {
	task, err := o.store.GetTask(ctx, taskID)
	if err != nil {
		return false
	}
	return task.CancellationRequested
}

func (o *Orchestrator) finalizeCancellation(ctx context.Context, corrID, taskID, actor, idempotencyKey string) response.Response {
	if err := o.store.TransitionTask(ctx, taskID, store.StateCancelled); err != nil {
		// Already cancelled or otherwise terminal — no-op, not an error
		// surfaced to the user (STOP-007).
	}
	o.audit(ctx, store.AuditEvent{CorrelationID: corrID, TaskID: taskID, Actor: actor, EventType: store.EventTaskCancelled, ResultStatus: "OK", Sensitivity: store.SensitivityInternal})
	if idempotencyKey != "" {
		o.store.CompleteIdempotency(ctx, idempotencyKey)
	}
	return response.Cancelled(taskID)
}

// assuranceFactors presents exactly the Phase-1-honest evidence this CLI
// Runtime actually has: device_trusted_session, fresh for the lifetime of
// this process (matching policy-engine's own Phase-1 definition of that
// factor verbatim — "satisfied for the lifetime of the local FRIDAY
// process"). No other factor is ever presented: Phase 1 has no real
// biometric/security-key/active-confirmation infrastructure (M7 brief
// §32), so fabricating one here would be exactly the "text claims a
// higher AAL" attack this whole architecture exists to prevent, just
// moved into the Runtime instead of into user text.
func (o *Orchestrator) assuranceFactors() []wireclient.PresentedFactorWire {
	return []wireclient.PresentedFactorWire{
		{Factor: "device_trusted_session", Available: true, EstablishedAt: o.startedAt},
	}
}

func mustDigest(args map[string]interface{}) string {
	d, err := ir.ArgumentsDigest(args)
	if err != nil {
		// args here is always a map of compiler-produced plain strings
		// (see cognitive-core/intentcompiler), which json.Marshal never
		// fails on — see that package's own identical comment.
		return ""
	}
	return d
}

func tokenID(resp wireclient.EvaluateResponse) string {
	if resp.Token == nil {
		return ""
	}
	return resp.Token.TokenID
}

func tokenExpiry(resp wireclient.EvaluateResponse) *time.Time {
	if resp.Token == nil {
		return nil
	}
	t := resp.Token.ExpiresAt
	return &t
}

func responseForCompileError(cerr *intentcompiler.CompileError) response.Response {
	switch cerr.Code {
	case intentcompiler.ErrUnsupportedIntent:
		return response.UnsupportedIntent("")
	case intentcompiler.ErrAmbiguousIntent, intentcompiler.ErrMissingArgument:
		return response.AmbiguousIntent("", cerr.Field)
	default:
		return response.InvalidTextRequest("")
	}
}

func responseForSuccess(taskID string, raw ir.RawIR) response.Response {
	switch raw.Goal.Type {
	case "workspace.create_note":
		title, _ := raw.Content.Parameters["title"].(string)
		return response.CreateNoteSuccess(taskID, title)
	default:
		return response.GetStatusSuccess(taskID)
	}
}

func (o *Orchestrator) respondForExistingIdempotentTask(ctx context.Context, rec store.IdempotencyRecord) response.Response {
	if rec.Status == store.IdempotencyPending {
		return response.DuplicateRequestPending(rec.TaskID)
	}
	task, err := o.store.GetTask(ctx, rec.TaskID)
	if err != nil {
		return response.InternalError(rec.TaskID)
	}
	return response.DuplicateRequestCompleted(rec.TaskID, task.State == store.StateSucceeded)
}

// buildEnvelope reads every security- and data-relevant field from
// ctxObj (the Context Compiler's output, already passed through the
// Context Firewall) rather than from raw IR directly — the concrete
// integration point that makes FR-CONTEXT-001/002 load-bearing rather
// than a parallel, unused component (M8 brief §11).
func buildEnvelope(req textrequest.TextRequest, taskID string, ctxObj reqcontext.Object, irVersion string, evalResp wireclient.EvaluateResponse) wireclient.EnvelopeWire {
	return wireclient.EnvelopeWire{
		ExecutionID: fmt.Sprintf("exec-%s", taskID), RequestID: req.RequestID, CorrelationID: req.CorrelationID,
		Actor: req.Actor, TaskID: taskID, IRVersion: irVersion, IRID: ctxObj.IRID, Capability: ctxObj.CapabilityID,
		ValidatedArguments: ctxObj.Arguments, PolicyToken: evalResp.Token,
		Purpose: "", Risk: string(ctxObj.Risk),
		IdempotencyKey: ctxObj.IdempotencyKey, SafeToRetry: ctxObj.SafeToRetry,
		ExpectedOutcomeDescription: ctxObj.ExpectedOutcomeDescription, ExpectedSuccessCondition: ctxObj.ExpectedSuccessCondition,
		VerificationMethod: ctxObj.VerificationMethod,
		Cancellable:        ctxObj.Cancellable, CancellationEffect: ctxObj.CancellationEffect,
	}
}

// allowedArgKeysFor returns the capability's own declared input-schema
// key set — the Context Firewall's data_access scope (FR-CONTEXT-002),
// read from the exact same registry M2/M3 already independently enforce
// against, never a separately-maintained list that could drift.
func allowedArgKeysFor(capabilityID string) map[string]bool {
	schema := ir.Phase1Registry()[capabilityID]
	keys := make(map[string]bool, len(schema.RequiredArgs))
	for k := range schema.RequiredArgs {
		keys[k] = true
	}
	return keys
}
