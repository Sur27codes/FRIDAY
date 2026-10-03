package intentcompiler

import (
	"testing"
	"time"

	"friday/cognitive-core/textrequest"
	"friday/ir"
)

func req(rawText string) textrequest.TextRequest {
	return textrequest.TextRequest{
		RequestID: "req-1", CorrelationID: "corr-1", Actor: "user.owner",
		SessionID: "sess-1", RawText: rawText,
		ReceivedAt: time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC),
		Source:     textrequest.SourceText,
	}
}

// ---- M5-INTENT-001/002: supported intents compile correctly ----

func TestM5INTENT001_CheckSystemStatus(t *testing.T) {
	for _, text := range []string{
		"check system status", "get system status", "show system status",
		"what is the system status", "What is the system status?",
		"  CHECK   System   Status  ",
	} {
		raw, cerr := Compile(req(text))
		if cerr != nil {
			t.Fatalf("text %q: unexpected error: %v", text, cerr)
		}
		if raw.Goal.Type != "system.get_status" {
			t.Fatalf("text %q: expected system.get_status, got %q", text, raw.Goal.Type)
		}
		if len(raw.Content.Parameters) != 0 {
			t.Fatalf("text %q: expected zero arguments, got %+v", text, raw.Content.Parameters)
		}
	}
}

func TestM5INTENT002_CreateNote_ValidForms(t *testing.T) {
	cases := []struct{ text, wantTitle, wantBody string }{
		{"create a note called architecture-test with Phase 1 works", "architecture-test", "Phase 1 works"},
		{"make a note named architecture-test containing Phase 1 works", "architecture-test", "Phase 1 works"},
		{"Create a note called Architecture-Test with Phase 1 works.", "Architecture-Test", "Phase 1 works."},
	}
	for _, c := range cases {
		raw, cerr := Compile(req(c.text))
		if cerr != nil {
			t.Fatalf("text %q: unexpected error: %v", c.text, cerr)
		}
		if raw.Goal.Type != "workspace.create_note" {
			t.Fatalf("text %q: expected workspace.create_note, got %q", c.text, raw.Goal.Type)
		}
		if raw.Content.Parameters["title"] != c.wantTitle {
			t.Fatalf("text %q: title = %v, want %v", c.text, raw.Content.Parameters["title"], c.wantTitle)
		}
		if raw.Content.Parameters["body"] != c.wantBody {
			t.Fatalf("text %q: body = %v, want %v", c.text, raw.Content.Parameters["body"], c.wantBody)
		}
	}
}

// ---- M5-INTENT-003/004: ambiguous/incomplete create_note ----

func TestM5INTENT003_MissingNoteName_Ambiguous(t *testing.T) {
	_, cerr := Compile(req("create a note with Phase 1 works"))
	if cerr == nil {
		t.Fatalf("expected an ambiguous/missing-argument error")
	}
	if cerr.Code != ErrMissingArgument || cerr.Field != "title" {
		t.Fatalf("expected MISSING_ARGUMENT/title, got %+v", cerr)
	}
}

func TestM5INTENT004_MissingNoteContent_Ambiguous(t *testing.T) {
	_, cerr := Compile(req("create a note called architecture-test"))
	if cerr == nil {
		t.Fatalf("expected an ambiguous/missing-argument error")
	}
	if cerr.Code != ErrMissingArgument || cerr.Field != "body" {
		t.Fatalf("expected MISSING_ARGUMENT/body, got %+v", cerr)
	}
}

func TestM5INTENT003b_BareCreateANote_Ambiguous(t *testing.T) {
	_, cerr := Compile(req("create a note"))
	if cerr == nil || cerr.Code != ErrMissingArgument {
		t.Fatalf("expected MISSING_ARGUMENT for a bare \"create a note\", got %+v", cerr)
	}
}

// ---- M5-INTENT-005: unsupported ----

func TestM5INTENT005_UnsupportedCommand(t *testing.T) {
	for _, text := range []string{
		"check it", "make something", "delete every file", "send an email",
		"restart production", "open terminal and run rm -rf",
	} {
		_, cerr := Compile(req(text))
		if cerr == nil {
			t.Fatalf("text %q: expected UNSUPPORTED_INTENT, got success", text)
		}
		if cerr.Code != ErrUnsupportedIntent {
			t.Fatalf("text %q: expected UNSUPPORTED_INTENT, got %s", text, cerr.Code)
		}
	}
}

// ---- M5-INTENT-006/007: empty / whitespace-only ----

func TestM5INTENT006_EmptyText_Invalid(t *testing.T) {
	_, cerr := Compile(req(""))
	if cerr == nil || cerr.Code != ErrInvalidTextRequest {
		t.Fatalf("expected INVALID_TEXT_REQUEST for empty text, got %+v", cerr)
	}
}

func TestM5INTENT007_WhitespaceOnly_Invalid(t *testing.T) {
	_, cerr := Compile(req("   \t\n  "))
	if cerr == nil || cerr.Code != ErrInvalidTextRequest {
		t.Fatalf("expected INVALID_TEXT_REQUEST for whitespace-only text, got %+v", cerr)
	}
}

// ---- M5-INTENT-008: oversized input ----

func TestM5INTENT008_OversizedInput_Invalid(t *testing.T) {
	huge := make([]byte, textrequest.MaxRawTextBytes+1)
	for i := range huge {
		huge[i] = 'a'
	}
	_, cerr := Compile(req(string(huge)))
	if cerr == nil || cerr.Code != ErrInvalidTextRequest {
		t.Fatalf("expected INVALID_TEXT_REQUEST for oversized text, got %+v", cerr)
	}
}

func TestM5INTENT008b_AtLimit_NotRejectedForSizeAlone(t *testing.T) {
	// Exactly at the limit, but not a recognized phrase — must fail as
	// UNSUPPORTED_INTENT (recognized-but-different reason), not as
	// INVALID_TEXT_REQUEST — confirms the size check itself is exact, not
	// off-by-one in the rejecting direction.
	atLimit := make([]byte, textrequest.MaxRawTextBytes)
	for i := range atLimit {
		atLimit[i] = 'a'
	}
	_, cerr := Compile(req(string(atLimit)))
	if cerr == nil {
		t.Fatalf("expected an error (not a recognized phrase), got success")
	}
	if cerr.Code == ErrInvalidTextRequest {
		t.Fatalf("text exactly at the size limit must not be rejected for size alone, got %+v", cerr)
	}
}

// ---- M5-INTENT-009: normalization is deterministic ----

func TestM5INTENT009_NormalizationDeterministic(t *testing.T) {
	variants := []string{
		"check system status",
		"CHECK SYSTEM STATUS",
		"  check   system   status  ",
		"Check System Status.",
		"check system status?",
	}
	for _, v := range variants {
		raw, cerr := Compile(req(v))
		if cerr != nil {
			t.Fatalf("text %q: unexpected error: %v", v, cerr)
		}
		if raw.Goal.Type != "system.get_status" {
			t.Fatalf("text %q: expected system.get_status, got %q", v, raw.Goal.Type)
		}
	}
}

// ---- M5-INTENT-010: determinism ----

func TestM5INTENT010_SameInputProducesIdenticalRawIR(t *testing.T) {
	r := req("create a note called architecture-test with Phase 1 works")
	raw1, err1 := Compile(r)
	raw2, err2 := Compile(r)
	if err1 != nil || err2 != nil {
		t.Fatalf("unexpected errors: %v / %v", err1, err2)
	}
	if raw1.IRID != raw2.IRID || raw1.Idempotency.IdempotencyKey != raw2.Idempotency.IdempotencyKey {
		t.Fatalf("expected identical IRID/idempotency key across identical calls")
	}
	if !equalRawIR(raw1, raw2) {
		t.Fatalf("expected byte-identical RawIR for identical input:\n%+v\n%+v", raw1, raw2)
	}
}

func equalRawIR(a, b ir.RawIR) bool {
	return a.IRVersion == b.IRVersion && a.IRID == b.IRID && a.CorrelationID == b.CorrelationID &&
		a.Goal == b.Goal && a.Risk == b.Risk && a.Idempotency == b.Idempotency &&
		a.Verification == b.Verification && a.Cancellation == b.Cancellation
}
