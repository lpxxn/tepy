package diagnostics

import (
	"context"
	"crypto/tls"
	"io"
	"net"
	"net/url"
	"time"

	"github.com/eclipse/paho.mqtt.golang/packets"
	"github.com/lpxxn/tepy/apps/macos-agent/internal/config"
	"github.com/lpxxn/tepy/apps/macos-agent/internal/model"
	"github.com/lpxxn/tepy/apps/macos-agent/internal/platform"
)

// Doctor 不连接服务进程，也不修改 LaunchAgent 或配置。
// 网络检查只发送独立客户端的 CONNECT / DISCONNECT，不发布、不订阅、不设置遗嘱。
func Doctor(ctx context.Context, path, version string, probe platform.Probe, native, offline bool) model.DiagnosticReport {
	r := model.DiagnosticReport{V: 1, AgentVersion: version, Source: "doctor", Checks: []model.Check{}}
	c, err := config.Load(path)
	if err != nil {
		r.Checks = append(r.Checks, Check("configuration", "error", "configuration_invalid"))
	} else {
		r.AgentID = c.AgentID
		r.Checks = append(r.Checks, Check("configuration", "ok", "configuration_ok"))
		tlsConfig, err := c.TLSConfig()
		if err != nil {
			r.Checks = append(r.Checks, Check("tls_material", "error", "tls_configuration_invalid"))
		} else {
			if tlsConfig != nil {
				r.Checks = append(r.Checks, Check("tls_material", "ok", "tls_material_ok"))
			} else {
				r.Checks = append(r.Checks, Check("tls_material", "skipped", "tls_not_enabled"))
			}
		}
		if native {
			sample := probe.Sample(c.HID.DeviceID)
			r.Checks = append(r.Checks, localChecks(model.State{UserSession: sample.Session, HID: sample.HID})...)
		} else {
			r.Checks = append(r.Checks, Check("platform", "warning", "native_platform_unavailable"))
		}
		if c.MQTT.URL == "" {
			r.Checks = append(r.Checks, Check("mqtt", "skipped", "mqtt_disabled"))
		} else if offline {
			r.Checks = append(r.Checks, Check("network", "skipped", "network_skipped"))
		} else if err == nil {
			r.Checks = append(r.Checks, networkChecks(ctx, c, tlsConfig)...)
		} else {
			r.Checks = append(r.Checks, Check("network", "skipped", "dependency_failed"))
		}
	}
	r.ObservedAt = time.Now().UnixMilli()
	// 单次报告不具有在线租约；客户端只能将其作为一次检查结果。
	r.ValidUntil = 0
	Summarize(&r)
	return r
}

func networkChecks(ctx context.Context, c config.Config, tlsConfig *tls.Config) []model.Check {
	checks := []model.Check{}
	u, _ := url.Parse(c.Broker())
	host := u.Hostname()
	addresses := []net.IPAddr{}
	if ip := net.ParseIP(host); ip != nil {
		addresses = append(addresses, net.IPAddr{IP: ip})
		checks = append(checks, Check("dns", "ok", "dns_literal_ip"))
	} else {
		lookup, cancel := context.WithTimeout(ctx, 2*time.Second)
		var err error
		addresses, err = net.DefaultResolver.LookupIPAddr(lookup, host)
		cancel()
		if err != nil || len(addresses) == 0 {
			return append(checks, Check("dns", "error", "dns_lookup_failed"))
		}
		checks = append(checks, Check("dns", "ok", "dns_ok"))
	}
	dial, cancel := context.WithTimeout(ctx, 3*time.Second)
	var conn net.Conn
	var err error
	for i, address := range addresses {
		if i >= 16 {
			break
		}
		conn, err = (&net.Dialer{}).DialContext(dial, "tcp", net.JoinHostPort(address.String(), u.Port()))
		if err == nil {
			break
		}
	}
	cancel()
	if err != nil || conn == nil {
		return append(checks, Check("tcp", "error", "tcp_connect_failed"))
	}
	defer conn.Close()
	raw := conn
	stop := context.AfterFunc(ctx, func() { _ = raw.Close() })
	defer stop()
	checks = append(checks, Check("tcp", "ok", "tcp_connected"))
	if tlsConfig != nil {
		options := tlsConfig.Clone()
		options.ServerName = host
		secure := tls.Client(conn, options)
		handshake, cancel := context.WithTimeout(ctx, 3*time.Second)
		err = secure.HandshakeContext(handshake)
		cancel()
		if err != nil {
			code := ErrorCode(err)
			if code == "mqtt_connection_failed" {
				code = "tls_handshake_failed"
			}
			return append(checks, Check("tls", "error", code))
		}
		conn = secure
		checks = append(checks, Check("tls", "ok", "tls_verified"))
	} else {
		checks = append(checks, Check("tls", "skipped", "tls_not_enabled"))
	}
	deadline := time.Now().Add(3 * time.Second)
	if value, ok := ctx.Deadline(); ok && value.Before(deadline) {
		deadline = value
	}
	_ = conn.SetDeadline(deadline)
	identifier, err := config.RandomHex(8)
	if err != nil {
		return append(checks, Check("mqtt", "error", "mqtt_connection_failed"))
	}
	packet := packets.NewControlPacket(packets.Connect).(*packets.ConnectPacket)
	packet.ProtocolName, packet.ProtocolVersion, packet.CleanSession = "MQTT", 4, true
	packet.ClientIdentifier, packet.Keepalive = "tepy-doctor-"+identifier, 5
	packet.UsernameFlag = c.MQTT.Username != ""
	packet.PasswordFlag = c.MQTT.Password != ""
	packet.Username, packet.Password = c.MQTT.Username, []byte(c.MQTT.Password)
	err = packet.Write(conn)
	clear(packet.Password)
	if err != nil {
		return append(checks, Check("mqtt", "error", ErrorCode(err)))
	}
	// CONNACK 的长度固定为 4；不使用可按 Broker 声明长度分配内存的通用解析器。
	var reply [4]byte
	if _, err = io.ReadFull(conn, reply[:]); err != nil {
		return append(checks, Check("mqtt", "error", ErrorCode(err)))
	}
	if reply[0] != 0x20 || reply[1] != 2 || reply[2] != 0 || reply[3] > 5 {
		return append(checks, Check("mqtt", "error", "mqtt_protocol_error"))
	}
	code, status := ConnackCode(reply[3]), "error"
	if reply[3] == 0 {
		status = "ok"
		_ = packets.NewControlPacket(packets.Disconnect).Write(conn)
	}
	return append(checks, Check("mqtt", status, code))
}
