package spamwatch

import (
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"strings"
	"time"
)

// Block actions passed to a BlockFunc.
const (
	ActionBlock          = "block"
	ActionBlockAndReport = "block_and_report"
	ActionUnblock        = "unblock"
)

// BlockPath is the local HTTP endpoint for manual block and unblock.
const BlockPath = "/api/spam/block"

// BlockFunc asks the phone to block, block-and-report or unblock one
// conversation. phone is the other party's number ("" if unknown).
type BlockFunc func(conversationID, phone, action string) error

// SetBlocker installs the function that talks to Google Messages. Without
// one, block mode only logs and the endpoint answers 503.
func (w *Watcher) SetBlocker(fn BlockFunc) {
	w.mu.Lock()
	w.blocker = fn
	w.mu.Unlock()
}

// Wait blocks until in-flight automatic blocks finish. Used by tests.
func (w *Watcher) Wait() { w.wg.Wait() }

// autoBlockDecision returns the phone number to block and "" when the entry
// should be blocked automatically, or a reason it is only logged.
func (w *Watcher) autoBlockDecision(rules Rules, e Entry) (string, string) {
	if !rules.blockMode() {
		return "", "log mode"
	}
	w.mu.Lock()
	hasBlocker := w.blocker != nil
	w.mu.Unlock()
	if !hasBlocker {
		return "", "blocking not available"
	}
	if e.IsGroup {
		return "", "group thread: never auto-blocked"
	}
	if !e.ConversationKnown {
		return "", "conversation not in store yet"
	}
	if e.ShortCode && !rules.BlockShortCodes {
		return "", "short code"
	}
	phone, reason := w.blockTarget(e.ConversationID)
	if reason != "" {
		return "", reason
	}
	if !w.reserveBlock(rules.maxBlocksPerDay()) {
		return "", fmt.Sprintf("daily cap of %d reached", rules.maxBlocksPerDay())
	}
	return phone, ""
}

// blockTarget checks that a conversation is a 1:1 thread with someone who
// is not a saved contact and returns their number.
func (w *Watcher) blockTarget(conversationID string) (string, string) {
	conv, err := w.store.GetConversation(conversationID)
	if err != nil || conv == nil {
		return "", "conversation not found"
	}
	if conv.IsGroup {
		return "", "group thread"
	}
	phone := otherParticipantNumber(conv.Participants)
	if phone == "" {
		return "", "could not find exactly one other participant"
	}
	if w.isContact(phone) {
		return "", "saved contact"
	}
	return phone, ""
}

func (w *Watcher) runAutoBlock(rules Rules, e Entry, phone string) {
	action := ActionBlockAndReport
	if rules.NoReport {
		action = ActionBlock
	}
	w.mu.Lock()
	blocker := w.blocker
	w.mu.Unlock()
	if err := blocker(e.ConversationID, phone, action); err != nil {
		w.releaseBlock()
		e.Action = "block_failed"
		e.Note = err.Error()
	} else {
		e.Action = "blocked"
		e.Note = action
	}
	w.record(e)
}

// reserveBlock takes one slot from today's cap. The count starts from the
// log so a restart does not reset it.
func (w *Watcher) reserveBlock(max int) bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	now := w.now()
	day := now.Local().Format("2006-01-02")
	if !w.blockCounted || w.blockDay != day {
		w.blockDay = day
		w.blocksToday = 0
		y, m, d := now.Local().Date()
		start := time.Date(y, m, d, 0, 0, 0, 0, time.Local)
		if entries, err := ReadLog(w.LogPath(), start); err == nil {
			for _, e := range entries {
				if e.Action == "blocked" {
					w.blocksToday++
				}
			}
		}
		w.blockCounted = true
	}
	if w.blocksToday >= max {
		return false
	}
	w.blocksToday++
	return true
}

func (w *Watcher) releaseBlock() {
	w.mu.Lock()
	if w.blocksToday > 0 {
		w.blocksToday--
	}
	w.mu.Unlock()
}

// BlockRequest is the JSON body of POST /api/spam/block.
type BlockRequest struct {
	ConversationID string `json:"conversation_id"`
	Action         string `json:"action"`
}

// BlockResponse is its JSON reply.
type BlockResponse struct {
	OK     bool   `json:"ok"`
	Action string `json:"action,omitempty"`
	Error  string `json:"error,omitempty"`
}

// Manual blocks or unblocks one conversation by hand. It refuses group
// threads and saved contacts for block actions; unblock is always allowed.
func (w *Watcher) Manual(conversationID, action string) error {
	conversationID = strings.TrimSpace(conversationID)
	if conversationID == "" {
		return errors.New("conversation_id is required")
	}
	switch action {
	case ActionBlock, ActionBlockAndReport, ActionUnblock:
	default:
		return fmt.Errorf("unknown action %q", action)
	}
	w.mu.Lock()
	blocker := w.blocker
	w.mu.Unlock()
	if blocker == nil {
		return errors.New("blocking is not available (not connected to Google Messages)")
	}

	var phone string
	if action == ActionUnblock {
		if conv, err := w.store.GetConversation(conversationID); err == nil && conv != nil && !conv.IsGroup {
			phone = otherParticipantNumber(conv.Participants)
		}
	} else {
		var reason string
		phone, reason = w.blockTarget(conversationID)
		if reason != "" {
			return fmt.Errorf("refused: %s", reason)
		}
	}

	err := blocker(conversationID, phone, action)
	verb := "manual_unblock"
	if action != ActionUnblock {
		verb = "manual_block"
	}
	e := Entry{
		Time:              w.now().Format(time.RFC3339),
		ConversationID:    conversationID,
		SenderNumber:      phone,
		ConversationKnown: true,
		ShortCode:         IsShortCode(phone),
		Matched:           []string{},
		Action:            verb,
		Note:              action,
	}
	if err != nil {
		e.Action = verb + "_failed"
		e.Note = err.Error()
	}
	w.record(e)
	return err
}

// WrapHTTP serves BlockPath and ScanPath itself and passes every other
// request to next. Both endpoints need the control token as a Bearer header
// (no cookie), a loopback client and no browser Origin, so a web page cannot
// trigger them. An empty token disables them.
func (w *Watcher) WrapHTTP(next http.Handler, token string) http.Handler {
	token = strings.TrimSpace(token)
	return http.HandlerFunc(func(rw http.ResponseWriter, r *http.Request) {
		if r.URL.Path != BlockPath && r.URL.Path != ScanPath {
			next.ServeHTTP(rw, r)
			return
		}
		reply := func(status int, resp any) {
			rw.Header().Set("Content-Type", "application/json")
			rw.WriteHeader(status)
			_ = json.NewEncoder(rw).Encode(resp)
		}
		fail := func(status int, msg string) {
			if r.URL.Path == ScanPath {
				reply(status, ScanResponse{Error: msg})
			} else {
				reply(status, BlockResponse{Error: msg})
			}
		}
		if r.Method != http.MethodPost {
			fail(http.StatusMethodNotAllowed, "POST only")
			return
		}
		if token == "" {
			fail(http.StatusServiceUnavailable, "control token not available")
			return
		}
		if !loopbackClient(r) || r.Header.Get("Origin") != "" || r.Header.Get("Sec-Fetch-Site") != "" {
			fail(http.StatusForbidden, "local command-line requests only")
			return
		}
		auth := strings.Fields(r.Header.Get("Authorization"))
		if len(auth) != 2 || !strings.EqualFold(auth[0], "Bearer") ||
			subtle.ConstantTimeCompare([]byte(auth[1]), []byte(token)) != 1 {
			fail(http.StatusUnauthorized, "missing or wrong control token")
			return
		}

		if r.URL.Path == ScanPath {
			var req ScanRequest
			if err := json.NewDecoder(http.MaxBytesReader(rw, r.Body, 4096)).Decode(&req); err != nil {
				fail(http.StatusBadRequest, "invalid JSON")
				return
			}
			scanned, cands, err := w.Scan(req.Days)
			if err != nil {
				fail(http.StatusInternalServerError, err.Error())
				return
			}
			if cands == nil {
				cands = []ScanCandidate{}
			}
			reply(http.StatusOK, ScanResponse{OK: true, Scanned: scanned, Candidates: cands})
			return
		}

		var req BlockRequest
		if err := json.NewDecoder(http.MaxBytesReader(rw, r.Body, 4096)).Decode(&req); err != nil {
			fail(http.StatusBadRequest, "invalid JSON")
			return
		}
		if err := w.Manual(req.ConversationID, req.Action); err != nil {
			status := http.StatusBadGateway
			if strings.HasPrefix(err.Error(), "refused:") || strings.Contains(err.Error(), "required") || strings.HasPrefix(err.Error(), "unknown action") {
				status = http.StatusUnprocessableEntity
			}
			reply(status, BlockResponse{Action: req.Action, Error: err.Error()})
			return
		}
		reply(http.StatusOK, BlockResponse{OK: true, Action: req.Action})
	})
}

func loopbackClient(r *http.Request) bool {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}
