package orchestrator

import (
	"context"

	"friday/runtime-store/store"
	"friday/runtime/response"
)

// Cancel implements the runtime cancellation primitive
// (docs/PHASE-1-EMERGENCY-STOP-TEST-SPEC.md), honestly scoped to what
// Phase-1's two fast, non-preemptible capabilities actually allow (M7
// brief §19): CREATED/VALIDATED/PLANNED/AWAITING_AUTHORIZATION/AUTHORIZED
// cancel immediately (§3's table — no adapter has been invoked yet, so
// there is nothing to wait for). RUNNING/VERIFYING cannot be preemptively
// interrupted — this durably records the request (RequestCancellation)
// and lets HandleTextRequest's own cooperative checkpoints (after
// Dispatch returns) decide the final outcome, exactly as §3/§4 specify.
func (o *Orchestrator) Cancel(ctx context.Context, taskID string) response.Response {
	task, err := o.store.GetTask(ctx, taskID)
	if err != nil {
		return response.InternalError(taskID)
	}
	if task.State.Terminal() {
		o.audit(ctx, store.AuditEvent{CorrelationID: task.CorrelationID, TaskID: taskID, Actor: task.Actor,
			EventType: store.EventStopRequestIgnored, ResultStatus: "already_terminal", Sensitivity: store.SensitivityInternal})
		return response.AlreadyTerminal(taskID)
	}

	if err := o.store.RequestCancellation(ctx, taskID); err != nil {
		return response.InternalError(taskID)
	}
	o.audit(ctx, store.AuditEvent{CorrelationID: task.CorrelationID, TaskID: taskID, Actor: task.Actor,
		EventType: store.EventStopRequested, ResultStatus: "OK", Sensitivity: store.SensitivityInternal})

	switch task.State {
	case store.StateCreated, store.StateValidated, store.StatePlanned, store.StateAwaitingAuthorization, store.StateAuthorized:
		return o.finalizeCancellation(ctx, task.CorrelationID, taskID, task.Actor, task.IdempotencyKey)
	default:
		// RUNNING or VERIFYING: acknowledged and durably recorded; the
		// actual terminal state is decided cooperatively by the in-flight
		// HandleTextRequest call, per PHASE-1-EMERGENCY-STOP-TEST-SPEC.md
		// §3's table for those two states.
		return response.CancellationAcknowledged(taskID)
	}
}
