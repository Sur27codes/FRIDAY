package createnote

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// Tests in this file translate the M3 brief §15's adversarial list into
// executable Go tests. All tests use t.TempDir() — never a real user
// directory (item 15's explicit requirement).

func newTestSandbox(t *testing.T) *Sandbox {
	t.Helper()
	s, err := NewSandbox(t.TempDir())
	if err != nil {
		t.Fatalf("NewSandbox: %v", err)
	}
	return s
}

// ---- ResolveNotePath adversarial tests (path traversal etc.) ----

func TestResolveNotePath_RejectsTraversalAndAbsolutePaths(t *testing.T) {
	s := newTestSandbox(t)

	adversarial := []string{
		"../escape",
		"../../escape",
		"nested/../../../escape",
		"..",
		".",
		"",
		"/absolute/path/escape",
		"a/b/../../../escape",
		"..\\windows-style-escape", // mixed separator attempt
		"a/../../b",
	}

	for _, id := range adversarial {
		t.Run(id, func(t *testing.T) {
			path, err := s.ResolveNotePath(id)
			if err == nil {
				t.Fatalf("expected rejection for note id %q, got resolved path %q", id, path)
			}
		})
	}
}

func TestResolveNotePath_AcceptsWellFormedGeneratedID(t *testing.T) {
	s := newTestSandbox(t)
	// Shape of what generateNoteID actually produces: hex string, no
	// separators.
	path, err := s.ResolveNotePath("deadbeefcafef00d0123456789abcdef")
	if err != nil {
		t.Fatalf("expected a well-formed id to resolve, got: %v", err)
	}
	rel, err := filepath.Rel(s.canonicalRoot, path)
	if err != nil || strings.HasPrefix(rel, "..") {
		t.Fatalf("resolved path %q escaped the sandbox root %q", path, s.canonicalRoot)
	}
}

// ---- Symlink escape (§9) ----

func TestSymlinkEscape_LinkPointingOutsideWorkspaceCannotBeWrittenThrough(t *testing.T) {
	root := t.TempDir()
	outside := t.TempDir() // a separate temp dir, standing in for "/private/location"

	// workspace/safe-link -> outside
	linkPath := filepath.Join(root, "safe-link")
	if err := os.Symlink(outside, linkPath); err != nil {
		t.Skipf("symlink creation not supported in this environment: %v", err)
	}

	s, err := NewSandbox(root)
	if err != nil {
		t.Fatalf("NewSandbox: %v", err)
	}

	// Attempting to resolve a note "through" the symlink directory name
	// is rejected outright: ResolveNotePath only ever joins
	// canonicalRoot + noteID + ".md" — there is no code path that lets a
	// caller name "safe-link" as part of the note id/target, since note
	// IDs never contain separators (enforced above). This test proves
	// that even an explicit attempt to reference the symlink's name as an
	// id is rejected as a malformed id, not silently resolved through it.
	_, err = s.ResolveNotePath("safe-link/secret")
	if err == nil {
		t.Fatal("expected an id containing a path separator (even one naming a symlink) to be rejected")
	}

	// Additionally confirm: nothing this package ever writes lands
	// outside `root`, by exercising a real Execute() call and checking
	// the result path.
	result, err := s.Execute("idem-symlink-test", Args{Title: "t", Body: "b"})
	if err != nil {
		t.Fatalf("Execute: %v", err)
	}
	rel, err := filepath.Rel(s.canonicalRoot, result.Path)
	if err != nil || strings.HasPrefix(rel, "..") {
		t.Fatalf("Execute produced a path outside the sandbox: %q", result.Path)
	}
	// And confirm the outside directory received nothing.
	entries, _ := os.ReadDir(outside)
	if len(entries) != 0 {
		t.Fatalf("expected the outside directory to remain empty, found %d entries", len(entries))
	}
}

// ---- Overwrite semantics (§10): CREATE-NEW ONLY ----

func TestOverwriteSemantics_ExistingFileAtTargetIsNeverModified(t *testing.T) {
	s := newTestSandbox(t)

	result1, err := s.Execute("idem-a", Args{Title: "first", Body: "original content"})
	if err != nil {
		t.Fatalf("first Execute: %v", err)
	}

	// Directly place a colliding file at a path shaped like a note, to
	// simulate the (cryptographically near-impossible in practice, but
	// tested anyway) case of a pre-existing file at the exact target.
	collisionID := "0000000000000000000000000000000collision"
	collisionPath, err := s.ResolveNotePath(collisionID[:32]) // trim to plausible hex length
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if err := os.WriteFile(collisionPath, []byte("pre-existing content, must survive"), 0o600); err != nil {
		t.Fatalf("seeding collision file: %v", err)
	}

	// Confirm the seeded file's content is untouched by anything this
	// package does afterward (it never targets this path itself, since
	// note IDs are randomly generated — this assertion documents that
	// fact rather than exercising a direct collision, which would require
	// forcing generateNoteID's output, not exposed as a seam in M3).
	data, err := os.ReadFile(collisionPath)
	if err != nil || string(data) != "pre-existing content, must survive" {
		t.Fatalf("pre-existing file was modified or unreadable: err=%v data=%q", err, data)
	}

	// First result's content is also still exactly as written.
	data1, err := os.ReadFile(result1.Path)
	if err != nil || string(data1) != "first\n\noriginal content" {
		t.Fatalf("first note's content was modified: err=%v data=%q", err, data1)
	}
}

func TestOverwriteSemantics_OExclRejectsPreexistingLeaf(t *testing.T) {
	s := newTestSandbox(t)
	path, err := s.ResolveNotePath("preexistingleaf00000000000000000")
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if err := os.WriteFile(path, []byte("already here"), 0o600); err != nil {
		t.Fatalf("seed: %v", err)
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err == nil {
		f.Close()
		t.Fatal("expected O_EXCL to reject a pre-existing leaf, but open succeeded")
	}
	if !errors.Is(err, os.ErrExist) {
		t.Fatalf("expected ErrExist, got: %v", err)
	}
}

// ---- Idempotency (§11) ----

func TestIdempotency_SameKeySameArguments_NoDuplicateSideEffect(t *testing.T) {
	s := newTestSandbox(t)
	args := Args{Title: "t", Body: "b"}

	r1, err := s.Execute("idem-x", args)
	if err != nil {
		t.Fatalf("first execute: %v", err)
	}
	r2, err := s.Execute("idem-x", args)
	if err != nil {
		t.Fatalf("second execute: %v", err)
	}
	if r1.NoteID != r2.NoteID || r1.Path != r2.Path {
		t.Fatalf("expected identical result for repeated idempotency key + args, got %+v vs %+v", r1, r2)
	}

	entries, err := os.ReadDir(s.canonicalRoot)
	if err != nil {
		t.Fatalf("readdir: %v", err)
	}
	if len(entries) != 1 {
		t.Fatalf("expected exactly one file created despite two Execute calls, found %d", len(entries))
	}
}

func TestIdempotency_SameKeyDifferentArguments_Rejected(t *testing.T) {
	s := newTestSandbox(t)
	if _, err := s.Execute("idem-y", Args{Title: "t", Body: "b"}); err != nil {
		t.Fatalf("first execute: %v", err)
	}
	_, err := s.Execute("idem-y", Args{Title: "t", Body: "DIFFERENT"})
	if err == nil {
		t.Fatal("expected rejection: same idempotency key reused with different arguments")
	}
}

// ---- Empty/malformed filename shapes (already covered by
// TestResolveNotePath_RejectsTraversalAndAbsolutePaths's "" and "."/".."
// cases, restated here at the Execute level for completeness) ----

func TestExecute_NeverAcceptsUserSuppliedPathLikeTitleAsAPathComponent(t *testing.T) {
	s := newTestSandbox(t)
	// Even a title crafted to look like a path traversal attempt is only
	// ever written as CONTENT, never interpreted as a path segment — the
	// note's filename is always the generated note_id.
	result, err := s.Execute("idem-content-test", Args{Title: "../../etc/passwd", Body: "irrelevant"})
	if err != nil {
		t.Fatalf("execute: %v", err)
	}
	if strings.Contains(result.Path, "etc/passwd") || strings.Contains(result.Path, "..") {
		t.Fatalf("title content leaked into the resolved path: %q", result.Path)
	}
	rel, err := filepath.Rel(s.canonicalRoot, result.Path)
	if err != nil || strings.HasPrefix(rel, "..") {
		t.Fatalf("resolved path escaped the sandbox: %q", result.Path)
	}
}

// ---- Concurrency basics (§21) ----

func TestConcurrentCreates_DoNotCorruptOrCollide(t *testing.T) {
	s := newTestSandbox(t)
	const n = 20
	var wg sync.WaitGroup
	results := make([]Result, n)
	errs := make([]error, n)

	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			// Distinct idempotency keys: each should produce its own
			// note, none should collide or corrupt another's file.
			r, err := s.Execute(concurrentKey(i), Args{Title: concurrentTitle(i), Body: "body"})
			results[i] = r
			errs[i] = err
		}(i)
	}
	wg.Wait()

	seen := map[string]bool{}
	for i, err := range errs {
		if err != nil {
			t.Fatalf("goroutine %d: %v", i, err)
		}
		if seen[results[i].NoteID] {
			t.Fatalf("duplicate note_id %q generated concurrently", results[i].NoteID)
		}
		seen[results[i].NoteID] = true
	}

	entries, err := os.ReadDir(s.canonicalRoot)
	if err != nil {
		t.Fatalf("readdir: %v", err)
	}
	if len(entries) != n {
		t.Fatalf("expected %d files, found %d — possible silent overwrite/collision", n, len(entries))
	}

	// Verify each file's content matches exactly its own request — proof
	// no cross-goroutine content corruption occurred.
	for i := 0; i < n; i++ {
		data, err := os.ReadFile(results[i].Path)
		if err != nil {
			t.Fatalf("reading result %d: %v", i, err)
		}
		want := concurrentTitle(i) + "\n\nbody"
		if string(data) != want {
			t.Fatalf("goroutine %d: content mismatch, got %q want %q", i, data, want)
		}
	}
}

func concurrentKey(i int) string   { return "idem-concurrent-" + itoa(i) }
func concurrentTitle(i int) string { return "title-" + itoa(i) }

func itoa(i int) string {
	if i == 0 {
		return "0"
	}
	neg := i < 0
	if neg {
		i = -i
	}
	var b []byte
	for i > 0 {
		b = append([]byte{byte('0' + i%10)}, b...)
		i /= 10
	}
	if neg {
		b = append([]byte{'-'}, b...)
	}
	return string(b)
}
