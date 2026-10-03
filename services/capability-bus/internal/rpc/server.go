package rpc

import (
	"encoding/json"
	"log"
	"net"
	"os"
	"time"

	"friday/capability-bus/internal/bus"
	"friday/capability-bus/internal/capabilities/createnote"
	"friday/capability-bus/internal/capabilities/getstatus"
	"friday/capability-bus/internal/envelope"
	"friday/capability-bus/internal/store"
	"friday/policytoken"
	"friday/rpcframe"
)

// Server hosts the Capability Bus's Unix-socket RPC surface. It holds a
// *bus.Bus (M3, unchanged) plus the in-memory stores DevSeed* methods
// populate. It never holds anything derived from the Policy Engine's
// private key — only a policytoken.Verifier (public-key-only, read from
// -policy-pubkey at startup, see cmd/capabilitybusd/main.go).
type Server struct {
	b         *bus.Bus
	irStore   *store.IRStore
	taskStore *store.TaskStore
	listener  net.Listener
	ready     bool
}

func Listen(socketPath string, b *bus.Bus, irStore *store.IRStore, taskStore *store.TaskStore) (*Server, error) {
	_ = os.Remove(socketPath)
	l, err := net.Listen("unix", socketPath)
	if err != nil {
		return nil, err
	}
	if err := os.Chmod(socketPath, 0o700); err != nil {
		l.Close()
		return nil, err
	}
	return &Server{b: b, irStore: irStore, taskStore: taskStore, listener: l, ready: true}, nil
}

func (s *Server) Close() error { return s.listener.Close() }

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
	conn.SetDeadline(time.Now().Add(30 * time.Second)) // create_note's declared timeout (5s) plus generous margin

	var req Envelope
	if err := rpcframe.ReadFrame(conn, &req); err != nil {
		log.Printf("capability-bus rpc: malformed request frame: %v", err)
		return
	}

	switch req.Method {
	case "Dispatch":
		s.handleDispatch(conn, req)
	case "DevSeedIR":
		s.handleDevSeedIR(conn, req)
	case "DevSeedTask":
		s.handleDevSeedTask(conn, req)
	case "Health":
		writeResult(conn, req.Method, map[string]bool{"alive": true, "ready": s.ready})
	default:
		writeError(conn, req.Method, ErrExecutionEnvelopeInvalid, "unknown method")
	}
}

func (s *Server) handleDispatch(conn net.Conn, req Envelope) {
	var in DispatchRequest
	if err := unmarshalPayload(req.Payload, &in); err != nil {
		writeError(conn, req.Method, ErrExecutionEnvelopeInvalid, "malformed DispatchRequest payload")
		return
	}

	env := envelopeFromWire(in.Envelope)
	out := s.b.Dispatch(env)

	if !out.Dispatched && out.Err == nil {
		// Defensive: should be unreachable, but never silently succeed.
		writeError(conn, req.Method, ErrExecutionEnvelopeInvalid, "dispatch produced no result")
		return
	}

	resp := DispatchResponse{Outcome: outcomeToWire(out)}
	if out.Err != nil {
		writeErrorFromDispatch(conn, req.Method, out.Err)
		return
	}
	writeResult(conn, req.Method, resp)
}

func (s *Server) handleDevSeedIR(conn net.Conn, req Envelope) {
	var in DevSeedIRRequest
	if err := unmarshalPayload(req.Payload, &in); err != nil {
		writeError(conn, req.Method, ErrExecutionEnvelopeInvalid, "malformed DevSeedIRRequest payload")
		return
	}
	s.irStore.Put(in.IRID, store.IRRecord{CapabilityID: in.CapabilityID, Arguments: in.Arguments})
	writeResult(conn, req.Method, DevSeedResponse{OK: true})
}

func (s *Server) handleDevSeedTask(conn net.Conn, req Envelope) {
	var in DevSeedTaskRequest
	if err := unmarshalPayload(req.Payload, &in); err != nil {
		writeError(conn, req.Method, ErrExecutionEnvelopeInvalid, "malformed DevSeedTaskRequest payload")
		return
	}
	s.taskStore.Set(in.TaskID, store.TaskState(in.State))
	writeResult(conn, req.Method, DevSeedResponse{OK: true})
}

func envelopeFromWire(w EnvelopeWire) envelope.Envelope {
	var tok *policytoken.PolicyToken
	if w.PolicyToken != nil {
		tok = &policytoken.PolicyToken{
			TokenID: w.PolicyToken.TokenID, IRID: w.PolicyToken.IRID, CapabilityID: w.PolicyToken.CapabilityID,
			Actor: w.PolicyToken.Actor, RiskLevel: policytoken.RiskLevel(w.PolicyToken.RiskLevel),
			Purpose: w.PolicyToken.Purpose, ArgumentsDigest: w.PolicyToken.ArgumentsDigest,
			IssuedAt: w.PolicyToken.IssuedAt, ExpiresAt: w.PolicyToken.ExpiresAt, Signature: w.PolicyToken.Signature,
		}
	}
	return envelope.Envelope{
		ExecutionID: w.ExecutionID, RequestID: w.RequestID, CorrelationID: w.CorrelationID,
		Actor: w.Actor, GoalID: w.GoalID, TaskID: w.TaskID, IRVersion: w.IRVersion, IRID: w.IRID,
		Capability: w.Capability, ValidatedArguments: w.ValidatedArguments, PolicyToken: tok,
		Purpose: w.Purpose, IdempotencyKey: w.IdempotencyKey, SafeToRetry: w.SafeToRetry,
		ExpectedOutcomeDescription: w.ExpectedOutcomeDescription, ExpectedSuccessCondition: w.ExpectedSuccessCondition,
		VerificationMethod: w.VerificationMethod, Cancellable: w.Cancellable, CancellationEffect: w.CancellationEffect,
	}
}

func outcomeToWire(out bus.Outcome) OutcomeWire {
	w := OutcomeWire{Dispatched: out.Dispatched, Executed: out.Executed, Verified: out.Verified, Success: out.Success}
	if out.GetStatusResult != nil {
		b, _ := json.Marshal(marshalableSnapshot(*out.GetStatusResult))
		w.GetStatusResult = b
	}
	if out.CreateNoteResult != nil {
		b, _ := json.Marshal(*out.CreateNoteResult)
		w.CreateNoteResult = b
	}
	return w
}

// marshalableSnapshot exists only because getstatus.Snapshot's fields are
// already exported/JSON-friendly — kept as a named pass-through for
// clarity at the call site, not because any transformation happens.
func marshalableSnapshot(s getstatus.Snapshot) getstatus.Snapshot { return s }

// writeErrorFromDispatch maps M3's envelope.DispatchError categories onto
// this package's ErrorCode 1:1 — no new taxonomy invented, per the M4
// brief's "use current documented names where already defined."
func writeErrorFromDispatch(conn net.Conn, method string, derr *envelope.DispatchError) {
	code := ErrExecutionEnvelopeInvalid
	switch derr.Category {
	case envelope.CategoryUnknownCapability:
		code = ErrCapabilityUnknown
	case envelope.CategoryAuthorizationMissing:
		code = ErrAuthorizationMissing
	case envelope.CategoryAuthorizationInvalid:
		code = ErrAuthorizationInvalid
	case envelope.CategoryAuthorizationExpired:
		code = ErrAuthorizationExpired
	case envelope.CategoryAuthorizationScopeMismatch:
		code = ErrAuthorizationScopeMismatch
	case envelope.CategoryArgumentDigestMismatch:
		code = ErrArgumentDigestMismatch
	case envelope.CategoryPurposeMismatch:
		code = ErrPurposeMismatch
	case envelope.CategoryCapabilityInputInvalid:
		code = ErrCapabilityInputInvalid
	case envelope.CategoryCapabilityExecutionFailed:
		code = ErrCapabilityExecutionFailed
	case envelope.CategoryCapabilityVerificationFailed:
		code = ErrVerificationFailed
	case envelope.CategoryCancelled:
		code = ErrCancelled
	}
	writeError(conn, method, code, "dispatch failed: "+string(derr.Category))
}

// unused-import guards for createnote (kept imported for the doc
// reference in Server's comment; Go requires an actual use, so this
// no-op keeps the import list honest about what this package touches).
var _ = createnote.KnownLimitation
