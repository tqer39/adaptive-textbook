package harness

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestModelImplementIndependentReviewRepairAndEvidence(t *testing.T) {
	e, path, task := codexFixture(t, "by-content")
	root := filepath.Dir(path)
	task.Implement = &Action{Kind: "codex", Codex: fakeCodexConfig(t, root, "partial"), Instructions: "implement source only", TimeoutSeconds: 3}
	task.Repair = &Action{Kind: "codex", Codex: fakeCodexConfig(t, root, "success"), Instructions: "address the independent finding", TimeoutSeconds: 3}
	task.MaxRepairCycles = 2
	task.TimeoutSeconds = 30
	writeTask(t, path, task)
	r := executeRun(t, e, newRun(t, e, path))
	if r.Status != "accepted" || r.Cycle != 1 {
		t.Fatalf("model cycle failed: %+v", r)
	}
	var roles []string
	threads := map[string]bool{}
	for _, proof := range r.Evidence {
		if proof.Model == nil {
			continue
		}
		m := proof.Model
		roles = append(roles, m.Role)
		if m.RequestedModel != "test-model" || m.ResolvedModel != m.RequestedModel || m.Provider != "openai" || m.ServiceTier != "default" || m.ReportedServiceTier == nil || *m.ReportedServiceTier != "default" || m.Quota == nil || m.Quota.HasCredits || m.Quota.UnlimitedCredits || len(m.Quota.Windows) == 0 || m.ThreadID == "" || m.TurnID == "" || m.Tokens == nil {
			t.Fatalf("model evidence missing: %+v", m)
		}
		if threads[m.ThreadID] {
			t.Fatal("implementation and independent review reused a thread")
		}
		threads[m.ThreadID] = true
		log, _ := os.ReadFile(filepath.Join(e.Store.Directory, proof.Log))
		if strings.Contains(string(log), "sensitive-config-placeholder") {
			t.Fatal("config credential leaked")
		}
	}
	if strings.Join(roles, ",") != "implement,review,repair,review" {
		t.Fatalf("wrong model roles: %v", roles)
	}
}

func TestModelActionsRequireOptInAndChecksRemainCommands(t *testing.T) {
	e, path, task := fixture(t)
	task.Implement = &Action{Kind: "codex", Codex: fakeCodexConfig(t, filepath.Dir(path), "success"), TimeoutSeconds: 3}
	writeTask(t, path, task)
	if _, err := e.New(path); err == nil || err.Error() != "codex-disabled" {
		t.Fatalf("edit model was enabled implicitly: %v", err)
	}
	task.Checks = []Action{*task.Implement}
	writeTask(t, path, task)
	if _, _, _, err := LoadTask(path); err == nil || err.Error() != "checks-must-be-local-commands" {
		t.Fatalf("model self-grading check accepted: %v", err)
	}
}

func TestIncludedQuotaPreflightStopsBeforeDispatch(t *testing.T) {
	cases := map[string]string{
		"quota-credit":         "codex-additional-credits-refused",
		"quota-unlimited":      "codex-additional-credits-refused",
		"quota-credit-unknown": "codex-credit-state-unknown",
		"quota-exhausted":      "codex-included-quota-insufficient-or-unknown",
		"quota-window-unknown": "codex-included-quota-insufficient-or-unknown",
		"quota-reset-expired":  "codex-included-quota-insufficient-or-unknown",
		"quota-spend-reached":  "codex-quota-reached",
		"quota-reached":        "codex-quota-reached",
		"quota-other-bucket":   "codex-included-quota-insufficient-or-unknown",
		"wrong-provider":       "codex-model-provider-or-tier-mismatch",
		"wrong-model":          "codex-model-provider-or-tier-mismatch",
		"fast-tier":            "codex-model-provider-or-tier-mismatch",
	}
	for mode, want := range cases {
		t.Run(mode, func(t *testing.T) {
			e, path, _ := codexFixture(t, mode)
			r := executeRun(t, e, newRun(t, e, path))
			if r.Status != "blocked" || r.Reason != want || r.Pending != nil {
				t.Fatalf("unsafe preflight %+v, want %s", r, want)
			}
		})
	}
}

func TestIncludedQuotaMissingAndMultiBucketMetadata(t *testing.T) {
	now := time.Now()
	data, _ := json.Marshal(fakeQuota("success"))
	q, err := includedQuota("prolite", data, now)
	if err != nil || !q.SpendControlUnknown || len(q.Windows) != 1 || !q.CreditsPresent {
		t.Fatalf("quota metadata: %+v %v", q, err)
	}
	for _, data := range []string{`{}`, `{"rateLimitsByLimitId":{}}`, `{"rateLimits":{"credits":{"hasCredits":false,"unlimited":false}}}`} {
		if _, err := includedQuota("prolite", []byte(data), now); err == nil {
			t.Fatal("unknown quota treated as permission")
		}
	}
	if _, err := includedQuota("business", data, now); err == nil {
		t.Fatal("workspace billing admitted")
	}
}

func TestUnknownModelEditRequiresReconcileAndNeverRepeatsTurn(t *testing.T) {
	e, path, task := codexFixture(t, "by-content")
	task.Implement = &Action{Kind: "codex", Codex: fakeCodexConfig(t, filepath.Dir(path), "edit-recovery"), TimeoutSeconds: 3}
	writeTask(t, path, task)
	r := newRun(t, e, path)
	_ = os.WriteFile(filepath.Join(task.Workspace, "code.txt"), []byte("fixed"), 0o600)
	observed, _ := CodeHash(task.Workspace)
	r.Status = "stopped"
	r.Pending = &Pending{Phase: "implement", Effect: "model-action", CodeHash: r.CodeHash, ObservedHash: observed, ThreadID: "prior-thread", TurnID: "turn-test", Dispatched: true}
	r.Operations = 1
	_ = e.Store.Save(r, false)
	if _, err := e.Execute(context.Background(), r.ID, false); err == nil || err.Error() != "model-edit-unknown-inspect-and-use-reconcile-local" {
		t.Fatalf("unknown model edit resent: %v", err)
	}
	recovered, err := e.Execute(context.Background(), r.ID, true)
	if err != nil || recovered.Status != "ready" || recovered.Phase != "checks" || recovered.Pending != nil || recovered.CodeHash != observed {
		t.Fatalf("recovery: %+v %v", recovered, err)
	}
	if len(recovered.Evidence) != 1 || recovered.Evidence[0].Phase != "implement-recovery" {
		t.Fatalf("missing recovered model evidence: %+v", recovered)
	}
	if got := executeRun(t, e, recovered); got.Status != "accepted" {
		t.Fatalf("checks not rerun after recovery: %+v", got)
	}
}

func TestReadOnlyModelReviewMutationCannotReuseOldChecks(t *testing.T) {
	e, path, _ := codexFixture(t, "review-mutate")
	r := executeRun(t, e, newRun(t, e, path))
	if r.Status != "blocked" || r.Reason != "verification-modified-code" {
		t.Fatalf("model reviewer changed source: %+v", r)
	}
	if _, err := e.Execute(context.Background(), r.ID, false); err == nil {
		t.Fatal("stale checks allowed acceptance after reviewer mutation")
	}
}
