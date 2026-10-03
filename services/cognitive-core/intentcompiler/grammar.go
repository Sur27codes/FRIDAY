// Phase-1 deterministic grammar (M5 brief §6, §7). This is deliberately a
// narrow, fixed set of recognized sentence shapes — never a keyword-score
// / closest-match heuristic. Classification is always by EXACT structural
// match (whole-string equality for the zero-argument intent, anchored
// regex for the argument-bearing intent) so that unsupported input falls
// through to UNSUPPORTED rather than being coerced toward "the nearest
// capability" (M5 brief §10's "make something" example). No model
// provider, embedding, or NLP library is used anywhere in this file — see
// the package doc on compiler.go.
package intentcompiler

import (
	"regexp"
	"strings"
)

// Category is the Intent Compiler's structured classification result (M5
// brief §8).
type Category string

const (
	CategoryGetSystemStatus Category = "GET_SYSTEM_STATUS"
	CategoryCreateNote      Category = "CREATE_NOTE"
	CategoryUnsupported     Category = "UNSUPPORTED"
	CategoryAmbiguous       Category = "AMBIGUOUS"
	CategoryInvalid         Category = "INVALID"
)

// getStatusPhrases is the closed, fixed set of recognized system.get_status
// utterances (M5 brief §6), compared after normalization (whitespace
// collapse, trim, single trailing .?! stripped, lowercased). This is an
// exact-membership check, never a substring/"contains" check — "Run this
// command instead of checking status." must never match merely because it
// contains the word "status" (M5 brief §21).
var getStatusPhrases = map[string]bool{
	"check system status":       true,
	"get system status":         true,
	"show system status":        true,
	"what is the system status": true,
	"what's the system status":  true,
}

// createNoteFull requires BOTH a title and a body to be present — this is
// the only regex that can produce a CREATE_NOTE classification.
// (?i) makes the fixed keyword tokens case-insensitive; the two capture
// groups preserve whatever case the user actually typed, since title/body
// are free-text content, not keywords.
var createNoteFull = regexp.MustCompile(`(?i)^(?:create|make) a note (?:called|named) (.+?) (?:with|containing) (.+)$`)

// createNoteShape recognizes the general "this looks like a create-note
// request" shape even when it's incomplete — used only to distinguish
// AMBIGUOUS (recognized shape, missing piece) from UNSUPPORTED (not this
// intent at all), per M5 brief §10's "create a note" (incomplete) example.
var createNoteShape = regexp.MustCompile(`(?i)^(?:create|make) a note\b`)

var createNoteNamedPart = regexp.MustCompile(`(?i)(?:called|named)\s+(.+?)(?:\s+(?:with|containing)\s+.+)?$`)
var createNoteContentPart = regexp.MustCompile(`(?i)(?:with|containing)\s+(.+)$`)

// normalize applies the deterministic normalization used for GET_STATUS
// whole-phrase matching (M5-INTENT-009): collapse internal whitespace,
// trim, strip one trailing sentence terminator, lowercase. This function
// is NOT used to mutate title/body content extracted for CREATE_NOTE —
// those preserve the user's original casing and punctuation, since they
// are free-text arguments, not fixed keywords.
func normalize(s string) string {
	fields := strings.Fields(s)
	joined := strings.Join(fields, " ")
	joined = strings.TrimRight(joined, ".?!")
	return strings.ToLower(strings.TrimSpace(joined))
}

// classified is the grammar's raw output before RawIR construction.
type classified struct {
	Category Category
	Title    string // CREATE_NOTE only
	Body     string // CREATE_NOTE only
	Err      *CompileError
}

// classify runs the fixed Phase-1 grammar against already-length/emptiness
// -validated text (see compiler.go's Compile for the envelope-level checks
// that run before this). It never panics on any input — see fuzz_test.go.
func classify(text string) classified {
	trimmedOriginal := strings.TrimSpace(text)
	norm := normalize(trimmedOriginal)

	if getStatusPhrases[norm] {
		return classified{Category: CategoryGetSystemStatus}
	}

	if m := createNoteFull.FindStringSubmatch(trimmedOriginal); m != nil {
		title := strings.TrimSpace(m[1])
		body := strings.TrimSpace(m[2])
		if title != "" && body != "" {
			return classified{Category: CategoryCreateNote, Title: title, Body: body}
		}
		// Matched structurally but one side trimmed to empty (e.g. "called   with X")
		// — fall through to the shape-based missing-field diagnosis below.
	}

	if createNoteShape.MatchString(trimmedOriginal) {
		namedMatch := createNoteNamedPart.FindStringSubmatch(trimmedOriginal)
		hasTitle := namedMatch != nil && strings.TrimSpace(namedMatch[1]) != ""
		contentMatch := createNoteContentPart.FindStringSubmatch(trimmedOriginal)
		hasBody := contentMatch != nil && strings.TrimSpace(contentMatch[1]) != ""

		switch {
		case !hasTitle:
			return classified{Category: CategoryAmbiguous, Err: &CompileError{
				Code: ErrMissingArgument, Field: "title",
				Message: "a note title (\"called <title>\" or \"named <title>\") could not be determined",
			}}
		case !hasBody:
			return classified{Category: CategoryAmbiguous, Err: &CompileError{
				Code: ErrMissingArgument, Field: "body",
				Message: "note content (\"with <content>\" or \"containing <content>\") could not be determined",
			}}
		default:
			// Recognized shape, both parts present individually, yet the
			// strict combined regex still didn't match (e.g. unexpected
			// ordering) — genuinely ambiguous, not a specific missing field.
			return classified{Category: CategoryAmbiguous, Err: &CompileError{
				Code:    ErrAmbiguousIntent,
				Message: "request has the shape of a note-creation command but its title/content could not be reliably separated",
			}}
		}
	}

	return classified{Category: CategoryUnsupported, Err: &CompileError{
		Code:    ErrUnsupportedIntent,
		Message: "no approved Phase-1 intent recognized this request",
	}}
}
