package mqtt

import (
	"context"
	"encoding/json"
	"sync/atomic"
	"time"

	paho "github.com/eclipse/paho.mqtt.golang"
	"github.com/lpxxn/tepy/apps/macos-agent/internal/config"
	"github.com/lpxxn/tepy/apps/macos-agent/internal/model"
)

type Transport struct {
	config     config.Config
	connected  atomic.Bool
	tlsOptions *paho.ClientOptions
	changed    chan struct{}
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
		client := paho.NewClient(t.tlsOptions)
		if wait(ctx, client.Connect()) {
			t.connected.Store(true)
			if !wait(ctx, client.Publish(t.Topic("availability"), 1, true, "online")) {
				client.Disconnect(0)
			} else {
				timer := time.NewTicker(time.Duration(t.config.HeartbeatSeconds) * time.Second)
				for ctx.Err() == nil && client.IsConnectionOpen() {
					current := state()
					// Use the most recent probe only; never queue an expired state offline.
					if current.ValidUntil > time.Now().UnixMilli() {
						current.MQTT.Connected = true
						bytes, err := json.Marshal(current)
						if err != nil || !wait(ctx, client.Publish(t.Topic("state"), 1, true, bytes)) {
							break
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
		t.connected.Store(false)
		if ctx.Err() != nil && client.IsConnectionOpen() {
			shutdown, cancel := context.WithTimeout(context.Background(), time.Second)
			_ = wait(shutdown, client.Publish(t.Topic("availability"), 1, true, "offline"))
			cancel()
		}
		client.Disconnect(0)
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
