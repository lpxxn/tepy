// Package diagnostics 把系统与网络结果转换成稳定、脱敏的诊断代码。
package diagnostics

import (
	"crypto/x509"
	"errors"
	"net"
	"time"

	"github.com/eclipse/paho.mqtt.golang/packets"
	"github.com/lpxxn/tepy/apps/macos-agent/internal/model"
)

var messages = map[string]string{
	"configuration_ok": "配置格式与版本有效。", "configuration_invalid": "配置无法读取或校验失败，请运行 validate 查看固定错误说明。",
	"tls_material_ok": "CA 与客户端证书材料可以加载。", "tls_configuration_invalid": "证书文件无法读取、格式无效或证书与私钥不匹配。",
	"tls_not_enabled": "当前未使用 TLS。", "tls_verified": "服务器证书和主机名校验通过。",
	"dns_ok": "Broker 名称解析成功。", "dns_literal_ip": "Broker 使用 IP 地址，无需 DNS 解析。",
	"dns_lookup_failed": "无法解析 Broker 名称。", "tcp_connected": "Broker TCP 端口可以连接。", "tcp_connect_failed": "无法连接 Broker TCP 端口。",
	"network_timeout": "网络检查超时。", "network_skipped": "本次未执行主动网络检查。", "dependency_failed": "前置检查失败，已跳过此项。",
	"tls_ca_untrusted": "服务器证书不受当前 CA 信任。", "tls_hostname_mismatch": "服务器证书与 Broker 主机名不匹配。",
	"tls_certificate_expired": "证书不在有效期内，请检查证书和系统时间。", "tls_handshake_failed": "TLS 握手未完成，请检查服务器和客户端证书要求。",
	"mqtt_connected": "MQTT 已连接。", "mqtt_disconnected": "MQTT 尚未连接。", "mqtt_disabled": "配置中未启用 MQTT。",
	"mqtt_bad_credentials": "Broker 拒绝用户名或密码。", "mqtt_not_authorized": "Broker 拒绝此次连接授权。",
	"mqtt_server_unavailable": "Broker 暂时不可用。", "mqtt_protocol_rejected": "Broker 拒绝 MQTT 协议版本。",
	"mqtt_client_id_rejected": "Broker 拒绝客户端标识。", "mqtt_protocol_error": "Broker 返回的 MQTT 应答无效。",
	"mqtt_connection_failed": "MQTT 连接或通信失败；运行 doctor 可继续定位 DNS、TCP 和 TLS。",
	"agent_state_fresh":      "服务采样仍在有效期内。", "agent_state_stale": "服务采样已过期，不能据此判断 Mac 当前状态。",
	"gui_session_active": "当前 GUI 用户位于控制台且登录完成。", "gui_session_inactive": "当前用户不在活动控制台或尚未完成登录。",
	"gui_session_unknown": "无法确认当前图形会话。", "screen_locked": "观察到屏幕锁定。", "screen_unlocked": "观察到屏幕未锁定。",
	"screen_lock_unknown": "暂时无法确认锁定状态，等待原生采样或锁定事件。",
	"hid_registered":      "已找到目标 Tepy HID 键盘。", "hid_absent": "未找到目标 Tepy HID 键盘，请检查供电、蓝牙连接与配对。",
	"hid_unknown": "HID 查询失败或结果无法解析。", "power_monitor_ready": "原生电源事件监听正在运行。",
	"power_monitor_unavailable": "原生电源事件监听尚未就绪或不可用。", "native_platform_unavailable": "当前程序不是原生 macOS CGo 构建，无法检查 Mac 会话和键盘。",
}

// Check 会拒绝未知错误文本；调用方不能把 err.Error() 当作诊断消息发出去。
func Check(component, status, code string) model.Check {
	message, ok := messages[code]
	if !ok {
		code, message = "mqtt_connection_failed", messages["mqtt_connection_failed"]
	}
	return model.Check{Component: component, Status: status, Code: code, Message: message}
}

func Summarize(report *model.DiagnosticReport) {
	report.Status = "ok"
	for _, check := range report.Checks {
		if check.Status == "error" {
			report.Status = "error"
			return
		}
		if check.Status == "warning" {
			report.Status = "warning"
		}
	}
}

func localChecks(state model.State) []model.Check {
	checks := []model.Check{}
	s := state.UserSession
	if !s.Available || s.OnConsole == nil || s.LoginDone == nil {
		checks = append(checks, Check("user_session", "warning", "gui_session_unknown"))
	} else if !*s.OnConsole || !*s.LoginDone {
		checks = append(checks, Check("user_session", "warning", "gui_session_inactive"))
	} else {
		checks = append(checks, Check("user_session", "ok", "gui_session_active"))
	}
	lock := s.LockState
	if !s.Available || s.OnConsole == nil || !*s.OnConsole || s.LoginDone == nil || !*s.LoginDone {
		lock = "unknown"
	}
	switch lock {
	case "locked":
		checks = append(checks, Check("screen_lock", "ok", "screen_locked"))
	case "unlocked":
		checks = append(checks, Check("screen_lock", "ok", "screen_unlocked"))
	default:
		checks = append(checks, Check("screen_lock", "warning", "screen_lock_unknown"))
	}
	if state.HID.Available && state.HID.State == "registered" {
		checks = append(checks, Check("hid", "ok", "hid_registered"))
	} else if state.HID.Available && state.HID.State == "absent" {
		checks = append(checks, Check("hid", "warning", "hid_absent"))
	} else {
		checks = append(checks, Check("hid", "warning", "hid_unknown"))
	}
	return checks
}

// Live 仅消费已有快照，HTTP 请求和 MQTT 发布不会触发网络探测或 hidutil 子进程。
func Live(state model.State, connection model.ConnectionStatus, now time.Time) model.DiagnosticReport {
	r := model.DiagnosticReport{V: 1, AgentID: state.AgentID, AgentVersion: state.AgentVersion, Session: state.Session,
		Source: "live", ObservedAt: state.ObservedAt, ValidUntil: state.ValidUntil, Checks: []model.Check{}}
	if state.ObservedAt <= 0 || state.ValidUntil <= now.UnixMilli() {
		r.Checks = append(r.Checks, Check("agent", "error", "agent_state_stale"))
	} else {
		r.Checks = append(r.Checks, Check("agent", "ok", "agent_state_fresh"))
	}
	if !state.MQTT.Configured {
		r.Checks = append(r.Checks, Check("mqtt", "skipped", "mqtt_disabled"))
	} else if connection.Connected {
		r.Checks = append(r.Checks, Check("mqtt", "ok", "mqtt_connected"))
	} else {
		code := connection.ErrorCode
		if code == "" {
			code = "mqtt_disconnected"
		}
		r.Checks = append(r.Checks, Check("mqtt", "error", code))
	}
	r.Checks = append(r.Checks, localChecks(state)...)
	if state.Power.Monitoring {
		r.Checks = append(r.Checks, Check("power", "ok", "power_monitor_ready"))
	} else {
		r.Checks = append(r.Checks, Check("power", "warning", "power_monitor_unavailable"))
	}
	Summarize(&r)
	return r
}

func ConnackCode(code byte) string {
	switch code {
	case 0:
		return "mqtt_connected"
	case 1:
		return "mqtt_protocol_rejected"
	case 2:
		return "mqtt_client_id_rejected"
	case 3:
		return "mqtt_server_unavailable"
	case 4:
		return "mqtt_bad_credentials"
	case 5:
		return "mqtt_not_authorized"
	default:
		return "mqtt_protocol_error"
	}
}

func ErrorCode(err error) string {
	for _, code := range []byte{1, 2, 3, 4, 5} {
		if errors.Is(err, packets.ConnErrors[code]) {
			return ConnackCode(code)
		}
	}
	var authority x509.UnknownAuthorityError
	var hostname x509.HostnameError
	var invalid x509.CertificateInvalidError
	var dns *net.DNSError
	var network net.Error
	switch {
	case errors.As(err, &authority):
		return "tls_ca_untrusted"
	case errors.As(err, &hostname):
		return "tls_hostname_mismatch"
	case errors.As(err, &invalid) && invalid.Reason == x509.Expired:
		return "tls_certificate_expired"
	case errors.As(err, &dns):
		return "dns_lookup_failed"
	case errors.As(err, &network) && network.Timeout():
		return "network_timeout"
	default:
		return "mqtt_connection_failed"
	}
}
