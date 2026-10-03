// Package rpcframe is a minimal, dependency-free, length-prefixed JSON
// framing layer over any io.ReadWriter — used to carry RPC requests and
// responses over the Unix domain sockets M4 introduces between the
// Policy Engine and Capability Bus processes.
//
// This package is deliberately NOT security logic. It has no concept of
// authorization, capabilities, or tokens — it only moves bytes reliably
// and deterministically. Per the M4 brief §6's "do not duplicate
// cryptographic implementation unnecessarily," extracting only this
// transport plumbing into a shared module (rather than the actual
// verification/signing logic, which stays split between
// friday/policytoken and friday/policy-engine exactly as M3 established)
// avoids copy-pasting the same 20 lines of framing code into two
// otherwise-independent daemons without touching the security boundary
// at all.
//
// Wire format: a 4-byte big-endian uint32 length prefix, followed by
// exactly that many bytes of JSON. One message per prefix — no
// multiplexing, no streaming; Phase-1's RPC pattern is strictly
// request-then-response-then-close per call (ADR-021's "local gRPC (or
// Unix-domain-socket) contract" — M4 implements the Unix-domain-socket
// option; see docs/W-adr-backlog.md's M4 addendum for why).
package rpcframe

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
)

// MaxFrameSize bounds a single frame to prevent a malformed or hostile
// peer from claiming an enormous length prefix and exhausting memory —
// generous enough for any Phase-1 payload (IR documents, tokens,
// envelopes are all small), far too small for any plausible attack
// payload to matter.
const MaxFrameSize = 4 << 20 // 4 MiB

// WriteFrame JSON-encodes v and writes it as one length-prefixed frame.
func WriteFrame(w io.Writer, v interface{}) error {
	payload, err := json.Marshal(v)
	if err != nil {
		return fmt.Errorf("rpcframe: marshaling payload: %w", err)
	}
	if len(payload) > MaxFrameSize {
		return fmt.Errorf("rpcframe: payload of %d bytes exceeds MaxFrameSize %d", len(payload), MaxFrameSize)
	}
	var lenBuf [4]byte
	binary.BigEndian.PutUint32(lenBuf[:], uint32(len(payload)))
	if _, err := w.Write(lenBuf[:]); err != nil {
		return fmt.Errorf("rpcframe: writing length prefix: %w", err)
	}
	if _, err := w.Write(payload); err != nil {
		return fmt.Errorf("rpcframe: writing payload: %w", err)
	}
	return nil
}

// ReadFrame reads one length-prefixed frame and JSON-decodes it into v.
// A malformed frame (bad length, truncated payload, invalid JSON) always
// returns a non-nil error — there is no partial-success return value a
// careless caller could mistake for a valid decode (M4-POL-016's "malformed
// policy response cannot become authorization" is enforced by callers
// always checking this error before trusting v).
func ReadFrame(r io.Reader, v interface{}) error {
	var lenBuf [4]byte
	if _, err := io.ReadFull(r, lenBuf[:]); err != nil {
		return fmt.Errorf("rpcframe: reading length prefix: %w", err)
	}
	n := binary.BigEndian.Uint32(lenBuf[:])
	if n > MaxFrameSize {
		return fmt.Errorf("rpcframe: claimed frame size %d exceeds MaxFrameSize %d", n, MaxFrameSize)
	}
	payload := make([]byte, n)
	if _, err := io.ReadFull(r, payload); err != nil {
		return fmt.Errorf("rpcframe: reading payload (%d bytes): %w", n, err)
	}
	if err := json.Unmarshal(payload, v); err != nil {
		return fmt.Errorf("rpcframe: unmarshaling payload: %w", err)
	}
	return nil
}
