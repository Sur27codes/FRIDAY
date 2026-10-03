// Command friday is the smallest local text interface for the Phase-1
// vertical slice (M7 brief §6). It hands user text directly into the M5
// pipeline via orchestrator.HandleTextRequest — it does not parse or
// interpret the text itself in any way.
package main

import (
	"bufio"
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"strings"
	"time"

	"friday/cognitive-core/textrequest"
	"friday/runtime-store/store"
	"friday/runtime/orchestrator"
	"friday/runtime/wireclient"
)

func main() {
	policySocket := flag.String("policy-socket", "", "path to the Policy Engine's Unix socket (required)")
	busSocket := flag.String("bus-socket", "", "path to the Capability Bus's Unix socket (required)")
	storePath := flag.String("store", "", "path to the runtime-store SQLite database (required)")
	actor := flag.String("actor", "user.owner", "actor identity for this session")
	workspaceRoot := flag.String("workspace-root", "", "informational only: the same workspace root capabilitybusd was started with, used only for the M8 World Model's approved-workspace entity — this process never touches the filesystem itself")
	flag.Parse()

	if *policySocket == "" || *busSocket == "" || *storePath == "" {
		log.Fatal("friday: -policy-socket, -bus-socket, and -store are all required")
	}

	st, err := store.Open(*storePath)
	if err != nil {
		log.Fatalf("friday: opening store: %v", err)
	}
	defer st.Close()

	// P2-M4R: same one-time, safe self-repair friday-daemon performs —
	// see store.RepairOrphanedIdempotencyRecords's doc comment.
	if repaired, err := st.RepairOrphanedIdempotencyRecords(context.Background()); err != nil {
		log.Printf("friday: idempotency repair check failed (continuing): %v", err)
	} else if repaired > 0 {
		log.Printf("friday: repaired %d orphaned idempotency record(s) from before a fixed bug", repaired)
	}

	orch := orchestrator.New(orchestrator.Config{
		Store:         st,
		PolicyClient:  wireclient.NewPolicyClient(*policySocket, 10*time.Second),
		BusClient:     wireclient.NewBusClient(*busSocket, 10*time.Second),
		WorkspaceRoot: *workspaceRoot,
	})

	fmt.Println("friday: Phase-1 vertical slice. Type a command, \"stop <task-id>\" to cancel, \"forget <task-id>\" to forget a note's content, or \"exit\" to quit.")
	scanner := bufio.NewScanner(os.Stdin)
	seq := 0
	for {
		fmt.Print("friday> ")
		if !scanner.Scan() {
			break
		}
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		if line == "exit" || line == "quit" {
			break
		}
		if strings.HasPrefix(line, "stop ") {
			taskID := strings.TrimSpace(strings.TrimPrefix(line, "stop "))
			resp := orch.Cancel(context.Background(), taskID)
			fmt.Println(resp.Text)
			continue
		}
		if strings.HasPrefix(line, "forget ") {
			taskID := strings.TrimSpace(strings.TrimPrefix(line, "forget "))
			resp := orch.Forget(context.Background(), taskID, *actor)
			fmt.Println(resp.Text)
			continue
		}

		seq++
		now := time.Now().UTC()
		taskID := fmt.Sprintf("cli-task-%d-%d", now.UnixNano(), seq)
		req := textrequest.TextRequest{
			RequestID: fmt.Sprintf("cli-req-%d-%d", now.UnixNano(), seq), CorrelationID: fmt.Sprintf("cli-corr-%d-%d", now.UnixNano(), seq),
			Actor: *actor, SessionID: "cli-session", RawText: line, ReceivedAt: now, Source: textrequest.SourceText,
		}
		resp := orch.HandleTextRequest(context.Background(), req, taskID)
		fmt.Printf("[%s] %s\n", resp.TaskID, resp.Text)
	}
}
