package spamwatch_test

// End-to-end through the real Google event handler and SQLite store: a libgm
// event goes in, the spam log (and blocker) is checked on the way out. This
// covers the wiring in cmd/serve.go: OnIncomingMessage -> Watcher.Check.

import (
	"sync"
	"testing"
	"time"

	"github.com/rs/zerolog"
	"go.mau.fi/mautrix-gmessages/pkg/libgm"
	"go.mau.fi/mautrix-gmessages/pkg/libgm/gmproto"

	"github.com/maxghenis/openmessage/internal/client"
	"github.com/maxghenis/openmessage/internal/db"
	"github.com/maxghenis/openmessage/internal/spamwatch"
)

const spamText = "Polls close Tuesday! Chip in $5: actblue.com/x Paid for by Committee. Reply STOP to end"

func conversation(id, number string) *gmproto.Conversation {
	return &gmproto.Conversation{
		ConversationID: id,
		Participants: []*gmproto.Participant{
			{ID: &gmproto.SmallInfo{Number: number, ParticipantID: "p-" + id}, FullName: number},
			{ID: &gmproto.SmallInfo{Number: "+15559990000"}, IsMe: true},
		},
	}
}

func message(id, conv, number, body string, fromMe, old bool) *libgm.WrappedMessage {
	return &libgm.WrappedMessage{
		IsOld: old,
		Message: &gmproto.Message{
			MessageID:      id,
			ConversationID: conv,
			Timestamp:      time.Now().UnixMicro(),
			SenderParticipant: &gmproto.Participant{
				IsMe: fromMe,
				ID:   &gmproto.SmallInfo{Number: number},
			},
			MessageInfo: []*gmproto.MessageInfo{{
				Data: &gmproto.MessageInfo_MessageContent{MessageContent: &gmproto.MessageContent{Content: body}},
			}},
		},
	}
}

type harness struct {
	t       *testing.T
	watcher *spamwatch.Watcher
	handler *client.EventHandler
	mu      sync.Mutex
	blocks  []string
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	store, err := db.New(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { store.Close() })
	if err := store.UpsertContact(&db.Contact{ContactID: "1", Name: "Friend", Number: "(555) 000-2222"}); err != nil {
		t.Fatal(err)
	}
	h := &harness{t: t}
	h.watcher = spamwatch.New(zerolog.Nop(), store, t.TempDir())
	h.watcher.SetBlocker(func(conv, phone, action string) error {
		h.mu.Lock()
		h.blocks = append(h.blocks, conv+"|"+phone+"|"+action)
		h.mu.Unlock()
		return nil
	})
	h.handler = &client.EventHandler{Store: store, Logger: zerolog.Nop(), OnIncomingMessage: h.watcher.Check}
	for _, c := range []*gmproto.Conversation{
		conversation("spam", "+15550001111"),
		conversation("friend", "+15550002222"),
	} {
		h.handler.Handle(c)
	}
	return h
}

func (h *harness) entries() []spamwatch.Entry {
	h.watcher.Wait()
	e, err := spamwatch.ReadLog(h.watcher.LogPath(), time.Time{})
	if err != nil {
		h.t.Fatal(err)
	}
	return e
}

func TestEndToEndLogMode(t *testing.T) {
	h := newHarness(t)
	h.handler.Handle(message("live", "spam", "+15550001111", spamText, false, false))
	h.handler.Handle(message("backfill", "spam", "+15550001111", spamText, false, true))
	h.handler.Handle(message("friend", "friend", "+15550002222", spamText, false, false))
	h.handler.Handle(message("mine", "spam", "+15559990000", spamText, true, false))

	e := h.entries()
	if len(e) != 1 || e[0].MessageID != "live" {
		t.Fatalf("entries = %+v, want only the live unknown-sender message", e)
	}
	if !e[0].ConversationKnown || e[0].IsGroup || e[0].Action != "logged" {
		t.Fatalf("entry = %+v", e[0])
	}
	if len(h.blocks) != 0 {
		t.Fatalf("blocked in log mode: %v", h.blocks)
	}
}

func TestEndToEndBlockMode(t *testing.T) {
	h := newHarness(t)
	if err := writeFile(h.watcher.RulesPath(), `{"mode":"block"}`); err != nil {
		t.Fatal(err)
	}
	h.handler.Handle(message("live", "spam", "+15550001111", spamText, false, false))
	h.handler.Handle(message("friend", "friend", "+15550002222", spamText, false, false))

	e := h.entries()
	if len(e) != 1 || e[0].Action != "blocked" {
		t.Fatalf("entries = %+v", e)
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if len(h.blocks) != 1 || h.blocks[0] != "spam|+15550001111|block_and_report" {
		t.Fatalf("blocks = %v", h.blocks)
	}
}
