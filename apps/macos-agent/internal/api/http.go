package api

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/lpxxn/tepy/apps/macos-agent/internal/model"
)

func Handler(token string, state func() model.State) http.Handler {
	expected := sha256.Sum256([]byte(token))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		// No browser CORS / cross-origin access and no mutation endpoints.
		if r.Header.Get("Origin") != "" {
			w.WriteHeader(http.StatusForbidden)
			_, _ = w.Write([]byte(`{"error":"origin_forbidden"}`))
			return
		}
		authorization := r.Header.Get("Authorization")
		actual := sha256.Sum256([]byte(strings.TrimPrefix(authorization, "Bearer ")))
		if len(authorization) > 160 || !strings.HasPrefix(authorization, "Bearer ") || subtle.ConstantTimeCompare(actual[:], expected[:]) != 1 {
			w.WriteHeader(http.StatusUnauthorized)
			_, _ = w.Write([]byte(`{"error":"unauthorized"}`))
			return
		}
		if r.URL.Path != "/api/v1/agent/status" || r.URL.RawQuery != "" {
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"error":"not_found"}`))
			return
		}
		if r.Method != http.MethodGet {
			w.Header().Set("Allow", "GET")
			w.WriteHeader(http.StatusMethodNotAllowed)
			_, _ = w.Write([]byte(`{"error":"method_not_allowed"}`))
			return
		}
		if r.ContentLength != 0 || len(r.TransferEncoding) != 0 {
			w.WriteHeader(http.StatusBadRequest)
			_, _ = w.Write([]byte(`{"error":"unexpected_body"}`))
			return
		}
		current := state()
		if current.ObservedAt == 0 || current.ValidUntil <= time.Now().UnixMilli() {
			w.WriteHeader(http.StatusServiceUnavailable)
			_, _ = w.Write([]byte(`{"error":"state_stale"}`))
			return
		}
		_ = json.NewEncoder(w).Encode(current)
	})
}
func Server(address, token string, state func() model.State) *http.Server {
	return &http.Server{Addr: address, Handler: Handler(token, state), ReadHeaderTimeout: 3 * time.Second,
		ReadTimeout: 5 * time.Second, WriteTimeout: 5 * time.Second, IdleTimeout: 15 * time.Second, MaxHeaderBytes: 4096}
}
