package spamwatch

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/maxghenis/openmessage/internal/db"
)

type historyStore struct {
	*fakeStore
	list []*db.Conversation
	msgs map[string][]*db.Message
}

func (h *historyStore) ListConversations(int) ([]*db.Conversation, error) { return h.list, nil }

func (h *historyStore) GetMessagesByConversationBetween(id string, start, end int64, _ int) ([]*db.Message, error) {
	var out []*db.Message
	for _, m := range h.msgs[id] {
		if m.TimestampMS >= start && m.TimestampMS <= end {
			out = append(out, m)
		}
	}
	return out, nil
}

func newScanFixture(t *testing.T) (*Watcher, *historyStore) {
	t.Helper()
	now := time.Date(2026, 11, 2, 9, 0, 0, 0, time.UTC)
	recent := now.Add(-48 * time.Hour).UnixMilli()
	old := now.Add(-60 * 24 * time.Hour).UnixMilli()
	spam := oneToOne("spam", "+15550001111")
	spam.LastMessageTS = recent
	friend := oneToOne("friend", "+15552223333")
	friend.LastMessageTS = recent
	group := &db.Conversation{ConversationID: "group", IsGroup: true, LastMessageTS: recent}
	clean := oneToOne("clean", "+15554445555")
	clean.LastMessageTS = recent
	stale := oneToOne("stale", "+15556667777")
	stale.LastMessageTS = old
	mine := oneToOne("mine", "+15558889999")
	mine.LastMessageTS = recent
	short := oneToOne("short", "12345")
	short.LastMessageTS = recent
	chat := oneToOne("chat", "+15551231234")
	chat.LastMessageTS = recent
	chat.SourcePlatform = "whatsapp"

	fs := &fakeStore{
		contacts: []*db.Contact{{Number: "+1 (555) 222-3333"}},
		convs:    map[string]*db.Conversation{},
	}
	h := &historyStore{fakeStore: fs, list: []*db.Conversation{spam, friend, group, clean, stale, mine, short, chat}, msgs: map[string][]*db.Message{}}
	for _, c := range h.list {
		fs.convs[c.ConversationID] = c
	}
	add := func(conv, number, body string, ts int64, fromMe bool) {
		h.msgs[conv] = append(h.msgs[conv], &db.Message{MessageID: conv + body[:3], ConversationID: conv, SenderNumber: number, Body: body, TimestampMS: ts, IsFromMe: fromMe})
	}
	add("spam", "+15550001111", "Chip in now, Stop2End", recent-1000, false)
	add("spam", "+15550001111", spamBody, recent, false)
	add("friend", "+15552223333", spamBody, recent, false)
	add("group", "+15550001111", spamBody, recent, false)
	add("clean", "+15554445555", "see you at dinner", recent, false)
	add("stale", "+15556667777", spamBody, old, false)
	add("mine", "+15558889999", spamBody, recent, true)
	add("short", "12345", spamBody, recent, false)
	add("chat", "+15551231234", spamBody, recent, false)

	w := New(zerolog.Nop(), h, t.TempDir())
	w.now = func() time.Time { return now }
	return w, h
}

func TestScanFindsOnlyRuleMatchesFromStrangers(t *testing.T) {
	w, _ := newScanFixture(t)
	scanned, cands, err := w.Scan(30)
	if err != nil {
		t.Fatal(err)
	}
	if scanned != 6 { // stale is out of range, chat is not SMS
		t.Fatalf("scanned = %d", scanned)
	}
	got := map[string]ScanCandidate{}
	for _, c := range cands {
		got[c.ConversationID] = c
	}
	if len(got) != 3 {
		t.Fatalf("candidates = %+v", cands)
	}
	if c := got["spam"]; !c.Blockable || c.Matches != 2 || c.SenderNumber != "+15550001111" || c.AlreadyBlocked {
		t.Fatalf("spam = %+v", c)
	}
	if c := got["group"]; c.Blockable || c.Skip != "group thread" {
		t.Fatalf("group = %+v", c)
	}
	if c := got["short"]; c.Blockable || c.Skip != "short code" {
		t.Fatalf("short = %+v", c)
	}
	for _, id := range []string{"friend", "clean", "stale", "mine", "chat"} {
		if _, ok := got[id]; ok {
			t.Fatalf("%s should not be a candidate", id)
		}
	}
}

func TestScanMarksThreadsTheLogRecordsAsBlocked(t *testing.T) {
	w, _ := newScanFixture(t)
	w.record(Entry{Time: w.now().Format(time.RFC3339), ConversationID: "spam", Action: "manual_block"})
	_, cands, _ := w.Scan(30)
	for _, c := range cands {
		if c.ConversationID == "spam" && !c.AlreadyBlocked {
			t.Fatal("spam should be already blocked")
		}
	}
	w.record(Entry{Time: w.now().Format(time.RFC3339), ConversationID: "spam", Action: "manual_unblock"})
	_, cands, _ = w.Scan(30)
	for _, c := range cands {
		if c.ConversationID == "spam" && c.AlreadyBlocked {
			t.Fatal("unblock should clear already blocked")
		}
	}
}

func TestScanNeverCallsTheBlocker(t *testing.T) {
	w, _ := newScanFixture(t)
	b := &fakeBlocker{}
	w.SetBlocker(b.fn)
	writeRules(t, w, `{"mode":"block"}`)
	if _, _, err := w.Scan(30); err != nil {
		t.Fatal(err)
	}
	if len(b.calls) != 0 {
		t.Fatalf("scan called the blocker: %+v", b.calls)
	}
}

func TestScanEndpointNeedsTokenAndReturnsCandidates(t *testing.T) {
	w, _ := newScanFixture(t)
	h := w.WrapHTTP(http.NotFoundHandler(), "secret")
	do := func(auth, origin string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodPost, ScanPath, bytes.NewBufferString(`{"days":30}`))
		req.RemoteAddr = "127.0.0.1:5000"
		if auth != "" {
			req.Header.Set("Authorization", auth)
		}
		if origin != "" {
			req.Header.Set("Origin", origin)
		}
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		return rec
	}
	if rec := do("", ""); rec.Code != http.StatusUnauthorized {
		t.Fatalf("no token: %d", rec.Code)
	}
	if rec := do("Bearer secret", "https://evil.example"); rec.Code != http.StatusForbidden {
		t.Fatalf("origin: %d", rec.Code)
	}
	rec := do("Bearer secret", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("ok: %d %s", rec.Code, rec.Body.String())
	}
	var resp ScanResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil || !resp.OK || len(resp.Candidates) != 3 {
		t.Fatalf("resp = %+v err=%v", resp, err)
	}
}
