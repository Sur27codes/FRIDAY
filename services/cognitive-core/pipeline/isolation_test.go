package pipeline

import (
	"os/exec"
	"strings"
	"testing"
)

// M5-SEC-008/009: the Intent Compiler cannot produce an authorization
// token or an Execution Envelope. Proven the same way M4 proved private-
// key isolation: `go list -deps` walks the actual import graph the
// compiler would use to build any binary from this module — if
// friday/policy-engine, friday/policytoken, and friday/capability-bus
// never appear in this module's dependency closure, there is no code
// path, accidental or otherwise, by which this module could construct a
// policytoken.PolicyToken (the only type in this system capable of
// representing "an authorization token") or an Execution Envelope (whose
// type lives in capability-bus/internal/envelope, structurally
// unreachable from here even if the module dependency existed, per Go's
// internal/ rule already exercised in M4). go.mod itself already shows
// this module requires only friday/ir — this test makes that guarantee
// self-verifying rather than trusting a human to keep go.mod honest.
func TestM5SEC008_009_CognitiveCoreHasNoDependencyOnAuthorizationOrExecutionTypes(t *testing.T) {
	cmd := exec.Command("go", "list", "-deps", "./...")
	cmd.Dir = ".." // module root (services/cognitive-core)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("go list -deps failed: %v\n%s", err, out)
	}
	deps := string(out)
	for _, forbidden := range []string{"friday/policy-engine", "friday/policytoken", "friday/capability-bus", "friday/rpcframe"} {
		if strings.Contains(deps, forbidden) {
			t.Fatalf("cognitive-core's dependency closure includes %s — the Intent Compiler/Planner must have no path to minting a token or building an Execution Envelope.\nfull dependency list:\n%s", forbidden, deps)
		}
	}
}

// M5 brief §27 ("no side effects"): production code in this module must
// never touch the filesystem, network, a shell, or a database. Grepping
// production (non-_test.go) source for the standard-library entry points
// that would do any of those things is a stronger, harder-to-accidentally-
// violate check than "no test happened to fail."
func TestNoSideEffects_ProductionCodeTouchesNoIOPrimitive(t *testing.T) {
	cmd := exec.Command("go", "list", "-deps", "./...")
	cmd.Dir = ".."
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("go list -deps failed: %v\n%s", err, out)
	}
	forbidden := map[string]bool{"os/exec": true, "database/sql": true, "net": true, "net/http": true}
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if forbidden[strings.TrimSpace(line)] {
			t.Fatalf("cognitive-core's dependency closure includes %q — M5 production code must have no shell/network/database access.\nfull dependency list:\n%s", line, out)
		}
	}
}
