//go:build !darwin || !cgo

package platform

import (
	"context"
	"errors"
	"github.com/lpxxn/tepy/apps/macos-agent/internal/model"
)

type nativeProbe struct{}

func NativeSupported() bool { return false }
func (nativeProbe) Sample(deviceID string) Snapshot {
	return Snapshot{Session: model.Session{LockState: "unknown", LockSource: "unavailable"},
		HID:         model.HID{State: "unknown", TargetDeviceID: deviceID, Devices: []model.HIDDevice{}},
		Diagnostics: []string{"native_macos_probe_unavailable"}}
}
func (nativeProbe) Watch(context.Context, chan<- Event) error {
	return errors.New("native_macos_power_monitor_unavailable")
}
