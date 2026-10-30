package launchd

import (
	"bytes"
	"context"
	"encoding/xml"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"time"
)

const Label = "com.tepy.macos-agent"

func escaped(value string) string {
	var b bytes.Buffer
	_ = xml.EscapeText(&b, []byte(value))
	return b.String()
}
func Plist(binary, configPath, logPath string) []byte {
	return []byte(fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>%s</string>
<key>ProgramArguments</key><array><string>%s</string><string>run</string><string>-config</string><string>%s</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ThrottleInterval</key><integer>10</integer>
<key>LimitLoadToSessionType</key><string>Aqua</string>
<key>ProcessType</key><string>Background</string>
<key>StandardOutPath</key><string>%s</string>
<key>StandardErrorPath</key><string>%s</string>
</dict></plist>
`, Label, escaped(binary), escaped(configPath), escaped(logPath), escaped(logPath)))
}
func command(args ...string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := exec.CommandContext(ctx, "/bin/launchctl", args...).Run(); err != nil {
		return errors.New("launchctl failed; check the GUI login session and installation paths")
	}
	return nil
}
func Install(configPath string) error {
	if runtime.GOOS != "darwin" || os.Geteuid() == 0 {
		return errors.New("install as the logged-in macOS user, without sudo")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return errors.New("cannot find home directory")
	}
	source, err := os.Executable()
	if err != nil {
		return errors.New("cannot locate executable")
	}
	dir := filepath.Join(home, "Library", "Application Support", "Tepy", "bin")
	logDir := filepath.Join(home, "Library", "Logs", "Tepy")
	plistDir := filepath.Join(home, "Library", "LaunchAgents")
	for _, p := range []string{dir, logDir, plistDir} {
		if err := os.MkdirAll(p, 0700); err != nil {
			return errors.New("cannot create agent directories")
		}
	}
	binary := filepath.Join(dir, "tepy-agent")
	plistPath := filepath.Join(plistDir, Label+".plist")
	domain := "gui/" + strconv.Itoa(os.Getuid())
	target := domain + "/" + Label
	if command("print", target) == nil {
		if err := command("bootout", target); err != nil {
			return err
		}
		deadline := time.Now().Add(5 * time.Second)
		for command("print", target) == nil {
			if time.Now().After(deadline) {
				return errors.New("previous LaunchAgent is still stopping; retry installation shortly")
			}
			time.Sleep(100 * time.Millisecond)
		}
	}
	if source != binary {
		data, err := os.ReadFile(source)
		if err != nil {
			return errors.New("cannot read executable")
		}
		if err := os.WriteFile(binary+".new", data, 0700); err != nil {
			return errors.New("cannot install executable")
		}
		if err := os.Rename(binary+".new", binary); err != nil {
			return errors.New("cannot replace executable")
		}
	}
	absolute, err := filepath.Abs(configPath)
	if err != nil {
		return errors.New("invalid configuration path")
	}
	if err := os.WriteFile(plistPath+".new", Plist(binary, absolute, filepath.Join(logDir, "agent.log")), 0600); err != nil {
		return errors.New("cannot write LaunchAgent")
	}
	if err := os.Rename(plistPath+".new", plistPath); err != nil {
		return errors.New("cannot replace LaunchAgent")
	}
	var bootstrapErr error
	for attempt := 0; attempt < 3; attempt++ {
		bootstrapErr = command("bootstrap", domain, plistPath)
		if bootstrapErr == nil {
			return nil
		}
		if command("print", target) == nil {
			return nil
		}
		time.Sleep(250 * time.Millisecond)
	}
	return bootstrapErr
}
func Uninstall() error {
	if runtime.GOOS != "darwin" || os.Geteuid() == 0 {
		return errors.New("uninstall as the logged-in macOS user, without sudo")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return errors.New("cannot find home directory")
	}
	_ = command("bootout", "gui/"+strconv.Itoa(os.Getuid())+"/"+Label)
	if err := os.Remove(filepath.Join(home, "Library", "LaunchAgents", Label+".plist")); err != nil && !os.IsNotExist(err) {
		return errors.New("cannot remove LaunchAgent")
	}
	return nil // Configuration, credentials, logs and binary are intentionally preserved.
}
