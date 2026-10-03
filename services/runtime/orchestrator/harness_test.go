// M7 brief §35-41: real end-to-end tests. This harness launches the real,
// independently-compiled policyengined and capabilitybusd binaries as
// real subprocesses (the same technique services/integration established
// for M4) and drives the real orchestrator.Orchestrator directly (this
// test file is IN package orchestrator, so it calls HandleTextRequest/
// Cancel exactly as cmd/friday's CLI does — no shortcut, no mock).
package orchestrator

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"friday/ir"
	"friday/runtime-store/store"
	"friday/runtime/reqcontext"
	"friday/runtime/wireclient"
)

// contextObjFromRaw builds a reqcontext.Object directly from a RawIR for
// tests that construct scenarios (tamper, expiry, stale-cancellation)
// where reqcontext.Compile's ir.ValidatedIR precondition doesn't apply —
// these tests are deliberately exercising the wire boundary below the
// Context Compiler, not the compiler itself (which has its own dedicated
// tests). Mirrors Compile's field-for-field mapping exactly.
func contextObjFromRaw(raw ir.RawIR, taskID, requestID, argsDigest string) reqcontext.Object {
	args := make(map[string]interface{}, len(raw.Content.Parameters))
	for k, v := range raw.Content.Parameters {
		args[k] = v
	}
	return reqcontext.Object{
		TaskID: taskID, RequestID: requestID, CorrelationID: raw.CorrelationID, IRID: raw.IRID,
		Actor: raw.Source.Actor, SessionID: raw.Source.SessionID,
		CapabilityID: raw.Goal.Type, Risk: raw.Risk.Level,
		Arguments: args, ArgumentsDigest: argsDigest,
		VerificationMethod:         raw.Verification.Method,
		ExpectedOutcomeDescription: raw.ExpectedOutcome.Description,
		ExpectedSuccessCondition:   raw.ExpectedOutcome.SuccessCondition,
		Cancellable:                raw.Cancellation.Cancellable,
		CancellationEffect:         string(raw.Cancellation.CancellationEffect),
		IdempotencyKey:             raw.Idempotency.IdempotencyKey,
		SafeToRetry:                raw.Idempotency.SafeToRetry,
	}
}

var (
	policyenginedBin  string
	capabilitybusdBin string
)

func TestMain(m *testing.M) {
	binDir, err := os.MkdirTemp("/tmp", "fm7-bin-")
	if err != nil {
		fmt.Println("mkdir temp bin dir:", err)
		os.Exit(1)
	}
	defer os.RemoveAll(binDir)

	policyenginedBin = filepath.Join(binDir, "policyengined")
	capabilitybusdBin = filepath.Join(binDir, "capabilitybusd")

	if err := buildBinary("../../policy-engine", "./cmd/policyengined", policyenginedBin); err != nil {
		fmt.Println(err)
		os.Exit(1)
	}
	if err := buildBinary("../../capability-bus", "./cmd/capabilitybusd", capabilitybusdBin); err != nil {
		fmt.Println(err)
		os.Exit(1)
	}

	os.Exit(m.Run())
}

func buildBinary(moduleDir, pkg, outPath string) error {
	cmd := exec.Command("go", "build", "-o", outPath, pkg)
	cmd.Dir = moduleDir
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("go build %s (dir=%s): %w\n%s", pkg, moduleDir, err, out)
	}
	return nil
}

type daemon struct {
	cmd            *exec.Cmd
	stdout, stderr *bytes.Buffer
	once           sync.Once
}

func (d *daemon) Stop() {
	d.once.Do(func() {
		if d.cmd.Process == nil {
			return
		}
		_ = d.cmd.Process.Signal(os.Interrupt)
		done := make(chan error, 1)
		go func() { done <- d.cmd.Wait() }()
		select {
		case <-done:
		case <-time.After(3 * time.Second):
			_ = d.cmd.Process.Kill()
			<-done
		}
	})
}

func (d *daemon) Kill() {
	d.once.Do(func() {
		if d.cmd.Process != nil {
			_ = d.cmd.Process.Kill()
			_ = d.cmd.Wait()
		}
	})
}

func newTestDir(t testing.TB) string {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "fm7-")
	if err != nil {
		t.Fatalf("mkdir temp: %v", err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	return dir
}

func waitForFile(path string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(path); err == nil {
			return nil
		}
		time.Sleep(20 * time.Millisecond)
	}
	return fmt.Errorf("%s did not appear within %s", path, timeout)
}

func startPolicyEngine(t testing.TB, dir string) (d *daemon, socketPath, pubkeyPath string) {
	t.Helper()
	socketPath = filepath.Join(dir, "p.sock")
	pubkeyPath = filepath.Join(dir, "p.pub")
	cmd := exec.Command(policyenginedBin, "-socket", socketPath, "-pubkey-out", pubkeyPath)
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Start(); err != nil {
		t.Fatalf("starting policyengined: %v", err)
	}
	d = &daemon{cmd: cmd, stdout: &stdout, stderr: &stderr}
	t.Cleanup(d.Stop)

	if err := waitForFile(pubkeyPath, 3*time.Second); err != nil {
		t.Fatalf("policyengined did not publish its public key: %v\nstderr:\n%s", err, stderr.String())
	}
	if err := waitForFile(socketPath, 3*time.Second); err != nil {
		t.Fatalf("policyengined did not open its socket: %v\nstderr:\n%s", err, stderr.String())
	}
	return d, socketPath, pubkeyPath
}

func startCapabilityBus(t testing.TB, dir, pubkeyPath string) (d *daemon, socketPath, workspaceRoot string) {
	t.Helper()
	socketPath = filepath.Join(dir, "b.sock")
	workspaceRoot = filepath.Join(dir, "ws")
	if err := os.MkdirAll(workspaceRoot, 0o700); err != nil {
		t.Fatalf("mkdir workspace root: %v", err)
	}
	cmd := exec.Command(capabilitybusdBin, "-socket", socketPath, "-policy-pubkey", pubkeyPath, "-workspace-root", workspaceRoot)
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Start(); err != nil {
		t.Fatalf("starting capabilitybusd: %v", err)
	}
	d = &daemon{cmd: cmd, stdout: &stdout, stderr: &stderr}
	t.Cleanup(d.Stop)

	if err := waitForFile(socketPath, 3*time.Second); err != nil {
		t.Fatalf("capabilitybusd did not open its socket: %v\nstderr:\n%s", err, stderr.String())
	}
	return d, socketPath, workspaceRoot
}

// testHarness bundles a fresh durable store + real Policy Engine/
// Capability Bus subprocesses + a real Orchestrator wired to all three —
// exactly cmd/friday's composition, built fresh per test.
type testHarness struct {
	Orch          *Orchestrator
	Store         *store.Store
	StorePath     string
	WorkspaceRoot string
	PolicyEngine  *daemon
	CapabilityBus *daemon
}

func newHarness(t testing.TB) *testHarness {
	t.Helper()
	dir := newTestDir(t)
	pe, policySocket, pubkeyPath := startPolicyEngine(t, dir)
	cb, busSocket, workspaceRoot := startCapabilityBus(t, dir, pubkeyPath)

	storePath := filepath.Join(dir, "runtime.db")
	st, err := store.Open(storePath)
	if err != nil {
		t.Fatalf("store.Open: %v", err)
	}
	t.Cleanup(func() { st.Close() })

	orch := New(Config{
		Store:        st,
		PolicyClient: wireclient.NewPolicyClient(policySocket, 5*time.Second),
		BusClient:    wireclient.NewBusClient(busSocket, 5*time.Second),
	})

	return &testHarness{Orch: orch, Store: st, StorePath: storePath, WorkspaceRoot: workspaceRoot, PolicyEngine: pe, CapabilityBus: cb}
}
