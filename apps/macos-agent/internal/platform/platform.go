package platform

import (
	"context"
	"github.com/lpxxn/tepy/apps/macos-agent/internal/model"
)

type Snapshot struct {
	Session     model.Session
	HID         model.HID
	Diagnostics []string
}
type Event struct {
	Kind string
	At   int64
}
type Probe interface {
	Sample(deviceID string) Snapshot
	Watch(context.Context, chan<- Event) error
}

func New() Probe { return nativeProbe{} }
