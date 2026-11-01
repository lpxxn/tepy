package api

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/lpxxn/tepy/apps/macos-agent/internal/model"
)

type Sources struct {
	Diagnostics func() model.DiagnosticReport
	Events      *model.Journal
}

func Handler(token string, state func() model.State, sources ...Sources) http.Handler {
	var extra Sources
	if len(sources) > 0 {
		extra = sources[0]
	}
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
		path := r.URL.Path
		available := path == "/api/v1/agent/status" || (path == "/api/v1/agent/diagnostics" && extra.Diagnostics != nil) || (path == "/api/v1/agent/events" && extra.Events != nil)
		if !available || (path != "/api/v1/agent/events" && (r.URL.RawQuery != "" || r.URL.ForceQuery)) {
			failure(w, http.StatusNotFound, "not_found")
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
		if path == "/api/v1/agent/diagnostics" {
			_ = json.NewEncoder(w).Encode(extra.Diagnostics())
			return
		}
		if path == "/api/v1/agent/events" {
			query, err := parseEventsQuery(r)
			if err != nil {
				failure(w, http.StatusBadRequest, "invalid_query")
				return
			}
			page, err := extra.Events.Read(query.after, query.limit, query.session)
			if err == model.ErrEventSession {
				failure(w, http.StatusConflict, "event_session_changed")
				return
			}
			if err == model.ErrEventCursor {
				failure(w, http.StatusConflict, "event_cursor_ahead")
				return
			}
			if err != nil {
				failure(w, http.StatusBadRequest, "invalid_query")
				return
			}
			_ = json.NewEncoder(w).Encode(page)
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
func Server(address, token string, state func() model.State, sources ...Sources) *http.Server {
	return &http.Server{Addr: address, Handler: Handler(token, state, sources...), ReadHeaderTimeout: 3 * time.Second,
		ReadTimeout: 5 * time.Second, WriteTimeout: 5 * time.Second, IdleTimeout: 15 * time.Second, MaxHeaderBytes: 4096}
}

func failure(w http.ResponseWriter, status int, code string) {
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": code})
}

type eventQuery struct {
	after   *uint64
	limit   int
	session string
}

var sessionID = regexp.MustCompile(`^[a-f0-9]{32}$`)
var unsigned = regexp.MustCompile(`^[0-9]{1,20}$`)

func parseEventsQuery(r *http.Request) (eventQuery, error) {
	result := eventQuery{limit: 50}
	values, err := url.ParseQuery(r.URL.RawQuery)
	if err != nil {
		return result, err
	}
	for key, items := range values {
		if len(items) != 1 {
			return result, errors.New("invalid_query")
		}
		value := items[0]
		switch key {
		case "session":
			if !sessionID.MatchString(value) {
				return result, errors.New("invalid_query")
			}
			result.session = value
		case "limit":
			if !unsigned.MatchString(value) {
				return result, errors.New("invalid_query")
			}
			result.limit, err = strconv.Atoi(value)
			if err != nil || result.limit < 1 || result.limit > model.EventCapacity {
				return result, errors.New("invalid_query")
			}
		case "after":
			if !unsigned.MatchString(value) {
				return result, errors.New("invalid_query")
			}
			cursor, parseErr := strconv.ParseUint(value, 10, 64)
			if parseErr != nil {
				return result, parseErr
			}
			result.after = &cursor
		default:
			return result, errors.New("invalid_query")
		}
	}
	if result.after != nil && result.session == "" {
		return result, errors.New("invalid_query")
	}
	return result, nil
}
