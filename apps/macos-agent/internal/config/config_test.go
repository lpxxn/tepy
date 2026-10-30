package config

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestInitRoundTripAndNoOverwrite(t *testing.T) {
	path := filepath.Join(t.TempDir(), "agent.toml")
	if err := WriteInitial(path); err != nil {
		t.Fatal(err)
	}
	first, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	c, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(c.HTTP.Token) != 64 || c.AgentID == "" || c.MQTT.URL != "mqtt://192.168.50.99:1883" {
		t.Fatal("invalid generated defaults")
	}
	if err := WriteInitial(path); err == nil {
		t.Fatal("existing credentials overwritten")
	}
	after, _ := os.ReadFile(path)
	if string(after) != string(first) {
		t.Fatal("configuration changed")
	}
}
func TestCustomCAAndClientCertificate(t *testing.T) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "Tepy test CA"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), IsCA: true, BasicConstraintsValid: true,
		KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	certPath := filepath.Join(dir, "client.pem")
	keyPath := filepath.Join(dir, "client.key")
	if err := os.WriteFile(certPath, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(keyPath, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: encoded}), 0600); err != nil {
		t.Fatal(err)
	}
	c := Default()
	c.MQTT.URL = "mqtts://broker.example:8883"
	c.MQTT.CAFile = certPath
	c.MQTT.ClientCertFile = certPath
	c.MQTT.ClientKeyFile = keyPath
	tlsConfig, err := c.TLSConfig()
	if err != nil {
		t.Fatal(err)
	}
	if tlsConfig.RootCAs == nil || len(tlsConfig.Certificates) != 1 || tlsConfig.InsecureSkipVerify {
		t.Fatal("custom TLS credentials not applied")
	}
	c.MQTT.ClientKeyFile = certPath
	if _, err := c.TLSConfig(); err == nil {
		t.Fatal("invalid private key accepted")
	}
}
func TestStrictTOMLAndSecretSafeErrors(t *testing.T) {
	path := filepath.Join(t.TempDir(), "agent.toml")
	if err := WriteInitial(path); err != nil {
		t.Fatal(err)
	}
	original, _ := os.ReadFile(path)
	for name, body := range map[string]string{"unknown": "unexpected_key = 42\n" + string(original), "syntax": "password = \"sensitive-never-echo\n", "version": strings.Replace(string(original), "version = 1", "version = 9", 1)} {
		t.Run(name, func(t *testing.T) {
			_ = os.WriteFile(path, []byte(body), 0600)
			_, err := Load(path)
			if err == nil || strings.Contains(err.Error(), "sensitive-never-echo") {
				t.Fatal("invalid config accepted or secret reflected")
			}
		})
	}
}
func TestBrokerAndTLSValidation(t *testing.T) {
	c := Default()
	c.AgentID = "mac-test"
	c.HTTP.Token = strings.Repeat("a", 64)
	if err := c.Validate(); err != nil {
		t.Fatal(err)
	}
	if c.Broker() != "tcp://192.168.50.99:1883" {
		t.Fatal(c.Broker())
	}
	c.MQTT.URL = "mqtts://broker.example"
	tlsConfig, err := c.TLSConfig()
	if err != nil || tlsConfig.MinVersion != tls.VersionTLS12 || tlsConfig.InsecureSkipVerify {
		t.Fatal("TLS verification disabled")
	}
	c.MQTT.ClientCertFile = "client.pem"
	if c.Validate() == nil {
		t.Fatal("unpaired key accepted")
	}
	c.MQTT.ClientKeyFile = "client.key"
	c.MQTT.URL = "mqtt://broker.example"
	if c.Validate() == nil {
		t.Fatal("TLS files ignored on plaintext URL")
	}
	c.MQTT.ClientCertFile = ""
	c.MQTT.ClientKeyFile = ""
	for _, uri := range []string{"http://broker", "mqtt://user:password@broker", "mqtt://broker/path", "mqtt://broker:99999", "mqtt://broker?password=value"} {
		c.MQTT.URL = uri
		if c.Validate() == nil {
			t.Fatalf("invalid broker accepted: %s", uri)
		}
	}
	c.MQTT.URL = "mqtts://[::1]:8883"
	if err := c.Validate(); err != nil {
		t.Fatal(err)
	}
	if c.Broker() != "ssl://[::1]:8883" {
		t.Fatal(c.Broker())
	}
}
