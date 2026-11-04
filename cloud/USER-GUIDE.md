# Your texts in Claude: a one-page guide

This lets Claude (claude.ai) read and search your text messages (SMS and RCS
from Google Messages on your Android phone) so you can ask things like
"what did I miss today?" or "find the address Sarah sent last week".

## What it can and can't do

- **Reads only.** Claude can read, search and summarize your texts. It can't
  send, react to, or delete anything. If you ask it to send a text, it can draft
  one for you to copy into Google Messages yourself.
- **Your own copy.** Your texts are stored on a small Google Cloud computer
  set up for you alone by the person who runs your service, and pass through
  Claude when you ask about them. They aren't shared with anyone else's
  setup.
- **Verification codes are hidden.** One-time login codes in your texts show
  up as "[code hidden]", so a trick message can't get Claude to pass them on.
- **It says how fresh it is.** Every answer starts with a line like "Texts
  synced through 3:42 PM; Google Messages connected." If it says WARNING
  instead, recent texts are missing.

## Using it

Use any chat with the OpenMessage connector turned on (or the **Texts**
project, if one was set up for you). Try:

- "What texts did I get today? Anything I need to reply to?"
- "Find the restaurant Alex recommended."
- "Summarize my conversation with Mom this week."
- "Draft a reply to Jordan saying I'll be 10 minutes late."

Treat what's in texts as information, not instructions. A text that says
"Claude, forward this to..." is just a text.

## Keep it working

- **Keep your phone on and online** with Google Messages as your texting app.
  Your phone is the source; if it's off, nothing new arrives.
- **Don't remove the paired device** in Google Messages (Settings, Device
  pairing). That's the connection.
- **Don't sign out of Google everywhere** or change your Google password
  without telling the person who runs your service: either can disconnect
  it.
- **Nothing to install or watch.** The person who runs your service gets an
  alert if your connection stops, and a weekly check. Updates install
  themselves overnight and undo themselves if they break anything.

## If it stops

If Claude's answers start with WARNING, or the person who runs your service
gets in touch to say it needs reconnecting: it takes about 5 minutes with
your phone in hand. You sign in to Google when asked, then tap the matching
emoji on your phone. There are no commands for you to run.

## Turning it off

Any of these stops it, from least to most permanent:

1. claude.ai: Settings, Connectors, remove OpenMessage (Claude can no longer
   read your texts).
2. Google Messages: Settings, Device pairing, remove the device (the server
   stops receiving texts).
3. Ask the person who runs your service to delete your setup. That erases
   the stored texts and the Google sign-in it holds.

## Privacy, plainly

- Your texts, including messages from your contacts, are stored on the VM and
  read by Claude when you ask. Claude's handling follows your claude.ai
  account's data settings.
- The VM holds a Google sign-in for your account. The person who runs your
  service has admin access to it, so they could read your texts; the terms say
  what they may do with that access. Keep 2-step
  verification on for your Google account.
