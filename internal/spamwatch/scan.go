package spamwatch

import (
	"errors"
	"sort"
	"time"

	"github.com/maxghenis/openmessage/internal/db"
)

// ScanPath is the local HTTP endpoint that checks stored history against the
// rules. It only reads; blocking goes through BlockPath one thread at a time.
const ScanPath = "/api/spam/scan"

const (
	scanConversationLimit = 100000
	scanMessagesPerThread = 2000
	// MaxScanDays bounds how far back a scan looks.
	MaxScanDays = 3650
)

// HistoryStore is what Scan needs beyond Store. *db.Store has both.
type HistoryStore interface {
	ListConversations(limit int) ([]*db.Conversation, error)
	GetMessagesByConversationBetween(conversationID string, startMS, endMS int64, limit int) ([]*db.Message, error)
}

// ScanRequest is the JSON body of POST /api/spam/scan.
type ScanRequest struct {
	Days int `json:"days"`
}

// ScanCandidate is one thread with at least one matching message from a
// sender who is not a saved contact.
type ScanCandidate struct {
	ConversationID string   `json:"conversation_id"`
	SenderNumber   string   `json:"sender_number"`
	LastMatchMS    int64    `json:"last_match_ms"`
	Matches        int      `json:"matches"`
	Matched        []string `json:"matched"`
	Snippet        string   `json:"snippet"`
	// Blockable is true when a manual block would be accepted.
	Blockable bool `json:"blockable"`
	// Skip says why it is not blockable (group thread, saved contact, ...).
	Skip string `json:"skip,omitempty"`
	// AlreadyBlocked is true when the log records a successful block of
	// this thread.
	AlreadyBlocked bool `json:"already_blocked"`
}

// ScanResponse is its JSON reply.
type ScanResponse struct {
	OK         bool            `json:"ok"`
	Error      string          `json:"error,omitempty"`
	Scanned    int             `json:"scanned_threads"`
	Candidates []ScanCandidate `json:"candidates"`
}

// Scan checks incoming SMS/RCS messages from the last days against the
// current rules, the same way Check does for new messages, and returns one
// candidate per matching thread, newest first. It changes nothing.
func (w *Watcher) Scan(days int) (int, []ScanCandidate, error) {
	hs, ok := w.store.(HistoryStore)
	if !ok {
		return 0, nil, errors.New("store cannot list history")
	}
	if days < 1 {
		days = 1
	}
	if days > MaxScanDays {
		days = MaxScanDays
	}
	now := w.now()
	startMS := now.Add(-time.Duration(days) * 24 * time.Hour).UnixMilli()
	endMS := now.UnixMilli()

	convs, err := hs.ListConversations(scanConversationLimit)
	if err != nil {
		return 0, nil, err
	}
	rules := w.rules()
	blocked := w.blockedConversations()

	scanned := 0
	var out []ScanCandidate
	for _, conv := range convs {
		if conv == nil || conv.LastMessageTS < startMS || !isGoogleSMS(conv.SourcePlatform) {
			continue
		}
		scanned++
		msgs, err := hs.GetMessagesByConversationBetween(conv.ConversationID, startMS, endMS, scanMessagesPerThread)
		if err != nil {
			w.logger.Warn().Err(err).Str("conv_id", conv.ConversationID).Msg("Spam scan: cannot read thread")
			continue
		}
		var cand *ScanCandidate
		seen := map[string]bool{}
		for _, m := range msgs {
			if m == nil || m.IsFromMe || !isGoogleSMS(m.SourcePlatform) || w.isContact(m.SenderNumber) {
				continue
			}
			matched := matchRules(rules, m.SenderNumber, m.Body)
			if len(matched) == 0 {
				continue
			}
			if cand == nil {
				cand = &ScanCandidate{ConversationID: conv.ConversationID}
			}
			cand.Matches++
			for _, r := range matched {
				if !seen[r] {
					seen[r] = true
					cand.Matched = append(cand.Matched, r)
				}
			}
			if m.TimestampMS >= cand.LastMatchMS {
				cand.LastMatchMS = m.TimestampMS
				cand.SenderNumber = m.SenderNumber
				cand.Snippet = snippet(m.Body)
			}
		}
		if cand == nil {
			continue
		}
		if conv.IsGroup {
			cand.Skip = "group thread"
		} else if _, reason := w.blockTarget(conv.ConversationID); reason != "" {
			cand.Skip = reason
		} else if IsShortCode(cand.SenderNumber) && !rules.BlockShortCodes {
			cand.Skip = "short code"
		} else {
			cand.Blockable = true
		}
		cand.AlreadyBlocked = blocked[conv.ConversationID]
		out = append(out, *cand)
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].LastMatchMS > out[j].LastMatchMS })
	return scanned, out, nil
}

// blockedConversations returns threads the log records as blocked and not
// unblocked since.
func (w *Watcher) blockedConversations() map[string]bool {
	entries, err := ReadLog(w.LogPath(), time.Time{})
	if err != nil {
		w.logger.Warn().Err(err).Msg("Spam scan: cannot read log")
	}
	out := map[string]bool{}
	for _, e := range entries {
		switch e.Action {
		case "blocked", "manual_block":
			out[e.ConversationID] = true
		case "manual_unblock":
			delete(out, e.ConversationID)
		}
	}
	return out
}
