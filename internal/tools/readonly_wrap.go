package tools

// Fork addition (mjshuster1): result wrapping for the read-only MCP surface
// (`serve --mcp-read-only`). See readonly.go for what it does and the
// OPENMESSAGES_MCP_SHOW_CODES opt-out.

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/mark3labs/mcp-go/mcp"
	"github.com/mark3labs/mcp-go/server"

	"github.com/maxghenis/openmessage/internal/app"
	"github.com/maxghenis/openmessage/internal/db"
	"github.com/maxghenis/openmessage/internal/readsource"
)

const (
	// freshnessLatestTTL matches /api/status's freshness cache.
	freshnessLatestTTL = 30 * time.Second
	// freshnessDaemonTTL caches the daemon's status in MCP client mode.
	freshnessDaemonTTL = 10 * time.Second
	// freshnessDaemonTimeout bounds the daemon status probe per tool call.
	freshnessDaemonTimeout = 2 * time.Second
	// freshnessSampleEvery is how often the in-process tracker samples the
	// Google state, so "disconnected since" is accurate to this interval.
	freshnessSampleEvery = 15 * time.Second
	// freshnessTimeLayout is local time, like the date arguments
	// (db.ParseDayBound) and the range tool's row labels.
	freshnessTimeLayout = "2006-01-02 15:04 MST"
)

// ApplyReadOnlySurface is ApplyReadOnly plus the read-only result wrapping:
// every kept tool except get_status starts its result with a one-line
// freshness note, and one-time codes are redacted from every kept tool's
// result unless OPENMESSAGES_MCP_SHOW_CODES=1. options should be the ones the
// tools were registered with; Daemon set means MCP client mode, where the
// Google state comes from the running app's /api/status.
func ApplyReadOnlySurface(s *server.MCPServer, a *app.App, options Options) []string {
	removed := ApplyReadOnly(s)
	reporter := newFreshnessReporter(a, options)
	if options.Daemon == nil && a != nil {
		reporter.startSampling(freshnessSampleEvery)
	}
	wrapReadOnlyTools(s, reporter, os.Getenv("OPENMESSAGES_MCP_SHOW_CODES") != "1")
	return removed
}

func wrapReadOnlyTools(s *server.MCPServer, reporter *freshnessReporter, redact bool) {
	var wrapped []server.ServerTool
	for name, tool := range s.ListTools() {
		addFreshness := name != "get_status" && reporter != nil
		wrapped = append(wrapped, server.ServerTool{
			Tool:    tool.Tool,
			Handler: wrapReadOnlyHandler(tool.Handler, reporter, addFreshness, redact),
		})
	}
	if len(wrapped) > 0 {
		s.AddTools(wrapped...)
	}
}

func wrapReadOnlyHandler(inner server.ToolHandlerFunc, reporter *freshnessReporter, addFreshness, redact bool) server.ToolHandlerFunc {
	return func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		result, err := inner(ctx, req)
		if err != nil || result == nil {
			return result, err
		}
		line := ""
		if addFreshness {
			line = reporter.safeLine(ctx)
		}
		postProcessReadOnlyResult(result, line, redact)
		return result, nil
	}
}

// postProcessReadOnlyResult redacts codes and prepends the freshness line,
// in that order, so the line itself is never redacted.
func postProcessReadOnlyResult(result *mcp.CallToolResult, line string, redact bool) {
	prepended := line == ""
	for i, content := range result.Content {
		text, ok := mcp.AsTextContent(content)
		if !ok {
			continue
		}
		updated := *text
		if redact {
			updated.Text = RedactOneTimeCodes(updated.Text)
		}
		if !prepended {
			updated.Text = line + "\n" + updated.Text
			prepended = true
		}
		result.Content[i] = updated
	}
	if !prepended {
		result.Content = append([]mcp.Content{mcp.NewTextContent(line)}, result.Content...)
	}
	if result.StructuredContent != nil && (redact || line != "") {
		if generic, ok := toJSONValue(result.StructuredContent); ok {
			if redact {
				generic = redactStructured(generic)
			}
			if m, isMap := generic.(map[string]any); isMap && line != "" {
				m["freshness"] = line
			}
			result.StructuredContent = generic
		} else if redact {
			// Unmarshalable structured content can't be checked for codes.
			result.StructuredContent = nil
		}
	}
}

// freshnessReporter builds the one-line freshness note. Every source is
// optional; a missing one drops its half of the line.
type freshnessReporter struct {
	now          func() time.Time
	googleStatus func(ctx context.Context) (app.GoogleStatusSnapshot, bool)
	latestText   func() (int64, bool)

	mu sync.Mutex
	// Cached newest text timestamp.
	latestMS   int64
	latestOK   bool
	latestAt   time.Time
	latestTTL  time.Duration
	googleTTL  time.Duration
	googleSnap app.GoogleStatusSnapshot
	googleOK   bool
	googleAt   time.Time
	// Transition tracking for "disconnected since".
	observed       bool
	lastHealthy    bool
	unhealthySince time.Time
	sinceExact     bool
}

func newFreshnessReporter(a *app.App, options Options) *freshnessReporter {
	r := &freshnessReporter{now: time.Now, latestTTL: freshnessLatestTTL}
	reads := options.Reads
	if reads == nil && a != nil && a.Store != nil {
		reads = a.Store
	}
	if reads != nil {
		r.latestText = func() (int64, bool) { return newestGoogleTextMS(reads) }
	}
	switch {
	case options.Daemon != nil:
		daemon := options.Daemon
		r.googleTTL = freshnessDaemonTTL
		r.googleStatus = func(ctx context.Context) (app.GoogleStatusSnapshot, bool) {
			ctx, cancel := context.WithTimeout(ctx, freshnessDaemonTimeout)
			defer cancel()
			raw, err := daemon.RawStatus(ctx)
			if err != nil {
				return app.GoogleStatusSnapshot{}, false
			}
			return googleSnapshotFromStatus(raw)
		}
	case a != nil:
		r.googleStatus = func(context.Context) (app.GoogleStatusSnapshot, bool) {
			return a.GoogleStatus(), true
		}
	}
	return r
}

// googleSnapshotFromStatus reads the "google" block of an /api/status
// document, which the daemon marshals from app.GoogleStatusSnapshot.
func googleSnapshotFromStatus(raw map[string]any) (app.GoogleStatusSnapshot, bool) {
	block, ok := raw["google"].(map[string]any)
	if !ok {
		return app.GoogleStatusSnapshot{}, false
	}
	encoded, err := json.Marshal(block)
	if err != nil {
		return app.GoogleStatusSnapshot{}, false
	}
	var snap app.GoogleStatusSnapshot
	if err := json.Unmarshal(encoded, &snap); err != nil {
		return app.GoogleStatusSnapshot{}, false
	}
	return snap, true
}

// newestGoogleTextMS is /api/status's freshness.google.latest_ms: the newest
// sms/rcs message on the active read source. A v2 store answers with index
// seeks (PlatformLatest); the legacy store aggregates PlatformStats.
func newestGoogleTextMS(reads readsource.ReadSource) (int64, bool) {
	var latest []db.PlatformLatest
	if source, ok := reads.(platformLatestReader); ok {
		rows, err := source.PlatformLatest()
		if err != nil {
			return 0, false
		}
		latest = rows
	} else {
		stats, err := reads.PlatformStats()
		if err != nil {
			return 0, false
		}
		for _, st := range stats {
			latest = append(latest, db.PlatformLatest{Platform: st.Platform, LatestMS: st.LatestMS, LatestRecvMS: st.LatestRecvMS})
		}
	}
	var newest int64
	for _, st := range latest {
		if (st.Platform == "sms" || st.Platform == "rcs") && st.LatestMS > newest {
			newest = st.LatestMS
		}
	}
	return newest, true
}

type platformLatestReader interface {
	PlatformLatest() ([]db.PlatformLatest, error)
}

func (r *freshnessReporter) startSampling(every time.Duration) {
	if r.googleStatus == nil {
		return
	}
	r.sampleGoogle(context.Background())
	go func() {
		ticker := time.NewTicker(every)
		defer ticker.Stop()
		for range ticker.C {
			func() {
				defer func() { _ = recover() }()
				r.sampleGoogle(context.Background())
			}()
		}
	}()
}

// sampleGoogle reads the Google state now and records it.
func (r *freshnessReporter) sampleGoogle(ctx context.Context) (app.GoogleStatusSnapshot, bool) {
	snap, ok := r.googleStatus(ctx)
	r.mu.Lock()
	defer r.mu.Unlock()
	now := r.now()
	r.googleSnap, r.googleOK, r.googleAt = snap, ok, now
	if ok {
		r.observeLocked(googleHealthy(snap), now)
	}
	return snap, ok
}

func (r *freshnessReporter) observeLocked(healthy bool, now time.Time) {
	switch {
	case healthy:
		r.unhealthySince = time.Time{}
	case r.unhealthySince.IsZero():
		r.unhealthySince = now
		// Exact only when we saw the healthy state before it.
		r.sinceExact = r.observed && r.lastHealthy
	}
	r.observed = true
	r.lastHealthy = healthy
}

func (r *freshnessReporter) google(ctx context.Context) (app.GoogleStatusSnapshot, bool) {
	if r.googleStatus == nil {
		return app.GoogleStatusSnapshot{}, false
	}
	r.mu.Lock()
	if r.googleTTL > 0 && !r.googleAt.IsZero() && r.now().Sub(r.googleAt) < r.googleTTL {
		snap, ok := r.googleSnap, r.googleOK
		r.mu.Unlock()
		return snap, ok
	}
	r.mu.Unlock()
	return r.sampleGoogle(ctx)
}

func (r *freshnessReporter) newestText() (int64, bool) {
	if r.latestText == nil {
		return 0, false
	}
	r.mu.Lock()
	if !r.latestAt.IsZero() && r.now().Sub(r.latestAt) < r.latestTTL {
		ms, ok := r.latestMS, r.latestOK
		r.mu.Unlock()
		return ms, ok
	}
	r.mu.Unlock()
	ms, ok := r.latestText()
	r.mu.Lock()
	if ok || r.latestAt.IsZero() {
		r.latestMS, r.latestOK = ms, ok
	}
	r.latestAt = r.now()
	ms, ok = r.latestMS, r.latestOK
	r.mu.Unlock()
	return ms, ok
}

// safeLine is line, but a panic in a lookup yields no line instead of
// failing the tool call.
func (r *freshnessReporter) safeLine(ctx context.Context) (line string) {
	if r == nil {
		return ""
	}
	defer func() {
		if recover() != nil {
			line = ""
		}
	}()
	return r.line(ctx)
}

// line formats the freshness note. Formats:
//
//	Texts synced through <t>; Google Messages connected.
//	Texts synced through <t>.                        (Google state unavailable)
//	No texts stored yet; Google Messages connected.
//	WARNING: Google Messages has been disconnected since [at least ]<t> (<detail>). Messages after <newest> are missing; tell the user before relying on this.
//
// The warning says "is connected but the phone is not responding" instead of
// "has been disconnected" when only the phone is unreachable, and drops the
// "since" or "after" clause when that time is unknown.
func (r *freshnessReporter) line(ctx context.Context) string {
	newestMS, newestOK := r.newestText()
	snap, googleOK := r.google(ctx)
	newest := ""
	if newestOK && newestMS > 0 {
		newest = time.UnixMilli(newestMS).In(time.Local).Format(freshnessTimeLayout)
	}
	if googleOK && !googleHealthy(snap) {
		r.mu.Lock()
		since, exact := r.unhealthySince, r.sinceExact
		r.mu.Unlock()
		var b strings.Builder
		b.WriteString("WARNING: Google Messages ")
		phoneOnly := snap.Connected && !snap.NeedsRepair && !snap.NeedsPairing && !googleSupervisorBlocked(snap) && !snap.PhoneResponding
		if phoneOnly {
			b.WriteString("is connected but the phone is not responding")
		} else {
			b.WriteString("has been disconnected")
		}
		if !since.IsZero() {
			b.WriteString(" since ")
			if !exact {
				b.WriteString("at least ")
			}
			b.WriteString(since.In(time.Local).Format(freshnessTimeLayout))
		}
		if detail := googleUnhealthyDetail(snap); detail != "" && !phoneOnly {
			fmt.Fprintf(&b, " (%s)", detail)
		}
		if newest != "" {
			fmt.Fprintf(&b, ". Messages after %s are missing", newest)
		} else {
			b.WriteString(". New messages are missing")
		}
		b.WriteString("; tell the user before relying on this.")
		return b.String()
	}
	switch {
	case googleOK && newest != "":
		return fmt.Sprintf("Texts synced through %s; Google Messages connected.", newest)
	case googleOK && newestOK:
		return "No texts stored yet; Google Messages connected."
	case newest != "":
		return fmt.Sprintf("Texts synced through %s.", newest)
	default:
		return ""
	}
}

func googleSupervisorBlocked(s app.GoogleStatusSnapshot) bool {
	return s.Supervisor != nil && s.Supervisor.State == "blocked"
}

// googleHealthy reports whether texts are arriving: connected, the phone
// answering, and nothing parked or waiting on a person.
func googleHealthy(s app.GoogleStatusSnapshot) bool {
	return s.Connected && s.PhoneResponding && !s.NeedsPairing && !s.NeedsRepair && !googleSupervisorBlocked(s)
}

func googleUnhealthyDetail(s app.GoogleStatusSnapshot) string {
	switch {
	case googleSupervisorBlocked(s):
		reason := s.Supervisor.BlockReason
		if reason == "" {
			reason = "parked"
		}
		return "blocked: " + reason
	case s.NeedsPairing:
		return "needs pairing"
	case s.NeedsRepair:
		return "needs repair"
	case s.AuthExpired:
		return "auth expired, reconnecting"
	case s.Supervisor != nil && s.Supervisor.State != "" && s.Supervisor.State != "online":
		return s.Supervisor.State
	case s.Reconnecting:
		return "reconnecting"
	}
	return ""
}
