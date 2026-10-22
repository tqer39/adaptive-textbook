package harness

import "encoding/json"

func safeServerRequestMethod(method string) string {
	switch method {
	case "item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/tool/requestUserInput", "mcpServer/elicitation/request", "item/permissions/requestApproval", "account/chatgptAuthTokens/refresh":
		return method
	default:
		return "unknown"
	}
}

// Preserve public error categories, never upstream messages or additionalDetails.
func recordTurnMetadata(meta *ModelMetadata, turn codexTurn) {
	switch turn.Status {
	case "completed", "failed", "interrupted", "inProgress":
		meta.TurnStatus = turn.Status
	default:
		meta.TurnStatus = "unknown"
	}
	meta.CodexErrorInfo = ""
	meta.ErrorHTTPStatus = nil
	if turn.Error == nil || len(turn.Error.Info) == 0 || string(turn.Error.Info) == "null" {
		return
	}
	meta.CodexErrorInfo = "unknown"
	var code string
	if json.Unmarshal(turn.Error.Info, &code) == nil {
		switch code {
		case "contextWindowExceeded", "sessionBudgetExceeded", "usageLimitExceeded", "serverOverloaded", "cyberPolicy", "misalignmentPolicyViolation", "internalServerError", "unauthorized", "badRequest", "threadRollbackFailed", "sandboxError", "other":
			meta.CodexErrorInfo = code
		}
		return
	}
	var variants map[string]json.RawMessage
	if json.Unmarshal(turn.Error.Info, &variants) != nil || len(variants) != 1 {
		return
	}
	for name, data := range variants {
		switch name {
		case "httpConnectionFailed", "responseStreamConnectionFailed", "responseStreamDisconnected", "responseTooManyFailedAttempts", "activeTurnNotSteerable":
			meta.CodexErrorInfo = name
		default:
			return
		}
		var detail struct {
			HTTP *int `json:"httpStatusCode"`
		}
		if json.Unmarshal(data, &detail) == nil && detail.HTTP != nil && *detail.HTTP >= 100 && *detail.HTTP <= 599 {
			meta.ErrorHTTPStatus = detail.HTTP
		}
	}
}
