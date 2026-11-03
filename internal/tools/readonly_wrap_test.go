package tools

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/mark3labs/mcp-go/mcp"
	"github.com/mark3labs/mcp-go/server"

	"github.com/maxghenis/openmessage/internal/app"
)

func fixedReporter(now *time.Time, snap *app.GoogleStatusSnapshot, googleOK *bool, newestMS int64, newestOK bool) *freshnessReporter {
	return &freshnessReporter{
		now:       func() time.Time { return *now },
		latestTTL: time.Nanosecond,
		googleStatus: func(context.Context) (app.GoogleStatusSnapshot, bool) {
			return *snap, *googleOK
		},
		latestText: func() (int64, bool) { return newestMS, newestOK },
	}
}

func localFmt(t time.Time) string { return t.In(time.Local).Format(freshnessTimeLayout) }

func TestFreshnessLineHealthy(t *testing.T) {
	now := time.Date(2026, 11, 3, 15, 50, 0, 0, time.Local)
	newest := now.Add(-8 * time.Minute)
	snap := app.GoogleStatusSnapshot{Connected: true, Paired: true, PhoneResponding: true,
		Supervisor: &app.GoogleSupervisorStatus{State: "online"}}
	ok := true
	r := fixedReporter(&now, &snap, &ok, newest.UnixMilli(), true)
	want := "Texts synced through " + localFmt(newest) + "; Google Messages connected."
	if got := r.line(context.Background()); got != want {
		t.Fatalf("got %q want %q", got, want)
	}
}

func TestFreshnessLineBlockedSinceTransition(t *testing.T) {
	now := time.Date(2026, 11, 3, 15, 0, 0, 0, time.Local)
	newest := now.Add(-2 * time.Minute)
	snap := app.GoogleStatusSnapshot{Connected: true, Paired: true, PhoneResponding: true}
	ok := true
	r := fixedReporter(&now, &snap, &ok, newest.UnixMilli(), true)
	r.sampleGoogle(context.Background()) // healthy

	now = now.Add(time.Minute)
	disconnectedAt := now
	snap = app.GoogleStatusSnapshot{Paired: true, NeedsRepair: true, PhoneResponding: true,
		Supervisor: &app.GoogleSupervisorStatus{State: "blocked", BlockReason: "terminal_failure"}}
	r.sampleGoogle(context.Background())

	now = now.Add(30 * time.Minute)
	got := r.line(context.Background())
	want := "WARNING: Google Messages has been disconnected since " + localFmt(disconnectedAt) +
		" (blocked: terminal_failure). Messages after " + localFmt(newest) +
		" are missing; tell the user before relying on this."
	if got != want {
		t.Fatalf("got  %q\nwant %q", got, want)
	}
}

func TestFreshnessLineVariants(t *testing.T) {
	now := time.Date(2026, 11, 3, 15, 0, 0, 0, time.Local)
	newest := now.Add(-time.Hour)
	cases := []struct {
		name     string
		snap     app.GoogleStatusSnapshot
		googleOK bool
		newestOK bool
		newestMS int64
		want     string
	}{
		{"first seen disconnected", app.GoogleStatusSnapshot{Paired: true, PhoneResponding: true, Reconnecting: true,
			Supervisor: &app.GoogleSupervisorStatus{State: "backoff"}}, true, true, newest.UnixMilli(),
			"WARNING: Google Messages has been disconnected since at least " + localFmt(now) + " (backoff). Messages after " + localFmt(newest) + " are missing; tell the user before relying on this."},
		{"needs pairing", app.GoogleStatusSnapshot{NeedsPairing: true}, true, true, newest.UnixMilli(),
			"WARNING: Google Messages has been disconnected since at least " + localFmt(now) + " (needs pairing). Messages after " + localFmt(newest) + " are missing; tell the user before relying on this."},
		{"phone not responding", app.GoogleStatusSnapshot{Connected: true, Paired: true}, true, true, newest.UnixMilli(),
			"WARNING: Google Messages is connected but the phone is not responding since at least " + localFmt(now) + ". Messages after " + localFmt(newest) + " are missing; tell the user before relying on this."},
		{"no texts, disconnected", app.GoogleStatusSnapshot{NeedsPairing: true}, true, true, 0,
			"WARNING: Google Messages has been disconnected since at least " + localFmt(now) + " (needs pairing). New messages are missing; tell the user before relying on this."},
		{"google unknown", app.GoogleStatusSnapshot{}, false, true, newest.UnixMilli(),
			"Texts synced through " + localFmt(newest) + "."},
		{"nothing known", app.GoogleStatusSnapshot{}, false, false, 0, ""},
		{"no texts yet", app.GoogleStatusSnapshot{Connected: true, PhoneResponding: true}, true, true, 0,
			"No texts stored yet; Google Messages connected."},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			n, snap, ok := now, tc.snap, tc.googleOK
			r := fixedReporter(&n, &snap, &ok, tc.newestMS, tc.newestOK)
			if got := r.line(context.Background()); got != tc.want {
				t.Fatalf("got  %q\nwant %q", got, tc.want)
			}
		})
	}
}

func TestGoogleSnapshotFromDaemonStatus(t *testing.T) {
	raw := map[string]any{"google": map[string]any{
		"connected": false, "paired": true, "needs_repair": true, "phone_responding": true,
		"supervisor": map[string]any{"state": "blocked", "block_reason": "terminal_failure"},
	}}
	snap, ok := googleSnapshotFromStatus(raw)
	if !ok || snap.Supervisor == nil || snap.Supervisor.BlockReason != "terminal_failure" || googleHealthy(snap) {
		t.Fatalf("snapshot = %+v ok=%v", snap, ok)
	}
	if _, ok := googleSnapshotFromStatus(map[string]any{}); ok {
		t.Fatal("missing google block should be unknown")
	}
}

func TestReadOnlyWrapPrependsLineAndRedacts(t *testing.T) {
	now := time.Date(2026, 11, 3, 15, 0, 0, 0, time.Local)
	snap := app.GoogleStatusSnapshot{Connected: true, PhoneResponding: true}
	ok := true
	r := fixedReporter(&now, &snap, &ok, now.UnixMilli(), true)

	s := server.NewMCPServer("test", "0")
	s.AddTool(mcp.NewTool("search_messages"), func(context.Context, mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		return structuredResult(map[string]any{
			"messages": []messageSummary{{MessageID: "482193", Body: "Your code is 482193"}},
		}, "«Your code is 482193»"), nil
	})
	s.AddTool(mcp.NewTool("get_messages"), func(context.Context, mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		return textResult("«G-123456 is your Google verification code.»"), nil
	})
	s.AddTool(mcp.NewTool("get_status"), func(context.Context, mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		return textResult("Overall: connected"), nil
	})
	s.AddTool(mcp.NewTool("list_contacts"), func(context.Context, mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		return nil, errors.New("boom")
	})
	wrapReadOnlyTools(s, r, true)

	call := func(name string) (*mcp.CallToolResult, error) {
		return s.GetTool(name).Handler(context.Background(), mcp.CallToolRequest{})
	}
	line := "Texts synced through " + localFmt(now) + "; Google Messages connected."

	res, _ := call("search_messages")
	text := res.Content[0].(mcp.TextContent).Text
	if text != line+"\n«Your code is [code hidden]»" {
		t.Errorf("search_messages text = %q", text)
	}
	structured := res.StructuredContent.(map[string]any)
	msg := structured["messages"].([]any)[0].(map[string]any)
	if msg["body"] != "Your code is [code hidden]" || msg["message_id"] != "482193" || structured["freshness"] != line {
		t.Errorf("structured = %v", structured)
	}

	res, _ = call("get_messages")
	if got := res.Content[0].(mcp.TextContent).Text; got != line+"\n«[code hidden] is your Google verification code.»" {
		t.Errorf("get_messages text = %q", got)
	}

	res, _ = call("get_status")
	if got := res.Content[0].(mcp.TextContent).Text; got != "Overall: connected" {
		t.Errorf("get_status should not get a freshness line: %q", got)
	}

	if _, err := call("list_contacts"); err == nil || err.Error() != "boom" {
		t.Errorf("handler error not passed through: %v", err)
	}
}

func TestReadOnlyWrapShowCodesOptOut(t *testing.T) {
	s := server.NewMCPServer("test", "0")
	s.AddTool(mcp.NewTool("get_messages"), func(context.Context, mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		return textResult("Your code is 482193"), nil
	})
	wrapReadOnlyTools(s, nil, false)
	res, _ := s.GetTool("get_messages").Handler(context.Background(), mcp.CallToolRequest{})
	if got := res.Content[0].(mcp.TextContent).Text; got != "Your code is 482193" {
		t.Errorf("opt-out text = %q", got)
	}
}

func TestReadOnlyWrapSurvivesPanickingLookup(t *testing.T) {
	r := &freshnessReporter{
		now:          time.Now,
		latestTTL:    time.Second,
		googleStatus: func(context.Context) (app.GoogleStatusSnapshot, bool) { panic("status exploded") },
	}
	s := server.NewMCPServer("test", "0")
	s.AddTool(mcp.NewTool("get_messages"), func(context.Context, mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		return textResult("hello"), nil
	})
	wrapReadOnlyTools(s, r, true)
	res, err := s.GetTool("get_messages").Handler(context.Background(), mcp.CallToolRequest{})
	if err != nil || res.Content[0].(mcp.TextContent).Text != "hello" {
		t.Fatalf("res=%v err=%v", res, err)
	}
}

func TestApplyReadOnlySurfaceWrapsRealTools(t *testing.T) {
	t.Setenv("OPENMESSAGES_MCP_SHOW_CODES", "")
	a := testApp(t)
	s := server.NewMCPServer("test", "0")
	opts := Options{Reads: a.Store}
	RegisterWithOptions(s, a, opts)
	ApplyReadOnlySurface(s, a, opts)
	if got, want := strings.Join(registeredNames(s), ","), strings.Join(sortedReadOnly(), ","); got != want {
		t.Fatalf("tools = %s want %s", got, want)
	}
	res, err := s.GetTool("list_conversations").Handler(context.Background(), mcp.CallToolRequest{})
	if err != nil {
		t.Fatal(err)
	}
	first := res.Content[0].(mcp.TextContent).Text
	// An empty test app has no Google session: the line must warn.
	if !strings.HasPrefix(first, "WARNING: Google Messages has been disconnected") {
		t.Fatalf("first line = %q", strings.SplitN(first, "\n", 2)[0])
	}
}

func sortedReadOnly() []string {
	out := append([]string(nil), ReadOnlyTools...)
	for i := range out {
		for j := i + 1; j < len(out); j++ {
			if out[j] < out[i] {
				out[i], out[j] = out[j], out[i]
			}
		}
	}
	return out
}
