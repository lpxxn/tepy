package service

import (
	"context"
	"runtime"
	"sync"
	"time"

	"github.com/lpxxn/tepy/apps/macos-agent/internal/config"
	"github.com/lpxxn/tepy/apps/macos-agent/internal/diagnostics"
	"github.com/lpxxn/tepy/apps/macos-agent/internal/model"
	"github.com/lpxxn/tepy/apps/macos-agent/internal/platform"
)

type Publisher interface {
	Connected() bool
	Run(context.Context, func() model.State)
	Notify()
}
type Service struct {
	Config      config.Config
	Journal     *model.Journal
	Store       model.Store
	Probe       platform.Probe
	Publisher   Publisher
	Instance    string
	Version     string
	started     time.Time
	sampleMu    sync.Mutex
	mu          sync.Mutex
	power       model.Power
	watchFailed bool
	lockEvent   string
}

func New(c config.Config, version string, probe platform.Probe, publisher Publisher) (*Service, error) {
	instance, err := config.RandomHex(16)
	if err != nil {
		return nil, err
	}
	s := &Service{Config: c, Version: version, Probe: probe, Publisher: publisher, Instance: instance,
		started: time.Now(), power: model.Power{State: "awake", LastEvent: "none"}}

	s.Journal = model.NewJournal(c.AgentID, instance)
	s.Journal.Append("agent_started", "", "running", "", time.Now().UnixMilli())
	// 回调只传固定诊断代码，不传原始网络异常。
	if observable, ok := publisher.(interface {
		Observe(func(model.ConnectionStatus, model.ConnectionStatus))
	}); ok {
		observable.Observe(func(previous, current model.ConnectionStatus) {
			kind := "mqtt_error"
			if previous.Connected != current.Connected {
				if current.Connected {
					kind = "mqtt_connected"
				} else {
					kind = "mqtt_disconnected"
				}
			}
			from, to := "disconnected", "disconnected"
			if previous.Connected {
				from = "connected"
			}
			if current.Connected {
				to = "connected"
			}
			s.Journal.Append(kind, from, to, current.ErrorCode, time.Now().UnixMilli())
		})
	}
	if source, ok := publisher.(interface{ SetEventSource(func() model.EventPage) }); ok {
		source.SetEventSource(func() model.EventPage { page, _ := s.Journal.Read(nil, model.EventCapacity, ""); return page })
	}
	s.Sample()
	return s, nil
}
func (s *Service) Sample() {
	s.sampleMu.Lock()
	defer s.sampleMu.Unlock()
	sample := s.Probe.Sample(s.Config.HID.DeviceID)
	now := time.Now()
	previous := s.Store.Get()
	state := model.State{V: 1, AgentID: s.Config.AgentID, AgentVersion: s.Version, Name: s.Config.Name,
		Platform: runtime.GOOS, Session: s.Instance, Sequence: previous.Sequence + 1, ObservedAt: now.UnixMilli(),
		ValidUntil:    now.Add(time.Duration(s.Config.HeartbeatSeconds*3) * time.Second).UnixMilli(),
		UptimeSeconds: int64(time.Since(s.started).Seconds()), UserSession: sample.Session, HID: sample.HID,
		Diagnostics: append([]string{}, sample.Diagnostics...)}
	state.MQTT.Configured = s.Config.MQTT.URL != ""
	state.MQTT.Connected = s.Publisher != nil && s.Publisher.Connected()
	s.mu.Lock()
	state.Power = s.power
	if state.UserSession.OnConsole == nil || !*state.UserSession.OnConsole || state.UserSession.LoginDone == nil || !*state.UserSession.LoginDone {
		s.lockEvent = ""
	} else if state.UserSession.Available && state.UserSession.LockState == "unknown" && s.lockEvent != "" {
		state.UserSession.LockState = s.lockEvent
		state.UserSession.LockSource = "screen_notification"
		filtered := state.Diagnostics[:0]
		for _, item := range state.Diagnostics {
			if item != "screen_lock_state_unavailable" {
				filtered = append(filtered, item)
			}
		}
		state.Diagnostics = filtered
	}
	if s.watchFailed {
		state.Diagnostics = append(state.Diagnostics, "power_monitor_unavailable")
	}
	s.mu.Unlock()
	s.Store.Put(state)
	s.recordChanges(previous, state)
}
func (s *Service) Handle(event platform.Event) {
	s.mu.Lock()
	if event.At <= 0 {
		event.At = time.Now().UnixMilli()
	}
	switch event.Kind {
	case "monitor_ready":
		if !s.power.Monitoring {
			s.Journal.Append("power_monitor_ready", "unavailable", "ready", "", event.At)
		}
		s.power.Monitoring = true
	case "will_sleep":
		if s.power.State != "sleeping" {
			s.Journal.Append("will_sleep", s.power.State, "sleeping", "", event.At)
		}
		s.power.State = "sleeping"
		s.power.LastEvent = event.Kind
		s.power.LastEventAt = event.At
	case "did_wake":
		if s.power.LastEvent == event.Kind && s.power.LastEventAt == event.At {
			break
		}
		s.Journal.Append("did_wake", s.power.State, "awake", "", event.At)
		s.power.State = "awake"
		s.power.LastEvent = event.Kind
		s.power.LastEventAt = event.At
		s.power.WakeCount++
	case "screen_locked":
		s.lockEvent = "locked"
	case "screen_unlocked":
		s.lockEvent = "unlocked"
	}
	s.mu.Unlock()
}
func (s *Service) Run(ctx context.Context) {
	events := make(chan platform.Event, 32)
	var workers sync.WaitGroup
	workers.Add(1)
	go func() {
		defer workers.Done()
		timer := time.NewTicker(time.Duration(s.Config.SampleSeconds) * time.Second)
		defer timer.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case event := <-events:
				s.Handle(event)
				s.Sample()
				if s.Publisher != nil {
					s.Publisher.Notify()
				}
			case <-timer.C:
				s.Sample()
			}
		}
	}()
	if s.Publisher != nil {
		workers.Add(1)
		go func() { defer workers.Done(); s.Publisher.Run(ctx, s.Store.Get) }()
	}
	// macOS notification delivery is serviced on the initial OS thread; HTTP,
	// MQTT and sampling stay on independent goroutines.
	if err := s.Probe.Watch(ctx, events); err != nil && ctx.Err() == nil {
		s.mu.Lock()
		s.watchFailed = true
		s.power.Monitoring = false
		s.Journal.Append("power_monitor_unavailable", "ready", "unavailable", "power_monitor_unavailable", time.Now().UnixMilli())
		s.mu.Unlock()
		s.Sample()
		<-ctx.Done()
	}
	workers.Wait()
}

// Diagnostics 复用快照，HTTP 轮询不会触发额外的系统或网络查询。
func (s *Service) Diagnostics() model.DiagnosticReport {
	current := s.Store.Get()
	connection := model.ConnectionStatus{Connected: current.MQTT.Connected}
	if status, ok := s.Publisher.(interface{ Status() model.ConnectionStatus }); ok {
		connection = status.Status()
	}
	return diagnostics.Live(current, connection, time.Now())
}
func consoleState(s model.Session) string {
	if !s.Available || s.OnConsole == nil || s.LoginDone == nil {
		return "unknown"
	}
	if *s.OnConsole && *s.LoginDone {
		return "active"
	}
	return "inactive"
}
func (s *Service) recordChanges(previous, current model.State) {
	at := current.ObservedAt
	if from, to := consoleState(previous.UserSession), consoleState(current.UserSession); from != to {
		s.Journal.Append("console_"+to, from, to, "", at)
	}
	lock := current.UserSession.LockState
	if lock != previous.UserSession.LockState && (lock == "locked" || lock == "unlocked" || lock == "unknown") {
		kind := "screen_" + lock
		if lock == "unknown" {
			kind = "screen_lock_unknown"
		}
		s.Journal.Append(kind, previous.UserSession.LockState, lock, "", at)
	}
	hid := current.HID.State
	if hid != previous.HID.State && (hid == "registered" || hid == "absent" || hid == "unknown") {
		s.Journal.Append("hid_"+hid, previous.HID.State, hid, "", at)
	}
}
