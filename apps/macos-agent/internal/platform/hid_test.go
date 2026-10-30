package platform

import (
	"strings"
	"testing"
)

const hidExample = `Services:
VendorID ProductID LocationID UsagePage Usage RegistryID  Transport            Class                    Product     UserClass               Built-In
0x303a   0x4001    0x424aaca5 1         6     0x1000195f0 Bluetooth Low Energy AppleUserHIDEventService Tepy-da3a18 AppleUserHIDEventDriver 0

Devices:
VendorID ProductID LocationID UsagePage Usage RegistryID  Transport            Class           Product     UserClass Built-In
0x303a   0x4001    0x424aaca5 1         6     0x1000195ed Bluetooth Low Energy IOHIDUserDevice Tepy-da3a18 (null)    0
`

func TestHIDMac27Keyboard(t *testing.T) {
	result, err := ParseHID(hidExample, "24587cda3a18")
	if err != nil || result.State != "registered" || len(result.Devices) != 1 || result.Devices[0].Product != "Tepy-da3a18" || result.Devices[0].Transport != "Bluetooth Low Energy" {
		t.Fatal(result, err)
	}
	filtered, err := ParseHID(hidExample, "001122334455")
	if err != nil || filtered.State != "absent" {
		t.Fatal(filtered, err)
	}
	empty := strings.Split(hidExample, "0x303a")[0] + "\nDevices:\nVendorID ProductID LocationID UsagePage Usage RegistryID  Transport            Class           Product     UserClass Built-In\n"
	absent, err := ParseHID(empty, "")
	if err != nil || absent.State != "absent" {
		t.Fatal(absent, err)
	}
}
func TestHIDUnknownIsNotAbsent(t *testing.T) {
	for _, input := range []string{"permission denied", "Devices:\nbroken header\n", strings.Replace(hidExample, "Devices:", "Unsupported:", 1)} {
		result, err := ParseHID(input, "")
		if err == nil || result.State != "unknown" || result.Available {
			t.Fatal("uncertain HID state accepted", result, err)
		}
	}
	if _, err := ParseHID(hidExample, "short"); err == nil {
		t.Fatal("invalid target accepted")
	}
}
func FuzzHIDNeverPanics(f *testing.F) {
	f.Add(hidExample, "24587cda3a18")
	f.Add("", "")
	f.Fuzz(func(t *testing.T, input, target string) { _, _ = ParseHID(input, target) })
}
