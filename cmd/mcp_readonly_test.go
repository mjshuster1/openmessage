package cmd

import "testing"

func TestParseServeOptionsMCPReadOnly(t *testing.T) {
	opts, err := parseServeOptions([]string{"--mcp-read-only"})
	if err != nil {
		t.Fatal(err)
	}
	if !opts.mcpReadOnly {
		t.Fatal("--mcp-read-only not set")
	}
	def, err := parseServeOptions(nil)
	if err != nil {
		t.Fatal(err)
	}
	if def.mcpReadOnly {
		t.Fatal("read-only must be off by default")
	}
	if def.web != opts.web || def.mcpSSE != opts.mcpSSE || def.mcpStdio != opts.mcpStdio {
		t.Fatal("--mcp-read-only must not change which transports run")
	}
}
