package harness

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func productFixture(t *testing.T) (Engine, string, Task, string) {
	t.Helper()
	e, path, task := fixture(t)
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	root := filepath.Dir(cwd)
	for _, relative := range []string{"scripts/product-check.sh", "AGENTS.md", ".agents/skills/harness-development/SKILL.md", ".agents/skills/independent-review/SKILL.md", "package.json", "package-lock.json", "scripts/check-docs.mjs", "docs/rules/documentation.md", "apple/scripts/check-native.sh", "apple/scripts/test-macos-bundle.sh", "apple/scripts/build-macos-app.sh", "apple/Package.swift", ".agents/skills/apple-native-validation/SKILL.md"} {
		data, err := os.ReadFile(filepath.Join(root, relative))
		if err != nil {
			t.Fatal(err)
		}
		target := filepath.Join(task.Workspace, relative)
		if err := os.MkdirAll(filepath.Dir(target), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(target, data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Mkdir(filepath.Join(task.Workspace, "node_modules"), 0700); err != nil {
		t.Fatal(err)
	}
	tools := filepath.Join(filepath.Dir(path), "tool bin")
	if err := os.Mkdir(tools, 0700); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"node", "npm"} {
		body := "#!/bin/sh\ncase \"$*\" in --version) echo fixture-version; exit 0 ;; 'run lint') exit 0 ;; *) exit 39 ;; esac\n"
		if err := os.WriteFile(filepath.Join(tools, name), []byte(body), 0700); err != nil {
			t.Fatal(err)
		}
	}
	writeTask(t, path, task)
	return e, path, task, tools
}

func TestPreparedProductPreservesFixedContractAndHostExitCodes(t *testing.T) {
	e, path, task, tools := productFixture(t)
	output := filepath.Join(filepath.Dir(path), "product.json")
	generated, err := PrepareProductTask(path, output, ProductOptions{Profiles: []string{"lint"}, ToolDirectories: []string{tools}, CheckTimeoutSeconds: 5})
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(task.Acceptance, generated.Acceptance) || task.Goal != generated.Goal || task.MaxOperations != generated.MaxOperations || !reflect.DeepEqual(task.Checks[0], generated.Checks[0]) || len(generated.Checks) != 2 || len(generated.Preflight) != 1 {
		t.Fatal("trusted contract replaced")
	}
	r := executeRun(t, e, newRun(t, e, output))
	if r.Status != "accepted" || r.Operations != 4 {
		t.Fatalf("prepared profile failed: %+v", r)
	}
	summary, err := e.Summary(r.ID)
	if err != nil || len(summary.Preflight) != 1 || summary.Preflight[0].PreflightIndex == nil || !filepath.IsAbs(summary.Preflight[0].Log) || summary.History.PreflightOperations != 1 {
		t.Fatalf("preflight diagnostics missing: %+v %v", summary, err)
	}
	if _, err := PrepareProductTask(path, output, ProductOptions{Profiles: []string{"lint"}, CheckTimeoutSeconds: 5}); err == nil {
		t.Fatal("overwrote frozen product task")
	}
	// A host runner's real failure must not be converted into success by the wrapper.
	if err := os.WriteFile(filepath.Join(tools, "npm"), []byte("#!/bin/sh\nif [ \"$1\" = --version ]; then exit 0; fi\nexit 39\n"), 0700); err != nil {
		t.Fatal(err)
	}
	second := newRun(t, e, output)
	second = executeRun(t, e, second)
	if second.Status != "blocked" || second.Evidence[len(second.Evidence)-1].ExitCode != 39 || second.Reason != "command-failed" {
		t.Fatalf("host exit code hidden: %+v", second)
	}
}

func TestPreparedProfileCannotBypassOriginalFailingReproducer(t *testing.T) {
	e, path, task, tools := productFixture(t)
	task.Checks[0] = Action{Command: []string{"/bin/sh", "-c", "exit 9"}, TimeoutSeconds: 3}
	writeTask(t, path, task)
	output := filepath.Join(filepath.Dir(path), "product.json")
	if _, err := PrepareProductTask(path, output, ProductOptions{Profiles: []string{"lint"}, ToolDirectories: []string{tools}, CheckTimeoutSeconds: 5}); err != nil {
		t.Fatal(err)
	}
	r := executeRun(t, e, newRun(t, e, output))
	if r.Status != "blocked" || r.Operations != 2 || r.Evidence[1].ExitCode != 9 {
		t.Fatalf("original check bypassed: %+v", r)
	}
}

func TestGeneratedRunnerIsFrozenAndMissingToolsNeverReachSourceChecks(t *testing.T) {
	e, path, _, tools := productFixture(t)
	output := filepath.Join(filepath.Dir(path), "product.json")
	generated, err := PrepareProductTask(path, output, ProductOptions{Profiles: []string{"lint"}, ToolDirectories: []string{tools}, CheckTimeoutSeconds: 5})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(tools, "node"), []byte("#!/bin/sh\nexit 17\n"), 0700); err != nil {
		t.Fatal(err)
	}
	r := executeRun(t, e, newRun(t, e, output))
	if r.Status != "blocked" || r.Reason != "prerequisite-failed" || r.Operations != 1 || r.Evidence[0].ExitCode != 78 {
		t.Fatalf("missing host reached source: %+v", r)
	}
	if err := os.WriteFile(filepath.Join(generated.Workspace, "scripts/product-check.sh"), []byte("exit 0\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := e.New(output); err == nil || err.Error() != "protected-file-modified" {
		t.Fatalf("runner mutation accepted: %v", err)
	}
}

func TestProductPreparationRejectsUnknownDuplicateAndImpossiblePlans(t *testing.T) {
	_, path, _, tools := productFixture(t)
	for _, profiles := range [][]string{{"unknown"}, {"lint", "lint"}, nil} {
		output := filepath.Join(filepath.Dir(path), "invalid.json")
		if _, err := PrepareProductTask(path, output, ProductOptions{Profiles: profiles, ToolDirectories: []string{tools}, CheckTimeoutSeconds: 5}); err == nil {
			t.Fatal("invalid profile accepted")
		}
		if _, err := os.Stat(output); !os.IsNotExist(err) {
			t.Fatal("invalid plan emitted")
		}
	}
}

func TestProductApplePreflightRefusesNonMacHost(t *testing.T) {
	e, path, task, tools := productFixture(t)
	if err := os.WriteFile(filepath.Join(tools, "uname"), []byte("#!/bin/sh\necho Linux\n"), 0700); err != nil {
		t.Fatal(err)
	}
	command := []string{"/usr/bin/env", "PATH=" + tools + ":/usr/bin:/bin", "/bin/sh", filepath.Join(task.Workspace, "scripts/product-check.sh"), "preflight", "ios-simulator"}
	result := execute(context.Background(), task.Workspace, Action{Command: command, TimeoutSeconds: 3}, nil, 4096, nil)
	if result.exitCode != 78 || !strings.Contains(string(result.stderr), "require macOS") {
		t.Fatalf("wrong external boundary: %+v", result)
	}
	_ = e
	_ = path
}

func TestAppleProfileProtectsBundleRegressionAndPackager(t *testing.T) {
	for _, relative := range []string{"apple/scripts/test-macos-bundle.sh", "apple/scripts/build-macos-app.sh"} {
		t.Run(relative, func(t *testing.T) {
			e, input, task, tools := productFixture(t)
			output := filepath.Join(filepath.Dir(input), "apple.json")
			if _, err := PrepareProductTask(input, output, ProductOptions{Profiles: []string{"apple-tests"}, ToolDirectories: []string{tools}, CheckTimeoutSeconds: 5}); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(task.Workspace, relative), []byte("#!/bin/sh\nexit 0\n"), 0600); err != nil {
				t.Fatal(err)
			}
			if _, err := e.New(output); err == nil || err.Error() != "protected-file-modified" {
				t.Fatalf("nested bundle control mutation accepted: %v", err)
			}
		})
	}
}

func TestAppleTestsPreflightRequiresBundleCompiler(t *testing.T) {
	_, _, task, tools := productFixture(t)
	for name, body := range map[string]string{
		"uname": "#!/bin/sh\necho Darwin\n",
		"swift": "#!/bin/sh\necho fixture-swift\n",
		"xcrun": "#!/bin/sh\n[ \"$2\" = swift ]\n",
	} {
		if err := os.WriteFile(filepath.Join(tools, name), []byte(body), 0700); err != nil {
			t.Fatal(err)
		}
	}
	command := []string{"/usr/bin/env", "PATH=" + tools + ":/usr/bin:/bin", "/bin/sh", filepath.Join(task.Workspace, "scripts/product-check.sh"), "preflight", "apple-tests"}
	result := execute(context.Background(), task.Workspace, Action{Command: command, TimeoutSeconds: 3}, nil, 4096, nil)
	if result.exitCode != 78 || !strings.Contains(string(result.stderr), "Clang for bundle regression") {
		t.Fatalf("missing bundle compiler reached source checks: %+v", result)
	}
}
