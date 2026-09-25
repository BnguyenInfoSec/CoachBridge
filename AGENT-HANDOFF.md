# Coach Bridge — agent handoff

You are taking over a native iOS app called **Coach Bridge**. This document is everything you need
to build it, run it, and keep developing it. Read it fully before touching anything.

The owner is Brandon: a cybersecurity professional and Ironman triathlete, not a full-time iOS
developer. He builds and runs the app in Xcode on an M2 MacBook Pro and installs to his own iPhone
and Apple Watch Ultra. He is training for IRONMAN California (Sacramento), ~17 Oct 2027.

---

## 0. The single most important fact

**No version of this app has ever been compiled by the agent that wrote it.** Every release so far
was written in a Linux sandbox with no Swift toolchain, shipped as a zip, and compiled by Brandon,
who relayed build errors back by screenshot. That loop is slow and it is why you are here.

**Your first job is to compile it and fix whatever breaks — before you write a single new feature.**

```bash
cd ~/Documents/Dev/CoachBridge
xcodegen generate
xcodebuild -scheme CoachBridge -destination 'generic/platform=iOS' build 2>&1 | tail -40
xcodebuild -scheme CoachBridge -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test 2>&1 | tail -40
```

Expect real errors on the first run, concentrated in the most recently added code (v2.6 and v2.7,
see §6). The test suite (`⌘U`) has not been run since v2.0 and several tests were rewritten around
a model refactor since then. Assume it is red until you have seen it green.

Do not report "done" on anything until `xcodebuild build` and `xcodebuild test` both pass.

---

## 1. What the app is

A training companion that does four things:

1. **Bridge.** Reads Apple Health on the iPhone and writes one JSON file per day to Google Drive, so
   a separate claude.ai coach page can read it. This was the original purpose and its data contract
   is fixed (§7).
2. **Dashboard.** Native charts of resting HR, HRV, weekly training hours by sport, recent workouts,
   and a transparent recovery signal.
3. **Plan.** Generates a full periodised training plan from a profile the athlete fills in, shows it
   as a month/week/day calendar, syncs sessions to Apple Calendar and to the Watch via WorkoutKit,
   and asks an LLM to adjust the coming week against real data.
4. **Coach.** An in-app chat with an LLM that can see the athlete's data and propose plan changes,
   plus a written note reacting to each completed workout.

Current version **2.7.0**. Distribution is personal: Xcode install, TestFlight later. Not on the App
Store and not currently intended for it (see §8).

---

## 2. Getting it building

### Prerequisites
- Xcode 26 or newer (the app builds against the iOS 26 SDK; see §5 on Liquid Glass).
- `brew install xcodegen`
- An Apple Developer Program membership ($99/yr) — Brandon has one. A free Personal Team also works
  but builds expire after 7 days, which breaks background export.

### Project generation
`CoachBridge.xcodeproj` is a **build product**. It is not in the repo and must never be hand-edited.
`project.yml` is the source of truth. Sources are folder-globbed, so new `.swift` files are picked
up automatically — but you must re-run `xcodegen generate` after adding any file.

### Configuration
`Config/Base.xcconfig` holds defaults and ends with `#include? "Secrets.xcconfig"`.
`Config/Secrets.xcconfig` is git-ignored, excluded from every zip, and holds:

```
BUNDLE_ID_PREFIX = com.brandonnguyen
DEVELOPMENT_TEAM = <his team ID>
GOOGLE_CLIENT_ID = <from Google Cloud>
GOOGLE_REVERSED_CLIENT_ID = <from Google Cloud>
```

If `Secrets.xcconfig` is missing, create it from `Config/Secrets.example.xcconfig`. The app builds
with placeholder Google values; only Drive sign-in fails.

### Gotchas that have already cost real time

| Symptom | Cause | Fix |
|---|---|---|
| "Signing requires a development team" after regenerating | `xcodegen generate` wipes `DEVELOPMENT_TEAM` | Put `DEVELOPMENT_TEAM` in `Secrets.xcconfig`, not the Xcode UI |
| **App loses its API key after a rebuild** | Keychain items are scoped to bundle ID + signing team. A re-sign with a different team makes iOS treat it as a different app | Same fix — pin `DEVELOPMENT_TEAM`. Also: deleting the app from the phone wipes the key; replacing the build via Run does not |
| Update zip doesn't apply | `ditto ~/Downloads/x.zip ./` does **not** extract | `ditto -x -k ~/Downloads/x.zip ./` |
| Stale files overwrite new ones | Old single `.swift` files left in `~/Downloads` and copied over v2 files | Prefer full-zip updates; `rm` loose files after use |
| "No such module 'UIKit'" | A `.swift` file opened in a standalone editor window targeting My Mac | Not a project error; open the workspace |
| WeatherKit signing failure | The `com.apple.developer.weatherkit` entitlement on a free team breaks signing | Only add it on the paid team, with WeatherKit enabled for the App ID |

### Target facts
iOS **18.0** minimum (raised from 17 for `onScrollGeometryChange`). iPhone only. Swift 5 language
mode, `SWIFT_STRICT_CONCURRENCY: targeted` — deliberately not `complete`, because Google and
HealthKit types aren't `Sendable` and the noise drowns real warnings. One SPM dependency:
GoogleSignIn-iOS 8. No analytics, no crash reporters.

---

## 3. Architecture

```
CoachBridge/
  Model/    pure value types and logic — no UI, no I/O, no Date.now. All unit-tested.
  Health/   HealthKit readers, plus DemoData
  Drive/    Google auth, Drive REST client, the exporter
  Coach/    LLM clients, prompt building, the ObservableObject models
  App/      SwiftUI views, theme, palette
```

The layering rule is strict and worth preserving: **anything that can be a pure function in `Model/`
is one.** Date arithmetic takes an injected `Calendar`; nothing in `Model/` reads `Date.now`. That
is what makes the plan engine, the scheduler and the comparison logic testable without a device.

### Services
`AppServices.shared` (`@MainActor` singleton) owns one instance of each model and is injected into
the environment at `CoachBridgeApp`. It exists because background launches (observer queries,
`BGAppRefreshTask`) start the app with no UI and still need the same objects.

Members: `health`, `google`, `exporter`, `dashboard`, `chat`, `plan`, `calendar`, `weather`,
`watch`, `venues`, `review`.

Two methods worth knowing:
- `syncSchedule()` — calendar sync, then Watch sync. Call after anything that changes the plan.
- `demoModeChanged()` — the single place that handles the demo toggle (§4).

### The plan pipeline
```
AthleteProfile          what the athlete told us (event, hours, days, equipment, goal, blocks)
   → PlanBlueprint      phases counted BACKWARD from race day, volume ramped, WeekBuilder per week
   → PlanEngine         reads the blueprint; applies commitments, blackouts, events, PlanRules
   → Prescriber         fills in duration, HR/power targets, pace, fuelling
   → PlanModel          merges athlete-added sessions and the LLM's changes; owns persistence
```

`PlanEngine` is rebuilt on **every access** of `PlanModel.engine` — it is a computed property. This
is cheap but not free; if you call it in a SwiftUI `body`, hoist it into a local. This has already
caused one performance bug.

### LLM access
`LLMClient` protocol with two methods: `stream(...)` for chat, `runTool(...)` for forced tool calls.
Three implementations: `AnthropicClient` (complete), `OpenAIClient` (written, never exercised),
`HostedClient` (a stub for a future shared server). `LLMFactory.current(maxTokens:)` picks by the
stored provider and reads the key from the Keychain. Each provider has its own Keychain account.

Three LLM features, all forced tool calls with validated parsing:
- `PlanAdjuster` (`update_week`) — adjusts the coming 7 days. Rate-limited to one request/minute,
  persisted so failures still count.
- `PlanProposal` / `PlanChangeTool` (`change_plan`) — lets the chat change the plan. **Nothing is
  applied until the athlete taps Apply.**
- `WorkoutReviewer` (`review_workout`) — the coach's note on a finished session.

---

## 4. Invariants — do not break these

These are decisions with reasons behind them. If you think one should change, raise it rather than
quietly changing it.

**Cost.** The athlete pays per API call and has complained about waste twice.
- A workout's coach note is generated **once and cached**. Opening a screen never generates one.
- The plan adjustment is rate-limited to one request per minute, and the counter is written
  *before* the call so failures can't be retried faster.
- The plan header's pull gesture has two detents; only the **second** refreshes.

**Privacy.** Brandon is an Information Security Officer. Hold the bar.
- HealthKit is **read-only**. Google scope is **`drive.file` only**.
- Never log metric values — log counts and status only.
- Local caches use `.completeFileProtection`.
- Venue photos never leave the phone: not to Drive, not to the LLM.
- No health data in iCloud.

**Demo mode** (`DemoData.isOn`) fills the app with generated data so it can be shown to someone with
no Apple Watch. It must never leak in either direction:
- Nothing generated is ever exported to Drive.
- The LLM is told the numbers are a demo.
- Switching modes goes through `AppServices.demoModeChanged()`, which drops the dashboard data,
  clears cached workouts, forgets the last system prompt and reloads. `DashboardModel` stamps its
  data with the mode it was loaded under and refuses data from the other mode; a generation token
  discards an in-flight read that lands after a switch. **This was a real bug** — real Health
  numbers stayed on screen after enabling demo mode. Don't reintroduce it.

**The athlete's own input is never overwritten.** Sessions with `addedByAthlete` are fixed; the LLM
is told to plan around them and `RuleEngine` never touches them.

**Liquid Glass is isolated.** Every iOS 26 API (`glassEffect`, `.buttonStyle(.glass)`,
`.tabBarMinimizeBehavior`, `.scrollEdgeEffectStyle`) lives in `App/Theme.swift` behind
`if #available(iOS 26.0, *)` with an `.ultraThinMaterial` fallback. Keep it that way — one file to
fix when a symbol is wrong.

---

## 5. Conventions

- **Comments explain why, not what.** The codebase is written to be read by someone returning in six
  months. Match that: note the reasoning, the bug that prompted the code, the trade-off taken.
- **User-facing copy is plain and specific.** Section footers explain what a setting actually does
  and what the consequence is. No marketing voice, no exclamation marks.
- Swift string escapes: `\u{2014}`, not `—`. This has broken a build before.
- Swift has **no key path to a tuple element** — `ForEach(pairs, id: \.0)` does not compile. Map to
  a small `Identifiable` struct.
- Persisted stores follow one pattern: an `ObservableObject` writing JSON to Application Support
  with `.completeFileProtection`, ISO-8601 dates, and a `prune(before:)`. See `CustomSessionStore`,
  `RuleStore`, `WorkoutJournal`.
- **Verify logic you can't run.** Where the sandbox couldn't compile Swift, non-trivial algorithms
  were re-implemented in Python and swept over their whole input range before shipping (the training
  block fitter was checked across every runway from 4 to 208 weeks plus 60,000 random override sets;
  the planned-vs-actual comparison across 8 cases). You can compile and run tests, so prefer that —
  but keep the habit of proving an invariant rather than eyeballing it.

---

## 6. State of the code

### Working and verified on device
M0–M3 (HealthKit read, Drive export, background automation) were verified on Brandon's iPhone.
Dashboard, chat, plan calendar, calendar sync and weather have all run on device.

### Written but never exercised
- The **OpenAI provider** has never been run.
- `HostedClient` is a stub.
- **Watch (WorkoutKit) and calendar sync are untested since the v2.0 plan rewrite.**
- **No human has read a generated training week and judged whether it's sensible.** The plan engine
  is tested for structure (phases contiguous, blocks sum to the runway) but not for coaching quality.
- **No one has seen a real coach's note.** The `review_workout` prompt has never hit a live model,
  and the quality of that note is the entire feature. Generate a few early and tune the prompt.

### Known open items
- **Privacy policy** — required before TestFlight external testing.
- `⌘U` not run since v2.0.
- Venue seed data is San Diego-only for a new user.
- Legacy `PlanSettings` fields (`classDays`, `classUntil`, `snowSaturdays`, `hasTrainer`) exist only
  for migration and should be deleted once every install has migrated.
- Migration gap: `PlanSettings.save()` only ever fired on change, so Brandon's own install gets an
  empty profile and has to re-enter it once.
- The workout feel sheet auto-opens for anything finished within 48 hours. That window is a guess.
- Two improvements offered and not yet built: a "Test key" button that verifies an API key before
  saving, and an honest empty state that says *which provider* has no key on *this iPhone* (a
  missing key currently looks identical to a fresh install).

---

## 7. The data contract — fixed, do not change

One file per day at `/Coach/health/YYYY-MM-DD.json` in Drive. A separate claude.ai coach page reads
these, so the field names and units are a contract with something outside this repo.

```json
{
  "schema": 1,
  "source": "coach-bridge",
  "date": "2026-09-22",
  "exportedAt": "2026-09-22T07:41:10-07:00",
  "metrics": { "rhr": 46, "hrv": 58, "sleep": 7.4, "...": 0 }
}
```

Keys: `rhr hrv sleep resp wristTemp spo2 vo2 cardioRecovery walkHR weight bodyFat activeCal
exerciseMin steps runPower gct vosc stride`.

Rules: **omit any metric with no data — never write `0` for missing.** Never write `-0`. JSON is
hand-serialised for fixed key order and per-key decimal places. `date` is the local calendar day the
check-in belongs to. The full per-metric computation table is in the project doc
`claude/coach-bridge-handoff.md`; `Model/DayRecord.swift` and `Health/DayRecordBuilder.swift`
implement it and `CoachBridgeTests/ContractTests.swift` guards it.

A real data hazard to know about: a workout that never ended produced a ~900-hour session and broke
the weekly-hours chart. `Stats.maxSessionHours = 18` and `isPlausibleSession` now filter these, and
the UI says how many were ignored. Don't remove that filter.

---

## 8. Constraints from outside the code

- **Strava is deliberately not integrated.** Its API terms bar using API data with AI models, bar
  showing it to anyone but that user, and require a paid developer subscription. Brandon uses the
  claude.ai Strava connector separately instead. Do not add Strava to the app.
- **App Store guideline 5.1.3** bars sharing HealthKit data with third parties. Sending it to an LLM
  provider or a cloud drive would need a redesign and explicit consent flows before any submission.
- **HealthKit cannot be read while the phone is locked.** Exports happen after the first unlock of
  the morning, not at a fixed time. Design for it; don't fight it.
- An **LLM subscription is not API access.** Any beta tester needs their own API key or a hosted
  server. This surprised Brandon once; don't let it surprise a tester.

---

## 9. Where the written history lives

The claude.ai project "Fitness Coach" holds the durable record. Read these before making
architectural decisions:

| Doc | Contents |
|---|---|
| `claude/coach-bridge-progress.md` | Milestone-by-milestone history, M0 through v2.6, with the reasoning behind each decision |
| `claude/coach-bridge-handoff.md` | The original brief and the full data-contract table |
| `claude/coach-bridge-ui-notes.md` | Artwork generation, light/dark, Liquid Glass, the charts |
| `claude/coach-bridge-feedback-loop.md` | The v2.7 feel prompt and coach's note subsystem |
| `claude/coach-bridge-beta-plan.md` | What a small beta would require |

`README.md` in the repo is a running changelog written for Brandon, newest section last. Keep
appending to it — a section per version, explaining what changed and why, in the same voice.

When you finish a meaningful piece of work, update `claude/coach-bridge-progress.md`. That file is
how the next agent learns what you did.

---

## 10. How to work with Brandon

- He reads the reasoning, not just the result. Explain what you changed and why; flag trade-offs.
- He will ask for several things in one message, sometimes adding another mid-task. Take them all.
- He is technically strong but not an iOS specialist — be precise about Xcode and signing steps,
  and give exact commands rather than describing them.
- When he reports a bug, check whether it's a real defect before explaining it away. The "training
  hours chart looks broken" report turned out to be genuine data corruption, and "demo mode doesn't
  update" turned out to be three separate caching bugs.
- Tell him plainly when something is untested or when you got something wrong.
