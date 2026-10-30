package launchd

import (
	"bytes"
	"encoding/xml"
	"io"
	"strings"
	"testing"
)

func TestPlistEscapesArgumentsAndContainsNoCredentials(t *testing.T) {
	data := Plist("/Users/example/a & b/tepy-agent", "/Users/example/a < b/agent.toml", "/Users/example/log.txt")
	decoder := xml.NewDecoder(bytes.NewReader(data))
	for {
		_, err := decoder.Token()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
	}
	if !strings.Contains(string(data), "a &amp; b") || !strings.Contains(string(data), "a &lt; b") || strings.Contains(string(data), "token") || strings.Contains(string(data), "password") {
		t.Fatal("unsafe LaunchAgent")
	}
}
