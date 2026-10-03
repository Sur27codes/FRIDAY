package bus

import (
	"testing"

	"friday/capability-bus/internal/envelope"
)

// FuzzDispatchUnknownCapabilityNeverPanicsOrDispatches targets the M3
// brief §22's "capability IDs" fuzz target: arbitrary capability_id
// strings thrown at Dispatch must never panic and must never result in a
// dispatched, successful execution unless the ID is exactly one of the
// two registered Phase-1 capabilities.
func FuzzDispatchUnknownCapabilityNeverPanicsOrDispatches(f *testing.F) {
	seeds := []string{
		"system.get_status", "workspace.create_note",
		"", "system.get_status ", "System.Get_Status",
		"system.execute_shell_command", "../../etc/passwd",
		"system.get_status\x00extra", "workspace.create_note; rm -rf /",
	}
	for _, s := range seeds {
		f.Add(s)
	}

	f.Fuzz(func(t *testing.T, capabilityID string) {
		h := newHarness(t)
		defer func() {
			if r := recover(); r != nil {
				t.Fatalf("Dispatch panicked on capabilityID=%q: %v", capabilityID, r)
			}
		}()

		env := envelope.Envelope{
			Capability: capabilityID, IRVersion: "0.2", TaskID: "fuzz-task", IdempotencyKey: "fuzz-idem",
		}
		out := h.bus.Dispatch(env)

		if out.Success {
			if capabilityID != "system.get_status" && capabilityID != "workspace.create_note" {
				t.Fatalf("capabilityID=%q unexpectedly dispatched successfully", capabilityID)
			}
		}
	})
}
