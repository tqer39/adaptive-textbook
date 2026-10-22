package harness

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// Put the newest check failure in the repair handoff. Paths alone left the
// repair agent working from an older failure after the compiler moved on.
// The original, hash-bound log remains authoritative; only bounded tails are sent.
func latestCheckDiagnostic(directory string, evidence []Evidence) (string, error) {
	for i := len(evidence) - 1; i >= 0; i-- {
		proof := evidence[i]
		if proof.Phase != "checks" {
			continue
		}
		if proof.ExitCode == 0 && proof.Outcome == "complete" {
			return "", nil
		}
		name := filepath.Clean(proof.Log)
		if filepath.IsAbs(name) || name == ".." || strings.HasPrefix(name, ".."+string(filepath.Separator)) {
			return "", errors.New("invalid-evidence-path")
		}
		f, err := os.Open(filepath.Join(directory, name))
		if err != nil {
			return "", err
		}
		const maximumEvidenceBytes = 8 * 1024 * 1024
		data, err := io.ReadAll(io.LimitReader(f, maximumEvidenceBytes+1))
		f.Close()
		if err != nil || len(data) > maximumEvidenceBytes || digest(data) != proof.LogHash {
			return "", errors.New("evidence-modified")
		}
		var log struct {
			Stdout string `json:"stdout"`
			Stderr string `json:"stderr"`
		}
		if err := strictJSON(data, &log); err != nil {
			return "", err
		}
		const tailBytes = 8 * 1024
		tail := func(value string) string {
			if len(value) > tailBytes {
				value = value[len(value)-tailBytes:]
			}
			return strings.ToValidUTF8(value, "�")
		}
		note, err := json.Marshal(struct {
			Operation int    `json:"operation"`
			CodeHash  string `json:"codeHash"`
			Log       string `json:"log"`
			LogHash   string `json:"logHash"`
			Stdout    string `json:"stdoutTail"`
			Stderr    string `json:"stderrTail"`
			Errors    string `json:"errorExcerpts"`
		}{proof.Operation, proof.CodeHash, proof.Log, proof.LogHash, tail(log.Stdout), tail(log.Stderr), diagnosticErrorExcerpts(log.Stdout, log.Stderr)})
		return string(note), err
	}
	return "", nil
}

// Test runners often print the failing assertion well before their final suite
// summaries. Keep those signals as well as the tails, without sending the log.
func diagnosticErrorExcerpts(streams ...string) string {
	const maximumBytes = 4 * 1024
	var result strings.Builder
	for _, stream := range streams {
		for stream != "" && result.Len() < maximumBytes {
			line, rest, _ := strings.Cut(stream, "\n")
			stream = rest
			lower := strings.ToLower(line)
			if !strings.Contains(lower, "error:") && !strings.Contains(lower, "xctassert") &&
				!strings.Contains(lower, "assertionerror") && !strings.Contains(lower, "fatal error") &&
				!strings.Contains(line, "--- FAIL:") {
				continue
			}
			remaining := maximumBytes - result.Len()
			if len(line)+1 > remaining {
				line = line[:remaining-1]
			}
			result.WriteString(line)
			result.WriteByte('\n')
		}
	}
	return strings.ToValidUTF8(result.String(), "")
}
