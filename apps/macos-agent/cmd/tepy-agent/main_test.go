package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/lpxxn/tepy/apps/macos-agent/internal/config"
	"github.com/lpxxn/tepy/apps/macos-agent/internal/model"
)

// execute 与 readReport 的输出只在当前测试捕获，不打印原始响应或凭据。
func capture(t *testing.T, run func() error) ([]byte, error) {
	t.Helper()
	file, err := os.CreateTemp(t.TempDir(), "stdout")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	previous := os.Stdout
	os.Stdout = file
	defer func() { os.Stdout = previous }()
	result := run()
	_, _ = file.Seek(0, 0)
	body, err := io.ReadAll(file)
	if err != nil {
		t.Fatal(err)
	}
	return body, result
}

func TestDoctorReturnsStructuredReportWhenConfigurationIsMissing(t *testing.T) {
	body, err := capture(t, func() error {
		return execute([]string{"doctor", "-offline", "-config", filepath.Join(t.TempDir(), "missing.toml")})
	})
	var report model.DiagnosticReport
	if err == nil || json.Unmarshal(body, &report) != nil || report.Source != "doctor" || report.Status != "error" || report.Checks[0].Code != "configuration_invalid" {
		t.Fatal("missing structured failure")
	}
	if err := execute([]string{"status", "-offline"}); err == nil {
		t.Fatal("unsupported flags accepted")
	}
}

func TestReportCLIUsesBearerAndRejectsWrongIdentity(t *testing.T) {
	c := config.Default()
	c.AgentID = "mac-test"
	c.HTTP.Token = "example-test-token-never-reflected"
	var wrong atomic.Bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+c.HTTP.Token || r.URL.Query().Has("token") {
			t.Error("incorrect authentication")
		}
		id := c.AgentID
		if wrong.Load() {
			id = "mac-other"
		}
		if r.URL.Path == "/api/v1/agent/events" {
			_ = json.NewEncoder(w).Encode(model.EventPage{V: 1, AgentID: id, Capacity: 200, Events: []model.Event{}})
		} else {
			_ = json.NewEncoder(w).Encode(model.DiagnosticReport{V: 1, AgentID: id, Source: "live", Checks: []model.Check{}})
		}
	}))
	defer server.Close()
	c.HTTP.Listen = strings.TrimPrefix(server.URL, "http://")
	for _, path := range []string{"/api/v1/agent/diagnostics", "/api/v1/agent/events?limit=50"} {
		body, err := capture(t, func() error { return readReport(c, path) })
		if err != nil || !json.Valid(body) || strings.Contains(string(body), c.HTTP.Token) {
			t.Fatal("invalid CLI response")
		}
		wrong.Store(true)
		body, err = capture(t, func() error { return readReport(c, path) })
		if err == nil || len(body) != 0 {
			t.Fatal("wrong agent accepted")
		}
		wrong.Store(false)
	}
}
