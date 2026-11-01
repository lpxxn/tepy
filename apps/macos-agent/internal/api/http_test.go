package api

import (
	"encoding/json"
	"fmt"
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

func TestDiagnosticsAndEventQueryAreAuthenticatedBoundedAndReadOnly(t *testing.T) {
	const token = "test-token-only-used-by-this-test"
	const session = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	j := model.NewJournal("mac-test", session)
	for i := 0; i < 230; i++ {
		j.Append("did_wake", "sleeping", "awake", "", 1)
	}
	// 采样已过期仍允许取诊断与历史，以便定位故障；原 status 仍应返回 503。
	state := model.State{V: 1, AgentID: "mac-test", ValidUntil: 1}
	handler := Handler(token, func() model.State { return state }, Sources{Events: j, Diagnostics: func() model.DiagnosticReport {
		return model.DiagnosticReport{V: 1, AgentID: "mac-test", Status: "error", Source: "live", Checks: []model.Check{}}
	}})
	for _, path := range []string{"/api/v1/agent/events", "/api/v1/agent/diagnostics"} {
		for _, test := range []struct {
			method, auth, body, origin string
			code                       int
		}{
			{"GET", token, "", "", 200}, {"GET", "", "", "", 401}, {"POST", token, "", "", 405}, {"GET", token, "x", "", 400}, {"GET", token, "", "http://untrusted", 403},
		} {
			r := httptest.NewRequest(test.method, path, strings.NewReader(test.body))
			r.Header.Set("Authorization", "Bearer "+test.auth)
			r.Header.Set("Origin", test.origin)
			w := httptest.NewRecorder()
			handler.ServeHTTP(w, r)
			if w.Code != test.code || strings.Contains(w.Body.String(), token) || w.Header().Get("Cache-Control") != "no-store" {
				t.Fatal(w.Code, w.Body.String())
			}
		}
	}
	for query, expected := range map[string]int{
		"?limit=0": 400, "?limit=201": 400, "?limit=2&limit=3": 400, "?limit=99999999999999999999": 400,
		"?after=1": 400, "?after=-1&session=" + session: 400, "?after=18446744073709551616&session=" + session: 400,
		"?session=other": 400, "?token=" + token: 400, "?limit=3;after=1": 400,
		"?session=" + strings.Repeat("b", 32): 409, "?after=231&session=" + session: 409,
		"?after=0&limit=10&session=" + session: 200,
	} {
		r := httptest.NewRequest("GET", "/api/v1/agent/events"+query, nil)
		r.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		if w.Code != expected || strings.Contains(w.Body.String(), token) {
			t.Fatal(query, w.Code, w.Body.String())
		}
		if expected == 200 {
			var page model.EventPage
			if json.Unmarshal(w.Body.Bytes(), &page) != nil || !page.Truncated || !page.HasMore || len(page.Events) != 10 || page.NextAfter != 40 {
				t.Fatal(fmt.Sprint(page))
			}
		}
	}
}
