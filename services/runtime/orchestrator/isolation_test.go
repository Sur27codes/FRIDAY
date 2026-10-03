package orchestrator

import (
	"os/exec"
	"strings"
	"testing"
)

// M7 brief §33: repeat the private-key-isolation structural proof for
// the new M7 module, using the same `go list -deps` technique M4
// established and M5 (cognitive-core) and M6 (runtime-store) already
// carry their own copies of. friday/runtime's compiled `friday` binary
// must have zero dependency on friday/policy-engine, friday/policytoken,
// or friday/capability-bus — every capability execution and
// authorization decision must cross the real Unix-socket RPC boundary
// wireclient implements, never a direct Go import.
func TestM7_RuntimeHasNoDependencyOnPolicyEngineOrCapabilityBus(t *testing.T) {
	cmd := exec.Command("go", "list", "-deps", "./...")
	cmd.Dir = ".."
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("go list -deps failed: %v\n%s", err, out)
	}
	deps := string(out)
	for _, forbidden := range []string{"friday/policy-engine", "friday/policytoken", "friday/capability-bus"} {
		if strings.Contains(deps, forbidden) {
			t.Fatalf("friday/runtime's dependency closure includes %s — the Runtime must never have a direct import path to policy-minting or capability-execution internals.\nfull dependency list:\n%s", forbidden, deps)
		}
	}
}
