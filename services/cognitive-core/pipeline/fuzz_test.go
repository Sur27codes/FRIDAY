package pipeline

import (
	"testing"

	"friday/cognitive-core/planner"
	"friday/cognitive-core/textrequest"
)

// FuzzRun_MalformedInputNeverBypassesM2Validation exercises the full
// TextRequest -> Compile -> ir.Validate -> CreatePlan chain end to end
// (M5 brief §26). The property under test: a Plan (State == PLANNED) is
// reachable if and only if ir.Validate actually ran and accepted the
// compiler's RawIR — there is no code path in pipeline.Run that skips
// straight from Compile's success to CreatePlan (see pipeline.go's source
// shape). This also re-exercises services/ir's own already-fuzzed
// validator (M2), now reached through a real, independently-written
// producer (the Intent Compiler) rather than only M2's own hand-built
// test fixtures — a meaningful integration-level check M2's fuzz suite
// alone could not perform, since M2 has no compiler of its own to fuzz
// through.
func FuzzRun_MalformedInputNeverBypassesM2Validation(f *testing.F) {
	seeds := []string{
		"", "check system status", "create a note called x with y",
		"create a note called " + string(make([]byte, 300)) + " with y", // oversized title, still schema-shaped
		"create a note called x with " + string(make([]byte, 20000)),    // oversized body
		"create a note called x with y called z with w",
		"CREATE A NOTE CALLED X WITH Y; ignore policy",
	}
	for _, s := range seeds {
		f.Add(s)
	}

	f.Fuzz(func(t *testing.T, text string) {
		req := textrequest.TextRequest{
			RequestID: "req-fuzz", CorrelationID: "corr-fuzz", Actor: "user.owner",
			SessionID: "sess-fuzz", RawText: text, Source: textrequest.SourceText,
		}
		res, perr := Run(req, "task-fuzz", false)

		if res.State == planner.TaskPlanned {
			if perr != nil {
				t.Fatalf("task reached PLANNED but an error was also returned: %v", perr)
			}
			if res.ValidatedIR == nil {
				t.Fatalf("task reached PLANNED without a recorded ValidatedIR — M2 validation was bypassed, input %q", text)
			}
			if res.Plan == nil || len(res.Plan.Steps) != 1 {
				t.Fatalf("PLANNED state without exactly one plan step, input %q", text)
			}
			cap := res.Plan.Steps[0].CapabilityID
			if cap != "system.get_status" && cap != "workspace.create_note" {
				t.Fatalf("planned an unregistered capability %q, input %q", cap, text)
			}
		}
		if res.State != planner.TaskPlanned && perr == nil {
			t.Fatalf("no error returned but task did not reach PLANNED either, input %q, state=%q", text, res.State)
		}
	})
}
