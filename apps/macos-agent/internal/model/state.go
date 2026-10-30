package model

import "sync"

type Session struct {
	Available  bool   `json:"available"`
	OnConsole  *bool  `json:"on_console"`
	LoginDone  *bool  `json:"login_done"`
	LockState  string `json:"lock_state"`
	LockSource string `json:"lock_source"`
}
type HIDDevice struct {
	Product    string `json:"product"`
	Transport  string `json:"transport"`
	RegistryID string `json:"registry_id"`
}
type HID struct {
	Available      bool        `json:"available"`
	State          string      `json:"state"`
	TargetDeviceID string      `json:"target_device_id"`
	Devices        []HIDDevice `json:"devices"`
}
type Power struct {
	Monitoring  bool   `json:"monitoring"`
	State       string `json:"state"`
	LastEvent   string `json:"last_event"`
	LastEventAt int64  `json:"last_event_at"`
	WakeCount   uint64 `json:"wake_count"`
}
type State struct {
	V             int    `json:"v"`
	AgentID       string `json:"agent_id"`
	AgentVersion  string `json:"agent_version"`
	Name          string `json:"name"`
	Platform      string `json:"platform"`
	Session       string `json:"session"`
	Sequence      uint64 `json:"sequence"`
	ObservedAt    int64  `json:"observed_at"`
	ValidUntil    int64  `json:"valid_until"`
	UptimeSeconds int64  `json:"uptime_seconds"`
	MQTT          struct {
		Configured bool `json:"configured"`
		Connected  bool `json:"connected"`
	} `json:"mqtt"`
	UserSession Session  `json:"user_session"`
	HID         HID      `json:"hid"`
	Power       Power    `json:"power"`
	Diagnostics []string `json:"diagnostics"`
}
type Store struct {
	mu    sync.RWMutex
	state State
}

func (s *Store) Put(value State) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.state = clone(value)
}
func (s *Store) Get() State { s.mu.RLock(); defer s.mu.RUnlock(); return clone(s.state) }
func clone(s State) State {
	s.HID.Devices = append([]HIDDevice{}, s.HID.Devices...)
	s.Diagnostics = append([]string{}, s.Diagnostics...)
	if s.UserSession.OnConsole != nil {
		value := *s.UserSession.OnConsole
		s.UserSession.OnConsole = &value
	}
	if s.UserSession.LoginDone != nil {
		value := *s.UserSession.LoginDone
		s.UserSession.LoginDone = &value
	}
	return s
}
