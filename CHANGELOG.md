# Coach Bridge — changelog

The development history, one section per milestone or version, oldest first. Each entry says what
changed and why. Earlier sections include the setup steps as they were at the time; the current setup
is in [README.md](README.md).

---

# M0 · Setup and the bridge

Native iPhone app that reads Apple Health once a day and writes `/Coach/health/YYYY-MM-DD.json` to Google Drive. Spec: `coach-bridge-handoff.md` in the Fitness Coach project.

M0 is done when the **M0 screen on your iPhone shows green for all four rows** and the contract tests pass.

---

## 1 · Apple account decision

**Recommendation: start free, pay $99 right before M3.**

| | Free Apple ID (Personal Team) | Developer Program ($99/yr) |
|---|---|---|
| Build to your own iPhone from Xcode | Yes | Yes |
| App keeps launching | **Expires every 7 days** — re-run from Xcode | 1 year |
| TestFlight | No | Yes |
| HealthKit background delivery | Yes (confirmed on device Sept 21) | Yes |

M0–M2 are all "open app, tap, check" work, so a 7-day expiry costs nothing. M3 is where it breaks: an app that stops launching every 7 days can't be a hands-off daily export. So the $99 buys exactly what M3 needs, and you don't pay until the bridge has proven itself through M2.


## 2 · Mac prerequisites

- Xcode 16 or newer (iOS 17+ SDK), signed in: **Xcode → Settings → Accounts → +** Apple ID.
- `brew install xcodegen`
- iPhone: **Settings → Privacy & Security → Developer Mode → On** (appears after the first Xcode run to the phone).

## 3 · Generate and run

```bash
cd CoachBridge
open Config/Base.xcconfig   # set BUNDLE_ID_PREFIX (e.g. com.brandonnguyen) — do this BEFORE step 4
xcodegen generate
open CoachBridge.xcodeproj
```

In Xcode: select the **CoachBridge** target → **Signing & Capabilities** → pick your Team. You should see **HealthKit** (with Background Delivery checked) already there, from `Support/CoachBridge.entitlements`. Plug in the iPhone, pick it as the run destination, ⌘R.

On the phone: **Request Health access** → turn everything on → **Check background delivery**.

Run the tests with ⌘U (simulator is fine for these).

## 4 · Google Cloud (use your personal Gmail, not the SDSU account)

Personal health data shouldn't sit in a university Workspace Drive, and Workspace admins can block unverified third-party OAuth apps anyway.

1. [console.cloud.google.com](https://console.cloud.google.com) → **New project** → `coach-bridge`.
2. **APIs & Services → Library → Google Drive API → Enable.**
3. **Google Auth Platform → Branding:** app name `Coach Bridge`, your Gmail as support + developer contact.
4. **Audience:** User type **External**. Then **Publish app → In production.**
   - Why: in *Testing* status Google expires refresh tokens after **7 days**, which would silently kill the M3 daily export.
   - `drive.file` is a non-sensitive scope, so production doesn't need Google verification. You'll get an "unverified app" warning once at sign-in; that's expected for a personal app.
5. **Data Access → Add scope:** `https://www.googleapis.com/auth/drive.file` — **only this one.**
6. **Clients → Create client → iOS.** Bundle ID = exactly `$(BUNDLE_ID_PREFIX).CoachBridge`. Leave App Store ID and Team ID blank for now.
7. Copy the **Client ID** and **iOS URL scheme** into a new `Config/Secrets.xcconfig` (template: `Secrets.example.xcconfig`), then `xcodegen generate` and rebuild. The **OAuth client ID set** row turns green.

No client secret exists for iOS clients; there's nothing to download or protect beyond the file above.

## What's in the box

```
project.yml                     XcodeGen spec — iOS 17, iPhone only, GoogleSignIn package
Config/Base.xcconfig            bundle prefix, team, Google placeholders; includes Secrets.xcconfig
Support/Info.plist              read-only Health usage string, BG task ID, Google URL scheme
Support/CoachBridge.entitlements  HealthKit + background delivery, no clinical records
CoachBridge/Model/                 MetricKey, DayRecord (JSON), DayWindows, SleepMath — pure, unit-tested
CoachBridge/Health/                HealthKit mapping, DayRecordBuilder (per-key rules), authorizer
CoachBridge/Drive/                 GoogleAuth (drive.file), DriveClient (REST), Exporter
CoachBridge/App/                   TodayView, SetupCheckView (M0), AppServices, BackgroundExport (M3)
CoachBridge/Health/HealthAuthorizer.swift  permission + entitlement smoke tests
CoachBridge/App/SetupCheckView.swift  the M0 checklist screen
CoachBridgeTests/                  contract, JSON format, windows/DST, sleep merging, Drive helpers
```

## Notes for M1+

- **Workouts added to the read set.** The contract's running-form metrics are "mean over the most recent run", which needs `HKWorkoutType` to find the run. It's the one type beyond the handoff's table.
- HealthKit never reveals whether *read* permission was granted; the M0 row only proves the sheet ran. M1 confirms access by reading real values.
- Logging uses `os.Logger` with counts and status only. Keep it that way: no metric values in logs.
- Only third-party package: GoogleSignIn-iOS (SPM), plus its Google-owned dependencies (AppAuth, GTMAppAuth, GTMSessionFetcher). Tokens live in its Keychain store.

---

# M1 + M2 · Read on device, export on tap

## Update an existing checkout
```bash
cd ~/Documents/Dev/CoachBridge
ditto ~/Downloads/CoachBridge-M2-update ./          # merge the update in (keeps your Config/)
rm -f CoachBridge/Health/MetricKey.swift           # renamed to Model/MetricKey.swift + Health/MetricKey+HealthKit.swift
xcodegen generate
open CoachBridge.xcodeproj
```
First open: Xcode fetches the GoogleSignIn Swift package (File → Packages → Resolve if it doesn't start on its own).

## Verify M1 (numbers)
Open the app, pick a day, compare each row with the Health app. Each row says how it was computed.
- **Sleep:** Health → Sleep → the night before, "Asleep" total (not "In Bed"). Should match within a couple of minutes.
- **HRV / resp / SpO₂:** Health shows individual samples; the app shows count and range, so check the range matches.
- **Resting HR:** today's value. **Steps / active energy / exercise:** *yesterday's* totals.
- **Wrist temp:** stays "not logged" until 7 prior nights exist.
- **Running form:** only if you ran yesterday or today.

## Verify M2 (Drive)
1. **Sign in with Google** → pick your personal Gmail → "Google hasn't verified this app" → **Advanced → Go to Coach Bridge** → allow access.
2. **Export to Drive** → "Created Coach/health/<date>.json".
3. Tap again → "Updated …" (same file, no duplicate).
4. In drive.google.com, open Coach → health → the file; it must match the JSON preview.
5. Sign out revokes the app's access; signing back in picks up the same folder.

Note: if you already had a folder called "Coach" in Drive, the app can't see it (drive.file) and makes its own. Rename or merge in Drive if that happens.

---

# M3 · Automatic

## Update
```bash
cd ~/Documents/Dev/CoachBridge
ditto ~/Downloads/CoachBridge-M3-update ./
xcodegen generate
```
Then ⌘R to the iPhone and ⌘U for tests.

## How it runs
| Trigger | When | Backfill |
|---|---|---|
| App open | every time the app comes to the foreground | all missing days in the last 60 |
| Health update | HealthKit wakes the app (at most daily) after new resting HR / HRV / sleep | 7 missing days |
| Daily refresh | `BGAppRefreshTask`, earliest 6:30 AM; iOS picks the actual time | 7 missing days |
| Sync now | button in the app | all missing days |

Every run re-exports **today and yesterday** (their values keep changing) and uploads missing older days. Days with no data at all are skipped, not written as empty files. Background runs are throttled to one per 10 minutes and never run while the phone is locked.

## Phone settings that matter
- **Settings → General → Background App Refresh:** on, and on for Coach Bridge.
- **Don't swipe Coach Bridge away** in the app switcher. iOS won't relaunch a force-quit app in the background until you open it again.
- Low Power Mode pauses background refresh.
- **Free Personal Team builds expire after 7 days** and then won't launch at all, including in the background. For hands-off daily exports, this is where the $99 Developer Program pays off (1-year builds / TestFlight).

## Verify
1. Open the app → **Automatic export** shows "Last automatic export: now · N new… · app open". Drive → Coach → health should now have files for the last 60 days (except days with no data).
2. **Simulate the background refresh** from Xcode: run on the phone, press Home to background the app, click **Pause** (⏸) in Xcode, and in the debug console type:
   ```
   e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.brandonnguyen.CoachBridge.daily-export"]
   ```
   then **Continue** (▶). Reopen the app: the summary line should end in "daily refresh" (or say it was throttled in the Xcode console if you ran it within 10 min of the last run).
3. **The real test:** leave the app in the background overnight. Tomorrow, after unlocking the phone and *before* opening Coach Bridge, check Drive in a browser: today's file should already be there with a morning timestamp. Opening the app afterward shows which trigger did it.

---

# Dashboard + Coach chat

## Update
```bash
cd ~/Documents/Dev/CoachBridge
ditto ~/Downloads/CoachBridge-dashboard-update ./
xcodegen generate
```
⌘R to the phone. Health asks once more, for **heart rate and distances** (used for workout details on the dashboard). ⌘U for tests.

## Tabs
| Tab | What it is |
|---|---|
| **Today** | Recovery signal (resting HR + HRV vs your 4-week baseline, with the reasons shown), today's key numbers, 4-week resting HR and HRV charts (tap and drag to read a day), weekly training hours by sport, recent workouts. Pull to refresh. |
| **Coach** | Chat with Claude via the API. Each message carries your profile and, if sharing is on, a Health summary. **⋯ → See what Claude sees** shows the exact text. **Continue in the Claude app** copies today's numbers and opens your Fitness Coach project. |
| **Plan** | Opens the Road to Sacramento page (sign in to claude.ai once inside it). |
| **Sync** | The Drive export screen from M1–M3. |
| **Settings** | API key (Keychain), model (`claude-sonnet-5` default), your "About me" profile, Health-sharing toggle, links, setup checks. |

## Claude API key
1. console.anthropic.com → sign in → **Billing**: add a card or credits (pay per use, separate from your Claude subscription).
2. **API Keys → Create key**, name it `coach-bridge-iphone`.
3. Settings tab → paste → **Save key**. It's stored in this iPhone's Keychain (this device only, readable only while unlocked); it isn't in the project files or iCloud.
4. Suggested: set a monthly spend limit in the console. A typical question with the Health summary is a few thousand input tokens.

## Privacy notes
- Chats are kept in memory only; they're gone when the app closes. Nothing chat-related is written to disk or logs.
- With sharing off, Claude gets only your profile text and your messages.
- The API chat does **not** see your Claude project, memory or Strava. For full coaching sessions, use **Continue in the Claude app**.

---

# Training calendar (Plan tab)

## Update
```bash
cd ~/Documents/Dev/CoachBridge
ditto ~/Downloads/CoachBridge-calendar-update ./
xcodegen generate
```
⌘R, then ⌘U. Health asks once more, for **cycling power and cadence**.

## How it works
- **The plan is built in.** The Road to Sacramento engine is ported to Swift (`Model/TrainingPlan.swift`): phases, weekly templates, long-weekend alternation, class nights, snowboard weekends, events, milestones. It matches the coach page as of Sept 21 2026. If the plan changes on the page, this file needs the same change.
- **Every session has targets and fueling** (`Model/Prescriber.swift`): progressions like "40 → 60 min" are interpolated across the phase, so the calendar shows *this week's* number. HR and power ranges appear once you enter **FTP** and **LTHR** in ⋯ → Plan settings; until then they're by feel. Fueling follows the page's gut-training table (60 g/h Base 1 → 80–90 g/h build, sodium, fluid, a savory bite each hour).
- **Month → Week → Day → session.** Tap a day in the month to open its week, a day in the week to open the day, and a session for its full targets and fueling. Past days list what Apple Health recorded; tap a workout for HR and power charts, time in zones (with LTHR set), pace/speed, elevation, calories, and what the plan called for that day.
- **Pull to refresh = Claude's update.** It sends the next 7 days of the plan, your recovery summary and last week's workouts to Claude, which returns today's call plus only the days it changes (marked ✦, with the reason and the original plan kept). **Max one request per minute**. The limit is saved on the phone, so relaunching doesn't reset it, and failed attempts count too. About 1–3¢ per update.
- Claude's changes are saved on the phone (Application Support, complete file protection) and drop off as days pass. ⋯ → **Undo Claude's changes** goes back to the plan as written.

---

# Calendar sync + weather

## Update
```bash
cd ~/Documents/Dev/CoachBridge
ditto ~/Downloads/CoachBridge-calendar-weather-update ./
xcodegen generate
```
⌘R, then ⌘U. Plan tab → ⋯ → **Plan settings → Connect Calendar**.

## Calendar (EventKit, two-way)
- **Reads** your calendars (birthdays/holidays off by default; choose which in Plan settings). Sessions go into free time: weekdays 4:30–8:30 pm, then 5:30–8:45 am; weekends from 7 am, then 3–7 pm, with 15 min around other events. Back-to-back sessions (run then lift, ride then brick) stay together.
- **Writes** the next 14 days of sessions into its own **Training** calendar (iCloud when available), with targets and fueling in the notes, so they show in Calendar, on the Lock Screen and on the Watch. If you drag a session to another time in Calendar, the app keeps your time; titles/notes are rewritten on each sync. Sessions with no free slot appear as an all-day "⚠︎ … no free slot" item.
- **Claude sees** event times and titles for the next 7 days when you refresh (your choice), never locations, notes or attendees. It returns start times when it moves something.
- The app only ever edits its own Training calendar. **Remove Training calendar** deletes it and its events and nothing else.

## Weather (Open-Meteo for now)
- Free, no key, non-commercial use; attribution shown in the day view. Default location Chula Vista Bayfront; "Use my current location" asks once for approximate location.
- Day high/low, rain, sunrise/sunset; forecast at each session's start time. A hot afternoon (feels ≥ 90°F, the plan's heat rule) moves sessions to the morning and gets flagged. The forecast goes to Claude with each refresh.
- **WeatherKit (Apple Weather)** needs the paid Developer Program; swap it in after you upgrade.

---

# Apple Developer Program + Apple Watch + Apple Weather

## 1 · Enroll ($99/yr)
Easiest on iPhone: install the **Apple Developer** app → **Account** → **Enroll now** → Individual → your legal name → pay. Approval is usually quick but can take up to 48 hours; you'll get an email.

## 2 · After approval
1. Xcode → Settings → Accounts: your team now shows **Brandon Nguyen** (not "Personal Team").
2. Target → Signing & Capabilities → **Team: Brandon Nguyen**. Same bundle ID, so Google sign-in and everything else keep working. Builds now last a year.
3. **Turn on Apple Weather:**
   ```bash
   /usr/libexec/PlistBuddy -c "Add :com.apple.developer.weatherkit bool true" Support/CoachBridge.entitlements
   xcodegen generate
   ```
   Then [developer.apple.com/account](https://developer.apple.com/account) → Certificates, IDs & Profiles → Identifiers → `com.brandonnguyen.CoachBridge` → **App Services** tab → check **WeatherKit** → Save. It can take ~30 minutes to activate. Relaunch the app: Plan settings → Weather location → Source shows **Apple Weather**.
   (Don't add that entitlement before the membership is active; a Personal Team can't sign it.)

## Apple Watch (WorkoutKit)
- The next 7 days of placed sessions go to the Watch's **Workout → Scheduled** list (Apple caps how many an app can schedule), each with its steps: sweet-spot rides get warm-up, 3×12 → 2×20 intervals with power alerts and easy spins between, and a cool-down; the Wednesday key run gets an easy block then a steady finish with HR alerts; easy sessions get one block with an HR (runs) or power (rides) range alert. Swims and lifts go on as simple time goals.
- Alerts need numbers: add FTP and LTHR in Plan settings. Without them, sessions still schedule, just without alerts.
- Changes (Claude's updates, moving a session in Calendar) replace the Watch copy on the next sync. **Start on Apple Watch** in a session opens it in the Workout app immediately.
- First sync asks permission to schedule workouts.

---

# Your own sessions

Plan tab → **+** (top right), or **Add your own session** inside a day. Pick date, start time, length, type, title and a description, then **Add session and update plan**.

What happens:
1. The session is saved on the phone and treated as **fixed** — that exact time is booked.
2. It goes into your Training calendar and onto the Watch like any other session.
3. Claude gets it flagged as yours, keeps it exactly as entered, and reworks the rest of that week around it (moving, shortening or cutting plan sessions by the plan's cut order). Rate limit still applies: one Claude update a minute.

Your sessions show a **YOURS** badge in the calendar. Open one and tap **Edit or delete** to change it; the plan updates again on save.

---

# Coach chat can change the plan

Plan settings → **Coach chat** → *Let chat change my plan* (on by default).

Ask in the Coach tab the way you'd ask a person: *"swap Saturday's ride for a run with the guys"*, *"move the long ride to Sunday for the rest of Base 1"*, *"I'm travelling next week, keep it to 45 minutes a day"*. Claude answers in the chat and, when the ask is a real change, attaches a **Proposed plan change** card. Nothing happens until you tap **Apply**; **Discard** throws it away.

Two kinds of change, so a one-off doesn't rewrite the season:

- **Day changes** — specific dates. Saturday becomes a run; Tuesday is off. They sit on top of the plan and drop away as those days pass.
- **Rules** — anything lasting, with a date range: *swap sport*, *move weekday*, *drop kind*, *add weekly*, *scale duration*, *indoor rides*. A rule is a lens over the plan, not a rewrite: the season underneath is untouched, so when the range ends the plan snaps back to what it always was.

Rules are listed in Plan settings under Coach chat — swipe one away to drop it. **Undo N days changed in chat** clears the one-off day changes. Sessions you added yourself are never moved, shortened or removed by a rule or by Claude.

Applying a change re-places your Training calendar and re-sends the next 7 days to the Watch.

---

# Indoor rides (Wahoo KICKR CORE 2)

Plan settings → **Indoor trainer** → *I have a smart trainer*.

- Any ride can be indoors — Claude puts one there when weather, daylight or your calendar makes outside a bad idea, and you can ask for a stretch of them ("rides indoors through Thursday", which becomes an *indoor rides* rule).
- Indoor sessions drop distance targets (meaningless on a trainer), gain an **ERG / cadence** note, and add roughly **25% more fluid** for the lack of airflow. Power targets come from FTP, so set it in Plan settings.
- They show a trainer icon in the calendar, go to the Watch as an **indoor cycling** workout (so the Watch doesn't wait for GPS), and land in your Training calendar titled "Bike (indoor): …".
- The trainer's own power and cadence reach Apple Health through the Wahoo app; Health dedupes overlapping energy by source priority, same as the Karoo.

---

# Places and photos

Plan settings → **Where you train** → *Places and photos*.

Every day screen leads with a photo of where that session actually happens — the Bayshore, Imperial Beach, the Aquaplex, La Jolla Cove, the pain cave. The app ships with the names already seeded; add your own shots and the day gets your photo instead of a sport-colored gradient.

- One library per sport, plus a separate one for **indoor rides**.
- With several places for a sport, the app rotates them — the same date always shows the same place, so the week isn't seven copies of one photo. **Always show this one** pins a favorite.
- Photos are resized to banner size and copied into the app's own storage with complete file protection. They are never uploaded, exported to Drive, or sent to Claude.

---

# Look and feel

## Light and dark
Settings → **Appearance**: System, Light or Dark. System follows the phone, including its schedule. The two schemes are tuned separately — dark is a blue-black (`#0B111C`) rather than pure black, because that's what translucent surfaces read against; light stays near-paper so text keeps its contrast.

## Color
Every screen sits on a soft wash of colored light, tinted by tab: Today blue, Coach violet, Plan aqua, Sync orange. Cards pick up a hue from what they contain — recovery takes the status color, the stat tiles are grouped by metric family (heart magenta, recovery aqua, overnight violet, body yellow, activity orange), sport cards carry a colored bar down the left edge. The chart colors are unchanged: they're the validated palette slots, and numbers are always written out in text as well as drawn.

## Liquid Glass
On **iOS 26** the cards, chat bubbles, input bar and buttons use real Liquid Glass (`glassEffect`, `.buttonStyle(.glass)`), the tab bar shrinks as you scroll, and scroll edges soften into the bars. On iOS 17–18 the same surfaces fall back to `.ultraThinMaterial` with a hairline border, which reads the same way.

All of it goes through `App/Theme.swift` — `glassSurface`, `glassCard`, `glassButton`, `AppBackground` — so there's one file to change if a surface looks wrong, and one place where the iOS 26 APIs are referenced.

Note: building with the **Xcode 26 SDK** also gives the navigation bars, tab bar, sheets and Form rows the system Liquid Glass automatically. Nothing opts out of it.

## The artwork
The 12 illustrations behind the seeded places are original flat scenes drawn from code — no photographs, no logos — by `tools/make_venue_art.py`, which writes them into `Resources/Assets.xcassets/VenueArt` as single-scale JPEGs (~600 KB for the set). Re-run it after editing a scene:

```bash
python3 tools/make_venue_art.py && xcodegen generate
```

Your own photo always wins over the illustration; removing the photo puts the illustration back.

---

# The place as the screen (v1.1)

The day screen and each session screen sit **on** the place they happen. The venue image fills the
background, heavily blurred, desaturated to 55% and under a scrim, so it reads as colored atmosphere
rather than a picture — and the glass panels on top finally have something real to refract, which is
the whole point of Liquid Glass.

- **Day screen:** full-bleed backdrop, and the place itself becomes a slim glass chip at the top
  (crisp thumbnail + name) instead of the old 150 px banner. A column of cards doesn't need both.
- **Session screen:** backdrop *and* the crisp banner — blurred behind, sharp in front, the way a
  now-playing screen works. List rows become glass so the photo shows through.
- **Week and month** keep the painted wash: they span several sports, so there's no single place.
- **Reduce Transparency** in Accessibility turns the photo backdrop off and falls back to the wash.

## Pastel light mode
The background wash and card tints no longer use the chart colors directly. `Palette.wash` lifts a
hue 55% toward white in light mode, because the saturated versions read as neon behind glass; dark
mode keeps the full hues, which it needs to show up at all. The **chart** palette is untouched —
those colors are calibrated for contrast and carry data.

`Color.blended(with:amount:)` does the mixing, resolved per trait collection so a dynamic
light/dark color stays dynamic. (`Color.mix(with:by:)` would do it in one line but is iOS 18+.)

---

# Training hours: why the chart was wrong

One workout in Apple Health had a duration of about **900 hours** — a session started and never
ended. It landed entirely in its starting week, set the y-axis to 1,000, and squashed every real
week to a flat line. The hours were always there; they were just 0.3% of the chart.

`Stats.weeklyLoad` now drops any session longer than `Stats.maxSessionHours` (18 h — a full
IRONMAN fits inside it, a stuck timer doesn't), and the dashboard **says so** under the chart
rather than silently discarding your data. To fix it at the source, delete that workout in
Health → Browse → Activity → Workouts.

Everything that isn't a swim, ride or run still falls into "Strength & other" — that's the
catch-all, which is why the stuck session showed up as a giant yellow bar.

---

# Chat history

The Coach tab keeps its conversations. **History** in the toolbar lists them newest first, grouped
Today / Yesterday / Previous 7 days / Earlier, with the opening question as the title. Swipe to
rename or delete; "Delete all" clears everything. **New chat** files the current one and starts
fresh.

Chats are stored in `chats.json` in Application Support with complete file protection — readable
only while the phone is unlocked, never uploaded, never exported to Drive. The last 100 are kept.

---

# Multiple providers, and sharing the app

## Providers
Settings → **Model provider**: Claude (Anthropic), OpenAI, or a shared server. Each keeps its own
key in the Keychain, so switching back and forth doesn't mean re-pasting, and each offers its own
model list with free-text override so a new model works the day it ships.

Everything above the network layer talks to `LLMClient` (`Coach/LLM.swift`) — two methods, stream
and forced-tool-call. `AnthropicClient` and `OpenAIClient` implement it; `LLMFactory` picks one.
Adding Gemini is one more conformance, not a refactor. The OpenAI client translates Anthropic's
tool shape (`input_schema`) into OpenAI's (`function.parameters`) so the plan tools work unchanged.

## Getting it to friends, today
Each friend brings their own key. What you need:

1. **Apple Developer Program**, $99/yr — you're enrolled. TestFlight needs it.
2. In App Store Connect, create the app record, archive in Xcode (**Product → Archive**), upload,
   and add testers. **Internal testing** covers up to 100 people on your own team with no review.
   **External testing** reaches 10,000 but needs a (usually quick) Beta App Review.
3. Each tester creates a key at `console.anthropic.com` or `platform.openai.com`, pastes it into
   Settings, and sets a spend limit in that console. They're billed for their own usage; you see
   none of it and none of their data.
4. Their Health data never leaves their phone except in the summary sent with each message, and
   only when "Share my Health summary" is on.

**Don't ship your own key in the app.** It's extractable from the binary in minutes.

## When you want a subscription instead
`LLMProvider.hosted` and `HostedClient` are the seam, already wired into Settings and the factory.
The app sends a per-person access token — not an API key — to a server you run, which holds one
real key and forwards. Two endpoints under your base URL:

- `POST /chat` — the app's JSON, replying with Anthropic-style SSE
- `POST /tool` — a forced tool call, replying with the tool's arguments as JSON

What you'd have to build on the server, none of which the app can do for you: accounts and token
issue/revoke, per-user rate and spend limits, abuse handling, logging you're comfortable owning
(these requests carry health data, so that's a real responsibility), and billing if it's a paid
subscription. Budget days, not hours — and note that taking money for it puts you in
App Store in-app-purchase territory.

---

# Scenery (v1.3)

## Times of day
Each scene is drawn once and **graded into four times of day** — morning, day, evening, night —
the way a Mac dynamic desktop shifts one photograph rather than shipping four unrelated pictures.
Night additionally gets stars, placed only where the frame is actually open sky (found per column
by walking down until the colour changes), and a moon in the widest patch of it.

The app picks the variant from the day's **real sunrise and sunset** when the forecast has them,
and from clock hours when it doesn't. Asset names are `<scene>-<phase>`; `VenueArtwork.asset`
falls back to `-day` and then to the bare name, so a missing file degrades instead of rendering
blank.

20 scenes × 4 = **80 images, about 4 MB.** Regenerate with `python3 tools/make_venue_art.py`.

## New places
Trail run · Golden Gate Park · Golden Gate Bridge · mountain road (switchbacks) · Sierra pass ·
open water · ski resort · alpine lake — alongside the San Diego set.

## Backdrops everywhere
Month, week and day all carry a backdrop now, driven by the selected day's main session; a rest
day borrows the next session inside the week rather than dropping to a flat wash. The blur came
down from 44 → 4 and the veil from 58% → 6% at the top, so you can actually see the place.

---

# First-run walkthrough

Eight full-screen slides on first launch: what the app is, Health (with the permission button on
the slide), your own API key, the plan, your own sessions, calendar and Watch, places, and where
your data goes. **Skip** is always there; the last slide is "Start training".

Settings → **Show the walkthrough again** reopens it. Raising `OnboardingView.version` shows it
once more after a release that changes setup — it's stored as a version number, not a boolean,
for exactly that.

---

# v2.0 — the plan is yours now

Everything that used to be hardcoded to one athlete is data.

## What moved
`PlanEngine` had the season written into it: start and end dates, race name and date, five phases
with literal date ranges, the weekly templates, the long-weekend alternation, class nights,
snowboard weekends and a hand-written milestone list. All of it is gone.

- **`Model/AthleteProfile.swift`** — event kind and date, current and peak weekly hours, which days
  you can train, your long day, work/school hours, recurring commitments, time away, races along
  the way, lifting frequency, pool/open-water/trainer access, sports to avoid, and a free-text note.
- **`Model/PlanBlueprint.swift`** — turns that into phases counted **backward from race day**, with
  volume ramping from where you actually are to what you can actually give. `WeekBuilder` then
  builds each week: long session on your long day, second-longest beside it, one quality session
  midweek, the rest filled round-robin from the sports you can do, lifts, rest everywhere else.
  Every fourth week eases off.
- **`PlanEngine`** now just reads the blueprint. `lifeRules` — the "when life happens" text the
  coach follows — is written from your own schedule instead of a fixed list.

Short plans behave differently from long ones on purpose: under ~20 weeks there's no recovery block
and the base is thin, because there isn't time for one.

## Setup
First launch asks, on a slide in the walkthrough, and Settings → **Your training** (or Plan
settings → The plan itself) edits it afterwards. The bottom of that screen previews the phases it
would produce, so you can see the season reshape as you change an answer.

## Migration
An install that already had a plan keeps it: the old `PlanSettings` is read once and converted into
the IRONMAN California profile, with class nights becoming a commitment and snowboard Saturdays
becoming cross-training blackouts. A fresh install starts empty and gets asked.

## "What the coach knows" is now blank
`AppSettings.defaultProfile` is an empty string. The structured facts go to the coach as prose
(`CoachContext.athleteText`); the free-text box is for everything a form can't hold, with
placeholder prompts rather than someone else's biography.

---

# Demo mode

Settings → **Demo** fills the app with generated training data — 28 days of resting HR and HRV,
eight weeks of load, recent workouts, a 70.3 profile — so you can show someone what the app does
with no Apple Watch and no Health history.

It's deterministic from the date, so the charts don't reshuffle. Nothing generated is exported to
Drive, and the coach's system prompt says the numbers are a demo so it won't talk about them as if
they were real. Turn it off to go back to your own data.

---

# Smoother replies, and a way out of the text field

`Coach/StreamSmoother.swift` buffers the model's output and releases it at a steady ~110 chars/sec,
accelerating as the backlog grows so it never falls behind, and flushing whatever's left when the
stream ends. The API delivers text in bursts; appending each burst straight to the screen is what
made it jump.

The Coach input now has a **Done** button above the keyboard, dismisses when you tap the
transcript, and sends on Return.

---

# v2.6 — goal, blocks and equipment

## Your goal, in your own words
Setup has a free-text **"What would make this a good day?"** under the event. It goes to the coach
with every message and to the plan adjuster, and it's the detail on the race-day milestone in the
calendar — so the reason you're doing this is on the screen, not just in a prompt.

## Training blocks you control
`PlanBlueprint` always had Recovery → Base 1 → Base 2 → Build → Taper. Now you set the length of
each one. Setup shows a stepper per block with what it's for, and the suggested split stays in
force until you touch a stepper — after that your numbers win (`AthleteProfile.blockWeeks`).

Your numbers are fitted to the runway rather than obeyed blindly:

- Spare weeks go into **Base 1**.
- A shortfall is cut in the order a coach would cut it — the easy weeks up front, then Base 1,
  then Base 2, and only then **Build**. The **taper is never cut**.
- A block whose weeks would be trimmed says so inline ("becomes 4 weeks to fit the runway"), and
  a block set to zero is dropped from the plan entirely.

`blockLengths` is covered by a sweep over every runway from 4 to 208 weeks plus random overrides:
the blocks always sum to the weeks available, Build and Taper always survive.

## Equipment
`AthleteProfile.equipment` replaces the three `hasPool` / `openWaterAccess` / `hasTrainer` booleans
with a list (`Equipment`), grouped in setup under Bike, Swim, Run and tracking, and Strength. The
old booleans still exist as read-only computed properties, so nothing downstream changed, and the
migration carries an existing install's trainer flag across.

The coach and the plan adjuster are both told the list and told not to program anything that needs
kit which isn't on it. The duplicate trainer toggle in Plan settings is gone — it lives in
**Settings → Your training** with everything else.

## Demo mode no longer leaks real data
Switching Demo mode on used to leave real Health readings on screen: the dashboard's 15-minute
cache didn't know the mode had changed, `invalidateWorkouts()` cleared the list of loaded ranges
but not the workouts themselves, and a slow HealthKit read started before the switch could land
afterwards and overwrite the demo numbers.

Now `AppServices.demoModeChanged()` is the one place that handles the switch: it drops the
dashboard data before anything can read it, clears every cached workout, forgets the last system
prompt, and reloads. `DashboardModel` stamps its data with the mode it was loaded under, so
`ensureLoaded()` refuses data from the other mode, and a generation token discards an in-flight
read that finishes after a switch. Leaving Settings with the mode changed reloads again, so no
other tab can be showing the wrong numbers.

---

# v2.7 — the coach reacts to what you did

Two halves of the same loop: the app asks how a session felt, and the coach writes back about it.

## "How did it feel?"
Every recorded workout gets the question, the way Strava asks it. A row of five faces, a Borg CR10
effort slider (1–10, with the scale described in words rather than left as a bare number) and an
optional note. Saved to `workout-journal.json`, keyed by the HealthKit workout UUID so it outlives
the dashboard's eight-week window.

The sheet opens by itself for anything finished in the **last 48 hours**, so a session logged this
morning gets asked about. Older workouts show a prompt card instead — browsing last month's training
shouldn't throw a sheet at you. Unanswered sessions carry the nudge on the card in the day view, and
answered ones show the face and RPE there.

## The coach's note
Under each workout: a headline, two or three sentences on what happened, a line tying it to the goal
you wrote in setup, and — only when it's warranted — something to watch for. The prompt tells it to
cite the numbers it was given and never invent history, that being off plan isn't automatically a
failure, and that praise has to be earned.

**It costs one request per session, and only when you ask for it.** Answering how it felt asks
automatically; otherwise there's a button. The note is then cached, so reopening a workout spends
nothing. Changing how a session felt throws the old note away, because it was written from an answer
that no longer applies.

Demo mode writes its own note on the phone from the same comparison — no key, no request — so the
feature demos without an API key.

## Planned versus actual
Above the note, and free: `SessionCompare` reads the plan's own targets (`WorkoutShaper.range` already
parsed "138–151 bpm" and "176–186 W") and puts them against what the watch recorded. Duration counts
as on plan within 10%, or five minutes, whichever is larger — so a 20-minute session isn't marked
short for finishing two minutes early. A target with no samples is **unknown**, not a miss; your
watch failing to record power is not you missing the target.

This works with no API key at all, which is most of the value on its own.

## The effort feeds back into planning
Recent RPE and mood now go into the weekly plan adjustment and the Coach chat, with a line telling
the model to trust the rating over heart rate when the two disagree — a rising RPE at the same power
is fatigue arriving before the numbers show it. That's the point of asking: the plan can respond to
a hard week before your resting heart rate does.

---

# v2.7.1 — compiled for the first time

No new features. This is the first version an agent built and tested itself, on your Mac, instead of
handing you a zip to compile. The project is now a git repo: commit `90d2b22` is v2.7.0 exactly as
delivered, and every fix after it is one commit saying what was wrong and why, so you can see what
was delivered versus what had to be repaired.

## What broke
The app compiled clean, the new v2.6/v2.7 code included. The tests didn't: `⌘U` hadn't run since
v2.0, and four tests still called things the way they worked before the model refactor. Those were
fixed in the tests; no app code changed for them.

Once the tests ran, three failed. One expected the wrong word — the line the plan adjuster sends
the coach says `run`, not `Run`, and that's correct, because the prompt tells the model to use
exactly those words. The other two were real bugs in the plan.

## Your first recovery week was the hardest week so far
A recovery week was 70% of its own spot on the ramp. Volume climbs from zero over the first twelve
weeks, so at week 3 that came out *above* week 2 — the first "easy" week carried more than the one
before it. A recovery week is now 70% of the week before it. Every recovery week is a little lighter
(week 7 goes from 41% of the ramp to 35%); from week 13 on nothing changes.

## The taper didn't end on race day
Phases were laid out forward from your start date in whole weeks, and weeks rarely divide the time
to a race exactly. For IRONMAN California it's exactly 57 weeks, and the taper finished on the
**Saturday before the race**, leaving race day outside every phase. From any other start date the
taper would have run up to six days *past* the race.

Phases are now counted backward from race day, which is what the plan was always described as
doing. Base 1 soaks up the odd days, the same place a short runway already came out of, so the taper
is never cut. Checked across every start weekday and every runway from 4 to 208 weeks — 10,003
cases — with the taper ending on race day in all of them.

Your phase dates move by a day or so. Nothing else in the plan changes shape.

## Before your next build to the phone
Put your real Team ID in `Config/Secrets.xcconfig` as `DEVELOPMENT_TEAM`. It's still the
placeholder, which is the setup that has cost you your API key twice.

---

# v2.8 — dashboard first, edit anything, phases you can see

## The first tab is a training dashboard
It opens on where you are, not on your resting heart rate: days to the race, which phase and which
week of it, the whole season as one ribbon, this week's hours against the plan with a Monday–Sunday
strip of what's done, and the next three sessions. Today is a section underneath — today's sessions,
then recovery and the day's numbers exactly as before — and the trends sit below that.

## Every field is tappable
Open any session, planned or your own, and every field is a live control: type, title, date, start,
length, trainer or road, distance, intensity, heart rate, power, pace, notes. There's no separate
edit form any more; adding a session uses the same fields.

Editing a **planned** session makes it yours. It's the rule your own sessions already had: fixed
where you put it, and Claude plans the rest of the week around it. "Go back to the planned session"
undoes it. A blank target shows what the plan would use, so you can see what you're overriding.

**Edits don't call Claude.** They save on the phone as you go. A "Rework my week around this"
button appears once you've changed something, and that's one request, still limited to one a
minute — the same as the old form's Save. Everything you type is length-capped and cleaned before
it's saved, because it ends up in Claude's prompt, your calendar and your Watch.

## Phases are part of the calendar now
The Plan header has the season ribbon and "week 3 of 16", with a badge on easier weeks. The month
grid has a band across the top of each day in the phase's color, paler on easier weeks, so you see
Base 1 turn into Base 2 across the month. The week and day views say which phase and week they're in.

With calendar writing on, each phase is also an all-day banner across its dates in your Training
calendar, and every session's notes start with its phase and week. The banners are marked free and
the Training calendar is never read back as busy, so they don't block anything. This part hasn't
run against a real calendar yet — check it on the phone.

## The Plan tab stutter
The month grid took about a quarter of a second to redraw, and it redraws whenever anything changes.
Three things stacked up: the whole plan was rebuilt twice for every day on screen, each day built its
entire week to find itself, and turning a date into "2026-09-25" built a new date formatter every
time. Now it's about 4 ms. The date change also names your Drive files, so a test checks the new
version against the old one across twelve years of timestamps and six calendars: identical.

## Underneath
Everything the app reads now comes through one `HealthSource`. Apple Health is the first; FIT import
and other devices plug in there. That also made the demo-mode leak testable for the first time: a
test holds a slow Health read open, switches demo on, and checks the late read is thrown away.

---

# v2.9 — a Watch app, other devices, and your data

## Coach Bridge on your wrist
A Watch app that shows what the phone knows: days to the race, which phase and week, today's
sessions and the next few, recovery, and a "How did it feel?" list for anything you finished in the
last two days. Rate it with five faces and the Digital Crown; the answer queues for the phone and
arrives even if the phone app isn't open. "Start in Workout" opens the session in the Workout app
with its steps and alerts. Complications show the next session and the race countdown.

The phone stays in charge. The Watch never reads Health, never builds a plan and never calls
Claude — and an answer from the Watch doesn't write a coach's note on its own, because a note
costs a request and a background launch shouldn't spend money you didn't see. Open the workout on
the phone when you want one. Watch faces draw while the watch is locked, so the complications read
a separate copy with only the next session and the countdown — no health numbers.

## Fuel reminders
On a session of 75 minutes or more, or on race day, "Start fuel timer" taps you every time it's
time to eat. It's local notifications on the watch: they come through while the Workout app is
recording, and nothing leaves the watch.

## Race day
From the dashboard: pacing for each leg from your FTP and threshold heart rate (an Ironman bike at
68–73% of FTP, the run in the low 80s of threshold), and a fuelling timeline from breakfast to the
finish — a gel before the swim, about 26 g of carbs every 20 minutes on the bike with a savory bite
each hour, carbs at the run's aid stations. It's the 80 g an hour you trained, at the low end,
because race nerves make the top of the range harder. Leg times are typical finish times, used only
to place the fuel; go by your watch. The plan reaches the Watch the day before, so it's there on
race morning even if your phone isn't.

## Rides from any bike computer
Settings → Other devices → Import FIT files, or open a .fit file in Coach Bridge from Files or the
share sheet. A ride that Garmin Connect or Wahoo also synced into Apple Health counts once — the
copy with more detail wins. Only the totals are kept: never the route, never the file.

The FIT reader is written for the app and assumes every file is hostile: sizes and counts are
capped, every length is checked, the checksum must match, and it's been fed thousands of corrupted
files and every possible truncation without falling over. It hasn't met a file from a real device
yet — send it one of yours.

## Fitness, fatigue and form
The training-load model everyone else uses (CTL, ATL, TSB), from your workouts: fitness is the last
six weeks, fatigue the last week, form the difference coming into today. It's worked out from
heart rate, so add your threshold heart rate in Plan settings for a better estimate; the card and
the coach both say how it was calculated.

## The coach knows which HRV it's looking at
Apple Health's HRV is SDNN. Whoop, Garmin and Oura report RMSSD, which runs higher, and the coach
was only ever told "HRV (ms)". It's now told it's SDNN and to judge it against your own trend, not
anyone's published norms.

## Golf
A session type for rounds you add: its own targets (walking 18 holes is easy aerobic time; a cart
isn't), water and a snack at the turn, and it goes to the Watch as a golf workout with no fixed
length. Add a photo of your course under Places; there's no illustration for golf yet.

## Your data
Settings → Your data. **Export** gives you everything Coach Bridge stored as one JSON file.
**Delete** removes all of it from the phone and the Watch, takes the scheduled workouts off the
Watch, revokes Drive access, deletes your API keys, and can remove the Training calendar. Apple
Health and the files already in Drive are yours to manage there. A draft privacy policy lives in
`docs/PRIVACY.md` — checking it against the code turned up that calendar event titles go to the
coach when the week is adjusted, so the policy says so.

## Keys
"Test key" checks an API key before you rely on it, using the provider's free model list —
nothing is generated, nothing billed. And a missing key now says which provider and that it's
missing on this iPhone; the chat used to say "Add your Anthropic API key" even with OpenAI chosen.

---

# v2.10 — fixes, your gear, projected times, WeatherKit, widgets

## Fixed
- **A walk showed the lifting icon** in Recent workouts. Everything that isn't swim, bike or run
  shares one bucket for the load chart, and its icon was the dumbbell. Each workout now carries its
  own activity's icon — walk, hike, golf, snowboard, yoga — everywhere a recorded workout appears.
- **"What the coach knows" had no way out.** Return adds a new line in a multi-line field, and the
  form didn't let go of the keyboard. Drag the form down, or tap Done in the top corner; the same
  fix is on every form with a long text field. (The usual "Done above the keyboard" didn't render
  on iOS 27 at all, so it lives in the navigation bar.)

## Snowboarding
Add a snowboard day like any other session. It gets its own targets (hard on the way down, easy on
the lift, counts as leg strength), fuelling for cold and altitude, and it goes to the Watch as an
open-ended snowboarding workout. "Snowboard — a few runs" used to be read as a run; not any more.

## Your bike, tires and shoes
"What you've got" asks what you ride and what tires (and tubeless or not), and which running shoes
you have — super trainer, max cushion, daily, carbon racer, stability, trail. The coach gets all of
it, and is asked to say which pair suits a run. Saving it can't wipe the rest of your profile: a
new required field would have done exactly that, so the gear is stored the careful way, with a
test.

## Projected race times
The dashboard projects your finish from the last eight weeks: swim pace, your quicker rides, and
your best run carried to race distance (with the usual fade for running off the bike). It's a
range, it says what each leg is based on, and legs without enough data say "typical". Give your
other races a distance and they get a time too. The race-day fuelling now follows your projected
leg times.

## Apple Weather
Forecasts come from Apple Weather only. The app always tried it first, but the entitlement was
never added, so every forecast had quietly been coming from the backup. **One step for you:** in
the Apple Developer portal, turn on WeatherKit for the Coach Bridge App ID under both Capabilities
and App Services. Until then the weather card says exactly that.

## Widget and Live Activities
A Today widget — home screen or Lock Screen — with today's session and a go / no-go: Go, Go easy,
Swap to easy (recovery's down and the session is hard), Rest day, or Go by feel. Start a Live
Activity from any session or the race-day plan: the session, a running clock, the target and the
fuel cadence, on the Lock Screen, in the Dynamic Island and on your Watch. Neither shows a health
number, since both can be seen on a locked phone.
