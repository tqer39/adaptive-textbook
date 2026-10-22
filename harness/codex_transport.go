package harness

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
)

// Transport traffic is ephemeral. These bounds are independent of retained logs.
// Keep the task schema and authorization/billing policy unchanged.
type protocolLimits struct {
	messageBytes  int
	streamBytes   int64
	queueBytes    int
	queueMessages int
}

var defaultProtocolLimits = protocolLimits{
	messageBytes:  4 * 1024 * 1024,
	streamBytes:   64 * 1024 * 1024,
	queueBytes:    4 * 1024 * 1024,
	queueMessages: 1000,
}

type protocolFailure string

func (e protocolFailure) Error() string { return string(e) }

const (
	protocolMessageLimit     protocolFailure = "codex-protocol-message-limit"
	protocolStreamLimit      protocolFailure = "codex-protocol-stream-limit"
	protocolQueueLimit       protocolFailure = "codex-protocol-queue-limit"
	protocolInvalidJSON      protocolFailure = "codex-protocol-invalid-json"
	protocolReadFailed       protocolFailure = "codex-protocol-read-failed"
	protocolDiagnosticsLimit protocolFailure = "codex-diagnostics-limit"
)

// This reader includes delimiters and unterminated fragments in the cumulative
// bound, and consumes at most one byte beyond it. No received payload is saved.
type protocolReader struct {
	source    io.Reader
	remaining int64
	cancel    context.CancelCauseFunc
}

func (r *protocolReader) Read(p []byte) (int, error) {
	if int64(len(p)) > r.remaining+1 {
		p = p[:int(r.remaining+1)]
	}
	n, err := r.source.Read(p)
	r.remaining -= int64(n)
	if r.remaining < 0 {
		r.cancel(protocolStreamLimit)
		return 0, protocolStreamLimit
	}
	return n, err
}

// Diagnostic stderr remains bounded by logLimitBytes, as before, but is never
// retained in memory or logged. The cause distinguishes it from user cancellation.
type diagnosticSink struct {
	remaining int
	cancel    context.CancelCauseFunc
}

func (w *diagnosticSink) Write(p []byte) (int, error) {
	if len(p) > w.remaining {
		w.remaining = 0
		w.cancel(protocolDiagnosticsLimit)
	} else {
		w.remaining -= len(p)
	}
	return len(p), nil
}

func (s *appServer) readMessages(stdout io.Reader) {
	defer close(s.messages)
	reader := &protocolReader{source: stdout, remaining: s.limits.streamBytes, cancel: s.cancel}
	scanner := bufio.NewScanner(reader)
	initial := 4096
	if initial > s.limits.messageBytes+2 {
		initial = s.limits.messageBytes + 2
	}
	// Allow the split function to see a full maximum-size message plus newline.
	scanner.Buffer(make([]byte, initial), s.limits.messageBytes+2)
	for scanner.Scan() {
		if len(scanner.Bytes()) > s.limits.messageBytes {
			s.cancel(protocolMessageLimit)
			return
		}
		var m rpcMessage
		if json.Unmarshal(scanner.Bytes(), &m) != nil {
			s.cancel(protocolInvalidJSON)
			return
		}
		select {
		case s.messages <- m:
		case <-s.ctx.Done():
			return
		}
	}
	if err := scanner.Err(); err != nil && s.ctx.Err() == nil {
		if errors.Is(err, bufio.ErrTooLong) {
			s.cancel(protocolMessageLimit)
		} else {
			s.cancel(protocolReadFailed)
		}
	}
}

func (s *appServer) transportFailure() error {
	var failure protocolFailure
	if errors.As(context.Cause(s.ctx), &failure) {
		return failure
	}
	return nil
}

func messageBytes(m rpcMessage) int {
	return len(m.ID) + len(m.Method) + len(m.Params) + len(m.Result) + len(m.Error)
}

func (s *appServer) queue(m rpcMessage) error {
	size := messageBytes(m)
	if len(s.queued) >= s.limits.queueMessages {
		s.cancel(protocolFailure("codex-event-limit"))
		return protocolFailure("codex-event-limit")
	}
	if size > s.limits.queueBytes-s.queuedBytes {
		s.cancel(protocolQueueLimit)
		return protocolQueueLimit
	}
	s.queued = append(s.queued, m)
	s.queuedBytes += size
	return nil
}

func (s *appServer) popQueued() rpcMessage {
	m := s.queued[0]
	s.queued[0] = rpcMessage{} // Release popped payloads rather than retaining the backing array.
	s.queued = s.queued[1:]
	s.queuedBytes -= messageBytes(m)
	return m
}

// Run before close() cancels the connection. A protocol cause takes precedence
// even if context cancellation, EOF, and a final message become ready together.
func (s *appServer) boundResult(result *processResult, logLimit int) {
	if failure := s.transportFailure(); failure != nil {
		result.outcome = failure.Error()
		result.stdout = nil
		result.stderr = nil
		result.exitCode = -1
		return
	}
	if len(result.stdout)+len(result.stderr) > logLimit {
		if len(result.stdout) > logLimit {
			result.stdout = result.stdout[:logLimit]
		}
		if len(result.stderr) > logLimit-len(result.stdout) {
			result.stderr = result.stderr[:logLimit-len(result.stdout)]
		}
		result.outcome = "log-limit"
		result.exitCode = -1
	}
}
