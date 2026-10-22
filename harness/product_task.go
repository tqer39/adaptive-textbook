package harness

import (
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type ProductOptions struct {
	Profiles              []string
	ToolDirectories       []string
	Files                 []string
	ExternalPrerequisites []string
	CheckTimeoutSeconds   int
}

// PrepareProductTask adds maintained checks without replacing the user's fixed contract.
// No command or model is dispatched here; preflight runs as budgeted Engine operations.
func PrepareProductTask(input, output string, options ProductOptions) (Task, error) {
	task, _, originalHash, err := LoadTask(input)
	if err != nil {
		return task, err
	}
	if err := verifySnapshots(task.ProtectedFiles); err != nil {
		return task, err
	}
	if len(options.Profiles) == 0 || len(options.Profiles) > 5 || len(options.ToolDirectories) > 16 || options.CheckTimeoutSeconds < 1 || options.CheckTimeoutSeconds > task.TimeoutSeconds {
		return task, errors.New("product-options-invalid")
	}
	pathParts := []string{}
	for _, directory := range options.ToolDirectories {
		real, err := filepath.EvalSymlinks(directory)
		info, statErr := os.Stat(directory)
		if !filepath.IsAbs(directory) || filepath.Clean(directory) != directory || strings.Contains(directory, ":") || err != nil || real != directory || statErr != nil || !info.IsDir() {
			return task, errors.New("product-tool-directory-invalid")
		}
		pathParts = append(pathParts, directory)
	}
	pathParts = append(pathParts, "/usr/bin", "/bin", "/usr/sbin", "/sbin")
	runner := filepath.Join(task.Workspace, "scripts/product-check.sh")
	controls := map[string]bool{runner: true}
	addControls := func(paths ...string) {
		for _, path := range paths {
			controls[filepath.Join(task.Workspace, path)] = true
		}
	}
	addControls("AGENTS.md", ".agents/skills/harness-development/SKILL.md", ".agents/skills/independent-review/SKILL.md")
	seen := map[string]bool{}
	for _, profile := range options.Profiles {
		if seen[profile] {
			return task, errors.New("product-profile-duplicate")
		}
		seen[profile] = true
		var artifacts []string
		switch profile {
		case "lint":
			addControls("package.json", "package-lock.json", "scripts/check-docs.mjs", "docs/rules/documentation.md")
		case "harness":
			addControls("scripts/check-harness.sh", "harness/go.mod")
		case "apple-tests":
			addControls("apple/scripts/check-native.sh", "apple/Package.swift", ".agents/skills/apple-native-validation/SKILL.md")
		case "macos-app":
			addControls("apple/scripts/build-macos-app.sh", "apple/Package.swift", ".agents/skills/apple-native-validation/SKILL.md")
			artifacts = []string{".local-state/product-build/macos/TsumikiText.app"}
		case "ios-simulator":
			addControls("apple/scripts/check-native.sh", "apple/TsumikiText.xcodeproj/project.pbxproj", ".agents/skills/apple-native-validation/SKILL.md")
			artifacts = []string{".local-state/product-build/ios/Build/Products/Debug-iphonesimulator/TsumikiText.app"}
		default:
			return task, errors.New("product-profile-unknown")
		}
		command := []string{"/usr/bin/env", "PATH=" + strings.Join(pathParts, ":"), "/bin/sh", runner}
		preflight := append(append([]string{}, command...), "preflight", profile)
		check := append(append([]string{}, command...), "check", profile)
		timeout := options.CheckTimeoutSeconds
		if timeout > 30 {
			timeout = 30
		}
		task.Preflight = append(task.Preflight, Action{Command: preflight, TimeoutSeconds: timeout})
		task.Checks = append(task.Checks, Action{Command: check, TimeoutSeconds: options.CheckTimeoutSeconds, PrerequisiteExitCode: 78, Artifacts: artifacts})
	}
	for _, file := range options.Files {
		controls[file] = true
	}
	existing := map[string]bool{}
	for _, file := range task.ProtectedFiles {
		existing[file.Path] = true
	}
	for path := range controls {
		if existing[path] {
			continue
		}
		snapshot, err := SnapshotFile(path)
		if err != nil {
			return task, err
		}
		task.ProtectedFiles = append(task.ProtectedFiles, snapshot)
	}
	sort.Slice(task.ProtectedFiles, func(i, j int) bool { return task.ProtectedFiles[i].Path < task.ProtectedFiles[j].Path })
	task.ExternalPrerequisites = append(task.ExternalPrerequisites, options.ExternalPrerequisites...)
	minimum := len(task.Preflight) + len(task.Checks) + 1
	if task.Implement != nil {
		minimum++
	}
	if minimum > task.MaxOperations {
		return task, errors.New("product-operation-budget-insufficient")
	}
	if err := task.validate(); err != nil {
		return task, err
	}
	_, _, currentHash, err := LoadTask(input)
	if err != nil || currentHash != originalHash {
		return task, errors.New("fixed-task-modified")
	}
	if err := verifySnapshots(task.ProtectedFiles); err != nil {
		return task, err
	}
	return writeNewTask(task, output)
}
