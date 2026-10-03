// Package response implements M7 brief §7's deterministic, grounded
// response generation and §46's error-to-user-response mapping. No LLM,
// no model call, no free-form phrasing — every message here is a fixed
// template selected by a closed set of outcome codes, and every SUCCESS
// message is only ever constructed from state this Runtime has already
// durably confirmed (M7 brief §45: never say "created" before
// verification actually passed).
package response

import "fmt"

type Outcome string

const (
	OutcomeSuccess               Outcome = "SUCCESS"
	OutcomeUnsupportedIntent     Outcome = "UNSUPPORTED_INTENT"
	OutcomeAmbiguousIntent       Outcome = "AMBIGUOUS_INTENT"
	OutcomeInvalidTextRequest    Outcome = "INVALID_TEXT_REQUEST"
	OutcomeIRValidationFailed    Outcome = "IR_VALIDATION_FAILED"
	OutcomePolicyDenied          Outcome = "POLICY_DENIED"
	OutcomePolicyUnavailable     Outcome = "POLICY_UNAVAILABLE"
	OutcomeCapabilityUnavailable Outcome = "CAPABILITY_UNAVAILABLE"
	OutcomeExecutionFailed       Outcome = "EXECUTION_FAILED"
	OutcomeVerificationFailed    Outcome = "VERIFICATION_FAILED"
	OutcomeCancelled             Outcome = "CANCELLED"
	OutcomeAlreadyTerminal       Outcome = "ALREADY_TERMINAL"
	OutcomeDuplicateRequest      Outcome = "DUPLICATE_REQUEST"
	OutcomeInternalError         Outcome = "INTERNAL_ERROR"
)

// Response is the deterministic, user-facing result of one request. Text
// never contains a stack trace, a raw token, a file path outside the
// sandbox, or internal configuration (M7 brief §46) — Text is always one
// of a small number of fixed templates in this file.
type Response struct {
	Outcome Outcome
	TaskID  string
	Text    string
}

func Success(taskID, text string) Response {
	return Response{Outcome: OutcomeSuccess, TaskID: taskID, Text: text}
}

func GetStatusSuccess(taskID string) Response {
	return Success(taskID, "System status retrieved successfully.")
}

func CreateNoteSuccess(taskID, title string) Response {
	return Success(taskID, fmt.Sprintf("Created and verified note %q.", title))
}

func UnsupportedIntent(taskID string) Response {
	return Response{Outcome: OutcomeUnsupportedIntent, TaskID: taskID, Text: "That capability isn't available in Phase 1."}
}

func AmbiguousIntent(taskID, missingField string) Response {
	text := "I need more information to do that."
	if missingField != "" {
		text = fmt.Sprintf("I need more information to do that (missing: %s).", missingField)
	}
	return Response{Outcome: OutcomeAmbiguousIntent, TaskID: taskID, Text: text}
}

func InvalidTextRequest(taskID string) Response {
	return Response{Outcome: OutcomeInvalidTextRequest, TaskID: taskID, Text: "I didn't receive a usable request."}
}

func IRValidationFailed(taskID string) Response {
	return Response{Outcome: OutcomeIRValidationFailed, TaskID: taskID, Text: "That request didn't pass validation, so I didn't attempt it."}
}

func PolicyDenied(taskID string) Response {
	return Response{Outcome: OutcomePolicyDenied, TaskID: taskID, Text: "I couldn't perform that action because authorization was denied."}
}

func PolicyRequiresMoreAssurance(taskID string) Response {
	return Response{Outcome: OutcomePolicyDenied, TaskID: taskID, Text: "That action requires stronger authorization."}
}

func PolicyUnavailable(taskID string) Response {
	return Response{Outcome: OutcomePolicyUnavailable, TaskID: taskID, Text: "I can't authorize that action right now."}
}

func CapabilityUnavailable(taskID string) Response {
	return Response{Outcome: OutcomeCapabilityUnavailable, TaskID: taskID, Text: "I can't perform that action right now."}
}

func ExecutionFailed(taskID string) Response {
	return Response{Outcome: OutcomeExecutionFailed, TaskID: taskID, Text: "The action could not be completed."}
}

func VerificationFailed(taskID string) Response {
	return Response{Outcome: OutcomeVerificationFailed, TaskID: taskID, Text: "The action ran, but I couldn't verify the expected result."}
}

func Cancelled(taskID string) Response {
	return Response{Outcome: OutcomeCancelled, TaskID: taskID, Text: "Cancelled."}
}

func CancellationAcknowledged(taskID string) Response {
	return Response{Outcome: OutcomeCancelled, TaskID: taskID, Text: "Stop request received; this task was already past the point Phase 1 can safely interrupt, so its outcome will be reported once it's known."}
}

func RequiresManualReview(taskID string) Response {
	return Response{Outcome: OutcomeVerificationFailed, TaskID: taskID, Text: "A stop was requested after the action may have already taken effect; I can't confirm it was undone. This needs manual review."}
}

func AlreadyTerminal(taskID string) Response {
	return Response{Outcome: OutcomeAlreadyTerminal, TaskID: taskID, Text: "That task has already finished; there's nothing to stop."}
}

func DuplicateRequestPending(taskID string) Response {
	return Response{Outcome: OutcomeDuplicateRequest, TaskID: taskID, Text: "That exact request is already in progress."}
}

func DuplicateRequestCompleted(taskID string, succeeded bool) Response {
	if succeeded {
		return Response{Outcome: OutcomeDuplicateRequest, TaskID: taskID, Text: "That was already done successfully; I didn't repeat it."}
	}
	return Response{Outcome: OutcomeDuplicateRequest, TaskID: taskID, Text: "That exact request was already attempted and did not succeed; I didn't repeat it."}
}

func InternalError(taskID string) Response {
	return Response{Outcome: OutcomeInternalError, TaskID: taskID, Text: "Something went wrong on my end; the action was not performed."}
}
