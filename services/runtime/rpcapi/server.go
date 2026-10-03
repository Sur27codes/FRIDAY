package rpcapi

import (
	"context"
	"encoding/json"
	"log"
	"net"
	"os"
	"time"

	"friday/cognitive-core/textrequest"
	"friday/rpcframe"
	"friday/runtime/orchestrator"
)

// healthChecker is satisfied by *wireclient.PolicyClient and
// *wireclient.BusClient — the daemon depends only on their existing
// Health method, never on anything resembling an authorization or
// dispatch call (P2-M2 instruction §5: friday-daemon must not duplicate
// policy/capability-selection/authorization logic).
type healthChecker interface {
	Health(ctx context.Context) (bool, error)
}

// Server hosts friday-daemon's local, versioned RPC surface. It holds
// only the existing, unmodified Orchestrator plus two Health-only client
// handles for readiness reporting — no capability implementation, no
// Policy Engine decision logic, no signing key, anywhere in this type
// (P2-M2 instruction §30/§31).
type Server struct {
	orch        *orchestrator.Orchestrator
	policyCheck healthChecker
	busCheck    healthChecker
	actor       string

	listener net.Listener
	sem      chan struct{} // bounds concurrent in-flight requests (§28)
}

// MaxConcurrentRequests bounds the daemon's own concurrency — Phase 2 is
// single-user, low-QPS (same load class as Phase 1); this exists so a
// buggy or hostile client opening many connections cannot spawn an
// unbounded number of goroutines, not because real load requires it.
const MaxConcurrentRequests = 16

// Listen creates the Unix domain socket at socketPath, restricted to
// owner-only permissions, removing any stale file left at that path
// first — same pattern as policy-engine/capability-bus's own Listen
// (P2-M2 instruction §14/§29: local-only, owner-only, safe stale-artifact
// handling; never unlink a path that isn't the one this daemon was
// configured to bind).
func Listen(socketPath string, orch *orchestrator.Orchestrator, policyCheck, busCheck healthChecker, actor string) (*Server, error) {
	_ = os.Remove(socketPath) // best-effort; Listen below fails loudly if this matters
	l, err := net.Listen("unix", socketPath)
	if err != nil {
		return nil, err
	}
	if err := os.Chmod(socketPath, 0o700); err != nil {
		l.Close()
		return nil, err
	}
	return &Server{
		orch: orch, policyCheck: policyCheck, busCheck: busCheck, actor: actor,
		listener: l, sem: make(chan struct{}, MaxConcurrentRequests),
	}, nil
}

func (s *Server) Addr() string { return s.listener.Addr().String() }
func (s *Server) Close() error { return s.listener.Close() }

// Serve accepts connections until the listener is closed (e.g. via
// Close(), called on SIGTERM by cmd/friday-daemon — see main.go). Each
// connection is one request/response exchange, matching rpcframe's
// documented model; an already-accepted, in-flight connection is allowed
// to finish naturally after Close() stops new ones — the graceful
// completion window §29 asks for, with no extra bookkeeping required.
func (s *Server) Serve() error {
	for {
		conn, err := s.listener.Accept()
		if err != nil {
			return err
		}
		go s.handleConn(conn)
	}
}

func (s *Server) handleConn(conn net.Conn) {
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(10 * time.Second)) // bound a stuck/hostile peer, same as policy-engine/capability-bus

	select {
	case s.sem <- struct{}{}:
		defer func() { <-s.sem }()
	default:
		writeError(conn, "", ErrRuntimeUnavailable, "too many concurrent requests")
		return
	}

	var req Envelope
	if err := rpcframe.ReadFrame(conn, &req); err != nil {
		// Malformed/truncated/oversized frame — rpcframe.ReadFrame
		// itself already bounds frame size (MaxFrameSize) and returns a
		// non-nil error for any truncated/invalid-JSON input; nothing to
		// respond to meaningfully, and never a crash (§15: malformed
		// clients must not panic the daemon).
		log.Printf("friday-daemon rpc: malformed request frame: %v", err)
		return
	}

	switch req.Method {
	case "Health":
		s.handleHealth(conn, req)
	case "SubmitTextRequest":
		s.handleSubmitTextRequest(conn, req)
	default:
		writeError(conn, req.Method, ErrUnknownMethod, "unknown method")
	}
}

func (s *Server) handleHealth(conn net.Conn, req Envelope) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	policyOK, _ := s.policyCheck.Health(ctx)
	busOK, _ := s.busCheck.Health(ctx)
	// Ready means the daemon can actually serve a normal request under
	// its real dependency contract — Policy Engine and Capability Bus
	// both reachable+ready — never merely "the socket is listening"
	// (§11). A failed dependency Health call is already fail-closed
	// (Health returns false, not an error masked as healthy).
	writeResult(conn, req.Method, HealthResponseWire{Alive: true, Ready: policyOK && busOK})
}

// decodeAndValidateSubmitTextRequest is the entire trust boundary for
// wire input, deliberately factored out of handleSubmitTextRequest so it
// can be fuzzed directly (fuzz_test.go) without needing a real
// Orchestrator behind it — nothing past this function's return ever
// executes for a payload this function rejects, and this function alone
// decides what's accepted. Strict decoding (§16) means an authority-
// shaped extra field is a hard, structural rejection, not a value that
// was decoded and then ignored.
func decodeAndValidateSubmitTextRequest(payload json.RawMessage) (SubmitTextRequestWire, *RPCError) {
	var in SubmitTextRequestWire
	dec := json.NewDecoder(bytesReader(payload))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&in); err != nil {
		return SubmitTextRequestWire{}, &RPCError{Code: ErrInvalidRequest, Message: "malformed or unrecognized SubmitTextRequest payload"}
	}
	if in.ProtocolVersion != CurrentProtocolVersion {
		return SubmitTextRequestWire{}, &RPCError{Code: ErrUnsupportedProtocolVersion, Message: "unsupported protocol_version"}
	}
	if in.RequestID == "" || in.Text == "" {
		return SubmitTextRequestWire{}, &RPCError{Code: ErrInvalidRequest, Message: "request_id and text are required"}
	}
	if len(in.Text) > MaxTextRequestBytes {
		return SubmitTextRequestWire{}, &RPCError{Code: ErrRequestTooLarge, Message: "text exceeds maximum size"}
	}
	return in, nil
}

func (s *Server) handleSubmitTextRequest(conn net.Conn, req Envelope) {
	in, rpcErr := decodeAndValidateSubmitTextRequest(req.Payload)
	if rpcErr != nil {
		writeError(conn, req.Method, rpcErr.Code, rpcErr.Message)
		return
	}

	// Construct exactly the same TextRequest the CLI (cmd/friday) already
	// builds, and call the SAME, unmodified Orchestrator method — no
	// second pipeline, no reimplemented intent/context/policy/verification
	// logic anywhere in this file (P2-M2 instruction §5). `Actor` is a
	// fixed, daemon-configured identity (main.go's -actor flag), never
	// taken from the wire request — the client cannot self-declare who
	// it is acting as, closing off a class of identity-spoofing this
	// milestone's own instructions warn against for authority fields
	// generally.
	now := time.Now().UTC()
	taskID := "companion-task-" + in.RequestID
	tr := textrequest.TextRequest{
		RequestID: in.RequestID, CorrelationID: in.CorrelationID,
		Actor: s.actor, SessionID: "companion-session", RawText: in.Text,
		ReceivedAt: now, Source: textrequest.SourceText,
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	resp := s.orch.HandleTextRequest(ctx, tr, taskID)

	// The response is exactly what the existing Response Validation Gate
	// already produced — never independently upgraded to SUCCESS here
	// (§10). Outcome/TaskID/Text are a direct, unmodified pass-through.
	writeResult(conn, req.Method, SubmitTextRequestResponseWire{
		ProtocolVersion: CurrentProtocolVersion,
		RequestID:       in.RequestID, CorrelationID: in.CorrelationID,
		TaskID: resp.TaskID, Outcome: string(resp.Outcome), Text: resp.Text,
	})
}
