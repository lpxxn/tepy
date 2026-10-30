package service

import (
	"context"
	"runtime"
	"sync"
	"time"

	"github.com/lpxxn/tepy/apps/macos-agent/internal/config"
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
	Store       model.Store
	Probe       platform.Probe
	Publisher   Publisher
	Instance    string
	Version     string
	started     time.Time
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
	s.Sample()
	return s, nil
}
func (s *Service) Sample() {
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
}
func (s *Service) Handle(event platform.Event) {
	s.mu.Lock()
	switch event.Kind {
	case "monitor_ready":
		s.power.Monitoring = true
	case "will_sleep":
		s.power.State = "sleeping"
		s.power.LastEvent = event.Kind
		s.power.LastEventAt = event.At
	case "did_wake":
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
		s.mu.Unlock()
		<-ctx.Done()
	}
	workers.Wait()
}
