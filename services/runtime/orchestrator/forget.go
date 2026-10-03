package orchestrator

import (
	"context"

	"friday/runtime-store/store"
	"friday/runtime/forgetting"
	"friday/runtime/response"
)

// Forget implements the M8 closure milestone's minimal forgetting
// mechanism (FR-MEM-004, mechanism-only Phase-1 scope) as a real
// Orchestrator entry point — not a parallel, unintegrated helper. It is
// bounded to the requesting actor (forgetting.ErrActorMismatch) and can
// only ever remove the content-bearing fields of one task's IR snapshot
// — never a task record, an audit event, an idempotency record, or a
// verification result (M8 brief §9/§10; see forgetting's own package
// doc for why that boundary is structural, not merely a rule this
// function happens to follow).
func (o *Orchestrator) Forget(ctx context.Context, taskID, actor string) response.Response {
	task, err := o.store.GetTask(ctx, taskID)
	if err != nil {
		return response.Response{Outcome: response.OutcomeInternalError, TaskID: taskID, Text: "I don't have a record of that task."}
	}

	result, ferr := forgetting.Forget(ctx, o.store, forgetting.Request{TaskID: taskID, Actor: actor})
	if ferr != nil {
		if ferr == forgetting.ErrActorMismatch {
			return response.Response{Outcome: response.OutcomeInternalError, TaskID: taskID, Text: "That request isn't associated with your session, so I can't forget it."}
		}
		return response.Response{Outcome: response.OutcomeInternalError, TaskID: taskID, Text: "I couldn't complete that forget request."}
	}

	o.audit(ctx, store.AuditEvent{CorrelationID: task.CorrelationID, TaskID: taskID, Actor: actor,
		EventType: store.EventContentForgotten, ResultStatus: "OK", Sensitivity: store.SensitivityInternal})

	if result.Forgotten {
		return response.Response{Outcome: response.OutcomeSuccess, TaskID: taskID, Text: "Done — I've forgotten the content associated with that request."}
	}
	return response.Response{Outcome: response.OutcomeInternalError, TaskID: taskID, Text: "I couldn't complete that forget request."}
}
