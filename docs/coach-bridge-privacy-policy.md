# Coach Bridge privacy policy

*Draft, last updated 2026-09-28. It describes what version 2.11 of the app does and must be
reviewed before it is published for TestFlight or App Store users. It is not legal advice.*

Coach Bridge is a training app for iPhone and Apple Watch. It is built so that your data stays on
your devices and goes only where you send it. There is no Coach Bridge server, no account, no
analytics and no advertising.

## What the app reads

- **Apple Health**, with your permission: resting heart rate, heart rate variability, sleep,
  respiratory rate, wrist temperature, blood oxygen, VO₂ max, heart-rate recovery, walking heart
  rate, weight, body fat, activity totals, running form metrics, and workouts with their heart
  rate, power, cadence and distance. Access is **read-only**: the app never writes to Apple Health.
- **Your calendars**, if you turn on calendar sync: the times and titles of your events, so
  sessions can be placed around them.
- **FIT files you import** from a bike computer or watch. Only each session's totals are kept
  (sport, start time, duration, distance, average heart rate and power, device name). Routes, GPS
  positions and per-second records are never stored, and the file itself isn't kept.
- **What you enter**: your training profile (including your bike, groupset, tires, tire pressures
  and running shoes, if you add them), sessions, notes, how workouts felt, and photos you add of
  places you train. If you type your weight for the tire-pressure calculator, it stays on your
  iPhone and is never sent anywhere.

## Where it's stored

On your iPhone and Apple Watch, in the app's private storage, encrypted by iOS. The app's records
(sessions, chats, workout notes, imported workouts) are unreadable while your device is locked;
settings and your training profile are protected until you first unlock after a restart. Nothing
is stored in iCloud. API keys are kept in the iPhone's Keychain, on that device only. The Watch
holds a copy of your upcoming sessions and recovery summary; its watch face complications keep only
the next session and the race countdown, never health values. The same rule holds for the iPhone
widget and Live Activities, which can appear on the Lock Screen: they show today's session and a
one-word recommendation ("Go", "Go easy"), never a health number.

## Where it goes, and only when you choose

| Destination | What | When |
|---|---|---|
| **Your Google Drive** | One file per day of health metrics, in a folder the app creates | Only if you sign in with Google. The app can see only files it created (`drive.file` scope). |
| **Your AI provider** (Anthropic, OpenAI, or a server you set up) | Your messages, training profile (including any bike, tires and shoes you listed) and plan; a summary of recent health metrics and workouts if "Share my Health summary" is on; the times and titles of your calendar events for the coming week when the plan is adjusted, if calendar reading is on; workout details when you ask for a coach's note | Only when you use the coach, with your own API key. The chat screen shows exactly what the chat sends ("See what Claude sees"). |
| **Apple Weather** | Your training location, rounded to about 1 km | When the plan checks the forecast |
| **Apple Calendar** | Your planned sessions and training phases, in a "Training" calendar | Only if you turn on calendar writing |
| **Apple Watch** | Your upcoming sessions, sent over Apple's encrypted connection between your devices | When the Watch app is installed |

Your AI provider processes what it is sent under its own terms. Anthropic and OpenAI both say they
don't train models on API data by default; check their current terms. Coach Bridge never sells,
shares or licenses your data, and never sends health data anywhere not listed above.

Demo mode fills the app with generated data. Generated data is never exported to Google Drive, and
the coach is told it isn't real.

## How it's protected

- Anything you type, and anything that comes from outside the app (such as calendar event titles
  written by whoever sent the invite), is cleaned and marked as data before it goes to your AI
  provider, so it can't be used to give the AI instructions. This is tested automatically for
  every text field.
- Imported files are read defensively and only their totals are kept.
- Web addresses you enter must be secure (https), and keys are checked before they're saved.

## Your control

- **Export my data** (Settings → Your data) gives you everything the app stored as one JSON file.
  Apple Health has its own export in the Health app.
- **Delete my data** removes everything the app stored from your iPhone and Watch, removes its
  scheduled Watch workouts, revokes its access to Google Drive, deletes your API keys and,
  optionally, the Training calendar. Files already in your Google Drive stay there for you to
  manage. Deleting the app also removes everything it stored on the device.
- Health, calendar and location access can be changed at any time in iOS Settings.

## Children

Coach Bridge is not directed at children under 13.

## Changes and contact

Changes to this policy will be listed in the app's changelog. Questions: contact the developer
through the address given on the App Store or TestFlight listing.
