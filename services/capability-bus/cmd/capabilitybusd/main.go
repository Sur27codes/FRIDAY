// Command capabilitybusd is the Phase-1 Capability Bus as a real,
// standalone OS process. It never possesses the Policy Engine's private
// signing key — only a policytoken.Verifier constructed from the public
// key read from -policy-pubkey (written by policyengined at its own
// startup, ST §S.2.1's key-distribution note). There is no environment
// variable, flag, or code path in this binary that accepts private-key
// material of any kind (grep-verifiable: "priv" / "PrivateKey" do not
// appear anywhere in this module outside its test files' ephemeral test
// keys — see the M4 status report).
package main

import (
	"encoding/base64"
	"flag"
	"log"
	"os"
	"os/signal"
	"syscall"

	"friday/capability-bus/internal/bus"
	"friday/capability-bus/internal/capabilities/createnote"
	"friday/capability-bus/internal/capabilities/getstatus"
	"friday/capability-bus/internal/envelope"
	"friday/capability-bus/internal/registry"
	"friday/capability-bus/internal/rpc"
	"friday/capability-bus/internal/store"
	"friday/policytoken"
)

func main() {
	socketPath := flag.String("socket", "", "path for this process's own Unix domain socket (required)")
	policyPubkeyPath := flag.String("policy-pubkey", "", "path to the Policy Engine's published public key file (required)")
	workspaceRoot := flag.String("workspace-root", "", "sandboxed root directory for workspace.create_note (required)")
	flag.Parse()

	if *socketPath == "" || *policyPubkeyPath == "" || *workspaceRoot == "" {
		log.Fatal("capabilitybusd: -socket, -policy-pubkey, and -workspace-root are all required")
	}

	pubB64, err := os.ReadFile(*policyPubkeyPath)
	if err != nil {
		log.Fatalf("capabilitybusd: reading policy engine public key: %v", err)
	}
	pubBytes, err := base64.StdEncoding.DecodeString(string(pubB64))
	if err != nil {
		log.Fatalf("capabilitybusd: decoding policy engine public key: %v", err)
	}
	verifier := policytoken.NewVerifier(pubBytes)

	sandbox, err := createnote.NewSandbox(*workspaceRoot)
	if err != nil {
		log.Fatalf("capabilitybusd: constructing workspace sandbox: %v", err)
	}

	irStore := store.NewIRStore()
	taskStore := store.NewTaskStore()

	ctx := envelope.ValidationContext{
		Registry:  registry.Phase1(),
		Verifier:  verifier,
		IRStore:   irStore,
		TaskStore: taskStore,
		// Now is intentionally left zero here: bus.Bus.Dispatch overrides
		// ValidationContext.Now with a fresh time.Now() on every single
		// call (see bus.go), so this long-lived daemon never evaluates
		// token expiry against a timestamp frozen at process startup.
	}
	b := bus.New(ctx, getstatus.StaticSource{}, sandbox)

	srv, err := rpc.Listen(*socketPath, b, irStore, taskStore)
	if err != nil {
		log.Fatalf("capabilitybusd: listen on %s: %v", *socketPath, err)
	}
	log.Printf("capabilitybusd: listening on %s, workspace root %s, policy public key from %s",
		*socketPath, *workspaceRoot, *policyPubkeyPath)

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-sigCh
		log.Print("capabilitybusd: shutting down")
		srv.Close()
	}()

	if err := srv.Serve(); err != nil {
		log.Printf("capabilitybusd: serve exited: %v", err)
	}
}
