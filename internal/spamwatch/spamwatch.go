// Package spamwatch checks fresh inbound SMS/RCS messages from numbers that
// are not in the phone's contacts against a list of spam rules and records
// each match in a local log file.
//
// By default it only logs. Setting "mode": "block" in the rules file turns
// on automatic block-and-report for 1:1 threads (see block.go). It never
// deletes a message and never acts on a saved contact.
//
// The rules file and the log hold phone numbers and message text. Both live
// in the data dir (never in the repository).
package spamwatch

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/rs/zerolog"

	"github.com/maxghenis/openmessage/internal/db"
)

const (
	// RulesFileName is the optional user rules file in the data dir.
	RulesFileName = "spam-rules.json"
	// LogFileName is the JSON Lines log of would-block matches in the data dir.
	LogFileName = "spam-watch.jsonl"

	snippetRunes    = 160
	contactCacheTTL = 10 * time.Minute
	contactLimit    = 100000
)

// BuiltinPhrases are generic political-spam phrases. They hold no personal
// data, so they can live in the public repository. Candidate names and
// specific numbers belong in the user's rules file instead.
var BuiltinPhrases = []string{
	"paid for by",
	"reply stop",
	"text stop",
	"stop to end",
	"stop to quit",
	"stop to opt out",
	"stop2end",
	"stop2quit",
	"stop=end",
	"actblue",
	"winred",
	"chip in",
	"donate",
	"polling place",
	"polling location",
	"early voting",
	"your ballot",
	"vote for",
	"election day",
}

// Rules is the shape of spam-rules.json. Phrases match case-insensitively
// anywhere in the message body. Numbers match on their last 10 digits.
type Rules struct {
	Phrases []string `json:"phrases"`
	Numbers []string `json:"numbers"`

	// Mode is "log" (default) or "block". Anything else means "log".
	Mode string `json:"mode,omitempty"`
	// NoReport makes automatic blocks plain blocks instead of
	// block-and-report.
	NoReport bool `json:"no_report,omitempty"`
	// BlockShortCodes allows automatic blocks of 5-6 digit senders.
	BlockShortCodes bool `json:"block_short_codes,omitempty"`
	// MaxBlocksPerDay caps automatic blocks per local day. 0 means the
	// default (DefaultMaxBlocksPerDay).
	MaxBlocksPerDay int `json:"max_blocks_per_day,omitempty"`
}

// DefaultMaxBlocksPerDay bounds the damage a bad rule can do in one day.
const DefaultMaxBlocksPerDay = 25

func (r Rules) blockMode() bool { return strings.EqualFold(strings.TrimSpace(r.Mode), "block") }

func (r Rules) maxBlocksPerDay() int {
	if r.MaxBlocksPerDay > 0 {
		return r.MaxBlocksPerDay
	}
	return DefaultMaxBlocksPerDay
}

// Store is the subset of *db.Store the watcher reads.
type Store interface {
	ListContacts(query string, limit int) ([]*db.Contact, error)
	GetConversation(id string) (*db.Conversation, error)
}

// Entry is one line of the log.
type Entry struct {
	Time              string   `json:"time"`
	MessageID         string   `json:"message_id"`
	ConversationID    string   `json:"conversation_id"`
	SenderNumber      string   `json:"sender_number"`
	SenderName        string   `json:"sender_name,omitempty"`
	IsGroup           bool     `json:"is_group"`
	ConversationKnown bool     `json:"conversation_known"`
	ShortCode         bool     `json:"short_code"`
	ParticipantContID string   `json:"participant_contact_id,omitempty"`
	Matched           []string `json:"matched"`
	Snippet           string   `json:"snippet"`
	// Action is what happened: "logged", "blocked", "block_failed",
	// "manual_block", "manual_block_failed", "manual_unblock",
	// "manual_unblock_failed". Empty in Phase 1 logs (means "logged").
	Action string `json:"action,omitempty"`
	// Note says why a match was only logged in block mode, or the error.
	Note string `json:"note,omitempty"`
}

// Watcher is safe for concurrent use.
type Watcher struct {
	logger  zerolog.Logger
	store   Store
	dataDir string
	now     func() time.Time

	mu            sync.Mutex
	rulesModTime  time.Time
	rulesLoaded   bool
	userRules     Rules
	contacts      map[string]struct{}
	contactsAt    time.Time
	warnedNoConts bool

	blocker      BlockFunc
	blockDay     string
	blocksToday  int
	blockCounted bool
	wg           sync.WaitGroup
}

// New returns a watcher that reads rules from and writes its log to dataDir.
func New(logger zerolog.Logger, store Store, dataDir string) *Watcher {
	return &Watcher{
		logger:  logger.With().Str("component", "spamwatch").Logger(),
		store:   store,
		dataDir: dataDir,
		now:     time.Now,
	}
}

// LogPath is where matches are written.
func (w *Watcher) LogPath() string { return filepath.Join(w.dataDir, LogFileName) }

// RulesPath is where the optional user rules file is read from.
func (w *Watcher) RulesPath() string { return filepath.Join(w.dataDir, RulesFileName) }

// Check inspects one message. It never returns an error and never panics:
// spam checking must not interfere with message delivery.
func (w *Watcher) Check(msg *db.Message) {
	if w == nil || msg == nil {
		return
	}
	defer func() {
		if r := recover(); r != nil {
			w.logger.Error().Interface("panic", r).Msg("Recovered from panic in spam check")
		}
	}()
	entry, ok := w.evaluate(msg)
	if !ok {
		return
	}
	rules := w.rules()
	if phone, reason := w.autoBlockDecision(rules, entry); reason == "" {
		// Never call the blocker on this goroutine: for Google it is
		// libgm's event goroutine, which also delivers the reply.
		w.wg.Add(1)
		go func() {
			defer w.wg.Done()
			defer func() {
				if r := recover(); r != nil {
					w.logger.Error().Interface("panic", r).Msg("Recovered from panic in spam auto-block")
				}
			}()
			w.runAutoBlock(rules, entry, phone)
		}()
		return
	} else if rules.blockMode() {
		entry.Note = reason
	}
	entry.Action = "logged"
	w.record(entry)
}

func (w *Watcher) record(entry Entry) {
	if err := w.appendLog(entry); err != nil {
		w.logger.Warn().Err(err).Msg("Failed to write spam-watch log")
		return
	}
	ev := w.logger.Info()
	if strings.HasSuffix(entry.Action, "_failed") {
		ev = w.logger.Warn()
	}
	ev.Str("conv_id", entry.ConversationID).
		Strs("matched", entry.Matched).
		Bool("group", entry.IsGroup).
		Str("action", entry.Action).
		Str("note", entry.Note).
		Msg("Spam watcher")
}

func (w *Watcher) evaluate(msg *db.Message) (Entry, bool) {
	if msg.IsFromMe || !isGoogleSMS(msg.SourcePlatform) {
		return Entry{}, false
	}
	if w.isContact(msg.SenderNumber) {
		return Entry{}, false
	}

	matched := matchRules(w.rules(), msg.SenderNumber, msg.Body)
	if len(matched) == 0 {
		return Entry{}, false
	}

	entry := Entry{
		Time:           w.now().Format(time.RFC3339),
		MessageID:      msg.MessageID,
		ConversationID: msg.ConversationID,
		SenderNumber:   msg.SenderNumber,
		SenderName:     msg.SenderName,
		ShortCode:      IsShortCode(msg.SenderNumber),
		Matched:        matched,
		Snippet:        snippet(msg.Body),
	}
	if conv, err := w.store.GetConversation(msg.ConversationID); err == nil && conv != nil {
		entry.ConversationKnown = true
		entry.IsGroup = conv.IsGroup
		entry.ParticipantContID = participantContactID(conv.Participants, msg.SenderNumber)
	}
	return entry, true
}

// isGoogleSMS reports whether the message came from Google Messages. The
// Google event handler leaves SourcePlatform empty; WhatsApp and Signal,
// which share the same incoming hook, set theirs.
func isGoogleSMS(platform string) bool {
	switch strings.ToLower(strings.TrimSpace(platform)) {
	case "", "sms", "rcs":
		return true
	}
	return false
}

func (w *Watcher) isContact(number string) bool {
	key := NumberKey(number)
	if key == "" {
		return false
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.contacts == nil || w.now().Sub(w.contactsAt) > contactCacheTTL {
		contacts, err := w.store.ListContacts("", contactLimit)
		if err != nil {
			w.logger.Warn().Err(err).Msg("Failed to load contacts; treating sender as unknown")
		} else {
			set := make(map[string]struct{}, len(contacts))
			for _, c := range contacts {
				if k := NumberKey(c.Number); k != "" {
					set[k] = struct{}{}
				}
			}
			w.contacts = set
			w.contactsAt = w.now()
			if len(set) == 0 && !w.warnedNoConts {
				w.warnedNoConts = true
				w.logger.Warn().Msg("Contacts table is empty; every sender counts as unknown until contacts sync")
			}
		}
	}
	_, ok := w.contacts[key]
	return ok
}

func (w *Watcher) rules() Rules {
	w.mu.Lock()
	defer w.mu.Unlock()
	path := w.RulesPath()
	info, err := os.Stat(path)
	if err != nil {
		if !errors.Is(err, fs.ErrNotExist) {
			w.logger.Warn().Err(err).Msg("Cannot read spam rules file; using built-in rules only")
		}
		w.userRules = Rules{}
		w.rulesLoaded = false
		return w.userRules
	}
	if w.rulesLoaded && info.ModTime().Equal(w.rulesModTime) {
		return w.userRules
	}
	r, err := LoadRules(path)
	if err != nil {
		w.logger.Warn().Err(err).Msg("Invalid spam rules file; using built-in rules only")
		w.userRules = Rules{}
	} else {
		w.userRules = r
	}
	w.rulesModTime = info.ModTime()
	w.rulesLoaded = true
	return w.userRules
}

// LoadRules reads a rules file.
func LoadRules(path string) (Rules, error) {
	var r Rules
	b, err := os.ReadFile(path)
	if err != nil {
		return r, err
	}
	if err := json.Unmarshal(b, &r); err != nil {
		return r, fmt.Errorf("parse %s: %w", filepath.Base(path), err)
	}
	return r, nil
}

// matchRules returns the labels of every rule that matched, built-in
// phrases first.
func matchRules(user Rules, number, body string) []string {
	var matched []string
	text := normalizeText(body)
	seen := map[string]bool{}
	addPhrase := func(p string) {
		np := normalizeText(p)
		if np == "" || seen[np] {
			return
		}
		if strings.Contains(text, np) {
			seen[np] = true
			matched = append(matched, "phrase:"+np)
		}
	}
	for _, p := range BuiltinPhrases {
		addPhrase(p)
	}
	for _, p := range user.Phrases {
		addPhrase(p)
	}
	if key := NumberKey(number); key != "" {
		for _, n := range user.Numbers {
			if NumberKey(n) == key {
				matched = append(matched, "number:"+strings.TrimSpace(n))
				break
			}
		}
	}
	return matched
}

func normalizeText(s string) string {
	return strings.Join(strings.Fields(strings.ToLower(s)), " ")
}

// NumberKey reduces a phone number to its last 10 digits so "+1 (555)
// 123-4567" and "5551234567" compare equal. Shorter numbers (short codes)
// keep all their digits. Returns "" when there are no digits.
func NumberKey(number string) string {
	var b strings.Builder
	for _, r := range number {
		if r >= '0' && r <= '9' {
			b.WriteRune(r)
		}
	}
	d := b.String()
	if len(d) > 10 {
		d = d[len(d)-10:]
	}
	return d
}

// IsShortCode reports whether the sender is a 5 or 6 digit short code.
func IsShortCode(number string) bool {
	n := strings.TrimSpace(number)
	if n == "" {
		return false
	}
	for _, r := range n {
		if r < '0' || r > '9' {
			return false
		}
	}
	return len(n) == 5 || len(n) == 6
}

// otherParticipantNumber returns the number of the one participant who is
// not the user, or "" if there is not exactly one.
func otherParticipantNumber(participantsJSON string) string {
	var ps []struct {
		Number string `json:"number"`
		IsMe   bool   `json:"is_me"`
	}
	if json.Unmarshal([]byte(participantsJSON), &ps) != nil {
		return ""
	}
	found := ""
	for _, p := range ps {
		if p.IsMe || strings.TrimSpace(p.Number) == "" {
			continue
		}
		if found != "" {
			return ""
		}
		found = strings.TrimSpace(p.Number)
	}
	return found
}

func participantContactID(participantsJSON, senderNumber string) string {
	key := NumberKey(senderNumber)
	if key == "" {
		return ""
	}
	var ps []struct {
		Number    string `json:"number"`
		ContactID string `json:"contact_id"`
	}
	if json.Unmarshal([]byte(participantsJSON), &ps) != nil {
		return ""
	}
	for _, p := range ps {
		if NumberKey(p.Number) == key {
			return p.ContactID
		}
	}
	return ""
}

func snippet(body string) string {
	s := strings.Join(strings.Fields(body), " ")
	r := []rune(s)
	if len(r) > snippetRunes {
		return string(r[:snippetRunes]) + "…"
	}
	return s
}

func (w *Watcher) appendLog(e Entry) error {
	b, err := json.Marshal(e)
	if err != nil {
		return err
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	f, err := os.OpenFile(w.LogPath(), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	if _, err := f.Write(append(b, '\n')); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}
