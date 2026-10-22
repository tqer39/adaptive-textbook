package harness

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestPrerequisiteFailureNeverDispatchesImplementationOrRepair(t *testing.T) {
	e, path, task := fixture(t)
	ready := filepath.Join(filepath.Dir(path), "tool-ready")
	task.Preflight = []Action{{Command: []string{"/bin/sh", "-c", `test -f "$1" || exit 78`, "probe", ready}, TimeoutSeconds: 3}}
	implement := action("repair", "fix")
	task.Implement = &implement
	repair := action("repair", "fix")
	task.Repair = &repair
	task.MaxRepairCycles = 1
	writeTask(t, path, task)
	r := executeRun(t, e, newRun(t, e, path))
	code, _ := os.ReadFile(filepath.Join(task.Workspace, "code.txt"))
	if r.Status != "blocked" || r.Reason != "prerequisite-failed" || r.Cycle != 0 || r.Operations != 1 || string(code) != "initial" || r.Evidence[0].ExitCode != 78 {
		t.Fatalf("prerequisite dispatched work: %+v", r)
	}
	if err := os.WriteFile(ready, []byte("ready"), 0600); err != nil {
		t.Fatal(err)
	}
	r = executeRun(t, e, r)
	if r.Status != "accepted" || r.Operations != 5 || r.Cycle != 0 {
		t.Fatalf("preflight recovery: %+v", r)
	}
}

func TestLatePrerequisiteLossDoesNotConsumeRepairCycle(t *testing.T) {
	e, path, task := fixture(t)
	task.Checks = []Action{{Command: []string{"/bin/sh", "-c", "exit 78"}, TimeoutSeconds: 3, PrerequisiteExitCode: 78}}
	repair := action("repair", "fix")
	task.Repair = &repair
	task.MaxRepairCycles = 1
	writeTask(t, path, task)
	r := executeRun(t, e, newRun(t, e, path))
	if r.Status != "blocked" || r.Reason != "prerequisite-failed" || r.Cycle != 0 || r.Operations != 1 || r.Evidence[0].ExitCode != 78 {
		t.Fatalf("environment failure repaired as source: %+v", r)
	}
}

func TestExternalPrerequisitesPreventFullAcceptanceAndModelReplay(t *testing.T) {
	e, path, task := fixture(t)
	task.ExternalPrerequisites = []string{"Operate the exact macOS and iOS bundles on an unlocked host"}
	writeTask(t, path, task)
	r := executeRun(t, e, newRun(t, e, path))
	if r.Status != "awaiting-external-validation" || r.Reason != "external-validation-required" {
		t.Fatalf("missing external QA accepted: %+v", r)
	}
	again, err := e.Execute(context.Background(), r.ID, false)
	if err != nil || again.Operations != r.Operations || again.Status != r.Status {
		t.Fatalf("external wait replayed source work: %+v %v", again, err)
	}
	summary, err := e.Summary(r.ID)
	if err != nil || len(summary.ExternalPrerequisites) != 1 || summary.Stale {
		t.Fatalf("external requirement hidden: %+v %v", summary, err)
	}
}

func TestPreflightMayNotModifySource(t *testing.T) {
	e, path, task := fixture(t)
	task.Preflight = []Action{action("repair", "fix")}
	writeTask(t, path, task)
	r := executeRun(t, e, newRun(t, e, path))
	if r.Status != "blocked" || r.Reason != "verification-modified-code" || r.Operations != 1 {
		t.Fatalf("preflight modified source: %+v", r)
	}
}
