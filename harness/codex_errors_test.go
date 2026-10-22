package harness

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestServerRequestMethodMetadataIsAllowlisted(t *testing.T) {
	if got := safeServerRequestMethod("item/permissions/requestApproval"); got != "item/permissions/requestApproval" {
		t.Fatal(got)
	}
	if got := safeServerRequestMethod("private-method-placeholder"); got != "unknown" {
		t.Fatal("untrusted method leaked")
	}
}

func TestSafeTurnFailureClassification(t *testing.T) {
	for _, tc := range []struct {
		status, info, want string
		http               int
	}{
		{"failed", `"sandboxError"`, "sandboxError", 0},
		{"failed", `{"responseTooManyFailedAttempts":{"httpStatusCode":429,"message":"private-error-placeholder"}}`, "responseTooManyFailedAttempts", 429},
		{"failed", `"private-error-placeholder"`, "unknown", 0},
		{"failed", `{"private-error-placeholder":{}}`, "unknown", 0},
		{"interrupted", `null`, "", 0},
	} {
		t.Run(tc.want+tc.status, func(t *testing.T) {
			data := []byte(`{"id":"turn","status":"` + tc.status + `","items":[],"error":{"message":"private-error-placeholder","additionalDetails":"private-error-placeholder","codexErrorInfo":` + tc.info + `}}`)
			var turn codexTurn
			if err := json.Unmarshal(data, &turn); err != nil {
				t.Fatal(err)
			}
			meta := &ModelMetadata{}
			recordTurnMetadata(meta, turn)
			if meta.TurnStatus != tc.status || meta.CodexErrorInfo != tc.want {
				t.Fatalf("wrong classification: %+v", meta)
			}
			if tc.http != 0 && (meta.ErrorHTTPStatus == nil || *meta.ErrorHTTPStatus != tc.http) {
				t.Fatalf("missing safe HTTP classification: %+v", meta)
			}
			if tc.http == 0 && meta.ErrorHTTPStatus != nil {
				t.Fatal("unexpected HTTP metadata")
			}
			_, err := turnText(turn)
			want := "codex-turn-" + tc.status
			if err == nil || err.Error() != want {
				t.Fatalf("turn status conflated: %v", err)
			}
			stored, _ := json.Marshal(meta)
			if strings.Contains(string(stored), "private-error-placeholder") {
				t.Fatal("raw error leaked")
			}
		})
	}
}
