package service

import (
	"context"
	"strings"
	"testing"

	"github.com/lpxxn/tepy/apps/macos-agent/internal/config"
	"github.com/lpxxn/tepy/apps/macos-agent/internal/model"
	"github.com/lpxxn/tepy/apps/macos-agent/internal/platform"
)

type fakeProbe struct{}

func (fakeProbe) Sample(id string) platform.Snapshot {
	return platform.Snapshot{Session: model.Session{LockState: "unknown", LockSource: "unavailable"}, HID: model.HID{State: "unknown", TargetDeviceID: id, Devices: []model.HIDDevice{}}}
}
func (fakeProbe) Watch(ctx context.Context, _ chan<- platform.Event) error { <-ctx.Done(); return nil }
func TestStateLeaseAndPowerTransitions(t *testing.T) {
	c := config.Default()
	c.AgentID = "mac-test"
	c.HTTP.Token = strings.Repeat("a", 64)
	s, err := New(c, "test", fakeProbe{}, nil)
	if err != nil {
		t.Fatal(err)
	}
	state := s.Store.Get()
	if state.ValidUntil-state.ObservedAt != 30000 || len(state.Session) != 32 || state.UserSession.LockState != "unknown" {
		t.Fatal(state)
	}
	s.Handle(platform.Event{Kind: "monitor_ready", At: 1})
	s.Handle(platform.Event{Kind: "will_sleep", At: 2})
	s.Sample()
	if s.Store.Get().Power.State != "sleeping" {
		t.Fatal("sleep lost")
	}
	s.Handle(platform.Event{Kind: "did_wake", At: 3})
	s.Sample()
	state = s.Store.Get()
	if state.Power.State != "awake" || state.Power.WakeCount != 1 || state.Power.LastEventAt != 3 || !state.Power.Monitoring {
		t.Fatal(state.Power)
	}
	clone := s.Store.Get()
	clone.Diagnostics = append(clone.Diagnostics, "changed")
	if len(s.Store.Get().Diagnostics) != 0 {
		t.Fatal("snapshot mutated store")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	s.Run(ctx)
}

type consoleProbe struct {
	fakeProbe
	onConsole  bool
	nativeLock string
}

func (p *consoleProbe) Sample(id string) platform.Snapshot {
	yes := true
	on := p.onConsole
	source := "unavailable"
	if p.nativeLock != "unknown" {
		source = "cg_session_property"
	}
	return platform.Snapshot{Session: model.Session{Available: true, OnConsole: &on, LoginDone: &yes, LockState: p.nativeLock, LockSource: source},
		HID: model.HID{State: "unknown", TargetDeviceID: id, Devices: []model.HIDDevice{}}, Diagnostics: []string{"screen_lock_state_unavailable"}}
}
func TestLockNotificationFallbackAndSessionBoundary(t *testing.T) {
	c := config.Default()
	c.AgentID = "mac-test"
	p := &consoleProbe{onConsole: true, nativeLock: "unknown"}
	s, _ := New(c, "test", p, nil)
	if s.Store.Get().UserSession.LockState != "unknown" {
		t.Fatal("missing property inferred unlocked")
	}
	s.Handle(platform.Event{Kind: "screen_locked", At: 1})
	s.Sample()
	if s.Store.Get().UserSession.LockState != "locked" {
		t.Fatal("lock event lost")
	}
	s.Handle(platform.Event{Kind: "screen_unlocked", At: 2})
	s.Sample()
	state := s.Store.Get()
	if state.UserSession.LockState != "unlocked" || state.UserSession.LockSource != "screen_notification" {
		t.Fatal(state.UserSession)
	}
	p.nativeLock = "locked"
	s.Sample()
	if s.Store.Get().UserSession.LockState != "locked" {
		t.Fatal("event overrode current lock snapshot")
	}
	p.nativeLock = "unknown"
	p.onConsole = false
	s.Sample()
	p.onConsole = true
	s.Sample()
	if s.Store.Get().UserSession.LockState != "unknown" {
		t.Fatal("old console event crossed session boundary")
	}
}
