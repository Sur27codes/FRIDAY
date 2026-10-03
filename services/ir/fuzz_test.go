package ir

import "testing"

// FuzzValidateCapabilityAndRisk uses Go's native fuzzing (no external
// dependency, per item 12's "do not add unnecessary external dependencies
// just to satisfy this"). It targets exactly the two properties item 12
// calls out as useful: malformed input never panics, and arbitrary
// capability IDs / risk values never accidentally validate as an approved
// capability or a privileged risk level.
func FuzzValidateCapabilityAndRisk(f *testing.F) {
	seeds := []struct {
		capID string
		risk  string
	}{
		{"system.get_status", "none"},
		{"workspace.create_note", "low"},
		{"", ""},
		{"system.get_status", "critical"},
		{"../../etc/passwd", "none"},
		{"system.get_status\x00extra", "none"},
	}
	for _, s := range seeds {
		f.Add(s.capID, s.risk)
	}

	registry := Phase1Registry()

	f.Fuzz(func(t *testing.T, capID string, risk string) {
		raw := validStatusIR()
		raw.Goal.Type = capID
		raw.Risk.Level = RiskLevel(risk)

		defer func() {
			if r := recover(); r != nil {
				t.Fatalf("Validate panicked on capID=%q risk=%q: %v", capID, risk, r)
			}
		}()

		v, err := Validate(raw, registry)

		if err == nil {
			// If it validated, the capability MUST be a real registered
			// one and the risk MUST match that capability's exact
			// registered risk level — never an accidental approval.
			schema, ok := registry[capID]
			if !ok {
				t.Fatalf("capID=%q validated successfully but is not in the registry", capID)
			}
			if RiskLevel(risk) != schema.RegisteredRiskLevel {
				t.Fatalf("capID=%q validated with risk=%q but capability is registered at risk=%q", capID, risk, schema.RegisteredRiskLevel)
			}
			_ = v
		}
	})
}
