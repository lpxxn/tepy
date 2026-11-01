package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/lpxxn/tepy/apps/macos-agent/internal/api"
	"github.com/lpxxn/tepy/apps/macos-agent/internal/config"
	"github.com/lpxxn/tepy/apps/macos-agent/internal/diagnostics"
	"github.com/lpxxn/tepy/apps/macos-agent/internal/launchd"
	"github.com/lpxxn/tepy/apps/macos-agent/internal/model"
	"github.com/lpxxn/tepy/apps/macos-agent/internal/mqtt"
	"github.com/lpxxn/tepy/apps/macos-agent/internal/platform"
	"github.com/lpxxn/tepy/apps/macos-agent/internal/service"
)

var version = "0.2.1"

func init() { runtime.LockOSThread() }

func defaultPath() string {
	base, err := os.UserConfigDir()
	if err != nil {
		return "agent.toml"
	}
	return filepath.Join(base, "Tepy", "agent.toml")
}
func execute(args []string) error {
	if len(args) == 0 {
		return errors.New("usage: tepy-agent init|validate|doctor|probe|run|status|diagnostics|events|install|uninstall|version [-config path]")
	}
	if args[0] == "version" {
		fmt.Println(version)
		return nil
	}
	if args[0] == "uninstall" {
		return launchd.Uninstall()
	}
	flags := flag.NewFlagSet("tepy-agent", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	path := flags.String("config", defaultPath(), "TOML configuration path")
	offline := flags.Bool("offline", false, "doctor: skip network probes")
	after := flags.String("after", "", "events: sequence cursor")
	session := flags.String("session", "", "events: process session")
	limit := flags.Int("limit", 50, "events: maximum records")
	if err := flags.Parse(args[1:]); err != nil || flags.NArg() != 0 {
		return errors.New("invalid arguments; use -config <TOML path>")
	}
	if (args[0] != "doctor" && *offline) || (args[0] != "events" && (*after != "" || *session != "" || *limit != 50)) {
		return errors.New("flags are not supported by this command")
	}
	if args[0] == "doctor" {
		ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
		defer cancel()
		report := diagnostics.Doctor(ctx, *path, version, platform.New(), platform.NativeSupported(), *offline)
		if err := json.NewEncoder(os.Stdout).Encode(report); err != nil {
			return errors.New("cannot write diagnostic report")
		}
		if report.Status == "error" {
			return errors.New("doctor found errors; see diagnostic check codes")
		}
		return nil
	}
	if args[0] == "init" {
		if err := config.WriteInitial(*path); err != nil {
			return err
		}
		fmt.Printf("Configuration created: %s\n", *path)
		return nil
	}
	cfg, err := config.Load(*path)
	if err != nil {
		return err
	}
	switch args[0] {
	case "validate":
		if _, err := cfg.TLSConfig(); err != nil {
			return err
		}
		fmt.Println("Configuration valid")
		return nil
	case "probe":
		app, err := service.New(cfg, version, platform.New(), nil)
		if err != nil {
			return err
		}
		return json.NewEncoder(os.Stdout).Encode(app.Store.Get())
	case "status":
		return readStatus(cfg)
	case "diagnostics":
		return readReport(cfg, "/api/v1/agent/diagnostics")
	case "events":
		values := url.Values{}
		values.Set("limit", strconv.Itoa(*limit))
		if *after != "" {
			values.Set("after", *after)
		}
		if *session != "" {
			values.Set("session", *session)
		}
		return readReport(cfg, "/api/v1/agent/events?"+values.Encode())
	case "install":
		if !platform.NativeSupported() {
			return errors.New("macOS native build required")
		}
		if _, err := cfg.TLSConfig(); err != nil {
			return err
		}
		if err := launchd.Install(*path); err != nil {
			return err
		}
		fmt.Println("LaunchAgent installed for current GUI user")
		return nil
	case "run":
		return run(cfg)
	default:
		return errors.New("unknown subcommand")
	}
}
func readStatus(c config.Config) error {
	host, port, _ := net.SplitHostPort(c.HTTP.Listen)
	if net.ParseIP(host).IsUnspecified() {
		host = "127.0.0.1"
	}
	req, _ := http.NewRequest(http.MethodGet, "http://"+net.JoinHostPort(host, port)+"/api/v1/agent/status", nil)
	req.Header.Set("Authorization", "Bearer "+c.HTTP.Token)
	client := &http.Client{Timeout: 3 * time.Second, Transport: &http.Transport{Proxy: nil}, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	resp, err := client.Do(req)
	if err != nil {
		return errors.New("cannot reach agent status endpoint")
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return errors.New("agent status request rejected")
	}
	var current model.State
	if err := json.NewDecoder(io.LimitReader(resp.Body, 65536)).Decode(&current); err != nil || current.V != 1 || current.AgentID != c.AgentID {
		return errors.New("invalid agent status response")
	}
	return json.NewEncoder(os.Stdout).Encode(current)
}
func run(c config.Config) error {
	if !platform.NativeSupported() {
		return errors.New("run requires a native macOS build with CGo enabled")
	}
	publisher, err := mqtt.New(c)
	if err != nil {
		return err
	}
	app, err := service.New(c, version, platform.New(), publisher)
	if err != nil {
		return err
	}
	listener, err := net.Listen("tcp", c.HTTP.Listen)
	if err != nil {
		return errors.New("cannot listen on http.listen; address unavailable or another agent is running")
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	server := api.Server(c.HTTP.Listen, c.HTTP.Token, app.Store.Get, api.Sources{Diagnostics: app.Diagnostics, Events: app.Journal})
	stopped := make(chan error, 1)
	go func() {
		err := server.Serve(listener)
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			stopped <- errors.New("HTTP status server stopped")
			cancel()
		}
	}()
	log.Printf("tepy-agent %s started; agent_id=%s mqtt_configured=%t", version, c.AgentID, c.MQTT.URL != "")
	app.Run(ctx)
	shutdown, done := context.WithTimeout(context.Background(), 3*time.Second)
	defer done()
	_ = server.Shutdown(shutdown)
	select {
	case err := <-stopped:
		return err
	default:
		return nil
	}
}
func main() {
	if err := execute(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "tepy-agent:", err)
		os.Exit(1)
	}
}

// 复用本机 Bearer 身份读取新接口，不需要将口令放到终端命令行或 URL。
func readReport(c config.Config, path string) error {
	host, port, _ := net.SplitHostPort(c.HTTP.Listen)
	if net.ParseIP(host).IsUnspecified() {
		host = "127.0.0.1"
	}
	request, _ := http.NewRequest(http.MethodGet, "http://"+net.JoinHostPort(host, port)+path, nil)
	request.Header.Set("Authorization", "Bearer "+c.HTTP.Token)
	client := &http.Client{Timeout: 3 * time.Second, Transport: &http.Transport{Proxy: nil}, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	response, err := client.Do(request)
	if err != nil {
		return errors.New("cannot reach agent endpoint")
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return errors.New("agent request rejected; check service version and event cursor/session")
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, 65537))
	if err != nil || len(data) > 65536 {
		return errors.New("invalid agent response")
	}
	var identity struct {
		V       int    `json:"v"`
		AgentID string `json:"agent_id"`
	}
	if json.Unmarshal(data, &identity) != nil || identity.V != 1 || identity.AgentID != c.AgentID {
		return errors.New("invalid agent identity")
	}
	if strings.HasPrefix(path, "/api/v1/agent/events") {
		var page model.EventPage
		if json.Unmarshal(data, &page) != nil || page.Capacity != model.EventCapacity || len(page.Events) > model.EventCapacity {
			return errors.New("invalid event response")
		}
		return json.NewEncoder(os.Stdout).Encode(page)
	} else {
		var report model.DiagnosticReport
		if json.Unmarshal(data, &report) != nil || report.Source != "live" || len(report.Checks) > 32 {
			return errors.New("invalid diagnostic response")
		}
		return json.NewEncoder(os.Stdout).Encode(report)
	}
}
