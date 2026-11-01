package mqtt

import (
	"context"
	"encoding/json"
	"net"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eclipse/paho.mqtt.golang/packets"
	"github.com/lpxxn/tepy/apps/macos-agent/internal/config"
	"github.com/lpxxn/tepy/apps/macos-agent/internal/model"
)

type wireBroker struct {
	listener    net.Listener
	incoming    chan packets.ControlPacket
	mu          sync.Mutex
	clients     []net.Conn
	workers     sync.WaitGroup
	connackCode atomic.Uint32
}

func newBroker(t *testing.T) *wireBroker {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	b := &wireBroker{listener: listener, incoming: make(chan packets.ControlPacket, 32)}
	b.workers.Add(1)
	go func() {
		defer b.workers.Done()
		for {
			c, err := listener.Accept()
			if err != nil {
				return
			}
			b.mu.Lock()
			b.clients = append(b.clients, c)
			b.mu.Unlock()
			b.workers.Add(1)
			go b.serve(c)
		}
	}()
	t.Cleanup(func() {
		_ = listener.Close()
		b.mu.Lock()
		for _, c := range b.clients {
			_ = c.Close()
		}
		b.mu.Unlock()
		b.workers.Wait()
	})
	return b
}
func (b *wireBroker) serve(c net.Conn) {
	defer b.workers.Done()
	defer c.Close()
	for {
		packet, err := packets.ReadPacket(c)
		if err != nil {
			return
		}
		select {
		case b.incoming <- packet:
		default:
		}
		switch p := packet.(type) {
		case *packets.ConnectPacket:
			ack := packets.NewControlPacket(packets.Connack).(*packets.ConnackPacket)
			ack.ReturnCode = byte(b.connackCode.Load())
			_ = ack.Write(c)
		case *packets.PublishPacket:
			if p.Qos == 1 {
				ack := packets.NewControlPacket(packets.Puback).(*packets.PubackPacket)
				ack.MessageID = p.MessageID
				_ = ack.Write(c)
			}
		case *packets.PingreqPacket:
			_ = packets.NewControlPacket(packets.Pingresp).Write(c)
		case *packets.DisconnectPacket:
			return
		}
	}
}
func take(t *testing.T, b *wireBroker) packets.ControlPacket {
	t.Helper()
	select {
	case p := <-b.incoming:
		return p
	case <-time.After(4 * time.Second):
		t.Fatal("MQTT packet timeout")
		return nil
	}
}
func TestRealPahoWireHeartbeatAndWill(t *testing.T) {
	b := newBroker(t)
	c := config.Default()
	c.AgentID = "mac-test"
	c.MQTT.URL = "mqtt://" + b.listener.Addr().String()
	c.MQTT.Username = "example-user"
	c.MQTT.Password = "example-password"
	transport, err := New(c)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		transport.Run(ctx, func() model.State {
			return model.State{V: 1, AgentID: c.AgentID, ObservedAt: time.Now().UnixMilli(), ValidUntil: time.Now().Add(time.Minute).UnixMilli()}
		})
	}()
	connect, ok := take(t, b).(*packets.ConnectPacket)
	if !ok || !connect.CleanSession || connect.ProtocolVersion != 4 || !connect.WillFlag || !connect.WillRetain || connect.WillQos != 1 || string(connect.WillMessage) != "offline" || connect.Username != "example-user" || string(connect.Password) != "example-password" {
		cancel()
		t.Fatal("invalid MQTT CONNECT")
	}
	online, ok := take(t, b).(*packets.PublishPacket)
	if !ok || online.TopicName != "tepy/macos/mac-test/availability" || string(online.Payload) != "online" || online.Qos != 1 || !online.Retain {
		cancel()
		t.Fatal("invalid availability")
	}
	heartbeat, ok := take(t, b).(*packets.PublishPacket)
	if !ok || heartbeat.TopicName != "tepy/macos/mac-test/state" || !heartbeat.Retain || heartbeat.Qos != 1 {
		cancel()
		t.Fatal("invalid heartbeat")
	}
	var state model.State
	if json.Unmarshal(heartbeat.Payload, &state) != nil || state.AgentID != c.AgentID || !state.MQTT.Connected {
		cancel()
		t.Fatal("invalid state")
	}
	transport.Notify()
	if _, ok := take(t, b).(*packets.PublishPacket); !ok {
		cancel()
		t.Fatal("event did not trigger state")
	}
	cancel()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("shutdown blocked")
	}
	if transport.Connected() {
		t.Fatal("transport still online")
	}
}
func TestExpiredStateIsNotPublished(t *testing.T) {
	b := newBroker(t)
	c := config.Default()
	c.AgentID = "mac-stale"
	c.MQTT.URL = "mqtt://" + b.listener.Addr().String()
	transport, _ := New(c)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		transport.Run(ctx, func() model.State { return model.State{ValidUntil: 1} })
	}()
	_ = take(t, b)
	_ = take(t, b)
	select {
	case packet := <-b.incoming:
		cancel()
		t.Fatalf("expired state sent: %T", packet)
	case <-time.After(100 * time.Millisecond):
	}
	cancel()
	<-done
}

func TestDiagnosticAndHistoryTopicsPreserveStateAndReplayLatestHistory(t *testing.T) {
	b := newBroker(t)
	c := config.Default()
	c.AgentID = "mac-test"
	c.MQTT.URL = "mqtt://" + b.listener.Addr().String()
	transport, _ := New(c)
	journal := model.NewJournal(c.AgentID, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
	journal.Append("agent_started", "", "running", "", 1)
	transport.SetEventSource(func() model.EventPage { p, _ := journal.Read(nil, 200, ""); return p })
	transport.Observe(func(previous, current model.ConnectionStatus) {
		if current.Connected {
			journal.Append("mqtt_connected", "disconnected", "connected", "", 2)
		}
	})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan struct{})
	go func() {
		defer close(done)
		transport.Run(ctx, func() model.State {
			state := model.State{V: 1, AgentID: c.AgentID, AgentVersion: "test", Session: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", ObservedAt: time.Now().UnixMilli(), ValidUntil: time.Now().Add(time.Minute).UnixMilli()}
			state.MQTT.Configured = true
			return state
		})
	}()
	topics := map[string][]byte{}
	for len(topics) < 4 {
		if packet, ok := take(t, b).(*packets.PublishPacket); ok {
			if packet.Qos != 1 || !packet.Retain {
				t.Fatal("wrong delivery flags")
			}
			topics[packet.TopicName] = packet.Payload
		}
	}
	var events model.EventPage
	if json.Unmarshal(topics[transport.Topic("events")], &events) != nil || events.LatestSequence != 2 || len(events.Events) != 2 {
		t.Fatal(events)
	}
	var report model.DiagnosticReport
	if json.Unmarshal(topics[transport.Topic("diagnostics")], &report) != nil || report.Source != "live" || report.Checks[1].Code != "mqtt_connected" {
		t.Fatal(report)
	}
	var state map[string]any
	if json.Unmarshal(topics[transport.Topic("state")], &state) != nil || len(state["mqtt"].(map[string]any)) != 2 {
		t.Fatal("old nested state shape changed")
	}
	journal.Append("did_wake", "sleeping", "awake", "", 3)
	transport.Notify()
	for {
		if packet, ok := take(t, b).(*packets.PublishPacket); ok && packet.TopicName == transport.Topic("events") {
			if json.Unmarshal(packet.Payload, &events) != nil || events.LatestSequence != 3 {
				t.Fatal("history did not advance")
			}
			break
		}
	}
	cancel()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("shutdown blocked")
	}
}
func TestMQTTBadCredentialsBecomeFixedDiagnosticCode(t *testing.T) {
	b := newBroker(t)
	b.connackCode.Store(4)
	c := config.Default()
	c.AgentID = "mac-test"
	c.MQTT.URL = "mqtt://" + b.listener.Addr().String()
	transport, _ := New(c)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan struct{})
	go func() { defer close(done); transport.Run(ctx, func() model.State { return model.State{} }) }()
	_ = take(t, b)
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) && transport.Status().ErrorCode == "" {
		time.Sleep(time.Millisecond)
	}
	if transport.Status().ErrorCode != "mqtt_bad_credentials" || transport.Connected() {
		t.Fatal(transport.Status())
	}
	b.connackCode.Store(5)
	_ = take(t, b)
	deadline = time.Now().Add(time.Second)
	for time.Now().Before(deadline) && transport.Status().ErrorCode != "mqtt_not_authorized" {
		time.Sleep(time.Millisecond)
	}
	if transport.Status().ErrorCode != "mqtt_not_authorized" {
		t.Fatal("old authentication error persisted across attempts")
	}
	cancel()
	<-done
}
func TestLateConnectionNotificationDoesNotReplaceNewConnection(t *testing.T) {
	transport, _ := New(config.Default())
	transport.epoch.Store(2)
	transport.setStatus(true, "")
	transport.setGenerationStatus(1, false, "mqtt_connection_failed")
	if !transport.Connected() || transport.Status().ErrorCode != "" {
		t.Fatal("old disconnect changed current connection")
	}
}
