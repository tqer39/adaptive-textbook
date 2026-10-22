package harness

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

const (
	independentHashFirst          = "hash-ambiguity-a.bin"
	independentHashSecond         = "hash-ambiguity-b.go"
	independentHashFirstContents  = "prefix"
	independentHashSecondContents = "package regression\n"
)

func seedIndependentHashAmbiguity(t *testing.T, workspace string) {
	t.Helper()
	// Both names sort after fixture's code.txt and remain adjacent in the file list.
	for name, contents := range map[string]string{
		independentHashFirst:  independentHashFirstContents,
		independentHashSecond: independentHashSecondContents,
	} {
		path := filepath.Join(workspace, name)
		if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(path, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	tracked, err := gitOutput(workspace, "ls-files", "--cached", "--", independentHashFirst, independentHashSecond)
	if err != nil || len(tracked) != 0 {
		t.Fatalf("ambiguity fixture must use untracked files: %q %v", tracked, err)
	}
}

func collapseIndependentHashAmbiguity(t *testing.T, workspace string) {
	t.Helper()
	// A regular os.FileMode(0o600) is decimal "384" under fmt's %d.
	// Spell out the old record bytes: NUL + path + NUL + "384" + NUL + content.
	// Keeping the fixture independent of CodeHash prevents a framing fix from
	// silently changing the counterexample instead of detecting the source change.
	const contents = independentHashFirstContents + "\x00" + independentHashSecond + "\x00" + "384" + "\x00" + independentHashSecondContents
	if err := os.WriteFile(filepath.Join(workspace, independentHashFirst), []byte(contents), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(workspace, independentHashSecond)); err != nil {
		t.Fatal(err)
	}
}

func TestIndependentCodeHashSeparatesFileBoundaries(t *testing.T) {
	_, _, task := fixture(t)
	seedIndependentHashAmbiguity(t, task.Workspace)
	before, err := CodeHash(task.Workspace)
	if err != nil {
		t.Fatal(err)
	}
	collapseIndependentHashAmbiguity(t, task.Workspace)
	after, err := CodeHash(task.Workspace)
	if err != nil {
		t.Fatal(err)
	}
	if before == after {
		t.Fatalf("different file sets share a code hash after embedding a removed file's record: %s", before)
	}
}

func TestIndependentAcceptedRunRefusesSerializedFileMerge(t *testing.T) {
	e, path, task := fixture(t)
	seedIndependentHashAmbiguity(t, task.Workspace)
	r := executeRun(t, e, newRun(t, e, path))
	if r.Status != "accepted" {
		t.Fatalf("fixture did not reach acceptance: %+v", r)
	}
	collapseIndependentHashAmbiguity(t, task.Workspace)
	status, err := e.Status(r.ID)
	if err != nil {
		t.Fatal(err)
	}
	if !status.Stale || status.CurrentCodeHash == status.CodeHash {
		t.Errorf("accepted evidence remains current after a source file was removed: %+v", status)
	}
	if _, err := e.Execute(context.Background(), r.ID, false); err == nil || err.Error() != "code-modified-since-checkpoint" {
		t.Errorf("accepted run reused evidence for a different file set: %v", err)
	}
}
