// Package bus implements the Capability Bus dispatch path: validated
// Execution Envelope -> exact registered capability -> constrained
// execution -> capability-level verification. Per the M3 brief §5, this
// package never executes a capability because an IR requests it, a
// planner requests it, a caller knows its ID, or a valid-looking envelope
// exists — only because envelope.Validate (11 checks, including live
// Ed25519 token verification) returned success.
package bus

import (
	"time"

	"friday/capability-bus/internal/capabilities/createnote"
	"friday/capability-bus/internal/capabilities/getstatus"
	"friday/capability-bus/internal/envelope"
)

// Outcome keeps EXECUTION RESULT and VERIFICATION RESULT as two distinct,
// separately-inspectable fields (M3 brief §12) — Success is only ever
// true if Verified is true; a capability that executed but failed
// verification is never reported as succeeded.
type Outcome struct {
	Dispatched bool // false if envelope validation itself failed — nothing ran
	Executed   bool
	Verified   bool
	Success    bool

	GetStatusResult  *getstatus.Snapshot
	CreateNoteResult *createnote.Result

	Err *envelope.DispatchError
}

// Bus holds the two adapters' dependencies. Neither dependency lets the
// Bus mint authorization — SelfModelSource is a read-only status source,
// Sandbox writes only within its resolved workspace root.
type Bus struct {
	ctx             envelope.ValidationContext
	selfModelSource getstatus.SelfModelSource
	sandbox         *createnote.Sandbox
}

func New(ctx envelope.ValidationContext, selfModelSource getstatus.SelfModelSource, sandbox *createnote.Sandbox) *Bus {
	return &Bus{ctx: ctx, selfModelSource: selfModelSource, sandbox: sandbox}
}

// Dispatch is the Bus's only entry point. It accepts an envelope.Envelope
// — never a friday/ir.RawIR or friday/ir.ValidatedIR (no such overload
// exists; see envelope.go's package doc) — and never proceeds to
// execution without envelope.Validate succeeding first.
func (b *Bus) Dispatch(env envelope.Envelope) Outcome {
	// Server owns the clock (M4 principle, mirrored from
	// policy-engine/internal/rpc/server.go): a long-lived Bus process must
	// evaluate token expiry (envelope check 6b) against the real wall
	// clock at the moment of each request, never a value captured once at
	// Bus construction — otherwise a daemon running for hours would freeze
	// expiry checks at its own startup time and never actually enforce
	// expiry. b.ctx.Now is therefore always overridden here; the field
	// still exists on ValidationContext for direct envelope.Validate
	// callers (e.g. unit tests) that want to inject a specific instant.
	ctx := b.ctx
	ctx.Now = time.Now()
	cap, args, verr := envelope.Validate(env, ctx)
	if verr != nil {
		return Outcome{Dispatched: false, Err: verr}
	}

	switch cap.CapabilityID {
	case "system.get_status":
		return b.dispatchGetStatus()
	case "workspace.create_note":
		return b.dispatchCreateNote(env, args)
	default:
		// Unreachable given envelope.Validate already confirmed the
		// capability is one of the two registered entries — kept as an
		// explicit fail-closed default rather than an unchecked panic.
		return Outcome{Dispatched: true, Err: &envelope.DispatchError{
			Check: "dispatch_switch", Category: envelope.CategoryUnknownCapability,
			Detail: "validated capability has no matching dispatch case",
		}}
	}
}

func (b *Bus) dispatchGetStatus() Outcome {
	snap, err := getstatus.Execute(b.selfModelSource)
	if err != nil {
		return Outcome{Dispatched: true, Executed: false, Err: &envelope.DispatchError{
			Check: "execute", Category: envelope.CategoryCapabilityExecutionFailed, Detail: "get_status execution failed",
		}}
	}
	ok, err := getstatus.Verify(b.selfModelSource, snap)
	if err != nil || !ok {
		return Outcome{Dispatched: true, Executed: true, Verified: false, GetStatusResult: &snap, Err: &envelope.DispatchError{
			Check: "verify", Category: envelope.CategoryCapabilityVerificationFailed, Detail: "get_status verification failed",
		}}
	}
	return Outcome{Dispatched: true, Executed: true, Verified: true, Success: true, GetStatusResult: &snap}
}

func (b *Bus) dispatchCreateNote(env envelope.Envelope, args map[string]interface{}) Outcome {
	title, _ := args["title"].(string)
	body, _ := args["body"].(string)
	cnArgs := createnote.Args{Title: title, Body: body}

	result, err := b.sandbox.Execute(env.IdempotencyKey, cnArgs)
	if err != nil {
		return Outcome{Dispatched: true, Executed: false, Err: &envelope.DispatchError{
			Check: "execute", Category: envelope.CategoryCapabilityExecutionFailed, Detail: "create_note execution failed",
		}}
	}
	ok, err := b.sandbox.Verify(result, cnArgs)
	if err != nil || !ok {
		return Outcome{Dispatched: true, Executed: true, Verified: false, CreateNoteResult: &result, Err: &envelope.DispatchError{
			Check: "verify", Category: envelope.CategoryCapabilityVerificationFailed, Detail: "create_note verification failed",
		}}
	}
	return Outcome{Dispatched: true, Executed: true, Verified: true, Success: true, CreateNoteResult: &result}
}
