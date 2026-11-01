package spamwatch

import (
	"bytes"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"

	"github.com/maxghenis/openmessage/internal/db"
)

type blockCall struct{ conv, phone, action string }

type fakeBlocker struct {
	mu    sync.Mutex
	calls []blockCall
	err   error
}

func (f *fakeBlocker) fn(conv, phone, action string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, blockCall{conv, phone, action})
	return f.err
}

func oneToOne(id, number string) *db.Conversation {
	return &db.Conversation{ConversationID: id, Participants: `[{"number":"` + number + `"},{"number":"+15559990000","is_me":true}]`}
}

func writeRules(t *testing.T, w *Watcher, content string) {
	t.Helper()
	if err := os.WriteFile(w.RulesPath(), []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
}

func spamMsg(id, conv, number string) *db.Message {
	return &db.Message{MessageID: id, ConversationID: conv, SenderNumber: number, Body: spamBody}
}

func TestLogModeNeverCallsBlocker(t *testing.T) {
	store := &fakeStore{convs: map[string]*db.Conversation{"c": oneToOne("c", "+15550001111")}}
	w := newTestWatcher(t, store)
	b := &fakeBlocker{}
	w.SetBlocker(b.fn)
	w.Check(spamMsg("m", "c", "+15550001111"))
	w.Wait()
	if len(b.calls) != 0 {
		t.Fatalf("blocker called in log mode: %+v", b.calls)
	}
	e := readEntries(t, w)
	if len(e) != 1 || e[0].Action != "logged" || e[0].Note != "" {
		t.Fatalf("entries = %+v", e)
	}
}

func TestBlockModeBlocksAndReports(t *testing.T) {
	store := &fakeStore{convs: map[string]*db.Conversation{"c": oneToOne("c", "+15550001111")}}
	w := newTestWatcher(t, store)
	b := &fakeBlocker{}
	w.SetBlocker(b.fn)
	writeRules(t, w, `{"mode":"block"}`)
	w.Check(spamMsg("m", "c", "+15550001111"))
	w.Wait()
	if len(b.calls) != 1 || b.calls[0] != (blockCall{"c", "+15550001111", ActionBlockAndReport}) {
		t.Fatalf("calls = %+v", b.calls)
	}
	e := readEntries(t, w)
	if len(e) != 1 || e[0].Action != "blocked" {
		t.Fatalf("entries = %+v", e)
	}
}

func TestBlockModeNoReport(t *testing.T) {
	store := &fakeStore{convs: map[string]*db.Conversation{"c": oneToOne("c", "+15550001111")}}
	w := newTestWatcher(t, store)
	b := &fakeBlocker{}
	w.SetBlocker(b.fn)
	writeRules(t, w, `{"mode":"block","no_report":true}`)
	w.Check(spamMsg("m", "c", "+15550001111"))
	w.Wait()
	if len(b.calls) != 1 || b.calls[0].action != ActionBlock {
		t.Fatalf("calls = %+v", b.calls)
	}
}

func TestBlockModeSkips(t *testing.T) {
	cases := []struct {
		name, number, wantNote string
		conv                   *db.Conversation
		rules                  string
	}{
		{"group", "+15550001111", "group thread: never auto-blocked",
			&db.Conversation{ConversationID: "c", IsGroup: true, Participants: `[]`}, `{"mode":"block"}`},
		{"short code", "88022", "short code", oneToOne("c", "88022"), `{"mode":"block"}`},
		{"unknown conversation", "+15550001111", "conversation not in store yet", nil, `{"mode":"block"}`},
		{"two others", "+15550001111", "could not find exactly one other participant",
			&db.Conversation{ConversationID: "c", Participants: `[{"number":"+15550001111"},{"number":"+15550002222"}]`}, `{"mode":"block"}`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			store := &fakeStore{convs: map[string]*db.Conversation{}}
			if tc.conv != nil {
				store.convs["c"] = tc.conv
			}
			w := newTestWatcher(t, store)
			b := &fakeBlocker{}
			w.SetBlocker(b.fn)
			writeRules(t, w, tc.rules)
			w.Check(spamMsg("m", "c", tc.number))
			w.Wait()
			if len(b.calls) != 0 {
				t.Fatalf("blocker called: %+v", b.calls)
			}
			e := readEntries(t, w)
			if len(e) != 1 || e[0].Action != "logged" || e[0].Note != tc.wantNote {
				t.Fatalf("entries = %+v", e)
			}
		})
	}
}

func TestBlockModeShortCodeAllowed(t *testing.T) {
	store := &fakeStore{convs: map[string]*db.Conversation{"c": oneToOne("c", "88022")}}
	w := newTestWatcher(t, store)
	b := &fakeBlocker{}
	w.SetBlocker(b.fn)
	writeRules(t, w, `{"mode":"block","block_short_codes":true}`)
	w.Check(spamMsg("m", "c", "88022"))
	w.Wait()
	if len(b.calls) != 1 {
		t.Fatalf("calls = %+v", b.calls)
	}
}

func TestDailyCapCountsFromLogAndReleasesOnFailure(t *testing.T) {
	store := &fakeStore{convs: map[string]*db.Conversation{
		"a": oneToOne("a", "+15550000001"),
		"b": oneToOne("b", "+15550000002"),
		"c": oneToOne("c", "+15550000003"),
	}}
	w := newTestWatcher(t, store)
	b := &fakeBlocker{}
	w.SetBlocker(b.fn)
	writeRules(t, w, `{"mode":"block","max_blocks_per_day":2}`)

	// A block already logged today counts toward the cap after a restart.
	prior, _ := json.Marshal(Entry{Time: w.now().Format("2006-01-02T15:04:05Z07:00"), Action: "blocked", Matched: []string{}})
	if err := os.WriteFile(w.LogPath(), append(prior, '\n'), 0o600); err != nil {
		t.Fatal(err)
	}

	b.err = errors.New("phone said no")
	w.Check(spamMsg("m1", "a", "+15550000001")) // fails, slot released
	w.Wait()
	b.err = nil
	w.Check(spamMsg("m2", "b", "+15550000002")) // uses the last slot
	w.Wait()
	w.Check(spamMsg("m3", "c", "+15550000003")) // over the cap
	w.Wait()

	if len(b.calls) != 2 {
		t.Fatalf("calls = %+v", b.calls)
	}
	e := readEntries(t, w)
	got := []string{e[1].Action, e[2].Action, e[3].Action}
	want := []string{"block_failed", "blocked", "logged"}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("actions = %v, want %v", got, want)
		}
	}
	if !strings.Contains(e[3].Note, "daily cap of 2") {
		t.Errorf("cap note = %q", e[3].Note)
	}
}

func TestBlockRunsOffCallerGoroutine(t *testing.T) {
	store := &fakeStore{convs: map[string]*db.Conversation{"c": oneToOne("c", "+15550001111")}}
	w := newTestWatcher(t, store)
	release := make(chan struct{})
	w.SetBlocker(func(string, string, string) error { <-release; return nil })
	writeRules(t, w, `{"mode":"block"}`)
	w.Check(spamMsg("m", "c", "+15550001111")) // must return while the blocker waits
	close(release)
	w.Wait()
}

func TestManualRefusesContactsAndGroups(t *testing.T) {
	store := &fakeStore{
		contacts: []*db.Contact{{ContactID: "1", Number: "5550001111"}},
		convs: map[string]*db.Conversation{
			"friend": oneToOne("friend", "+15550001111"),
			"group":  {ConversationID: "group", IsGroup: true},
		},
	}
	w := newTestWatcher(t, store)
	b := &fakeBlocker{}
	w.SetBlocker(b.fn)
	for _, id := range []string{"friend", "group", "missing"} {
		if err := w.Manual(id, ActionBlockAndReport); err == nil || !strings.HasPrefix(err.Error(), "refused:") {
			t.Errorf("%s: err = %v", id, err)
		}
	}
	if len(b.calls) != 0 {
		t.Fatalf("calls = %+v", b.calls)
	}
	// Unblock is always allowed, even for a contact.
	if err := w.Manual("friend", ActionUnblock); err != nil {
		t.Fatal(err)
	}
	if len(b.calls) != 1 || b.calls[0].action != ActionUnblock || b.calls[0].phone != "+15550001111" {
		t.Fatalf("calls = %+v", b.calls)
	}
}

func TestManualWithoutBlocker(t *testing.T) {
	w := newTestWatcher(t, &fakeStore{})
	if err := w.Manual("c", ActionBlock); err == nil {
		t.Fatal("expected error without blocker")
	}
}

func TestHTTPEndpointAuth(t *testing.T) {
	store := &fakeStore{convs: map[string]*db.Conversation{"c": oneToOne("c", "+15550001111")}}
	w := newTestWatcher(t, store)
	b := &fakeBlocker{}
	w.SetBlocker(b.fn)
	next := http.HandlerFunc(func(rw http.ResponseWriter, r *http.Request) { rw.WriteHeader(299) })
	h := w.WrapHTTP(next, "secret")

	do := func(method string, headers map[string]string, remote string) int {
		body, _ := json.Marshal(BlockRequest{ConversationID: "c", Action: ActionBlockAndReport})
		r := httptest.NewRequest(method, BlockPath, bytes.NewReader(body))
		r.RemoteAddr = remote
		for k, v := range headers {
			r.Header.Set(k, v)
		}
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, r)
		return rec.Code
	}
	local := "127.0.0.1:5000"
	auth := map[string]string{"Authorization": "Bearer secret"}

	if c := do(http.MethodGet, auth, local); c != http.StatusMethodNotAllowed {
		t.Errorf("GET = %d", c)
	}
	if c := do(http.MethodPost, nil, local); c != http.StatusUnauthorized {
		t.Errorf("no token = %d", c)
	}
	if c := do(http.MethodPost, map[string]string{"Authorization": "Bearer wrong"}, local); c != http.StatusUnauthorized {
		t.Errorf("wrong token = %d", c)
	}
	if c := do(http.MethodPost, map[string]string{"Authorization": "Bearer secret", "Origin": "http://127.0.0.1:7007"}, local); c != http.StatusForbidden {
		t.Errorf("browser origin = %d", c)
	}
	if c := do(http.MethodPost, auth, "192.168.1.5:5000"); c != http.StatusForbidden {
		t.Errorf("non-loopback = %d", c)
	}
	if len(b.calls) != 0 {
		t.Fatalf("blocker called by rejected request: %+v", b.calls)
	}
	if c := do(http.MethodPost, auth, local); c != http.StatusOK {
		t.Errorf("good request = %d", c)
	}
	if len(b.calls) != 1 {
		t.Fatalf("calls = %+v", b.calls)
	}

	// Other paths pass through untouched.
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/status", nil))
	if rec.Code != 299 {
		t.Errorf("passthrough = %d", rec.Code)
	}

	// No token configured: endpoint disabled.
	rec = httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodPost, BlockPath, strings.NewReader(`{}`))
	r.RemoteAddr = local
	w.WrapHTTP(next, "").ServeHTTP(rec, r)
	if rec.Code != http.StatusServiceUnavailable {
		t.Errorf("no token configured = %d", rec.Code)
	}
}
