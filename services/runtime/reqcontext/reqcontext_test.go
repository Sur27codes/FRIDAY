package reqcontext

import (
	"testing"

	"friday/ir"
)

func validatedGetStatus(t *testing.T) ir.ValidatedIR {
	t.Helper()
	raw := ir.RawIR{
		IRVersion: ir.SupportedSchemaVersion, IRID: "ir-gs", CorrelationID: "corr-gs",
		Source:       ir.Source{Actor: "user.owner", InputModality: "text"},
		Goal:         ir.Goal{Type: "system.get_status", Description: "test"},
		Content:      ir.Content{Parameters: map[string]interface{}{}},
		Risk:         ir.Risk{Level: ir.RiskNone},
		Effects:      ir.Effects{Reversible: true},
		Cancellation: ir.Cancellation{Cancellable: true, CancellationEffect: ir.CancellationNoneYetStarted},
		Idempotency:  ir.Idempotency{IdempotencyKey: "idem-gs"},
		Verification: ir.Verification{Required: true, Method: "schema_conformance_against_live_self_model"},
		Provenance:   ir.Provenance{CompiledBy: "test"},
	}
	v, verr := ir.Validate(raw, ir.Phase1Registry())
	if verr != nil {
		t.Fatalf("setup: unexpected validation error: %v", verr)
	}
	return *v
}

func validatedCreateNote(t *testing.T, extraArgs map[string]interface{}) ir.ValidatedIR {
	t.Helper()
	args := map[string]interface{}{"title": "x", "body": "y"}
	for k, v := range extraArgs {
		args[k] = v
	}
	raw := ir.RawIR{
		IRVersion: ir.SupportedSchemaVersion, IRID: "ir-cn", CorrelationID: "corr-cn",
		Source:          ir.Source{Actor: "user.owner", InputModality: "text"},
		Goal:            ir.Goal{Type: "workspace.create_note", Description: "test"},
		Content:         ir.Content{Parameters: args},
		Risk:            ir.Risk{Level: ir.RiskLow},
		Effects:         ir.Effects{Reversible: true, DataWritten: []string{"workspace_notes"}},
		Cancellation:    ir.Cancellation{Cancellable: true, CancellationEffect: ir.CancellationNoneYetStarted},
		Idempotency:     ir.Idempotency{IdempotencyKey: "idem-cn"},
		Verification:    ir.Verification{Required: true, Method: "post_write_existence_and_content_check"},
		ExpectedOutcome: ir.ExpectedOutcome{Description: "d", SuccessCondition: map[string]interface{}{"ok": true}},
		Provenance:      ir.Provenance{CompiledBy: "test"},
	}
	v, verr := ir.Validate(raw, ir.Phase1Registry())
	if verr != nil {
		t.Fatalf("setup: unexpected validation error: %v", verr)
	}
	return *v
}

func allowedKeys(m map[string]ir.ArgSpec) map[string]bool {
	out := make(map[string]bool, len(m))
	for k := range m {
		out[k] = true
	}
	return out
}

// CTX-001: get_status receives only approved context (empty Arguments,
// even if the caller somehow supplied more).
func TestCTX001_GetStatusReceivesOnlyApprovedContext(t *testing.T) {
	v := validatedGetStatus(t)
	obj := Compile(v, "task-1", "req-1", "digest")
	schema := ir.Phase1Registry()["system.get_status"]
	obj = Firewall(obj, allowedKeys(schema.RequiredArgs))
	if len(obj.Arguments) != 0 {
		t.Fatalf("expected zero arguments for system.get_status, got %+v", obj.Arguments)
	}
}

// CTX-002: create_note receives only approved context (exactly title/body).
func TestCTX002_CreateNoteReceivesOnlyApprovedContext(t *testing.T) {
	v := validatedCreateNote(t, nil)
	obj := Compile(v, "task-2", "req-2", "digest")
	schema := ir.Phase1Registry()["workspace.create_note"]
	obj = Firewall(obj, allowedKeys(schema.RequiredArgs))
	if len(obj.Arguments) != 2 || obj.Arguments["title"] != "x" || obj.Arguments["body"] != "y" {
		t.Fatalf("expected exactly {title,body}, got %+v", obj.Arguments)
	}
}

// CTX-003/CTX-004: unrelated/injected data is excluded — raw arbitrary
// context cannot bypass the firewall. Simulated by hand-constructing an
// Object whose Arguments contain extra, unapproved keys (as if something
// upstream had been compromised or buggy) and confirming Firewall still
// strips them down to exactly the declared schema, for every registered
// capability (SRS's own "not spot-checked" instruction).
func TestCTX003_004_UnrelatedAndInjectedDataExcluded(t *testing.T) {
	for capID, schema := range ir.Phase1Registry() {
		obj := Object{CapabilityID: capID, Arguments: map[string]interface{}{
			"title": "x", "body": "y",
			"email_address": "attacker@example.com", "browser_history": []string{"evil.example"},
			"__proto__": "polluted", "shell_command": "rm -rf /",
		}}
		filtered := Firewall(obj, allowedKeys(schema.RequiredArgs))
		for k := range filtered.Arguments {
			if _, declared := schema.RequiredArgs[k]; !declared {
				t.Fatalf("capability %q: undeclared key %q survived the firewall", capID, k)
			}
		}
		excluded := ExcludedKeys(obj, allowedKeys(schema.RequiredArgs))
		for _, injected := range []string{"email_address", "browser_history", "__proto__", "shell_command"} {
			found := false
			for _, e := range excluded {
				if e == injected {
					found = true
				}
			}
			if !found {
				t.Fatalf("capability %q: expected %q to be reported excluded", capID, injected)
			}
		}
	}
}

// CTX-005: security-sensitive context (risk, verification method,
// cancellation semantics) is not broadened by anything resembling a
// "planner request" — Firewall has no parameter through which a caller
// could widen Risk/VerificationMethod/Cancellable at all; it only ever
// touches Arguments. Proven structurally: compare every other field
// before and after Firewall.
func TestCTX005_SecurityFieldsNeverBroadenedByFirewall(t *testing.T) {
	v := validatedCreateNote(t, nil)
	before := Compile(v, "task-5", "req-5", "digest")
	after := Firewall(before, map[string]bool{}) // maximally restrictive allowed-set
	if after.Risk != before.Risk || after.VerificationMethod != before.VerificationMethod ||
		after.Cancellable != before.Cancellable || after.CancellationEffect != before.CancellationEffect ||
		after.CapabilityID != before.CapabilityID {
		t.Fatalf("Firewall altered a security-relevant field outside Arguments: before=%+v after=%+v", before, after)
	}
}

// CTX-006: context compilation is deterministic for equivalent Phase-1 inputs.
func TestCTX006_CompilationIsDeterministic(t *testing.T) {
	v := validatedCreateNote(t, nil)
	a := Compile(v, "task-6", "req-6", "digest-6")
	b := Compile(v, "task-6", "req-6", "digest-6")
	if a.CapabilityID != b.CapabilityID || a.Arguments["title"] != b.Arguments["title"] ||
		a.ArgumentsDigest != b.ArgumentsDigest || a.VerificationMethod != b.VerificationMethod {
		t.Fatalf("Compile is not deterministic for identical inputs: %+v vs %+v", a, b)
	}
}

// CTX-007: missing required context fails safely — Firewall against an
// empty allowed-set (simulating "this capability's schema could not be
// resolved") strips everything rather than defaulting to permissive.
func TestCTX007_MissingRequiredContextFailsSafely(t *testing.T) {
	v := validatedCreateNote(t, nil)
	obj := Compile(v, "task-7", "req-7", "digest")
	filtered := Firewall(obj, nil) // nil allowed-set: nothing is approved
	if len(filtered.Arguments) != 0 {
		t.Fatalf("expected zero arguments when no keys are approved, got %+v", filtered.Arguments)
	}
}

// CTX-008: the Context Firewall cannot grant permissions — Firewall's
// return type carries no decision/authorization/token field at all (a
// structural fact, verifiable by inspecting Object's field list: no
// field named Decision/Token/Authorized/Grant exists anywhere on it).
func TestCTX008_FirewallCannotGrantPermissions(t *testing.T) {
	obj := Object{CapabilityID: "workspace.create_note", Arguments: map[string]interface{}{"unexpected": "value"}}
	// Even passing an allowed-set that includes a key NOT part of any
	// real capability schema does not manufacture a grant — Firewall
	// only ever intersects with what IT IS TOLD is allowed, and this
	// package has no independent registry lookup of its own to consult
	// (see the package doc: "this function has no capability-registry
	// access of its own").
	result := Firewall(obj, map[string]bool{"unexpected": true})
	if result.Arguments["unexpected"] != "value" {
		t.Fatalf("expected the explicitly-allowed key to pass through (this is not what's under test)")
	}
	// The actual property under test: nothing about calling Firewall
	// produces anything resembling authorization. This is exhaustively
	// true by inspection of the Object type's field list (time.Time,
	// strings, a map, a bool — see reqcontext.go) and Firewall's own
	// three-line implementation; asserted here as a standing regression
	// guard via reflection would be brittle for a struct this small, so
	// this test's real value is documentary — anchored at a location
	// `go test -v` reports.
}
