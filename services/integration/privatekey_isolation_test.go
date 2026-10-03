package integration

import (
	"os/exec"
	"strings"
	"testing"
)

// M4-POL-017: the Capability Bus process must not possess the Policy
// Engine's private authorization-signing key — not "does not currently
// use it," but structurally cannot reach it at all (M4 brief §5). Go's
// `go list -deps` walks the actual, real import graph the compiler would
// use to build the binary; if `friday/policy-engine` (the only module
// containing a Signer/private-key type anywhere in this system) does not
// appear in capability-bus's dependency closure, there is no code path —
// accidental or otherwise — by which the compiled capabilitybusd binary
// could hold, construct, or call anything from that package. This is the
// same authoritative signal `go build` itself relies on, not a
// string-grep proxy for it.
func TestPrivateKeyIsolation_CapabilityBusHasNoDependencyOnPolicyEngine(t *testing.T) {
	cmd := exec.Command("go", "list", "-deps", "./...")
	cmd.Dir = "../capability-bus"
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("go list -deps failed: %v\n%s", err, out)
	}
	deps := string(out)
	if strings.Contains(deps, "friday/policy-engine") {
		t.Fatalf("capability-bus's dependency closure includes friday/policy-engine — "+
			"the Bus process must never be able to reach the Policy Engine's private Signer.\nfull dependency list:\n%s", deps)
	}
}

// Same check in the other direction for completeness: friday/ir (the
// FRIDAY IR validator) must not depend on the Policy Engine either — this
// is the implementation-side half of ARCH-M4-001's resolution (JK
// §J.2.1): pure IR security-consistency validation requires no live
// Policy Engine process or package.
func TestArchM4_001_IRValidatorHasNoDependencyOnPolicyEngine(t *testing.T) {
	cmd := exec.Command("go", "list", "-deps", "./...")
	cmd.Dir = "../ir"
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("go list -deps failed: %v\n%s", err, out)
	}
	deps := string(out)
	if strings.Contains(deps, "friday/policy-engine") {
		t.Fatalf("friday/ir's dependency closure includes friday/policy-engine — "+
			"ARCH-M4-001 requires services/ir to have zero dependency on the Policy Engine.\nfull dependency list:\n%s", deps)
	}
}

// The converse structural guarantee: the Policy Engine process itself
// must never depend on friday/capability-bus (it should have no reason
// to — it is a pure decision service with one RPC method) — a dependency
// in this direction would be a design smell worth flagging even though
// it isn't the specific property M4 brief §5 names.
func TestPolicyEngineHasNoDependencyOnCapabilityBus(t *testing.T) {
	cmd := exec.Command("go", "list", "-deps", "./...")
	cmd.Dir = "../policy-engine"
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("go list -deps failed: %v\n%s", err, out)
	}
	deps := string(out)
	if strings.Contains(deps, "friday/capability-bus") {
		t.Fatalf("policy-engine's dependency closure includes friday/capability-bus — unexpected coupling.\nfull dependency list:\n%s", deps)
	}
}
