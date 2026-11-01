package diagnostics

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/BurntSushi/toml"
	"github.com/eclipse/paho.mqtt.golang/packets"
	"github.com/lpxxn/tepy/apps/macos-agent/internal/config"
	"github.com/lpxxn/tepy/apps/macos-agent/internal/model"
	"github.com/lpxxn/tepy/apps/macos-agent/internal/platform"
)

type doctorProbe struct{}

func (doctorProbe) Sample(string) platform.Snapshot {
	yes := true
	return platform.Snapshot{Session: model.Session{Available: true, OnConsole: &yes, LoginDone: &yes, LockState: "locked"}, HID: model.HID{Available: true, State: "registered"}}
}
func (doctorProbe) Watch(context.Context, chan<- platform.Event) error {
	panic("doctor must not start a watcher")
}

func configFile(t *testing.T, address, ca string) string {
	t.Helper()
	c := config.Default()
	c.AgentID = "mac-test"
	c.HTTP.Token = strings.Repeat("SecretToken", 4)
	c.MQTT.URL = address
	c.MQTT.CAFile = ca
	c.MQTT.Username = "example-user"
	c.MQTT.Password = "NeverReflectMe"
	var buffer bytes.Buffer
	if err := toml.NewEncoder(&buffer).Encode(c); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "agent.toml")
	if err := os.WriteFile(path, buffer.Bytes(), 0600); err != nil {
		t.Fatal(err)
	}
	return path
}
func hasCode(report model.DiagnosticReport, code string) bool {
	for _, check := range report.Checks {
		if check.Code == code {
			return true
		}
	}
	return false
}

type observedConnect struct {
	ID          string
	Clean, Will bool
	Next        byte
}

func wireServer(t *testing.T, options *tls.Config, ack []byte) (string, <-chan observedConnect) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	if options != nil {
		listener = tls.NewListener(listener, options)
	}
	observed := make(chan observedConnect, 4)
	var workers sync.WaitGroup
	var mu sync.Mutex
	var connections []net.Conn
	workers.Add(1)
	go func() {
		defer workers.Done()
		for {
			connection, err := listener.Accept()
			if err != nil {
				return
			}
			mu.Lock()
			connections = append(connections, connection)
			mu.Unlock()
			workers.Add(1)
			go func(c net.Conn) {
				defer workers.Done()
				defer c.Close()
				_ = c.SetDeadline(time.Now().Add(3 * time.Second))
				packet, err := packets.ReadPacket(c)
				if err != nil {
					return
				}
				connect, ok := packet.(*packets.ConnectPacket)
				if !ok {
					return
				}
				if ack != nil {
					_, _ = c.Write(ack)
				}
				next := byte(0)
				if p, err := packets.ReadPacket(c); err == nil {
					next = p.Details().Qos
					if _, ok := p.(*packets.DisconnectPacket); ok {
						next = 14
					} else {
						next = 255
					}
				}
				observed <- observedConnect{connect.ClientIdentifier, connect.CleanSession, connect.WillFlag, next}
			}(connection)
		}
	}()
	t.Cleanup(func() {
		_ = listener.Close()
		mu.Lock()
		for _, c := range connections {
			_ = c.Close()
		}
		mu.Unlock()
		workers.Wait()
	})
	return listener.Addr().String(), observed
}

func TestDoctorMQTTAuthenticationAndNoActions(t *testing.T) {
	for _, code := range []byte{0, 4, 5} {
		t.Run(ConnackCode(code), func(t *testing.T) {
			address, observed := wireServer(t, nil, []byte{0x20, 2, 0, code})
			path := configFile(t, "mqtt://"+address, "")
			identifiers := map[string]bool{}
			for i := 0; i < 2; i++ {
				report := Doctor(context.Background(), path, "test", doctorProbe{}, true, false)
				if !hasCode(report, ConnackCode(code)) || (report.Status == "error") != (code != 0) || report.ValidUntil != 0 {
					t.Fatal(report)
				}
				encoded, _ := json.Marshal(report)
				for _, secret := range []string{"NeverReflectMe", "SecretToken", address, "example-user"} {
					if strings.Contains(string(encoded), secret) {
						t.Fatal("sensitive report")
					}
				}
				select {
				case packet := <-observed:
					if !strings.HasPrefix(packet.ID, "tepy-doctor-") || identifiers[packet.ID] || !packet.Clean || packet.Will || (packet.Next != 14 && code == 0) || (packet.Next != 0 && code != 0) {
						t.Fatal(packet)
					}
					identifiers[packet.ID] = true
				case <-time.After(time.Second):
					t.Fatal("doctor connection did not close")
				}
			}
		})
	}
}

func testCertificate(t *testing.T, matching bool) (tls.Certificate, []byte) {
	t.Helper()
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	certificate := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "test"}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	if matching {
		certificate.IPAddresses = []net.IP{net.ParseIP("127.0.0.1")}
	} else {
		certificate.DNSNames = []string{"other.example"}
	}
	der, err := x509.CreateCertificate(rand.Reader, certificate, certificate, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	private, _ := x509.MarshalECPrivateKey(key)
	public := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	pair, err := tls.X509KeyPair(public, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: private}))
	if err != nil {
		t.Fatal(err)
	}
	return pair, public
}

func TestDoctorTLSCAAndHostnameValidation(t *testing.T) {
	for _, test := range []struct {
		name            string
		trust, matching bool
		code            string
	}{
		{"verified", true, true, "tls_verified"}, {"untrusted", false, true, "tls_ca_untrusted"}, {"hostname", true, false, "tls_hostname_mismatch"},
	} {
		t.Run(test.name, func(t *testing.T) {
			pair, public := testCertificate(t, test.matching)
			address, _ := wireServer(t, &tls.Config{MinVersion: tls.VersionTLS12, Certificates: []tls.Certificate{pair}}, []byte{0x20, 2, 0, 0})
			ca := ""
			if test.trust {
				ca = filepath.Join(t.TempDir(), "ca.pem")
				if err := os.WriteFile(ca, public, 0600); err != nil {
					t.Fatal(err)
				}
			}
			report := Doctor(context.Background(), configFile(t, "mqtts://"+address, ca), "test", doctorProbe{}, true, false)
			if !hasCode(report, test.code) {
				t.Fatal(report)
			}
		})
	}
}

func TestDoctorCancellationMalformedPacketAndOffline(t *testing.T) {
	address, observed := wireServer(t, nil, nil)
	path := configFile(t, "mqtt://"+address, "")
	ctx, cancel := context.WithTimeout(context.Background(), 80*time.Millisecond)
	defer cancel()
	start := time.Now()
	report := Doctor(ctx, path, "test", doctorProbe{}, true, false)
	if report.Status != "error" || time.Since(start) > time.Second {
		t.Fatal("unbounded network check")
	}
	<-observed
	report = Doctor(context.Background(), path, "test", doctorProbe{}, true, true)
	if !hasCode(report, "network_skipped") || report.Status == "error" {
		t.Fatal(report)
	}
	select {
	case <-observed:
		t.Fatal("offline doctor opened socket")
	default:
	}
	bad, _ := wireServer(t, nil, []byte{0x20, 0xff, 0xff, 0xff})
	report = Doctor(context.Background(), configFile(t, "mqtt://"+bad, ""), "test", doctorProbe{}, true, false)
	if !hasCode(report, "mqtt_protocol_error") {
		t.Fatal(report)
	}
	report = Doctor(context.Background(), filepath.Join(t.TempDir(), "missing.toml"), "test", doctorProbe{}, true, false)
	if !hasCode(report, "configuration_invalid") || report.AgentID != "" {
		t.Fatal(report)
	}
}
