package harness

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestStopWatcherJoinsInflightLedgerRead(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	reading := make(chan struct{})
	release := make(chan struct{})
	finished := make(chan struct{})
	calls := 0
	stop := watchStopRequests(ctx, cancel, func() (*Run, error) {
		calls++
		if calls == 1 {
			close(reading)
		}
		<-release
		return &Run{}, nil
	})
	select {
	case <-reading:
	case <-time.After(5 * time.Second):
		close(release)
		stop()
		t.Fatal("watcher never entered ledger read")
	}
	go func() { stop(); close(finished) }()
	returnedEarly := false
	select {
	case <-finished:
		returnedEarly = true
	case <-time.After(100 * time.Millisecond):
	}
	close(release)
	select {
	case <-finished:
	case <-time.After(5 * time.Second):
		t.Fatal("watcher did not finish after ledger read completed")
	}
	if returnedEarly {
		t.Fatal("shutdown returned while ledger read was still in flight")
	}
}

func TestStopWatcherCancelsOnRequestOrLedgerFailure(t *testing.T) {
	for _, failure := range []bool{false, true} {
		ctx, cancel := context.WithCancel(context.Background())
		stop := watchStopRequests(ctx, cancel, func() (*Run, error) {
			if failure {
				return nil, errors.New("ledger unavailable")
			}
			return &Run{StopRequested: true}, nil
		})
		select {
		case <-ctx.Done():
		case <-time.After(5 * time.Second):
			cancel()
			stop()
			t.Fatal("stop request or ledger error did not cancel execution")
		}
		stop()
		cancel()
	}
}
