// Package textrequest defines the smallest Phase-1 request envelope for
// user text input (M5 brief §5). RawText is always treated as untrusted
// user input by every downstream package in this module — nothing in
// this type, or anywhere else in cognitive-core, ever executes RawText as
// a shell command, template, SQL, or dynamic code (M5 brief §22).
package textrequest

import "time"

// Source names where a request originated. Phase 1 has exactly one.
type Source string

const SourceText Source = "text"

// TextRequest is the smallest Phase-1 request object (M5 brief §5).
// Deliberately excluded, per the brief: authentication secrets and full
// runtime policy state — those belong to the Policy Engine boundary
// (M4), not to a text-interpretation request.
type TextRequest struct {
	RequestID     string
	CorrelationID string
	Actor         string
	SessionID     string
	RawText       string
	ReceivedAt    time.Time
	Source        Source
}

// MaxRawTextBytes bounds oversized input (M5-INTENT-008). No authoritative
// Phase-1 document specifies an exact text-request size limit; this value
// is a disclosed, conservative Phase-1 choice — generously above the
// largest single argument Phase-1 accepts (workspace.create_note's body,
// 10,000 chars, ir.Phase1Registry) plus room for surrounding sentence
// structure — not a benchmarked figure. TBD — revisit if a future phase's
// SRS states an authoritative bound.
const MaxRawTextBytes = 20000
