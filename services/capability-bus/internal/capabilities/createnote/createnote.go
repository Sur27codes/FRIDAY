// Package createnote implements the workspace.create_note capability
// (PHASE-1-EXECUTION-SPEC.md §9, Capability 2). This is the most
// security-sensitive M3 implementation — it is a SANDBOXED NOTE CREATION
// capability, not filesystem.write, not shell.exec, not
// workspace.modify_anything. See PHASE-1-SCOPE-LOCK.md's non-goals.
//
// The primary defense is architectural, not input-sanitization: the
// on-disk filename is ALWAYS derived from a capability-generated note ID,
// never from user-supplied title/body content — there is no code path in
// this package that constructs a filesystem path from caller-supplied
// string content. ResolveNotePath below is exported specifically so this
// property, and the containment check backing it, can be tested directly
// against adversarial note IDs even though production callers (Execute)
// never pass anything but a freshly generated one.
package createnote

import (
	"crypto/rand"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Sandbox holds one resolved, canonical workspace root and the M3-local
// idempotency ledger. Construct with NewSandbox.
type Sandbox struct {
	// canonicalRoot is the workspace root after EvalSymlinks, resolved
	// once at construction — this is what every write is checked against.
	canonicalRoot string

	mu        sync.Mutex
	byIdemKey map[string]idemRecord // idempotency_key -> prior result
}

type idemRecord struct {
	argsDigest string
	noteID     string
	path       string
	createdAt  time.Time
}

// NewSandbox resolves root to its canonical (symlink-free) absolute form
// once, at construction time, and rejects construction outright if root
// does not exist or is not a directory. This is the one point where a
// symlinked *root* is accepted (it is resolved, not rejected) — every
// write thereafter is checked against the resolved canonical form, not
// the original possibly-symlinked path string.
func NewSandbox(root string) (*Sandbox, error) {
	abs, err := filepath.Abs(root)
	if err != nil {
		return nil, fmt.Errorf("resolving workspace root to absolute path: %w", err)
	}
	canon, err := filepath.EvalSymlinks(abs)
	if err != nil {
		return nil, fmt.Errorf("resolving workspace root symlinks: %w", err)
	}
	info, err := os.Stat(canon)
	if err != nil {
		return nil, fmt.Errorf("statting workspace root: %w", err)
	}
	if !info.IsDir() {
		return nil, fmt.Errorf("workspace root %q is not a directory", canon)
	}
	return &Sandbox{canonicalRoot: canon, byIdemKey: make(map[string]idemRecord)}, nil
}

var (
	ErrEmptyNoteID       = errors.New("note id must not be empty")
	ErrNoteIDContainsSep = errors.New("note id must not contain path separators")
	ErrOutsideWorkspace  = errors.New("resolved path escapes the workspace root")
)

// ResolveNotePath computes the on-disk path for a note ID and proves it
// is contained within the sandbox root. Exported and independently
// tested against adversarial note IDs (../escape, absolute paths,
// symlink-escape attempts, etc. — see createnote_test.go) even though
// Execute() below only ever calls it with a freshly generated UUID-shaped
// ID it produced itself, never anything derived from title/body.
//
// Containment is NOT checked by string-prefix comparison alone (which is
// spoofable by e.g. a sibling directory sharing a prefix, "workspace-evil"
// vs "workspace") — it uses filepath.Rel against the canonical root and
// rejects any result starting with ".." or being absolute.
func (s *Sandbox) ResolveNotePath(noteID string) (string, error) {
	if noteID == "" || noteID == "." || noteID == ".." {
		return "", ErrEmptyNoteID
	}
	if strings.ContainsAny(noteID, `/\`) || strings.Contains(noteID, ".") {
		// Rejecting ANY dot, not just "..", is deliberately stricter than
		// strictly necessary to prevent traversal (found during M3
		// testing: a noteID of "." combined with this function's ".md"
		// suffix produces the literal, sandbox-contained filename "..md"
		// — safe in practice, but a surprising, fragile edge case that
		// should not be allowed to pass by accident of string
		// concatenation rather than by deliberate design). Since real
		// note IDs are always generated as plain hex (generateNoteID
		// below), this costs nothing in practice and removes an entire
		// class of "is this construction actually safe" review burden.
		return "", ErrNoteIDContainsSep
	}

	candidate := filepath.Join(s.canonicalRoot, noteID+".md")
	candidate = filepath.Clean(candidate)

	rel, err := filepath.Rel(s.canonicalRoot, candidate)
	if err != nil {
		return "", fmt.Errorf("computing relative path: %w", err)
	}
	if rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) || filepath.IsAbs(rel) {
		return "", ErrOutsideWorkspace
	}

	return candidate, nil
}

// generateNoteID produces a random, filesystem-safe, non-user-derived
// identifier — hex-encoded random bytes, structurally incapable of
// containing "/", "\", or "..".
func generateNoteID() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("generating note id: %w", err)
	}
	return fmt.Sprintf("%x", b), nil
}

// Args mirrors the capability's declared {title, body} input.
type Args struct {
	Title string
	Body  string
}

// Result mirrors the capability's declared output_schema.
type Result struct {
	NoteID    string
	Path      string
	CreatedAt time.Time
}

// KnownLimitation documents, per the M3 brief §9's explicit instruction
// not to pretend a hard filesystem problem is fully solved: a TOCTOU
// (time-of-check-to-time-of-use) race on an INTERMEDIATE directory
// component of the workspace root (i.e., something replaces a directory
// between NewSandbox's EvalSymlinks call and a later write) is not fully
// closed by this implementation. The leaf write itself is race-safe
// (O_CREATE|O_EXCL, below) — a symlink or file planted at the exact
// target path is rejected atomically by the OS, and note IDs are
// unpredictable random values an attacker cannot pre-place a symlink for.
// Root-level TOCTOU is accepted as a known Phase-1 limitation, not solved
// perfectly, per the brief's explicit instruction to document rather than
// claim a false guarantee.
const KnownLimitation = "root-directory TOCTOU (time-of-check-to-time-of-use) is not fully closed; leaf-level writes are race-safe via O_CREATE|O_EXCL"

// Execute creates a note, enforcing: idempotency-key dedup, create-new-only
// (never overwrite — ALREADY_EXISTS on any pre-existing leaf), and
// sandbox containment via ResolveNotePath.
func (s *Sandbox) Execute(idempotencyKey string, args Args) (Result, error) {
	if idempotencyKey == "" {
		return Result{}, fmt.Errorf("idempotency key must not be empty")
	}

	digest := argsDigestForIdempotency(args)

	s.mu.Lock()
	if prior, ok := s.byIdemKey[idempotencyKey]; ok {
		s.mu.Unlock()
		if prior.argsDigest != digest {
			return Result{}, fmt.Errorf("idempotency key %q previously used with different arguments: reject", idempotencyKey)
		}
		// Same key, same arguments: return the prior result rather than
		// creating a duplicate — no second physical write occurs.
		return Result{NoteID: prior.noteID, Path: prior.path, CreatedAt: prior.createdAt}, nil
	}
	s.mu.Unlock()

	noteID, err := generateNoteID()
	if err != nil {
		return Result{}, err
	}
	path, err := s.ResolveNotePath(noteID)
	if err != nil {
		return Result{}, fmt.Errorf("%w: %v", ErrOutsideWorkspace, err)
	}

	// O_CREATE|O_EXCL: atomically fails if anything (file, symlink, or
	// directory) already exists at this exact leaf path — this is what
	// makes "create-new-only" and "no unexpected existing-file
	// replacement" a kernel-enforced guarantee at the leaf, not an
	// application-level check-then-write race.
	f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		if errors.Is(err, fs.ErrExist) {
			return Result{}, fmt.Errorf("note already exists at target path: %w", fs.ErrExist)
		}
		return Result{}, fmt.Errorf("creating note file: %w", err)
	}
	defer f.Close()

	if _, err := f.WriteString(args.Title + "\n\n" + args.Body); err != nil {
		return Result{}, fmt.Errorf("writing note content: %w", err)
	}

	result := Result{NoteID: noteID, Path: path, CreatedAt: time.Now()}

	s.mu.Lock()
	s.byIdemKey[idempotencyKey] = idemRecord{argsDigest: digest, noteID: noteID, path: path, createdAt: result.CreatedAt}
	s.mu.Unlock()

	return result, nil
}

// Verify re-reads the created note and confirms it exists, remains
// within the sandbox, and its content matches what was requested — the
// capability's declared verification_method
// (post_write_existence_and_content_check).
func (s *Sandbox) Verify(result Result, args Args) (bool, error) {
	rel, err := filepath.Rel(s.canonicalRoot, result.Path)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) || filepath.IsAbs(rel) {
		return false, ErrOutsideWorkspace
	}
	data, err := os.ReadFile(result.Path)
	if err != nil {
		return false, fmt.Errorf("reading back note for verification: %w", err)
	}
	want := args.Title + "\n\n" + args.Body
	return string(data) == want, nil
}

func argsDigestForIdempotency(args Args) string {
	// A simple, local digest sufficient for M3's in-memory idempotency
	// ledger's own dedup key — distinct from friday/ir's
	// ArgumentsDigest (used for the cross-module authorization-token
	// binding, see the cross-module test in bus_test.go). Using a
	// separate, simpler function here (rather than importing friday/ir
	// for it) keeps this capability's package independent of the ir
	// module, consistent with the "concrete capabilities depend on
	// contract, not on ir" dependency direction (M3 brief §18).
	return fmt.Sprintf("%x:%x", len(args.Title), len(args.Body)) + ":" + args.Title + "\x00" + args.Body
}
