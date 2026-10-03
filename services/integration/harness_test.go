package integration

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

var (
	policyenginedBin  string
	capabilitybusdBin string
)

// TestMain builds both real daemon binaries exactly once, from their own
// modules (each `go build` runs with Dir set to that module's directory,
// since this module deliberately does not depend on either service
// module — see wire.go's package doc). Every test below launches fresh
// child processes of these same two binaries.
func TestMain(m *testing.M) {
	binDir, err := os.MkdirTemp("/tmp", "fm4-bin-")
	if err != nil {
		fmt.Println("mkdir temp bin dir:", err)
		os.Exit(1)
	}
	defer os.RemoveAll(binDir)

	policyenginedBin = filepath.Join(binDir, "policyengined")
	capabilitybusdBin = filepath.Join(binDir, "capabilitybusd")

	if err := buildBinary("../policy-engine", "./cmd/policyengined", policyenginedBin); err != nil {
		fmt.Println(err)
		os.Exit(1)
	}
	if err := buildBinary("../capability-bus", "./cmd/capabilitybusd", capabilitybusdBin); err != nil {
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

// daemon wraps a running child process with an idempotent Stop/Kill so a
// test can explicitly crash the process (Kill) mid-test and the later
// t.Cleanup-registered Stop becomes a safe no-op.
type daemon struct {
	name           string
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

// Kill terminates the process immediately (SIGKILL) — used by the
// fail-closed "Policy Engine crashes" tests, which must prove no
// permissive fallback exists when the peer disappears without warning,
// not merely when it shuts down cleanly.
func (d *daemon) Kill() {
	d.once.Do(func() {
		if d.cmd.Process != nil {
			_ = d.cmd.Process.Kill()
			_ = d.cmd.Wait()
		}
	})
}

func newTestDir(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "fm4-")
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

// startPolicyEngine launches a real policyengined subprocess. Each test
// gets its own socket and key-distribution file, so processes from
// different tests never interfere.
func startPolicyEngine(t *testing.T, dir string) (d *daemon, socketPath, pubkeyPath string) {
	t.Helper()
	socketPath = filepath.Join(dir, "p.sock")
	pubkeyPath = filepath.Join(dir, "p.pub")
	cmd := exec.Command(policyenginedBin, "-socket", socketPath, "-pubkey-out", pubkeyPath)
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Start(); err != nil {
		t.Fatalf("starting policyengined: %v", err)
	}
	d = &daemon{name: "policyengined", cmd: cmd, stdout: &stdout, stderr: &stderr}
	t.Cleanup(d.Stop)

	if err := waitForFile(pubkeyPath, 3*time.Second); err != nil {
		t.Fatalf("policyengined did not publish its public key: %v\nstderr:\n%s", err, stderr.String())
	}
	if err := waitForFile(socketPath, 3*time.Second); err != nil {
		t.Fatalf("policyengined did not open its socket: %v\nstderr:\n%s", err, stderr.String())
	}
	return d, socketPath, pubkeyPath
}

// startCapabilityBus launches a real capabilitybusd subprocess, wired to
// verify tokens using the public key published by a (real, separately
// running) Policy Engine process at pubkeyPath.
func startCapabilityBus(t *testing.T, dir, pubkeyPath string) (d *daemon, socketPath, workspaceRoot string) {
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
	d = &daemon{name: "capabilitybusd", cmd: cmd, stdout: &stdout, stderr: &stderr}
	t.Cleanup(d.Stop)

	if err := waitForFile(socketPath, 3*time.Second); err != nil {
		t.Fatalf("capabilitybusd did not open its socket: %v\nstderr:\n%s", err, stderr.String())
	}
	return d, socketPath, workspaceRoot
}
