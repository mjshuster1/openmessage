package tools

// Fork addition (mjshuster1): one-time-code redaction for the read-only MCP
// surface. See readonly.go for the opt-out (OPENMESSAGES_MCP_SHOW_CODES=1).

import (
	"encoding/json"
	"regexp"
	"strings"
)

const codeRedaction = "[code hidden]"

// otpKeywordRE finds the words that make a nearby number a one-time code.
var otpKeywordRE = regexp.MustCompile(`(?i)\b(?:codes?|verification|verify|verifying|otp|passcodes?|pin|one[- ]?time|2fa|mfa|two[- ]factor|log[- ]?in|sign[- ]?in|is your|authenticat(?:e|ion|or))\b`)

// otpKeywordNotCodeRE marks "code" uses that are about addresses or phones.
var otpKeywordNotCodeRE = regexp.MustCompile(`(?i)\b(?:zip|postal|post|area|country|dialing|dial)\s*$`)

// otpYearCueRE is the strong cue a 19xx/20xx number needs to count as a code.
var otpYearCueRE = regexp.MustCompile(`(?i)\b(?:code|pin|otp|passcode|2fa)\W{0,3}(?:is\W{0,3})?$`)

// otpIDContextRE matches the end of the text before a number that labels it
// as an identifier, reference or quantity rather than a secret.
var otpIDContextRE = regexp.MustCompile(`(?i)(?:^|[^a-z])(?:id|ids|conv|conversation|msg|ref|reference|order|flight|room|suite|ste|apt|unit|ext|extension|box|no|number|num|route|bus|gate|seat|invoice|ticket|case|ending in|ending|account|acct|card|zip|platform|version|v|at|by|until|till|before|after|around)\s*$`)

// otpAmountContextRE matches the end of the text before a number that makes
// it an amount of money ("paid 2500", "owes me 300", "rent is 2400"), which a
// nearby "verify" or "sign in" doesn't turn into a code.
var otpAmountContextRE = regexp.MustCompile(`(?i)(?:^|[^a-z])(?:paid|pay|paying|owe|owes|owed|cost|costs|spent|spend|spending|charged|charge|price|priced|total|budget|worth|sold|bought|earned|tip|deposit|deposited|refund|refunded|balance|rent|salary|fee|bill)(?:\s+(?:is|was|of|for|about|around|me|you|him|her|them|us))?\s*$`)

// otpStreetWords end a street address ("1234 Main St") when they follow a
// number after at most two capitalized words.
var otpStreetWords = map[string]bool{
	"st": true, "street": true, "ave": true, "avenue": true, "rd": true, "road": true,
	"blvd": true, "boulevard": true, "dr": true, "drive": true, "ln": true, "lane": true,
	"way": true, "ct": true, "court": true, "pl": true, "place": true, "hwy": true,
	"highway": true, "pkwy": true, "parkway": true, "ter": true, "terrace": true, "cir": true,
}

// otpUnitWords make a number a time, address or amount when they follow it.
var otpUnitWords = map[string]bool{
	"am": true, "pm": true, "st": true, "street": true, "ave": true, "avenue": true,
	"rd": true, "road": true, "blvd": true, "dr": true, "drive": true, "ln": true,
	"lane": true, "way": true, "ct": true, "court": true, "pl": true, "place": true,
	"hwy": true, "pkwy": true, "dollars": true, "usd": true, "eur": true, "miles": true,
	"mi": true, "km": true, "kg": true, "lbs": true, "lb": true, "people": true,
	"points": true, "pts": true, "sq": true, "ft": true, "calories": true, "steps": true,
	"bucks": true, "cents": true,
}

const (
	otpKeywordBefore = 80 // bytes a keyword may precede a code by
	otpKeywordAfter  = 40 // bytes a keyword may follow a code by
)

func isASCIIDigit(c byte) bool  { return c >= '0' && c <= '9' }
func isASCIILetter(c byte) bool { return (c|0x20) >= 'a' && (c|0x20) <= 'z' }
func isASCIIAlnum(c byte) bool  { return isASCIIDigit(c) || isASCIILetter(c) }

type digitRun struct{ start, end int }

// RedactOneTimeCodes replaces likely one-time codes (4-8 digits, optionally
// grouped 3+3 or 4+4, optionally with a letter prefix such as "G-") that sit
// near a code keyword with "[code hidden]". Numbers shaped like dates, times,
// phone numbers, prices, addresses or identifiers are left alone.
func RedactOneTimeCodes(s string) string {
	if len(s) < 4 {
		return s
	}
	keywords := otpKeywords(s)
	if len(keywords) == 0 {
		return s
	}
	type span struct{ start, end int }
	var spans []span
	n := len(s)
	for i := 0; i < n; {
		if !isASCIIDigit(s[i]) {
			i++
			continue
		}
		// Collect a chunk: digit runs joined by a single '-', ' ' or '.'.
		var runs []digitRun
		var seps []byte
		j := i
		for {
			k := j
			for k < n && isASCIIDigit(s[k]) {
				k++
			}
			runs = append(runs, digitRun{j, k})
			if k+1 < n && (s[k] == '-' || s[k] == ' ' || s[k] == '.') && isASCIIDigit(s[k+1]) {
				seps = append(seps, s[k])
				j = k + 1
				continue
			}
			j = k
			break
		}
		i = j
		for _, cand := range otpChunkCandidates(runs, seps) {
			start, ok := otpCandidateStart(s, cand.start)
			if !ok || !otpRightOK(s, cand.end) {
				continue
			}
			if cand.digits == 4 && cand.start+4 == cand.end {
				if y := s[cand.start:cand.end]; (y[:2] == "19" || y[:2] == "20") && !otpYearCueRE.MatchString(s[:start]) {
					continue
				}
			}
			if !otpNearKeyword(keywords, start, cand.end) {
				continue
			}
			spans = append(spans, span{start, cand.end})
		}
	}
	if len(spans) == 0 {
		return s
	}
	var b strings.Builder
	b.Grow(len(s))
	last := 0
	for _, sp := range spans {
		b.WriteString(s[last:sp.start])
		b.WriteString(codeRedaction)
		last = sp.end
	}
	b.WriteString(s[last:])
	return b.String()
}

type otpCandidate struct{ start, end, digits int }

// otpChunkCandidates decides which parts of a digit chunk could be a code.
func otpChunkCandidates(runs []digitRun, seps []byte) []otpCandidate {
	length := func(r digitRun) int { return r.end - r.start }
	single := func(r digitRun) []otpCandidate {
		if l := length(r); l >= 4 && l <= 8 {
			return []otpCandidate{{r.start, r.end, l}}
		}
		return nil
	}
	if len(runs) == 1 {
		return single(runs[0])
	}
	hasHyphen := false
	for _, sep := range seps {
		switch sep {
		case '.':
			return nil // decimals, versions, IPs, dotted dates and phones
		case '-':
			hasHyphen = true
		}
	}
	grouped := func() []otpCandidate {
		a, b := length(runs[0]), length(runs[1])
		if len(runs) == 2 && a == b && (a == 3 || a == 4) {
			return []otpCandidate{{runs[0].start, runs[1].end, a + b}}
		}
		return nil
	}
	if hasHyphen {
		return grouped() // anything else hyphenated is a date or phone number
	}
	if g := grouped(); g != nil {
		return g
	}
	if len(runs) == 2 && length(runs[0]) == 3 && length(runs[1]) == 4 {
		return nil // "555 1234"
	}
	allShort := true
	for _, r := range runs {
		if length(r) > 4 {
			allShort = false
		}
	}
	if len(runs) >= 3 && allShort {
		return nil // phone or card number in groups
	}
	var out []otpCandidate
	for _, r := range runs {
		out = append(out, single(r)...)
	}
	return out
}

// otpCandidateStart checks what precedes a candidate and returns where the
// redaction starts (earlier when a letter prefix like "G-" belongs to it).
func otpCandidateStart(s string, start int) (int, bool) {
	if start == 0 {
		return 0, true
	}
	c := s[start-1]
	if c == '-' {
		// Letter prefix: 1-3 letters, then '-', at a word boundary ("G-123456").
		k := start - 1
		for k > 0 && isASCIILetter(s[k-1]) && start-1-(k-1) <= 3 {
			k--
		}
		letters := start - 1 - k
		if letters >= 1 && letters <= 3 && (k == 0 || !isASCIIAlnum(s[k-1])) {
			if otpIDContextRE.MatchString(strings.TrimRight(s[:k], " :=#")) {
				return 0, false
			}
			return k, true
		}
		return 0, false // negative number, range, or tail of a phone/date
	}
	if isASCIIAlnum(c) || c == '_' || c == '$' || c == '/' || c == '\\' || c == '+' ||
		c == '@' || c == '&' || c == '=' || c == '%' || c == '~' || c == '^' || c == '*' || c == '\'' {
		return 0, false
	}
	if c == ':' || c == '.' || c == ',' {
		if start >= 2 && isASCIIDigit(s[start-2]) {
			return 0, false // "10:30", "1.2345", "1,2345"
		}
	}
	for _, currency := range []string{"€", "£", "¥", "₹"} {
		if strings.HasSuffix(s[:start], currency) {
			return 0, false
		}
	}
	if before := strings.TrimRight(s[:start], " :=#"); otpIDContextRE.MatchString(before) || otpAmountContextRE.MatchString(before) {
		return 0, false
	}
	// A sender label in tool text: "← 22000: «…»" or "[ts] 22000: …".
	for _, label := range []string{"← ", "→ ", "] "} {
		if strings.HasSuffix(s[:start], label) {
			return 0, false
		}
	}
	return start, true
}

// otpRightOK checks what follows a candidate.
func otpRightOK(s string, end int) bool {
	n := len(s)
	if end >= n {
		return true
	}
	c := s[end]
	if isASCIIAlnum(c) || c == '_' || c == '/' || c == '%' || c == '\\' || c == '@' {
		return false
	}
	if (c == ':' || c == '.' || c == ',' || c == '-') && end+1 < n && isASCIIDigit(s[end+1]) {
		return false
	}
	// The next word: a unit or street suffix makes it a quantity or address.
	k := end
	for k < n && s[k] == ' ' {
		k++
	}
	w := k
	for w < n && isASCIILetter(s[w]) {
		w++
	}
	if w > k && otpUnitWords[strings.ToLower(s[k:w])] {
		return false
	}
	// "1234 Main St", "1600 Amphitheatre Pkwy", "10 N Main St".
	for words := 0; words < 3 && w > k && s[k] >= 'A' && s[k] <= 'Z'; words++ {
		k = w
		for k < n && s[k] == ' ' {
			k++
		}
		w = k
		for w < n && isASCIILetter(s[w]) {
			w++
		}
		if w > k && otpStreetWords[strings.ToLower(s[k:w])] {
			return false
		}
	}
	return true
}

func otpKeywords(s string) [][]int {
	all := otpKeywordRE.FindAllStringIndex(s, -1)
	out := all[:0]
	for _, m := range all {
		word := strings.ToLower(s[m[0]:m[1]])
		if strings.HasPrefix(word, "code") && otpKeywordNotCodeRE.MatchString(s[:m[0]]) {
			continue
		}
		out = append(out, m)
	}
	return out
}

func otpNearKeyword(keywords [][]int, start, end int) bool {
	for _, k := range keywords {
		if k[1] <= start && start-k[1] <= otpKeywordBefore {
			return true
		}
		if k[0] >= end && k[0]-end <= otpKeywordAfter {
			return true
		}
	}
	return false
}

// redactStructured redacts codes in every string of decoded structured
// content except identifier, number and time fields.
func redactStructured(v any) any {
	switch t := v.(type) {
	case map[string]any:
		for k, val := range t {
			if s, ok := val.(string); ok {
				if !otpSkipKey(k) {
					t[k] = RedactOneTimeCodes(s)
				}
				continue
			}
			t[k] = redactStructured(val)
		}
		return t
	case []any:
		for i, val := range t {
			t[i] = redactStructured(val)
		}
		return t
	case string:
		return RedactOneTimeCodes(t)
	default:
		return v
	}
}

func otpSkipKey(k string) bool {
	k = strings.ToLower(k)
	return k == "id" || strings.HasSuffix(k, "_id") || strings.HasSuffix(k, "_ids") ||
		strings.HasSuffix(k, "_ms") || strings.HasSuffix(k, "_ts") ||
		strings.Contains(k, "number") || strings.Contains(k, "phone")
}

// toJSONValue converts structured content into generic JSON values so it can
// be walked and annotated. It returns ok=false if the content won't marshal.
func toJSONValue(v any) (any, bool) {
	raw, err := json.Marshal(v)
	if err != nil {
		return nil, false
	}
	var out any
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, false
	}
	return out, true
}
