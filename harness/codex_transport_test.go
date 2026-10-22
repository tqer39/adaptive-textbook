package harness

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestProtocolProgressCanExceedRetainedLogLimit(t *testing.T) {
	e, path, task := codexFixture(t, "protocol-progress")
	task.LogLimitBytes = 1024
	task.Review.TimeoutSeconds = 5
	writeTask(t, path, task)
	run := executeRun(t, e, newRun(t, e, path))
	// The fake emits >1 MiB of progress, in addition to multi-KiB handshake data.
	// None of those payloads belongs in the retained output budget.
	if run.Status != "accepted" {
		t.Fatalf("ordinary progress consumed retained log budget: %+v", run)
	}
	for _, proof := range run.Evidence {
		data, err := os.ReadFile(filepath.Join(e.Store.Directory, proof.Log))
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(string(data), "PROTOCOL_PROGRESS_NOT_RETAINED") {
			t.Fatal("raw protocol persisted")
		}
		var log struct {
			Stdout string
			Stderr string
		}
		if json.Unmarshal(data, &log) != nil {
			t.Fatal("invalid evidence log")
		}
		if len(log.Stdout)+len(log.Stderr) > task.LogLimitBytes {
			t.Fatal("retained output exceeded budget")
		}
	}
	data, err := os.ReadFile(e.Store.DB)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(data, []byte("PROTOCOL_PROGRESS_NOT_RETAINED")) {
		t.Fatal("raw protocol stored in ledger")
	}
}

func TestProtocolFailuresHaveSpecificOutcomes(t *testing.T) {
	cases := map[string]string{
		"protocol-message":      string(protocolMessageLimit),
		"protocol-invalid-json": string(protocolInvalidJSON),
		"protocol-diagnostics":  string(protocolDiagnosticsLimit),
		"protocol-eof":          "codex-stream-closed",
		"protocol-final-output": "log-limit",
	}
	for mode, want := range cases {
		t.Run(mode, func(t *testing.T) {
			e, path, task := codexFixture(t, mode)
			task.LogLimitBytes = 1024
			task.Review.TimeoutSeconds = 5
			writeTask(t, path, task)
			run := executeRun(t, e, newRun(t, e, path))
			if run.Status == "accepted" || run.Reason != want || run.Pending == nil || !run.Pending.Dispatched {
				t.Fatalf("lost failure cause or dispatch checkpoint: reason=%s want=%s status=%s pending=%+v", run.Reason, want, run.Status, run.Pending)
			}
			proof := run.Evidence[len(run.Evidence)-1]
			if proof.Outcome != want {
				t.Fatal(proof.Outcome)
			}
			data, err := os.ReadFile(filepath.Join(e.Store.Directory, proof.Log))
			if err != nil {
				t.Fatal(err)
			}
			var log struct {
				Stdout string
				Stderr string
			}
			if json.Unmarshal(data, &log) != nil {
				t.Fatal("invalid log")
			}
			if len(log.Stdout)+len(log.Stderr) > task.LogLimitBytes {
				t.Fatal("retained output exceeded budget")
			}
			if strings.Contains(string(data), "NOT_RETAINED") {
				t.Fatal("raw diagnostic/protocol leaked")
			}
		})
	}
}

func TestBoundedStreamAndQueueAreIndependent(t *testing.T) {
	cases := []struct {
		mode   string
		limits protocolLimits
		want   string
	}{
		{"protocol-initial-stream", protocolLimits{messageBytes: 4096, streamBytes: 8192, queueBytes: 64 * 1024, queueMessages: 1000}, string(protocolStreamLimit)},
		{"protocol-initial-queue", protocolLimits{messageBytes: 4096, streamBytes: 64 * 1024, queueBytes: 4096, queueMessages: 1000}, string(protocolQueueLimit)},
		{"protocol-initial-message", protocolLimits{messageBytes: 4096, streamBytes: 64 * 1024, queueBytes: 64 * 1024, queueMessages: 1000}, string(protocolMessageLimit)},
	}
	for _, tc := range cases {
		t.Run(tc.mode, func(t *testing.T) {
			_, path, task := codexFixture(t, tc.mode)
			cfg := fakeCodexConfig(t, filepath.Dir(path), tc.mode)
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			server, err := startAppServerWithLimits(ctx, *cfg, task.Workspace, 1024, tc.limits)
			if err != nil {
				t.Fatal(err)
			}
			defer server.close()
			err = server.initialize()
			if err == nil || err.Error() != tc.want {
				t.Fatalf("wrong bounded transport reason: %v want %s", err, tc.want)
			}
			if server.queuedBytes > tc.limits.queueBytes {
				t.Fatal("retained queue exceeded its byte bound")
			}
		})
	}
}

func TestProtocolCancellationKeepsFirstCause(t *testing.T) {
	ctx, cancel := context.WithCancelCause(context.Background())
	server := &appServer{ctx: ctx, cancel: cancel, messages: make(chan rpcMessage, 1)}
	server.messages <- rpcMessage{Method: "turn/completed"}
	cancel(protocolStreamLimit)
	cancel(context.Canceled)
	for i := 0; i < 10; i++ {
		_, err := server.next()
		if err == nil || err.Error() != string(protocolStreamLimit) {
			t.Fatalf("cancellation erased first cause: %v", err)
		}
	}
	result := processResult{outcome: "complete", exitCode: 0, stdout: []byte("untrusted final output")}
	server.boundResult(&result, 1024)
	if result.outcome != string(protocolStreamLimit) || len(result.stdout) != 0 || result.exitCode != -1 {
		t.Fatalf("buffered completion hid transport failure: %+v", result)
	}
}

func TestProtocolReaderCountsDelimitersAndFiniteBoundary(t *testing.T) {
	ctx, cancel := context.WithCancelCause(context.Background())
	source := strings.NewReader("12345\n")
	reader := &protocolReader{source: source, remaining: 5, cancel: cancel}
	data, err := io.ReadAll(reader)
	if len(data) != 0 || err != protocolStreamLimit || context.Cause(ctx) != protocolStreamLimit {
		t.Fatalf("delimiter bypassed cumulative limit: %q %v", data, err)
	}
	if source.Len() != 0 {
		t.Fatal("reader did not stop at the first byte beyond the boundary")
	}
	ctx2, cancel2 := context.WithCancelCause(context.Background())
	defer cancel2(nil)
	valid := &protocolReader{source: strings.NewReader("1234\n"), remaining: 5, cancel: cancel2}
	got, err := io.ReadAll(valid)
	if err != nil || string(got) != "1234\n" || ctx2.Err() != nil {
		t.Fatalf("exact limit rejected: %q %v", got, err)
	}
}

func TestQueuedPayloadReleasedOnPop(t *testing.T) {
	server := &appServer{limits: defaultProtocolLimits}
	message := rpcMessage{Method: "progress", Params: json.RawMessage(`{"data":"temporary"}`)}
	if err := server.queue(message); err != nil {
		t.Fatal(err)
	}
	backing := server.queued
	got := server.popQueued()
	if got.Method != "progress" || server.queuedBytes != 0 || backing[0].Method != "" || backing[0].Params != nil {
		t.Fatal("popped protocol payload retained")
	}
}
