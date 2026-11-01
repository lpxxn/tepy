package diagnostics

import (
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/eclipse/paho.mqtt.golang/packets"
	"github.com/lpxxn/tepy/apps/macos-agent/internal/model"
)

func TestNetworkErrorsAreClassifiedWithoutReflectingInput(t *testing.T) {
	for _, test := range []struct {
		err  error
		code string
	}{
		{packets.ErrorRefusedBadUsernameOrPassword, "mqtt_bad_credentials"},
		{fmt.Errorf("wrapped: %w", packets.ErrorRefusedNotAuthorised), "mqtt_not_authorized"},
		{&net.DNSError{Err: "sensitive-host"}, "dns_lookup_failed"},
		{x509.UnknownAuthorityError{}, "tls_ca_untrusted"},
		{x509.HostnameError{}, "tls_hostname_mismatch"},
		{x509.CertificateInvalidError{Reason: x509.Expired}, "tls_certificate_expired"},
		{errors.New("password=NeverReflectMe"), "mqtt_connection_failed"},
	} {
		if actual := ErrorCode(test.err); actual != test.code {
			t.Fatal(actual, test.code)
		}
		encoded, _ := json.Marshal(Check("mqtt", "error", ErrorCode(test.err)))
		if strings.Contains(string(encoded), "NeverReflectMe") || strings.Contains(string(encoded), "sensitive-host") {
			t.Fatal("reflected error")
		}
	}
	if Check("mqtt", "error", "NeverReflectMe").Code != "mqtt_connection_failed" {
		t.Fatal("unknown message accepted")
	}
}

func TestLiveDiagnosticLeaseAndInactiveSession(t *testing.T) {
	yes := true
	now := time.Now()
	state := model.State{V: 1, AgentID: "mac-test", AgentVersion: "test", Session: strings.Repeat("a", 32), ObservedAt: now.UnixMilli(), ValidUntil: now.Add(time.Minute).UnixMilli(),
		UserSession: model.Session{Available: true, OnConsole: &yes, LoginDone: &yes, LockState: "locked"}, HID: model.HID{Available: true, State: "registered"}, Power: model.Power{Monitoring: true}}
	state.MQTT.Configured = true
	r := Live(state, model.ConnectionStatus{Connected: true}, now)
	if r.Status != "ok" || r.Source != "live" || r.ValidUntil != state.ValidUntil {
		t.Fatal(r)
	}
	state.ValidUntil = 1
	r = Live(state, model.ConnectionStatus{ErrorCode: "mqtt_bad_credentials"}, now)
	if r.Status != "error" || r.Checks[0].Code != "agent_state_stale" || r.Checks[1].Code != "mqtt_bad_credentials" {
		t.Fatal(r)
	}
	no := false
	state.UserSession.OnConsole = &no
	r = Live(state, model.ConnectionStatus{}, now)
	for _, check := range r.Checks {
		if check.Code == "screen_locked" {
			t.Fatal("inactive console presented as current lock")
		}
	}
}
