// Command friday-daemon is the P2-M2 network/IPC-facing entry point to
// the SAME Phase-1 orchestration path M7/M8 already proved end-to-end —
// it is a thin, long-running twin of cmd/friday's interactive CLI loop,
// serving the identical Orchestrator over a Unix-socket RPC surface
// (rpcapi) instead of an interactive stdin loop. It adds no business
// logic, no capability implementation, and no policy/authorization
// logic of its own (docs/PHASE-2-SCOPE-LOCK.md §5, docs/PHASE-2-
// ARCHITECTURE.md §5/§5a).
package main

import (
	"context"
	"flag"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"friday/runtime-store/store"
	"friday/runtime/orchestrator"
	"friday/runtime/rpcapi"
	"friday/runtime/wireclient"
)

func main() {
	socketPath := flag.String("socket", "", "path for this daemon's own Unix domain socket (required)")
	policySocket := flag.String("policy-socket", "", "path to the Policy Engine's Unix socket (required)")
	busSocket := flag.String("bus-socket", "", "path to the Capability Bus's Unix socket (required)")
	storePath := flag.String("store", "", "path to the runtime-store SQLite database (required)")
	workspaceRoot := flag.String("workspace-root", "", "informational only: the same workspace root capabilitybusd was started with")
	actor := flag.String("actor", "user.owner", "fixed daemon-configured actor identity — NEVER taken from the wire request")
	flag.Parse()

	if *socketPath == "" || *policySocket == "" || *busSocket == "" || *storePath == "" {
		log.Fatal("friday-daemon: -socket, -policy-socket, -bus-socket, and -store are all required")
	}

	st, err := store.Open(*storePath)
	if err != nil {
		log.Fatalf("friday-daemon: opening store: %v", err)
	}
	defer st.Close()

	// P2-M4R: one-time, safe self-repair of idempotency records orphaned
	// by a now-fixed orchestrator bug (see
	// store.RepairOrphanedIdempotencyRecords's own doc comment for the
	// full mechanism) — run once at startup, before serving any request,
	// so a database carried over from before the fix does not keep
	// misclassifying legitimate new requests as DUPLICATE_REQUEST forever.
	if repaired, err := st.RepairOrphanedIdempotencyRecords(context.Background()); err != nil {
		log.Printf("friday-daemon: idempotency repair check failed (continuing): %v", err)
	} else if repaired > 0 {
		log.Printf("friday-daemon: repaired %d orphaned idempotency record(s) from before a fixed bug", repaired)
	}

	policyClient := wireclient.NewPolicyClient(*policySocket, 10*time.Second)
	busClient := wireclient.NewBusClient(*busSocket, 10*time.Second)

	orch := orchestrator.New(orchestrator.Config{
		Store: st, PolicyClient: policyClient, BusClient: busClient, WorkspaceRoot: *workspaceRoot,
	})

	srv, err := rpcapi.Listen(*socketPath, orch, policyClient, busClient, *actor)
	if err != nil {
		log.Fatalf("friday-daemon: listen on %s: %v", *socketPath, err)
	}
	log.Printf("friday-daemon: listening on %s (policy=%s bus=%s store=%s)", *socketPath, *policySocket, *busSocket, *storePath)

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-sigCh
		log.Print("friday-daemon: shutting down")
		srv.Close()
	}()

	if err := srv.Serve(); err != nil {
		log.Printf("friday-daemon: serve exited: %v", err)
	}
}
