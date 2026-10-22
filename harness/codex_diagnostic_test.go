package harness

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"unicode/utf8"
)

func TestRepairHandoffUsesLatestHashBoundFailureAndBoundedTail(t *testing.T) {
	directory := t.TempDir()
	writeLog := func(name, message string) Evidence {
		t.Helper()
		data, err := json.Marshal(map[string]string{"stdout": "", "stderr": message})
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(directory, name), data, 0o600); err != nil {
			t.Fatal(err)
		}
		return Evidence{Phase: "checks", Log: name, LogHash: digest(data), ExitCode: 1, Outcome: "command-failed"}
	}
	old := writeLog("old.json", "OLD_ERROR_ALREADY_FIXED")
	latest := writeLog("latest.json", strings.Repeat("x", 20*1024)+"\nNEW_SWIFT_CONCURRENCY_ERROR")
	evidence := []Evidence{old, {Phase: "repair", Outcome: "complete"}, latest}
	note, err := latestCheckDiagnostic(directory, evidence)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(note, "NEW_SWIFT_CONCURRENCY_ERROR") || strings.Contains(note, "OLD_ERROR_ALREADY_FIXED") || len(note) > 10*1024 {
		t.Fatalf("wrong or unbounded repair feedback: %d bytes", len(note))
	}
	if !strings.Contains(note, latest.LogHash) {
		t.Fatal("diagnostic lost its evidence identity")
	}
	// A review revision after successful checks must not resurrect an old error.
	evidence = append(evidence, Evidence{Phase: "checks", ExitCode: 0, Outcome: "complete"})
	if note, err := latestCheckDiagnostic(directory, evidence); err != nil || note != "" {
		t.Fatalf("stale failure reused: %q %v", note, err)
	}
	if err := os.WriteFile(filepath.Join(directory, latest.Log), []byte("tampered"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := latestCheckDiagnostic(directory, []Evidence{latest}); err == nil {
		t.Fatal("unverified diagnostic sent")
	}
	latest.Log = "../outside.json"
	if _, err := latestCheckDiagnostic(directory, []Evidence{latest}); err == nil {
		t.Fatal("out-of-store log accepted")
	}
}

func TestRepairHandoffPreservesAssertionsBeforeVerboseSuiteSummary(t *testing.T) {
	directory := t.TempDir()
	stdout := "/source/ParserTests.swift:42: error: XCTAssertEqual failed - EXPECTED_READABLE_RSS\n" + strings.Repeat("passed suite summary\n", 2_000) + "LATEST_SUITE_RESULT"
	data, err := json.Marshal(map[string]string{"stdout": stdout, "stderr": ""})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, "checks.json"), data, 0o600); err != nil {
		t.Fatal(err)
	}
	note, err := latestCheckDiagnostic(directory, []Evidence{{Phase: "checks", ExitCode: 1, Outcome: "command-failed", Log: "checks.json", LogHash: digest(data)}})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(note, "EXPECTED_READABLE_RSS") || !strings.Contains(note, "LATEST_SUITE_RESULT") {
		t.Fatal("repair lost the assertion or the latest summary")
	}
	if got := diagnosticErrorExcerpts(strings.Repeat("error: broken 日本語\n", 10_000)); len(got) > 4*1024 || !utf8.ValidString(got) || !strings.HasPrefix(got, "error:") {
		t.Fatal("error excerpt is missing or unbounded")
	}
}
