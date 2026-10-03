package rpc

import (
	"log"
	"net"
	"os"
	"time"

	"friday/policy-engine/internal/policy"
	"friday/policytoken"
	"friday/rpcframe"
)

// Server hosts the Policy Engine's Unix-socket RPC surface. It holds a
// *policy.Engine (which in turn holds the private Signer, ADR-021) — this
// is the ONE process in the whole system where that's true.
type Server struct {
	engine   *policy.Engine
	listener net.Listener
	ready    bool
}

// Listen creates the Unix domain socket at socketPath, restricting its
// filesystem permissions to owner-only (M4 brief §17: "enforce
// appropriate filesystem permissions"). If a stale socket file already
// exists at socketPath (e.g., from an unclean prior shutdown), it is
// removed first — this is a local, single-owner Phase-1 deployment
// (H.2), not a multi-tenant service, so this is safe.
func Listen(socketPath string, engine *policy.Engine) (*Server, error) {
	_ = os.Remove(socketPath) // best-effort; Listen below will fail loudly if this matters
	l, err := net.Listen("unix", socketPath)
	if err != nil {
		return nil, err
	}
	if err := os.Chmod(socketPath, 0o700); err != nil {
		l.Close()
		return nil, err
	}
	return &Server{engine: engine, listener: l, ready: true}, nil
}

func (s *Server) Addr() string { return s.listener.Addr().String() }

// Serve accepts connections until the listener is closed. Each
// connection handles exactly one request-response exchange, matching
// rpcframe's documented one-message-per-frame, no-multiplexing model.
func (s *Server) Serve() error {
	for {
		conn, err := s.listener.Accept()
		if err != nil {
			return err // listener closed, or a real accept error — caller decides
		}
		go s.handleConn(conn)
	}
}

func (s *Server) Close() error { return s.listener.Close() }

func (s *Server) handleConn(conn net.Conn) {
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(10 * time.Second)) // bound a stuck/hostile peer

	var req Envelope
	if err := rpcframe.ReadFrame(conn, &req); err != nil {
		// Malformed request frame — nothing to respond to meaningfully;
		// close the connection. This is the server-side half of
		// M4-POL-015 ("malformed RPC payload cannot cause dispatch") —
		// here it means "cannot cause an EvaluateResponse to be
		// produced at all."
		log.Printf("policy-engine rpc: malformed request frame: %v", err)
		return
	}

	switch req.Method {
	case "EvaluateAuthorization":
		s.handleEvaluate(conn, req)
	case "Health":
		s.handleHealth(conn, req)
	default:
		writeError(conn, req.Method, ErrExecutionEnvelopeInvalid, "unknown method")
	}
}

func (s *Server) handleEvaluate(conn net.Conn, req Envelope) {
	var in EvaluateRequest
	if err := unmarshalPayload(req.Payload, &in); err != nil {
		writeError(conn, req.Method, ErrExecutionEnvelopeInvalid, "malformed EvaluateRequest payload")
		return
	}

	// The server's OWN clock is authoritative for freshness/expiry
	// evaluation — a client-supplied timestamp is never trusted for this
	// (there is no such field on EvaluateRequest at all; see protocol.go).
	now := time.Now()

	factors := make([]policy.PresentedFactor, 0, len(in.AssuranceFactors))
	for _, f := range in.AssuranceFactors {
		factors = append(factors, policy.PresentedFactor{
			Factor:        policy.AssuranceFactor(f.Factor),
			EstablishedAt: f.EstablishedAt,
			Available:     f.Available,
		})
	}

	out := s.engine.Evaluate(policy.PolicyInput{
		Actor:                   in.Actor,
		Capability:              in.Capability,
		IRID:                    in.IRID,
		Risk:                    policy.RiskLevel(in.Risk),
		AssuranceFactors:        factors,
		AutonomyLevelConfigured: in.AutonomyLevelConfigured,
		SimulatorVerified:       in.SimulatorVerified,
		EvaluatedAt:             now,
		ArgumentsDigest:         in.ArgumentsDigest,
		Purpose:                 in.Purpose,
		TaskCancelled:           in.TaskCancelled,
	})

	resp := EvaluateResponse{
		RequestID:     in.RequestID,
		CorrelationID: in.CorrelationID,
		Decision:      string(out.Decision),
		RequiredAAL:   out.RequiredAAL.String(),
		Reason:        out.Reason,
	}
	if out.Decision == policy.Allow && out.Token != nil {
		resp.Token = tokenToWire(out.Token)
	}

	writeResult(conn, req.Method, resp)
}

func (s *Server) handleHealth(conn net.Conn, req Envelope) {
	// Deliberately minimal (M4 brief §18): distinguishes "alive" (this
	// handler ran at all) from "ready" (engine constructed, listener
	// bound) without leaking keys, configuration, or any policy-relevant
	// state.
	writeResult(conn, req.Method, map[string]bool{"alive": true, "ready": s.ready})
}

func tokenToWire(t *policytoken.PolicyToken) *TokenWire {
	return &TokenWire{
		TokenID: t.TokenID, IRID: t.IRID, CapabilityID: t.CapabilityID, Actor: t.Actor,
		RiskLevel: string(t.RiskLevel), Purpose: t.Purpose, ArgumentsDigest: t.ArgumentsDigest,
		IssuedAt: t.IssuedAt, ExpiresAt: t.ExpiresAt, Signature: t.Signature,
	}
}
