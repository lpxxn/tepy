package config

import (
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/BurntSushi/toml"
)

type Config struct {
	Version          int    `toml:"version"`
	AgentID          string `toml:"agent_id"`
	Name             string `toml:"name"`
	SampleSeconds    int    `toml:"sample_seconds"`
	HeartbeatSeconds int    `toml:"heartbeat_seconds"`
	HID              struct {
		DeviceID string `toml:"device_id"`
	} `toml:"hid"`
	HTTP struct {
		Listen string `toml:"listen"`
		Token  string `toml:"token"`
	} `toml:"http"`
	MQTT struct {
		URL            string `toml:"url"`
		Username       string `toml:"username"`
		Password       string `toml:"password"`
		CAFile         string `toml:"ca_file"`
		ClientCertFile string `toml:"client_cert_file"`
		ClientKeyFile  string `toml:"client_key_file"`
	} `toml:"mqtt"`
}

var identifier = regexp.MustCompile(`^[a-zA-Z0-9_.-]{1,64}$`)
var deviceID = regexp.MustCompile(`^[a-f0-9]{12}$`)

func Default() Config {
	c := Config{Version: 1, Name: "Tepy Mac", SampleSeconds: 2, HeartbeatSeconds: 10}
	c.HTTP.Listen = "127.0.0.1:18765"
	c.MQTT.URL = "mqtt://192.168.50.99:1883"
	return c
}

func RandomHex(bytes int) (string, error) {
	value := make([]byte, bytes)
	if _, err := rand.Read(value); err != nil {
		return "", errors.New("cannot generate random identifier")
	}
	return hex.EncodeToString(value), nil
}

func Load(path string) (Config, error) {
	c := Default()
	info, err := os.Stat(path)
	if err != nil {
		return c, errors.New("cannot read configuration file")
	}
	if info.Size() > 65536 {
		return c, errors.New("configuration file is too large")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return c, errors.New("cannot read configuration file")
	}
	metadata, err := toml.Decode(string(data), &c)
	clear(data)
	if err != nil {
		return c, errors.New("invalid TOML configuration")
	}
	if len(metadata.Undecoded()) != 0 {
		return c, errors.New("configuration contains unknown fields")
	}
	if err := c.Validate(); err != nil {
		return c, err
	}
	for _, item := range []*string{&c.MQTT.CAFile, &c.MQTT.ClientCertFile, &c.MQTT.ClientKeyFile} {
		if *item != "" && !filepath.IsAbs(*item) {
			*item = filepath.Join(filepath.Dir(path), *item)
		}
	}
	return c, nil
}

func (c Config) Validate() error {
	switch {
	case c.Version != 1:
		return errors.New("unsupported configuration version")
	case !identifier.MatchString(c.AgentID):
		return errors.New("invalid agent_id")
	case len(c.Name) == 0 || len(c.Name) > 128:
		return errors.New("invalid name")
	case c.SampleSeconds < 1 || c.SampleSeconds > 30:
		return errors.New("sample_seconds must be 1..30")
	case c.HeartbeatSeconds < 2 || c.HeartbeatSeconds > 60 || c.HeartbeatSeconds < c.SampleSeconds:
		return errors.New("heartbeat_seconds must be 2..60 and at least sample_seconds")
	case c.HID.DeviceID != "" && !deviceID.MatchString(c.HID.DeviceID):
		return errors.New("invalid hid.device_id")
	case len(c.HTTP.Token) < 32 || len(c.HTTP.Token) > 128:
		return errors.New("http.token must be 32..128 ASCII characters")
	}
	for _, ch := range c.HTTP.Token {
		if ch < 33 || ch > 126 {
			return errors.New("invalid http.token")
		}
	}
	host, port, err := net.SplitHostPort(c.HTTP.Listen)
	if err != nil || net.ParseIP(host) == nil || port == "" {
		return errors.New("http.listen must contain a literal IP and port")
	}
	if parsed, err := net.LookupPort("tcp", port); err != nil || parsed < 1 || parsed > 65535 {
		return errors.New("invalid http.listen port")
	}
	if c.MQTT.URL == "" {
		if c.MQTT.Username != "" || c.MQTT.Password != "" || c.MQTT.CAFile != "" || c.MQTT.ClientCertFile != "" || c.MQTT.ClientKeyFile != "" {
			return errors.New("mqtt.url is required when MQTT credentials are configured")
		}
		return nil
	}
	u, err := url.Parse(c.MQTT.URL)
	if err != nil || (u.Scheme != "mqtt" && u.Scheme != "mqtts") || u.Hostname() == "" || u.User != nil || u.Path != "" || u.RawQuery != "" || u.Fragment != "" {
		return errors.New("invalid mqtt.url; use mqtt://host:port or mqtts://host:port without embedded credentials")
	}
	if u.Port() != "" {
		if p, err := net.LookupPort("tcp", u.Port()); err != nil || p < 1 || p > 65535 {
			return errors.New("invalid MQTT port")
		}
	}
	if (c.MQTT.ClientCertFile == "") != (c.MQTT.ClientKeyFile == "") {
		return errors.New("both MQTT client certificate and key are required")
	}
	if u.Scheme != "mqtts" && (c.MQTT.CAFile != "" || c.MQTT.ClientCertFile != "") {
		return errors.New("MQTT certificates require an mqtts:// URL")
	}
	if len(c.MQTT.Username) > 256 || len(c.MQTT.Password) > 4096 {
		return errors.New("MQTT credentials are too long")
	}
	return nil
}

func (c Config) Broker() string {
	u, _ := url.Parse(c.MQTT.URL)
	if u == nil || u.Hostname() == "" {
		return ""
	}
	port := u.Port()
	if port == "" {
		if u.Scheme == "mqtts" {
			port = "8883"
		} else {
			port = "1883"
		}
	}
	scheme := "tcp"
	if u.Scheme == "mqtts" {
		scheme = "ssl"
	}
	return scheme + "://" + net.JoinHostPort(u.Hostname(), port)
}

func (c Config) TLSConfig() (*tls.Config, error) {
	if !strings.HasPrefix(c.MQTT.URL, "mqtts://") {
		return nil, nil
	}
	result := &tls.Config{MinVersion: tls.VersionTLS12}
	if c.MQTT.CAFile != "" {
		pem, err := os.ReadFile(c.MQTT.CAFile)
		if err != nil {
			return nil, errors.New("cannot read mqtt.ca_file")
		}
		pool, err := x509.SystemCertPool()
		if err != nil {
			pool = x509.NewCertPool()
		}
		if !pool.AppendCertsFromPEM(pem) {
			return nil, errors.New("invalid MQTT CA certificate")
		}
		result.RootCAs = pool
	}
	if c.MQTT.ClientCertFile != "" {
		pair, err := tls.LoadX509KeyPair(c.MQTT.ClientCertFile, c.MQTT.ClientKeyFile)
		if err != nil {
			return nil, errors.New("cannot load MQTT client certificate and key")
		}
		result.Certificates = []tls.Certificate{pair}
	}
	return result, nil
}

func WriteInitial(path string) error {
	c := Default()
	id, err := RandomHex(6)
	if err != nil {
		return err
	}
	c.AgentID = "mac-" + id
	c.HTTP.Token, err = RandomHex(32)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return errors.New("cannot create configuration directory")
	}
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return errors.New("configuration already exists or cannot be created")
	}
	defer file.Close()
	if err := toml.NewEncoder(file).Encode(c); err != nil {
		return fmt.Errorf("cannot write configuration")
	}
	return file.Sync()
}
