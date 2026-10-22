//go:build darwin || linux

package harness

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

const sysNoFollow = syscall.O_NOFOLLOW

func lockFile(path string) (*os.File, error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR|sysNoFollow, 0o600)
	if err != nil {
		return nil, errors.New("lock-open-failed")
	}
	if syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB) != nil {
		f.Close()
		return nil, errors.New("already-running")
	}
	return f, nil
}

func unlockFile(f *os.File) { _ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN); _ = f.Close() }

func gitOutput(workspace string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	base := []string{"-C", workspace, "-c", "core.fsmonitor=false"}
	base = append(base, args...)
	cmd := exec.CommandContext(ctx, "/usr/bin/git", base...)
	cmd.Env = []string{"PATH=/usr/bin:/bin", "LC_ALL=C", "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null", "GIT_OPTIONAL_LOCKS=0"}
	out, err := cmd.Output()
	if err != nil {
		return nil, errors.New("workspace-git-failed")
	}
	return out, nil
}

func workspaceLock(workspace string) (*os.File, error) {
	rootPath, err := gitRoot(workspace)
	if err != nil {
		return nil, err
	}
	// A per-user fixed root coordinates different state directories without writing .git.
	root := filepath.Join("/tmp", fmt.Sprintf("adaptive-harness-locks-%d", os.Getuid()))
	if err := os.Mkdir(root, 0o700); err != nil && !os.IsExist(err) {
		return nil, errors.New("workspace-lock-root-failed")
	}
	info, err := os.Lstat(root)
	if err != nil || !info.IsDir() || info.Mode().Perm()&0o077 != 0 {
		return nil, errors.New("workspace-lock-root-unsafe")
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != uint32(os.Getuid()) {
		return nil, errors.New("workspace-lock-owner-invalid")
	}
	return lockFile(filepath.Join(root, digest([]byte(rootPath))+".lock"))
}

func gitRoot(workspace string) (string, error) {
	data, err := gitOutput(workspace, "rev-parse", "--show-toplevel")
	if err != nil {
		return "", err
	}
	root, err := filepath.EvalSymlinks(strings.TrimSpace(string(data)))
	if err != nil || root != workspace {
		return "", errors.New("workspace-must-be-git-root")
	}
	return root, nil
}

// Hash tracked and nonignored untracked files, including modes/deletions/symlink targets.
// Ignored build outputs and local secrets are deliberately outside this code identity.
func CodeHash(workspace string) (string, error) {
	out, err := gitOutput(workspace, "ls-files", "--cached", "--others", "--exclude-standard", "--deduplicate", "-z")
	if err != nil {
		return "", err
	}
	files := strings.Split(string(out), "\x00")
	sort.Strings(files)
	h := sha256.New()
	h.Write([]byte("adaptive-harness-code-hash-v2\x00"))
	var total int64
	for _, name := range files {
		if name == "" {
			continue
		}
		if filepath.IsAbs(name) || strings.HasPrefix(filepath.Clean(name), ".."+string(filepath.Separator)) {
			return "", errors.New("workspace-path-invalid")
		}
		path := filepath.Join(workspace, name)
		info, err := os.Lstat(path)
		if os.IsNotExist(err) {
			fmt.Fprintf(h, "%s\x00deleted\x00", name)
			continue
		}
		if err != nil {
			return "", errors.New("code-hash-failed")
		}
		fmt.Fprintf(h, "%s\x00%d\x00", name, info.Mode())
		if info.Mode()&os.ModeSymlink != 0 {
			target, err := os.Readlink(path)
			if err != nil {
				return "", err
			}
			fmt.Fprintf(h, "%s\x00", target)
			continue
		}
		if !info.Mode().IsRegular() || info.Size() > 16*1024*1024 {
			return "", errors.New("code-file-unsupported")
		}
		total += info.Size()
		if total > 128*1024*1024 {
			return "", errors.New("code-size-limit")
		}
		f, err := os.OpenFile(path, os.O_RDONLY|sysNoFollow, 0)
		if err != nil {
			return "", errors.New("code-read-failed")
		}
		fileHash := sha256.New()
		_, err = io.Copy(fileHash, io.LimitReader(f, 16*1024*1024+1))
		f.Close()
		if err != nil {
			return "", err
		}
		h.Write(fileHash.Sum(nil))
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// No inherited environment, API keys, proxy settings, shell startup files, or HOME.
func cleanEnvironment(home string) []string {
	return []string{"PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=" + home, "TMPDIR=" + home, "LANG=C", "LC_ALL=C", "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null"}
}

var secretPattern = regexp.MustCompile(`(?i)(sk-[a-z0-9_-]{10,}|bearer[ \t]+[a-z0-9._~+/-]{8,}|(?:api[_-]?key|token|secret|password)[ \t]*[=:][ \t]*[^\s,;"']+)`)

func redact(data []byte) []byte { return secretPattern.ReplaceAll(data, []byte("[REDACTED]")) }

type capture struct {
	mu             sync.Mutex
	stdout, stderr bytes.Buffer
	used, limit    int
	overflow       bool
	cancel         context.CancelFunc
}
type captureWriter struct {
	capture *capture
	stderr  bool
}

func (w captureWriter) Write(p []byte) (int, error) {
	c := w.capture
	c.mu.Lock()
	defer c.mu.Unlock()
	available := c.limit - c.used
	n := len(p)
	if n > available {
		n = available
		c.overflow = true
		c.cancel()
	}
	if w.stderr {
		c.stderr.Write(p[:n])
	} else {
		c.stdout.Write(p[:n])
	}
	c.used += n
	return len(p), nil
}

func configureProcess(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		err := syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		if err == syscall.ESRCH {
			return os.ErrProcessDone
		}
		return err
	}
	cmd.WaitDelay = 300 * time.Millisecond
}

type processResult struct {
	stdout   []byte
	stderr   []byte
	exitCode int
	outcome  string
	duration time.Duration
}

func execute(ctx context.Context, workspace string, action Action, input []byte, limit int, extraEnv []string) processResult {
	started := time.Now()
	ctx, cancel := context.WithTimeout(ctx, time.Duration(action.TimeoutSeconds)*time.Second)
	defer cancel()
	home, err := os.MkdirTemp("", "adaptive-harness-home-")
	if err != nil {
		return processResult{exitCode: -1, outcome: "home-create-failed"}
	}
	defer os.RemoveAll(home)
	cmd := exec.CommandContext(ctx, action.Command[0], action.Command[1:]...)
	cmd.Dir = workspace
	cmd.Env = append(cleanEnvironment(home), extraEnv...)
	cmd.Stdin = bytes.NewReader(input)
	c := &capture{limit: limit, cancel: cancel}
	cmd.Stdout = captureWriter{capture: c}
	cmd.Stderr = captureWriter{capture: c, stderr: true}
	configureProcess(cmd)
	err = cmd.Run()
	// Clean up grandchildren even when their parent exited while retaining a pipe.
	if cmd.Process != nil {
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	}
	code := -1
	if cmd.ProcessState != nil {
		code = cmd.ProcessState.ExitCode()
	}
	outcome := "complete"
	if err != nil {
		outcome = "command-failed"
	}
	if ctx.Err() != nil {
		outcome = "interrupted"
	}
	if c.overflow {
		outcome = "log-limit"
	}
	return processResult{stdout: c.stdout.Bytes(), stderr: c.stderr.Bytes(), exitCode: code, outcome: outcome, duration: time.Since(started)}
}

func writeEvidenceLog(path string, result processResult) (string, error) {
	data, _ := json.Marshal(struct {
		Stdout string `json:"stdout"`
		Stderr string `json:"stderr"`
	}{string(redact(result.stdout)), string(redact(result.stderr))})
	f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY|sysNoFollow, 0o600)
	if err != nil {
		return "", errors.New("evidence-write-failed")
	}
	defer f.Close()
	if _, err = f.Write(data); err != nil {
		return "", err
	}
	if err = f.Sync(); err != nil {
		return "", err
	}
	return digest(data), nil
}
