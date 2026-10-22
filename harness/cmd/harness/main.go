package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"adaptive-textbook/harness"
)

func main() { os.Exit(run()) }
func run() int {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: harness run|status|resume|stop -state ABS_PATH [-task ABS_PATH | -run ID]")
		return 2
	}
	verb := os.Args[1]
	flags := flag.NewFlagSet(verb, flag.ContinueOnError)
	state := flags.String("state", "", "private state directory")
	task := flags.String("task", "", "trusted task JSON")
	id := flags.String("run", "", "run ID")
	allow := flags.Bool("allow-codex", false, "explicitly opt into configured Codex implementation, review and repair")
	reconcile := flags.Bool("reconcile-local", false, "after inspecting interrupted local edits, rerun checks without replaying edits")
	if flags.Parse(os.Args[2:]) != nil || flags.NArg() != 0 {
		return 2
	}
	store, err := harness.OpenStore(*state)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	engine := harness.Engine{Store: store, AllowCodex: *allow}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	var result *harness.Run
	switch verb {
	case "run":
		result, err = engine.New(*task)
		if err == nil {
			fmt.Fprintln(os.Stderr, "run:", result.ID)
			result, err = engine.Execute(ctx, result.ID, false)
		}
	case "resume":
		result, err = engine.Execute(ctx, *id, *reconcile)
	case "status":
		result, err = engine.Status(*id)
	case "stop":
		err = store.Stop(*id)
		if err == nil {
			result, err = store.Load(*id)
		}
	default:
		fmt.Fprintln(os.Stderr, "unknown command")
		return 2
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	if json.NewEncoder(os.Stdout).Encode(result) != nil {
		return 1
	}
	if verb != "status" && verb != "stop" && result.Status != "accepted" {
		return 1
	}
	return 0
}
