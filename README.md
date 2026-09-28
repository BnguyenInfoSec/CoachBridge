# Coach Bridge

A native iPhone and Apple Watch training companion for endurance athletes. Coach Bridge brings
your training data together — Apple Health and the FIT files from any bike computer — builds a
periodised plan toward your race, adapts it with an LLM coach, and keeps your data yours:
read-only access, stored on your devices, exported only where you choose.

<p align="center">
  <img src="docs/images/dashboard.png" width="300" alt="Dashboard: race countdown, season phases, this week's progress and upcoming sessions">
  &nbsp;&nbsp;
  <img src="docs/images/plan.png" width="300" alt="Plan: the current phase, season ribbon and week view">
</p>

<p align="center"><sub>Screenshots use the app's demo mode. Every number shown is generated.</sub></p>

---

## Contents

- [Features](#features)
- [Architecture](#architecture)
- [Privacy and security](#privacy-and-security)
- [Security engineering](#security-engineering)
- [Getting started](#getting-started)
- [Development](#development)
- [Project status](#project-status)
- [Documentation](#documentation)

## Features

**Training dashboard.** The first screen shows where you are in the season: days to the race,
the current phase and week, the whole plan as a ribbon, this week's hours against the plan, and
the next sessions. Below it, a Today section shows today's sessions, a recovery signal and the
day's metrics, followed by the resting heart rate and HRV trends.

**A plan built from your profile.** You describe your event, available hours, training days,
equipment and goal. The plan is counted backward from race day through recovery, base, build and
taper phases, with recovery weeks built in. Phases appear throughout the calendar: in a season
ribbon, as color bands across the month view, and as all-day banners in Apple Calendar.

**Every session says why.** Each session explains what it does and what it builds ("we're doing
this to build that"), and where it fits in the current block. It's written by the app, so it
costs nothing.

**Edit any session in place.** Every field of every session can be changed with a tap. Editing
a planned session makes it yours: it stays where you put it, and the coach plans the rest of the
week around it.

**An LLM coach that costs only what you use.** It adjusts the coming week against your recent
data, can change the plan from chat (applied only after you confirm), and writes a note on each
completed workout. Every model response is validated and clipped before use. Requests are
deliberate and rate-limited, and nothing calls the model just because a screen opened.

**Schedule sync.** Sessions are placed around your existing calendar events in a dedicated Training
calendar and sent to Apple Watch as structured workouts through WorkoutKit.

**The original bridge.** Once a day the app writes a JSON summary of your health metrics to a
folder in your own Google Drive, for other tools to read. The format is a fixed contract,
documented in [`docs/data-contract.md`](docs/data-contract.md).

**Apple Watch companion.** Today's sessions, phase and week, recovery, and complications for the
next session and race countdown. Start a session straight into the Workout app, rate how a workout
felt with the Digital Crown, and get fuel reminders on long sessions and race day.

**Asks how it went, the way Strava does.** Open the app after a workout and it asks how it felt;
turn on workout reminders and a notification asks as soon as Health has the workout, with one
reminder later. Your answer is what the coach's note is written from, and the note shows right on
the workout in the plan. Run/walk intervals recorded as separate pieces count as one workout.

**Bring your own devices.** Import FIT files from Garmin, Wahoo, Hammerhead or any bike computer.
A session that's also in Apple Health counts once. Only totals are kept, never the route.

**Fitness, fatigue and form.** The CTL/ATL/TSB training-load model, computed from your workouts,
on the dashboard and in what the coach sees, always labelled with how it was estimated.

**Projected race times.** Its own dashboard card: a finish time for your goal race and every other
race on your calendar, split into swim, bike, run and transitions from your own recent training,
shown as a range and labelled with what it's based on.

**Your bike, set up properly.** Groupset and gearing, wheelsets, tires and rims, and a
tire-pressure calculator (weight, width, tubes or tubeless, hooked or hookless, surface) that
fills in your pressures and shows the right one on every outdoor ride, eased for rain, with the
shallower wheels suggested when it's gusty.

**Your fuel.** What you eat and drink for swim, bike and run, and how many carbs an hour your gut
handles. Each session's fuelling names your own products.

**Knows what it costs.** Every AI request's token counts are recorded on the phone (never the
content) and shown per feature with an estimated price, to size a subscription from real usage.

**Nothing shared without asking.** Before anything goes to your AI provider or Google Drive, the
app says exactly what, where and when, and waits for your OK. Settings → Data sharing turns
either off again.

**Widgets and Live Activities.** A Today widget for the home and Lock Screen with your session and
a go / no-go call from your recovery, and a Live Activity with a running clock and fuel cadence
for a session or a race.

**Race-day plan.** Pacing for each leg from your FTP and threshold heart rate, and a fuelling
timeline built from what you practised in training, on the phone and on your wrist.

**Your data, your call.** Export everything the app stored as one JSON file, or delete all of it
from your phone and Watch in one step.

**Demo mode.** Fills the app with generated data so it can be shown without an Apple Watch or any
Health history. Demo data never reaches Drive, and the coach is told the numbers are not real.

## Architecture

SwiftUI, iOS 18+ and watchOS 11+. One Swift package dependency:
[GoogleSignIn-iOS](https://github.com/google/GoogleSignIn-iOS). No analytics or crash reporting.

```
CoachBridge/
  Model/    Pure value types and logic: the plan engine, scheduler, data contract.
            No UI, no I/O, no clock reads; dates take an injected Calendar. Unit-tested.
  Health/   HealthSource protocol, the HealthKit readers behind it, demo data
  Drive/    Google sign-in (drive.file scope), Drive REST client, daily exporter
  Coach/    LLM clients, prompt construction, observable models, calendar and Watch sync
  App/      SwiftUI views, theme and palette
Shared/     The only code the phone and Watch share: the snapshot and feel-report values
Watch/      The watchOS app: shows the phone's snapshot, sends back how workouts felt
WatchWidgets/  Complications (next session, race countdown)
SharedPhone/   Shared by the iPhone app and its widget extension: widget data, Live Activity attributes
PhoneWidgets/  The iPhone widget and the Live Activity UI
```

**Phone and Watch.** The phone is the source of truth. It sends the Watch a small, versioned
snapshot over WatchConnectivity; the Watch never reads Health, computes a plan or calls an LLM.
Feel ratings come back as queued messages that the phone validates before saving.

**Data sources.** Everything the app reads comes through the `HealthSource` protocol.
`CombinedSource` merges Apple Health with imported FIT workouts through `WorkoutReconciler`, so
the same session from two sources counts once, then joins back-to-back pieces of one outing (run/walk
intervals saved as separate workouts) through `WorkoutSegments`. Each workout records its origin, and HRV is labelled
with its method (Apple's SDNN isn't comparable with the RMSSD other devices report).

**Plan pipeline.**

```
AthleteProfile → PlanBlueprint → PlanEngine → Prescriber → PlanModel
 (your input)    (phases,         (commitments,  (targets,     (athlete edits, coach
                  backward from    blackouts,     fuelling)     changes, persistence)
                  race day)        rules)
```

**LLM access.** The `LLMClient` protocol has two operations, streaming chat and forced tool
calls. Anthropic is the primary provider; an OpenAI client and a hosted-server client share the
same interface. Each provider's API key is stored separately in the Keychain.

**The workout loop.** A finished workout reaches the app through a HealthKit observer.
`FeelPrompter` asks how it felt, either as a sheet when the app opens or as a local notification
that names the sport only. The answer goes to `ReviewModel`, which asks the coach for one note
(`WorkoutReviewer`, a forced tool call validated before it's saved). The note appears on the
workout in the plan. Every session also carries a purpose line from `SessionPurpose`, a pure
function rather than a model call, so it costs nothing.

```mermaid
flowchart LR
    H["Apple Health<br/>new workout"] --> F["FeelPrompter<br/>sheet on open · notification"]
    F --> A["Athlete answers<br/>how it felt"]
    A --> R["ReviewModel<br/>one request"]
    R --> W["WorkoutReviewer<br/>PromptSafety in · validated out"]
    W --> N["Coach's note<br/>in the plan"]
```

### How it's developed

Claude Code writes and commits. OpenAI Codex reviews each change independently. The owner
decides, tests on devices and approves anything irreversible. Tests and a pre-commit hook gate
every commit. [`docs/SDLC.md`](docs/SDLC.md) describes the process: roles, the path each change
takes, how output from AI tools is treated as untrusted, the mapping to NIST SSDF and its
generative-AI profile, and where the process is weak.

```mermaid
flowchart LR
    O["Owner<br/>requirements · decisions"] --> C["Claude Code<br/>implements · tests"]
    C --> T{"360 tests<br/>simulator check"}
    T --> X["Codex<br/>independent review<br/>diff only · read-only"]
    X --> C
    T --> G{"pre-commit hook<br/>injection SOP"}
    G --> M["commit<br/>one change, one reason"]
    M --> O
```

## Privacy and security

Health data is sensitive. These are design constraints, and the code is built to uphold them:

- **Read-only Health access.** The app requests no HealthKit write permissions, and a test fails
  if any are added.
- **Least-privilege Google access.** The only scope is `drive.file`, so the app can see only files
  it created.
- **Encrypted at rest.** Local caches, chats and your edits are written with
  `.completeFileProtection`, so they're unreadable while the phone is locked. API keys are stored
  in the Keychain. Nothing goes to iCloud.
- **Nothing sensitive in logs.** Logs record counts and status, never metric values.
- **Explicit sharing.** The coach receives a health summary only when "Share my Health summary" is
  on. The exact prompt can be viewed from the chat screen.
- **Untrusted input is sanitised.** Anything typed into a session is length-capped and stripped
  of control characters before it reaches the model prompt, the calendar or the Watch. FIT files
  are parsed defensively (size and message caps, bounds checks, CRC verification) and fuzz-tested.
  Reports from the Watch are validated before they're saved.
- **Minimal data from other devices.** FIT imports keep session totals only: routes, GPS positions
  and per-second records are never stored, nor is the file.
- **Nothing numeric on a locked screen.** Watch complications, the iPhone widget and Live
  Activities can all show while the device is locked, so they carry the session and a one-word
  recommendation, never a health number (tested).
- **Export and delete.** Everything the app stored can be exported as JSON or deleted from the
  phone and Watch in one step (Settings → Your data). See the draft
  [privacy policy](docs/coach-bridge-privacy-policy.md).
- **No third-party analytics.** The only services contacted are Google Drive, your LLM provider
  and the weather service.

Strava is deliberately not integrated: its API terms prohibit using API data with AI models.

## Security engineering

Coach Bridge is also a worked example of a secure development lifecycle for an app that handles
health data and calls an LLM. The full design, with information-flow maps, trust boundaries, a
STRIDE threat model, an OWASP Top 10 for LLM Applications mapping and NIST SSDF practices, is in
[`docs/SECURITY.md`](docs/SECURITY.md).

```mermaid
flowchart LR
    U["Untrusted text<br/>typed fields · calendar invites<br/>the model's own stored replies"] --> P["PromptSafety<br/>clean · fence · cap"]
    P --> L(("LLM"))
    L --> V["Validate output<br/>schema · window · limits · clean"]
    V --> G{"Chat change?"}
    G -- yes --> A["Athlete taps Apply"]
    G -- "weekly update" --> R["Applied, rate-limited"]
```

Highlights:

- **AI security.** Every text field is tested against 14 injection payloads, including forged
  tags, fake conversation turns, bidi and zero-width hiding, Unicode tag smuggling, CR/LF and a
  100k flood, in every prompt it can reach. A pre-commit hook blocks any commit that changes a
  text field without passing the suite. Model output is treated as untrusted and validated
  before it's shown, stored or re-used.
- **Hostile-input parsing.** The FIT reader is fuzzed with 5,000 corrupted files and truncated at
  every byte.
- **Least privilege and minimisation.** Read-only Health, Drive access limited to the app's own
  files, location rounded to about 1 km, nothing numeric on a locked screen, routes never stored.
- **Verifiable.** Each claim in the security document names the test that proves it, and every
  fix is its own commit with the reason in the message.
- **Two-model review.** Every non-trivial change is reviewed by a second model from a different
  family, sandboxed and given only the diff. See [`docs/SDLC.md`](docs/SDLC.md).

## Getting started

### Requirements

- macOS with Xcode 26 or newer (the app uses the iOS 26 SDK and runs on iOS 18+)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- An Apple Developer Program membership for builds that last longer than 7 days and for
  background delivery. A free Personal Team works for short-term testing.
- Optional: a Google Cloud project for Drive export, and an Anthropic or OpenAI API key for the
  coach

### Build and run

```bash
git clone https://github.com/BnguyenInfoSec/CoachBridge.git
cd CoachBridge
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig   # then fill it in (below)
xcodegen generate
open CoachBridge.xcodeproj
```

`CoachBridge.xcodeproj` is generated from `project.yml` and is not checked in. Re-run
`xcodegen generate` after adding or removing files.

### Configuration

`Config/Secrets.xcconfig` is git-ignored and holds per-developer values:

| Key | Purpose |
|---|---|
| `DEVELOPMENT_TEAM` | Your Apple team ID. Keep it here rather than in Xcode's signing UI, which `xcodegen generate` resets. |
| `BUNDLE_ID_PREFIX` | Reverse-DNS prefix for the bundle ID. Choose it before creating the Google OAuth client. |
| `GOOGLE_CLIENT_ID` | iOS OAuth client ID from Google Cloud. |
| `GOOGLE_REVERSED_CLIENT_ID` | The same ID in reversed URL-scheme form. |

> **Keep the team ID stable.** Keychain items are tied to the signing team. If a build is signed
> by a different team, iOS treats it as a different app and the stored API key is lost. Deleting
> the app from the phone clears the Keychain as well.

The app builds and runs with placeholder Google values; only Drive sign-in is unavailable.

The Watch app, its complications, the iPhone app and its widget share an App Group,
`group.<BUNDLE_ID_PREFIX>.CoachBridge`. With automatic signing, Xcode registers it on the first
signed build to a device. Apple Weather also needs WeatherKit turned on for the App ID under both
Capabilities and App Services in the Apple Developer portal.

### Google Drive export (optional)

1. In the [Google Cloud console](https://console.cloud.google.com), create a project and enable the
   **Google Drive API**.
2. Under **Google Auth Platform**, set the app name and contact email. Set the audience to
   **External** and publish the app. In *Testing* status, Google expires refresh tokens after
   7 days, which stops the daily export.
3. Add exactly one scope: `https://www.googleapis.com/auth/drive.file`. It is non-sensitive, so no
   Google verification is needed. Users see an "unverified app" notice once.
4. Create an **iOS** OAuth client with bundle ID `<BUNDLE_ID_PREFIX>.CoachBridge`. iOS clients have
   no client secret.
5. Copy the client ID and reversed client ID into `Secrets.xcconfig`, then regenerate the project.

### LLM coach (optional)

Create an API key with [Anthropic](https://console.anthropic.com) or
[OpenAI](https://platform.openai.com), paste it in **Settings → Model provider**, and set a monthly
spend limit in that provider's console. An LLM subscription such as Claude Pro does not include
API access. Never build an API key into the app: anyone with the binary can extract it.

## Development

### Build and test

```bash
xcodegen generate
xcodebuild -scheme CoachBridge -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme CoachBridge -destination 'platform=iOS Simulator,name=iPhone 17' test
```

The suite has 360 tests and runs in about four seconds. It covers the data contract, the plan engine
(swept across every runway from 4 to 208 weeks), scheduling, input sanitisation, phase display,
demo-mode isolation using a fake `HealthSource`, the FIT parser (including fuzzing and truncation),
source merging, training load, the Watch snapshot and its validation, and data export. Any installed iPhone simulator works.

### Running in the simulator without Health data

Launch arguments override stored defaults without saving them:

```bash
xcrun simctl launch <simulator-udid> <bundle-id> -demo.enabled YES -onboarding.completedVersion 3
```

### Text fields and injection testing

Every text input is listed in `tools/text-fields.txt`. Adding or changing one means routing it
through `PromptSafety` and adding it to `InjectionTests`; a pre-commit hook enforces this. Enable it
once per clone:

```bash
git config core.hooksPath tools/githooks
```

### Conventions

- Keep logic in `Model/` as pure functions with an injected `Calendar`, so it can be tested
  without a device.
- Comments explain *why*: the bug that prompted the code, or the trade-off taken.
- Every iOS 26 API lives in `App/Theme.swift` behind an availability check, with a fallback for
  iOS 18.
- One fix per commit, with a message that explains the reason.

## Project status

Personal project in active development, currently **v2.14.0**. Distributed by direct Xcode install,
with TestFlight planned.

Verified on device: HealthKit reads, Drive export, background delivery, the dashboard, chat, the
plan calendar, calendar sync, weather, and the Today widget on the Lock Screen.

Not yet verified:

- The Watch app in use on a real Apple Watch (it installs on one): answering "How did it feel?" on
  the Watch, complications on a face, and fuel reminders during a Workout app session. The
  phone-to-Watch snapshot is verified in paired simulators.
- A FIT file from a real device (the parser is tested against generated files)
- Apple Weather on a signed build: it needs WeatherKit enabled for the App ID in the developer portal
- The Today widget on a real Home Screen (it's offered in the simulator's widget gallery), and Live
  Activities on a real Dynamic Island (verified on the simulator's Lock Screen)
- Workout reminder notifications on a real iPhone, which depend on HealthKit delivering new
  workouts in the background; the sheet that asks on opening the app is verified in the simulator
- Apple Calendar phase banners and WorkoutKit sync since the v2.0 plan rewrite
- The OpenAI provider; the hosted-server client is a stub
- Coaching quality: the plan engine is tested for structure, not for whether its weeks are good
  training, and the workout-review prompt hasn't yet been run against a live model
- The privacy policy is a draft and needs review before external TestFlight testing

App Store guideline 5.1.3 restricts sharing HealthKit data with third parties. A public release
would need explicit consent flows for the LLM and Drive features.

## Documentation

| Document | Contents |
|---|---|
| [`CHANGELOG.md`](CHANGELOG.md) | Development history: what changed in each version, and why |
| [`docs/data-contract.md`](docs/data-contract.md) | The daily JSON export format (fixed; external consumers depend on it) |
| [`docs/SECURITY.md`](docs/SECURITY.md) | Security design: information flow, threat model, OWASP LLM Top 10, NIST SSDF |
| [`docs/SDLC.md`](docs/SDLC.md) | How the app is built: AI implementer, independent AI reviewer, human owner, and the gates between them |
| [`docs/coach-bridge-privacy-policy.md`](docs/coach-bridge-privacy-policy.md) | Draft privacy policy, written from what the app actually does |
| [`AGENT-HANDOFF.md`](AGENT-HANDOFF.md) | In-depth architecture, invariants and project context for contributors |
| [`CLAUDE.md`](CLAUDE.md) | Condensed working rules for AI coding agents |
| [`AGENTS.md`](AGENTS.md) | The reviewer's role and limits, read by Codex |
| [`docs/review-log.md`](docs/review-log.md) | Every independent Codex review: what, when, and the result |
