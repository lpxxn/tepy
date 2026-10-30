package platform

import (
	"errors"
	"strconv"
	"strings"

	"github.com/lpxxn/tepy/apps/macos-agent/internal/model"
)

// Parse only the Devices section: the Services section describes the same HID
// again and must not double-count it. Column offsets come from that section's header.
func ParseHID(input, deviceID string) (model.HID, error) {
	result := model.HID{State: "unknown", TargetDeviceID: deviceID, Devices: []model.HIDDevice{}}
	if deviceID != "" && (len(deviceID) != 12 || strings.Trim(deviceID, "0123456789abcdef") != "") {
		return result, errors.New("invalid_target_device_id")
	}
	devices := false
	header := false
	var transportAt, classAt, productAt, userClassAt int
	for _, line := range strings.Split(input, "\n") {
		if strings.TrimSpace(line) == "Devices:" {
			devices = true
			continue
		}
		if !devices {
			continue
		}
		if strings.HasPrefix(line, "VendorID ") {
			transportAt = strings.Index(line, "Transport")
			classAt = strings.Index(line, "Class")
			productAt = strings.Index(line, "Product ")
			userClassAt = strings.Index(line, "UserClass")
			header = transportAt > 0 && classAt > transportAt && productAt > classAt && userClassAt > productAt
			if !header {
				return result, errors.New("unsupported_hidutil_format")
			}
			continue
		}
		if strings.TrimSpace(line) == "" {
			continue
		}
		if !header {
			return result, errors.New("unsupported_hidutil_format")
		}
		fields := strings.Fields(line)
		if len(fields) < 6 || len(line) < userClassAt {
			return result, errors.New("unsupported_hidutil_format")
		}
		vendor, e1 := strconv.ParseUint(fields[0], 0, 16)
		product, e2 := strconv.ParseUint(fields[1], 0, 16)
		page, e3 := strconv.ParseUint(fields[3], 0, 16)
		usage, e4 := strconv.ParseUint(fields[4], 0, 16)
		_, e5 := strconv.ParseUint(fields[5], 0, 64)
		if e1 != nil || e2 != nil || e3 != nil || e4 != nil || e5 != nil {
			return result, errors.New("unsupported_hidutil_format")
		}
		if vendor != 0x303a || product != 0x4001 || page != 1 || usage != 6 {
			continue
		}
		name := strings.TrimSpace(line[productAt:userClassAt])
		if deviceID != "" && !strings.EqualFold(name, "Tepy-"+deviceID[6:]) {
			continue
		}
		if len(result.Devices) >= 8 {
			return result, errors.New("too_many_tepy_devices")
		}
		result.Devices = append(result.Devices, model.HIDDevice{Product: name,
			Transport: strings.TrimSpace(line[transportAt:classAt]), RegistryID: fields[5]})
	}
	if !header {
		return result, errors.New("unsupported_hidutil_format")
	}
	result.Available = true
	result.State = "absent"
	if len(result.Devices) > 0 {
		result.State = "registered"
	}
	return result, nil
}
