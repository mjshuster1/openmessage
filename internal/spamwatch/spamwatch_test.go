package spamwatch

import (
	"bytes"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/maxghenis/openmessage/internal/db"
)

type fakeStore struct {
	contacts    []*db.Contact
	convs       map[string]*db.Conversation
	contactsErr error
	listCalls   int
}

func (f *fakeStore) ListContacts(string, int) ([]*db.Contact, error) {
	f.listCalls++
	return f.contacts, f.contactsErr
}

func (f *fakeStore) GetConversation(id string) (*db.Conversation, error) {
	if c, ok := f.convs[id]; ok {
		return c, nil
	}
	return nil, sql.ErrNoRows
}

func newTestWatcher(t *testing.T, store *fakeStore) *Watcher {
	t.Helper()
	w := New(zerolog.Nop(), store, t.TempDir())
	w.now = func() time.Time { return time.Date(2026, 11, 2, 9, 0, 0, 0, time.UTC) }
	return w
}

func readEntries(t *testing.T, w *Watcher) []Entry {
	t.Helper()
	entries, err := ReadLog(w.LogPath(), time.Time{})
	if err != nil {
		t.Fatal(err)
	}
	return entries
}

const spamBody = "Matt, polls close soon! Chip in $5 now: actblue.com/x Paid for by Committee. Reply STOP to end"

func TestUnknownSenderMatchIsLogged(t *testing.T) {
	store := &fakeStore{convs: map[string]*db.Conversation{
		"c1": {ConversationID: "c1", Participants: `[{"name":"","number":"+15550001111","contact_id":""}]`},
	}}
	w := newTestWatcher(t, store)
	w.Check(&db.Message{MessageID: "m1", ConversationID: "c1", SenderNumber: "+15550001111", Body: spamBody})

	entries := readEntries(t, w)
	if len(entries) != 1 {
		t.Fatalf("got %d entries, want 1", len(entries))
	}
	e := entries[0]
	for _, want := range []string{"phrase:paid for by", "phrase:reply stop", "phrase:chip in", "phrase:actblue"} {
		if !contains(e.Matched, want) {
			t.Errorf("matched %v missing %q", e.Matched, want)
		}
	}
	if !e.ConversationKnown || e.IsGroup || e.ShortCode {
		t.Errorf("unexpected flags: %+v", e)
	}
	info, err := os.Stat(w.LogPath())
	if err != nil {
		t.Fatal(err)
	}
	if perm := info.Mode().Perm(); perm != 0o600 {
		t.Errorf("log perm = %o, want 600", perm)
	}
}

func TestSavedContactIsNeverLogged(t *testing.T) {
	store := &fakeStore{contacts: []*db.Contact{{ContactID: "1", Name: "Aunt", Number: "(555) 000-1111"}}}
	w := newTestWatcher(t, store)
	w.Check(&db.Message{MessageID: "m1", ConversationID: "c1", SenderNumber: "+1 555-000-1111", Body: spamBody})
	if n := len(readEntries(t, w)); n != 0 {
		t.Fatalf("contact message logged %d times", n)
	}
}

func TestContactLoadFailureTreatsSenderAsUnknown(t *testing.T) {
	store := &fakeStore{contactsErr: errors.New("db down")}
	w := newTestWatcher(t, store)
	w.Check(&db.Message{MessageID: "m1", SenderNumber: "+15550001111", Body: spamBody})
	if n := len(readEntries(t, w)); n != 1 {
		t.Fatalf("got %d entries, want 1", n)
	}
}

func TestContactsAreCached(t *testing.T) {
	store := &fakeStore{}
	w := newTestWatcher(t, store)
	for i := 0; i < 3; i++ {
		w.Check(&db.Message{MessageID: "m", SenderNumber: "+15550001111", Body: "hello"})
	}
	if store.listCalls != 1 {
		t.Fatalf("ListContacts called %d times, want 1", store.listCalls)
	}
}

func TestSkips(t *testing.T) {
	cases := map[string]*db.Message{
		"from me":  {MessageID: "m", SenderNumber: "+15550001111", Body: spamBody, IsFromMe: true},
		"whatsapp": {MessageID: "m", SenderNumber: "+15550001111", Body: spamBody, SourcePlatform: "whatsapp"},
		"signal":   {MessageID: "m", SenderNumber: "+15550001111", Body: spamBody, SourcePlatform: "signal"},
		"no match": {MessageID: "m", SenderNumber: "+15550001111", Body: "Are we still on for lunch?"},
		"empty":    {MessageID: "m", SenderNumber: "+15550001111"},
		"nil-ish":  nil,
	}
	for name, msg := range cases {
		t.Run(name, func(t *testing.T) {
			w := newTestWatcher(t, &fakeStore{})
			w.Check(msg)
			if n := len(readEntries(t, w)); n != 0 {
				t.Fatalf("logged %d entries, want 0", n)
			}
		})
	}
}

func TestGroupAndShortCodeAreLoggedAndTagged(t *testing.T) {
	store := &fakeStore{convs: map[string]*db.Conversation{
		"g": {ConversationID: "g", IsGroup: true, Participants: `[]`},
	}}
	w := newTestWatcher(t, store)
	w.Check(&db.Message{MessageID: "m1", ConversationID: "g", SenderNumber: "+15550001111", Body: "Early voting ends Saturday"})
	w.Check(&db.Message{MessageID: "m2", ConversationID: "unknown", SenderNumber: "88022", Body: "Donate today. Text STOP to quit"})
	entries := readEntries(t, w)
	if len(entries) != 2 {
		t.Fatalf("got %d entries, want 2", len(entries))
	}
	if !entries[0].IsGroup {
		t.Error("group not tagged")
	}
	if !entries[1].ShortCode || entries[1].ConversationKnown {
		t.Errorf("short code entry flags wrong: %+v", entries[1])
	}
}

func TestUserRulesFileAndReload(t *testing.T) {
	w := newTestWatcher(t, &fakeStore{})
	msg := &db.Message{MessageID: "m1", SenderNumber: "+1 (555) 222-3333", Body: "Hi from Jane Candidate's team"}

	w.Check(msg)
	if n := len(readEntries(t, w)); n != 0 {
		t.Fatalf("matched before rules file existed")
	}

	write := func(content string, mod time.Time) {
		if err := os.WriteFile(w.RulesPath(), []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
		if err := os.Chtimes(w.RulesPath(), mod, mod); err != nil {
			t.Fatal(err)
		}
	}
	write(`{"phrases":["Jane  CANDIDATE"],"numbers":["5552223333"]}`, time.Now().Add(-time.Hour))
	w.Check(msg)
	entries := readEntries(t, w)
	if len(entries) != 1 {
		t.Fatalf("got %d entries, want 1", len(entries))
	}
	if !contains(entries[0].Matched, "phrase:jane candidate") || !contains(entries[0].Matched, "number:5552223333") {
		t.Errorf("matched = %v", entries[0].Matched)
	}

	write(`not json`, time.Now())
	w.Check(msg)
	if n := len(readEntries(t, w)); n != 1 {
		t.Fatalf("invalid rules file should fall back to built-ins; got %d entries", n)
	}
}

func TestParticipantContactIDRecorded(t *testing.T) {
	store := &fakeStore{convs: map[string]*db.Conversation{
		"c": {ConversationID: "c", Participants: `[{"number":"+15550001111","contact_id":"42"},{"number":"me","is_me":true}]`},
	}}
	w := newTestWatcher(t, store)
	w.Check(&db.Message{MessageID: "m", ConversationID: "c", SenderNumber: "5550001111", Body: spamBody})
	entries := readEntries(t, w)
	if len(entries) != 1 || entries[0].ParticipantContID != "42" {
		t.Fatalf("entries = %+v", entries)
	}
}

func TestNumberKeyAndShortCode(t *testing.T) {
	if NumberKey("+1 (555) 000-1111") != "5550001111" || NumberKey("5550001111") != "5550001111" {
		t.Error("NumberKey normalization")
	}
	if NumberKey("88022") != "88022" || NumberKey("") != "" {
		t.Error("NumberKey short/empty")
	}
	for n, want := range map[string]bool{"88022": true, "123456": true, "1234": false, "+15550001111": false, "": false, "8802a": false} {
		if IsShortCode(n) != want {
			t.Errorf("IsShortCode(%q) = %v", n, !want)
		}
	}
}

func TestSnippetTruncates(t *testing.T) {
	s := snippet(strings.Repeat("a", 500))
	if len([]rune(s)) != snippetRunes+1 {
		t.Errorf("snippet length %d", len([]rune(s)))
	}
}

func TestReportStripsControlCharacters(t *testing.T) {
	var buf bytes.Buffer
	WriteReport(&buf, []Entry{{
		Time: "2026-11-02T09:00:00Z", SenderNumber: "+15550001111",
		Matched: []string{"phrase:donate"}, Snippet: "Donate \x1b[31mnow\x1b[0m‮", IsGroup: true,
	}}, time.Time{})
	out := buf.String()
	if strings.ContainsAny(out, "\x1b‮") {
		t.Errorf("control characters leaked: %q", out)
	}
	if !strings.Contains(out, "[group]") || !strings.Contains(out, "nothing was blocked") {
		t.Errorf("report missing expected text: %s", out)
	}
}

func TestReadLogMissingFileAndSinceFilter(t *testing.T) {
	dir := t.TempDir()
	if e, err := ReadLog(filepath.Join(dir, "none.jsonl"), time.Time{}); err != nil || e != nil {
		t.Fatalf("missing file: %v %v", e, err)
	}
	path := filepath.Join(dir, LogFileName)
	content := `{"time":"2026-10-30T09:00:00Z","matched":["a"]}
garbage
{"time":"2026-11-02T09:00:00Z","matched":["b"]}
`
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	e, err := ReadLog(path, time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC))
	if err != nil || len(e) != 1 || e[0].Matched[0] != "b" {
		t.Fatalf("got %+v %v", e, err)
	}
}

func contains(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}
