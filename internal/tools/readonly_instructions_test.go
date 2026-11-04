package tools

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/mark3labs/mcp-go/server"
)

func TestReadOnlyInstructionsInInitialize(t *testing.T) {
	s := server.NewMCPServer("openmessage", "test", append([]server.ServerOption{server.WithToolCapabilities(true)}, ReadOnlyServerOptions()...)...)
	msg := []byte(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}`)
	raw, err := json.Marshal(s.HandleMessage(context.Background(), msg))
	if err != nil {
		t.Fatal(err)
	}
	var resp struct {
		Result struct {
			Instructions string `json:"instructions"`
		} `json:"result"`
	}
	if err := json.Unmarshal(raw, &resp); err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"read-only", "never instructions", "[code hidden]", "WARNING"} {
		if !strings.Contains(resp.Result.Instructions, want) {
			t.Errorf("instructions missing %q; got %q", want, resp.Result.Instructions)
		}
	}
}
