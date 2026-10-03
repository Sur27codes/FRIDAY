package createnote

import (
	"path/filepath"
	"strings"
	"testing"
)

// FuzzResolveNotePath targets exactly what the M3 brief §22 asks for:
// arbitrary workspace-path-shaped input never escapes the sandbox, and
// never panics — even though production code (Execute) never feeds this
// function anything but its own generated hex IDs.
func FuzzResolveNotePath(f *testing.F) {
	seeds := []string{
		"", ".", "..", "a", "../a", "../../a", "a/../../b",
		"/etc/passwd", "a/b/c", "....//....//etc/passwd",
		"a\x00b", strings.Repeat("../", 50) + "etc/passwd",
		"deadbeefcafef00d0123456789abcdef",
	}
	for _, s := range seeds {
		f.Add(s)
	}

	root := f.TempDir()
	s, err := NewSandbox(root)
	if err != nil {
		f.Fatalf("NewSandbox: %v", err)
	}

	f.Fuzz(func(t *testing.T, noteID string) {
		defer func() {
			if r := recover(); r != nil {
				t.Fatalf("ResolveNotePath panicked on noteID=%q: %v", noteID, r)
			}
		}()

		path, err := s.ResolveNotePath(noteID)
		if err != nil {
			return // rejection is always an acceptable outcome
		}

		// If it resolved at all, it MUST be contained within the
		// canonical root — no exceptions.
		rel, relErr := filepath.Rel(s.canonicalRoot, path)
		if relErr != nil {
			t.Fatalf("noteID=%q resolved to %q but filepath.Rel failed: %v", noteID, path, relErr)
		}
		if rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) || filepath.IsAbs(rel) {
			t.Fatalf("SANDBOX ESCAPE: noteID=%q resolved to %q, outside root %q (rel=%q)", noteID, path, s.canonicalRoot, rel)
		}
	})
}
