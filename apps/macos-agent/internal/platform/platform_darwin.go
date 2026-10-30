//go:build darwin && cgo

package platform

/*
#cgo CXXFLAGS: -std=c++23 -fno-exceptions -fno-rtti
#cgo LDFLAGS: -framework CoreFoundation -framework CoreGraphics -framework IOKit
#include "native.hpp"
*/
import "C"

import (
	"bytes"
	"context"
	"errors"
	"os/exec"
	"runtime"
	"sync"
	"time"

	"github.com/lpxxn/tepy/apps/macos-agent/internal/model"
)

type nativeProbe struct{}

func NativeSupported() bool { return true }

var hidCache struct {
	sync.Mutex
	sampled    time.Time
	deviceID   string
	value      model.HID
	diagnostic string
}

type limitedBuffer struct{ bytes.Buffer }

func (b *limitedBuffer) Write(p []byte) (int, error) {
	if b.Len()+len(p) > 65536 {
		return 0, errors.New("hidutil_output_too_large")
	}
	return b.Buffer.Write(p)
}
func optionalBool(value C.int) *bool {
	if value < 0 {
		return nil
	}
	result := value != 0
	return &result
}
func (nativeProbe) Sample(deviceID string) Snapshot {
	var native C.struct_tepy_session
	C.tepy_read_session(&native)
	result := Snapshot{Session: model.Session{Available: native.available != 0, OnConsole: optionalBool(native.on_console), LoginDone: optionalBool(native.login_done), LockState: "unknown", LockSource: "unavailable"}, Diagnostics: []string{}}
	if native.locked >= 0 {
		if native.locked != 0 {
			result.Session.LockState = "locked"
		} else {
			result.Session.LockState = "unlocked"
		}
	}
	if native.lock_source == 1 {
		result.Session.LockSource = "cg_session_property"
	}
	if native.lock_source == 2 {
		result.Session.LockSource = "io_console_property"
	}
	if !result.Session.Available {
		result.Diagnostics = append(result.Diagnostics, "gui_session_unavailable")
	}
	if result.Session.LockState == "unknown" {
		result.Diagnostics = append(result.Diagnostics, "screen_lock_state_unavailable")
	}
	hidCache.Lock()
	defer hidCache.Unlock()
	if hidCache.sampled.IsZero() || time.Since(hidCache.sampled) >= 5*time.Second || hidCache.deviceID != deviceID {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		command := exec.CommandContext(ctx, "/usr/bin/hidutil", "list", "--matching", `{"VendorID":12346,"ProductID":16385}`)
		var output limitedBuffer
		command.Stdout = &output
		err := command.Run()
		cancel()
		value := model.HID{State: "unknown", TargetDeviceID: deviceID, Devices: []model.HIDDevice{}}
		diagnostic := ""
		if err == nil {
			value, err = ParseHID(output.String(), deviceID)
		}
		if err != nil {
			diagnostic = "hid_probe_unavailable"
		}
		hidCache.value = value
		hidCache.diagnostic = diagnostic
		hidCache.deviceID = deviceID
		hidCache.sampled = time.Now()
	}
	result.HID = hidCache.value
	if hidCache.diagnostic != "" {
		result.Diagnostics = append(result.Diagnostics, hidCache.diagnostic)
	}
	return result
}
func (nativeProbe) Watch(ctx context.Context, events chan<- Event) error {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	observer := C.tepy_power_start()
	if observer == nil {
		return errors.New("power_monitor_unavailable")
	}
	defer C.tepy_power_stop(observer)
	select {
	case events <- Event{Kind: "monitor_ready", At: time.Now().UnixMilli()}:
	case <-ctx.Done():
		return nil
	}
	for ctx.Err() == nil {
		var value C.struct_tepy_event
		if C.tepy_power_poll(observer, &value) == 0 {
			continue
		}
		kind := "will_sleep"
		if value.kind == 2 {
			kind = "did_wake"
		}
		if value.kind == 3 {
			kind = "screen_locked"
		}
		if value.kind == 4 {
			kind = "screen_unlocked"
		}
		select {
		case events <- Event{Kind: kind, At: int64(value.at)}:
		case <-ctx.Done():
			return nil
		}
	}
	return nil
}
