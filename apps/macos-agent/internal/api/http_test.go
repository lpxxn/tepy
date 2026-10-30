package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/lpxxn/tepy/apps/macos-agent/internal/model"
)

func TestAuthenticatedReadOnlyStatus(t *testing.T) {
	current := model.State{V: 1, AgentID: "mac-test", ObservedAt: time.Now().UnixMilli(), ValidUntil: time.Now().Add(time.Minute).UnixMilli()}
	handler := Handler("sample-token-which-must-not-be-reflected", func() model.State { return current })
	for _, test := range []struct {
		name, method, path, token, origin string
		code                              int
	}{
		{"ok", "GET", "/api/v1/agent/status", "sample-token-which-must-not-be-reflected", "", 200},
		{"missing", "GET", "/api/v1/agent/status", "", "", 401},
		{"wrong", "GET", "/api/v1/agent/status", "wrong", "", 401},
		{"origin", "GET", "/api/v1/agent/status", "sample-token-which-must-not-be-reflected", "http://untrusted", 403},
		{"write", "POST", "/api/v1/agent/status", "sample-token-which-must-not-be-reflected", "", 405},
		{"query", "GET", "/api/v1/agent/status?token=wrong", "sample-token-which-must-not-be-reflected", "", 404},
	} {
		t.Run(test.name, func(t *testing.T) {
			r := httptest.NewRequest(test.method, test.path, nil)
			if test.token != "" {
				r.Header.Set("Authorization", "Bearer "+test.token)
			}
			if test.origin != "" {
				r.Header.Set("Origin", test.origin)
			}
			w := httptest.NewRecorder()
			handler.ServeHTTP(w, r)
			if w.Code != test.code || strings.Contains(w.Body.String(), "sample-token") {
				t.Fatal(w.Code, w.Body.String())
			}
			if w.Header().Get("Cache-Control") != "no-store" {
				t.Fatal("cacheable state")
			}
			if test.code == 200 {
				var state model.State
				if json.Unmarshal(w.Body.Bytes(), &state) != nil || state.AgentID != "mac-test" {
					t.Fatal("bad state")
				}
			}
		})
	}
	current.ValidUntil = 1
	r := httptest.NewRequest("GET", "/api/v1/agent/status", nil)
	r.Header.Set("Authorization", "Bearer sample-token-which-must-not-be-reflected")
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	if w.Code != http.StatusServiceUnavailable {
		t.Fatal("stale state accepted")
	}
}
