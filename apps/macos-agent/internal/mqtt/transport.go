package mqtt

import (
	"context"
	"encoding/json"
	"sync"
	"sync/atomic"
	"time"

	paho "github.com/eclipse/paho.mqtt.golang"
	"github.com/lpxxn/tepy/apps/macos-agent/internal/config"
	"github.com/lpxxn/tepy/apps/macos-agent/internal/diagnostics"
	"github.com/lpxxn/tepy/apps/macos-agent/internal/model"
)

type Transport struct {
	config      config.Config
	connected   atomic.Bool
	tlsOptions  *paho.ClientOptions
	changed     chan struct{}
	epoch       atomic.Uint64
	statusMu    sync.Mutex
	lastError   string
	observer    func(model.ConnectionStatus, model.ConnectionStatus)
	eventSource func() model.EventPage
}

func New(c config.Config) (*Transport, error) {
	t := &Transport{config: c, changed: make(chan struct{}, 1)}
	if c.MQTT.URL == "" {
		return t, nil
	}
	tlsConfig, err := c.TLSConfig()
	if err != nil {
		return nil, err
	}
	t.tlsOptions = paho.NewClientOptions().AddBroker(c.Broker()).SetProtocolVersion(4).
		SetClientID("tepy-agent-"+c.AgentID).SetUsername(c.MQTT.Username).SetPassword(c.MQTT.Password).
		SetTLSConfig(tlsConfig).SetCleanSession(true).SetAutoReconnect(false).SetConnectRetry(false).
		SetKeepAlive(15*time.Second).SetPingTimeout(5*time.Second).SetConnectTimeout(5*time.Second).
		SetWriteTimeout(5*time.Second).SetOrderMatters(false).
		SetWill(t.Topic("availability"), "offline", 1, true)
	return t, nil
}
func (t *Transport) Topic(kind string) string { return "tepy/macos/" + t.config.AgentID + "/" + kind }
func (t *Transport) Connected() bool          { return t.connected.Load() }
func (t *Transport) Notify() {
	select {
	case t.changed <- struct{}{}:
	default:
	}
}
func wait(ctx context.Context, token paho.Token) bool {
	select {
	case <-ctx.Done():
		return false
	case <-token.Done():
		return token.Error() == nil
	case <-time.After(6 * time.Second):
		return false
	}
}
func (t *Transport) Run(ctx context.Context, state func() model.State) {
	if t.tlsOptions == nil {
		<-ctx.Done()
		return
	}
	backoff := time.Second
	for ctx.Err() == nil {
		generation := t.epoch.Add(1)
		options := *t.tlsOptions
		options.SetConnectionLostHandler(func(_ paho.Client, err error) {
			// 旧连接迟到的通知不能覆盖已经恢复的新连接状态。
			t.setGenerationStatus(generation, false, diagnostics.ErrorCode(err))
		})
		client := paho.NewClient(&options)
		connection := client.Connect()
		if wait(ctx, connection) && client.IsConnectionOpen() {
			t.setStatus(true, "")
			if wait(ctx, client.Publish(t.Topic("availability"), 1, true, "online")) {
				lastEventSequence := uint64(0)
				timer := time.NewTicker(time.Duration(t.config.HeartbeatSeconds) * time.Second)
				for ctx.Err() == nil && client.IsConnectionOpen() {
					current := state()
					// 只发布当前有效快照。事件来自本机有上限的历史，不是离线发送队列。
					if current.ValidUntil > time.Now().UnixMilli() {
						current.MQTT.Connected = true
						if !t.publish(ctx, client, "state", current) {
							break
						}
						if !t.publish(ctx, client, "diagnostics", diagnostics.Live(current, t.Status(), time.Now())) {
							break
						}
						t.statusMu.Lock()
						eventSource := t.eventSource
						t.statusMu.Unlock()
						if eventSource != nil {
							page := eventSource()
							if page.LatestSequence != lastEventSequence {
								if !t.publish(ctx, client, "events", page) {
									break
								}
								lastEventSequence = page.LatestSequence
							}
						}
					}
					select {
					case <-ctx.Done():
					case <-timer.C:
					case <-t.changed:
					}
				}
				timer.Stop()
				backoff = time.Second
			}
		}
		if ctx.Err() == nil {
			code := diagnostics.ErrorCode(connection.Error())
			if connection.Error() == nil && t.Status().ErrorCode != "" {
				code = t.Status().ErrorCode
			}
			t.setStatus(false, code)
		}
		if ctx.Err() != nil && client.IsConnectionOpen() {
			shutdown, cancel := context.WithTimeout(context.Background(), time.Second)
			_ = wait(shutdown, client.Publish(t.Topic("availability"), 1, true, "offline"))
			cancel()
		}
		client.Disconnect(0)
		if ctx.Err() != nil {
			t.setStatus(false, "")
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff):
		}
		if backoff < 30*time.Second {
			backoff *= 2
			if backoff > 30*time.Second {
				backoff = 30 * time.Second
			}
		}
	}
}
func (t *Transport) publish(ctx context.Context, client paho.Client, topic string, value any) bool {
	body, err := json.Marshal(value)
	return err == nil && wait(ctx, client.Publish(t.Topic(topic), 1, true, body))
}
func (t *Transport) Status() model.ConnectionStatus {
	t.statusMu.Lock()
	defer t.statusMu.Unlock()
	return model.ConnectionStatus{Connected: t.connected.Load(), ErrorCode: t.lastError}
}
func (t *Transport) Observe(handler func(model.ConnectionStatus, model.ConnectionStatus)) {
	t.statusMu.Lock()
	defer t.statusMu.Unlock()
	t.observer = handler
}
func (t *Transport) SetEventSource(source func() model.EventPage) {
	t.statusMu.Lock()
	defer t.statusMu.Unlock()
	t.eventSource = source
}
func (t *Transport) setStatus(connected bool, code string) { t.setGenerationStatus(0, connected, code) }
func (t *Transport) setGenerationStatus(generation uint64, connected bool, code string) {
	if code != "" {
		code = diagnostics.Check("mqtt", "error", code).Code
	}
	t.statusMu.Lock()
	if generation != 0 && t.epoch.Load() != generation {
		t.statusMu.Unlock()
		return
	}
	previous := model.ConnectionStatus{Connected: t.connected.Load(), ErrorCode: t.lastError}
	current := model.ConnectionStatus{Connected: connected, ErrorCode: code}
	t.connected.Store(connected)
	t.lastError = code
	handler := t.observer
	t.statusMu.Unlock()
	if previous != current && handler != nil {
		handler(previous, current)
	}
}
