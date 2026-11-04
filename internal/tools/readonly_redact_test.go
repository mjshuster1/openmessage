package tools

import (
	"strings"
	"testing"
)

func TestRedactOneTimeCodesPositives(t *testing.T) {
	cases := []struct{ in, want string }{
		{"Your code is 4821", "Your code is [code hidden]"},
		{"G-123456 is your Google verification code.", "[code hidden] is your Google verification code."},
		{"Your Apple Account code is: 482193. Don't share it with anyone.\n\n@apple.com #482193 %apple.com",
			"Your Apple Account code is: [code hidden]. Don't share it with anyone.\n\n@apple.com #[code hidden] %apple.com"},
		{"Your Uber code is 4821. Never share this code.", "Your Uber code is [code hidden]. Never share this code."},
		{"Chase: Your one-time code is 12345678. Chase will never call you to ask for it.",
			"Chase: Your one-time code is [code hidden]. Chase will never call you to ask for it."},
		{"Bank of America: Your security code is 482-193. Don't share it.", "Bank of America: Your security code is [code hidden]. Don't share it."},
		{"Your Lyft code is 123 456", "Your Lyft code is [code hidden]"},
		{"Wells Fargo: 482193 is your verification code", "Wells Fargo: [code hidden] is your verification code"},
		{"Use verification code 482193 for Microsoft authentication.", "Use verification code [code hidden] for Microsoft authentication."},
		{"WhatsApp code 123-456\nYou can also tap this link", "WhatsApp code [code hidden]\nYou can also tap this link"},
		{"Your OTP: 559012", "Your OTP: [code hidden]"},
		{"PIN: 4821", "PIN: [code hidden]"},
		{"Your passcode is 99812", "Your passcode is [code hidden]"},
		{"Your 2FA code:774411", "Your 2FA code:[code hidden]"},
		{"Use 330291 to log in to Venmo.", "Use [code hidden] to log in to Venmo."},
		{"Your sign-in code is 1234 5678", "Your sign-in code is [code hidden]"},
		{"Amazon: 618204 is your one time password", "Amazon: [code hidden] is your one time password"},
		{"Your two-factor code (expires in 10 min): 771234", "Your two-factor code (expires in 10 min): [code hidden]"},
		{"[2026-11-03T15:42:00-05:00] ← 22000: «Your Google verification code is G-482193»",
			"[2026-11-03T15:42:00-05:00] ← 22000: «Your Google verification code is [code hidden]»"},
		{"Your code is 2024", "Your code is [code hidden]"},
		{"Verify your login: code 48219 (valid 5 minutes)", "Verify your login: code [code hidden] (valid 5 minutes)"},
		{"Your verification code is 482910. Never share it to pay anyone", "Your verification code is [code hidden]. Never share it to pay anyone"},
		{"Balance alert. Your login code: 553201", "Balance alert. Your login code: [code hidden]"},
		{"Your Instagram code is 482 193.", "Your Instagram code is [code hidden]."},
	}
	for _, tc := range cases {
		if got := RedactOneTimeCodes(tc.in); got != tc.want {
			t.Errorf("RedactOneTimeCodes(%q)\n got  %q\n want %q", tc.in, got, tc.want)
		}
	}
}

func TestRedactOneTimeCodesNegatives(t *testing.T) {
	cases := []string{
		"See you on 2026-11-03",
		"Dinner 11/03/2026 at 7",
		"call me at 555-123-4567",
		"call me at (555) 123-4567 for the code",
		"my number is 555 123 4567, code word is pineapple",
		"verification call from +1 415 555 0134",
		"It was $1234 total",
		"price was $1,234.56 for the login upgrade",
		"flight 1234 at 10:30",
		"Your verification flight 1234 departs at 10:30",
		"Meet at 1234 Main St to sign in",
		"Sign in at the front desk of 1600 Amphitheatre Pkwy",
		"[2026-11-03T15:42:00-05:00] → Bob: «what was the code?»",
		"Conversation: Bank (ID: 1234567, platform: sms)",
		"[2026-11-03T15:42:00-05:00] ← Bank (conv: 88812345): «Your code is ready»",
		"[image, message_id: 4829312] verification photo",
		"PIN",
		"Forgot my PIN again lol",
		"The verification is done, see you in 2026",
		"Code review at 1530",
		"my zip code is 94110",
		"area code 415 then 5550134",
		"I sent 4821 messages this year",
		"Your order #123456 has shipped",
		"card ending in 4821 was used to sign in",
		"Login took 1500ms",
		"code version 1.2345",
		"verification code expires 2026-11-04 15:42",
		"Your code is abc12345",
		"Your code is 123",
		"Your code is 123456789012",
		"Verify the wire for 10000 dollars",
		"paid 2500 for the couch, verify when you get it",
		"he owes me 3000, can you verify?",
		"Your balance is 4821. Log in to see details",
		"rent is 2400 this month, sign in to the portal to pay",
		"Total: 1299. Verify your order online",
	}
	for _, in := range cases {
		if got := RedactOneTimeCodes(in); got != in {
			t.Errorf("RedactOneTimeCodes(%q) changed it to %q", in, got)
		}
	}
}

func TestRedactStructuredSkipsIdentifiers(t *testing.T) {
	v := map[string]any{
		"message_id":      "123456",
		"conversation_id": "verify 654321",
		"sender_number":   "code 22000",
		"timestamp_ms":    float64(1762202520000),
		"messages": []any{
			map[string]any{"body": "Your code is 482193", "message_id": "code 482193"},
		},
	}
	out := redactStructured(v).(map[string]any)
	msg := out["messages"].([]any)[0].(map[string]any)
	if msg["body"] != "Your code is [code hidden]" {
		t.Errorf("body = %q", msg["body"])
	}
	if msg["message_id"] != "code 482193" || out["conversation_id"] != "verify 654321" || out["sender_number"] != "code 22000" {
		t.Errorf("identifier fields changed: %v", out)
	}
	if strings.Contains(out["message_id"].(string), "hidden") {
		t.Errorf("message_id redacted")
	}
}
