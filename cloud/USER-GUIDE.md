# Your texts in Claude: a one-page guide

This lets Claude (claude.ai) read and search your text messages (SMS and RCS
from Google Messages on your Android phone) so you can ask things like
"what did I miss today?" or "find the address Sarah sent last week".

## What it can and can't do

- **Reads only.** Claude can read, search and summarize your texts. It can't
  send, react to, or delete anything. If you ask it to send a text, it can draft
  one for you to copy into Google Messages yourself.
- **Your own copy.** Your texts are stored on a small Google Cloud computer in
  your own account, and pass through Claude when you ask about them. They
  aren't shared with anyone else's setup.
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
  without telling whoever helps you: either can disconnect it.
- **Alerts:** the ntfy app on your phone tells you if the connection stops
  ("Texts: disconnected" or "needs reconnecting") and when it's back. On
  Sunday evenings it also sends a short "all good this week" notice. No
  notice at all on a Sunday means something's off: tell whoever helps you.
- **Updates install themselves** overnight. If one ever breaks the
  connection, it undoes itself and you get a "Texts: update rolled back"
  notice; there's nothing for you to do.

## If it stops

- **"Texts: disconnected"**: usually fixes itself. Wait for "back online".
- **"Texts: needs reconnecting"**, or Claude's answers start with WARNING:
  run the reconnect command (below) once, at a computer with Chrome, with
  your phone in hand. It takes about 5 minutes: you sign in to Google in a
  window it opens, then tap a matching emoji on your phone. Don't run it over
  and over; if it fails twice, ask for help.

```
cloud/vm/reconnect.sh
```

## Turning it off

Any of these stops it, from least to most permanent:

1. claude.ai: Settings, Connectors, remove OpenMessage (Claude can no longer
   read your texts).
2. Google Messages: Settings, Device pairing, remove the device (the server
   stops receiving texts).
3. Google Cloud console: stop or delete the `om-test` VM (deleting it erases
   the stored texts).

## Privacy, plainly

- Your texts, including messages from your contacts, are stored on the VM and
  read by Claude when you ask. Claude's handling follows your claude.ai
  account's data settings.
- The VM holds a Google sign-in for your account. Keep your Google Cloud
  account secure (2-step verification on), and don't give others access to
  the project.
