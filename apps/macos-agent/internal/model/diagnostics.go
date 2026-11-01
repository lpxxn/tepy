package model

// Check 只包含固定的代码和说明，不接受原始系统异常或配置内容。
// 客户端按 Code 翻译或展示帮助，Status 用于排列问题的严重程度。
type Check struct {
	Component string `json:"component"`
	Status    string `json:"status"`
	Code      string `json:"code"`
	Message   string `json:"message"`
}

type DiagnosticReport struct {
	V            int     `json:"v"`
	AgentID      string  `json:"agent_id"`
	AgentVersion string  `json:"agent_version"`
	Session      string  `json:"session"`
	Source       string  `json:"source"`
	ObservedAt   int64   `json:"observed_at"`
	ValidUntil   int64   `json:"valid_until"`
	Status       string  `json:"status"`
	Checks       []Check `json:"checks"`
}

// ConnectionStatus 是进程内诊断信息，保持旧 MQTT state 的字段完全不变。
type ConnectionStatus struct {
	Connected bool
	ErrorCode string
}
