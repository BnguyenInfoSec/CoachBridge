# CLAUDE.md — Coach Bridge

Native iPhone app (SwiftUI, iOS 18+, iPhone only). Reads Apple Health, exports a daily JSON to
Google Drive, generates and adjusts a periodised triathlon training plan, and runs an LLM coach.
Owner: Brandon — Ironman triathlete and an Information Security Officer by trade, so the privacy
bar in §4 is not decoration.

**`AGENT-HANDOFF.md` in this repo is the long version.** Read it before any architectural decision.
`docs/data-contract.md` is the fixed JSON contract with an external consumer.

---

## 1. Build and test

```bash
xcodegen generate                       # after adding ANY file — sources are folder-globbed
xcodebuild -scheme CoachBridge -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme CoachBridge -destination 'platform=iOS Simulator,name=iPhone 17' test
```

To look at the app in the simulator without Health data or onboarding, pass defaults as launch
arguments (they override stored values and aren't saved):
`xcrun simctl launch <udid> <bundle-id> -demo.enabled YES -onboarding.completedVersion 3`.
Use the simulator's UDID, not `booted`, when more than one is running.

Xcode 27 ships no iPhone 16 Pro simulator; use any installed iPhone
(`xcrun simctl list devices available`). `CODE_SIGNING_ALLOWED=NO` makes the device build a pure
compile check, so it doesn't depend on the team in `Secrets.xcconfig`.

`CoachBridge.xcodeproj` is a **build product**. Never hand-edit it; edit `project.yml` and
regenerate. It's git-ignored.

Everything through v2.7.0 was written without a Swift toolchain. v2.7.1 (2026-09-25) is the first
version compiled and tested by an agent: the app built clean, the tests needed fixing, and two of the
failing tests were real plan-engine bugs (CHANGELOG, v2.7.1). Build and all 164 tests were green then.
Commit `90d2b22` is v2.7.0 exactly as delivered, for comparison.

Keep it green. Don't claim a task is done until `build` and `test` both pass, and commit one fix
per commit with the reason in the message.

## 2. Signing — the recurring trap

`xcodegen generate` **wipes `DEVELOPMENT_TEAM`**. When Xcode then re-signs with a different or empty
team, the Keychain access group changes and iOS can treat it as a different app — which silently
destroys the stored LLM API key. This has bitten Brandon twice.

`DEVELOPMENT_TEAM` belongs in `Config/Secrets.xcconfig` (git-ignored, survives regeneration), never
in the Xcode UI. `Config/Base.xcconfig` ends with `#include? "Secrets.xcconfig"`; copy
`Config/Secrets.example.xcconfig` if it's missing. It holds `BUNDLE_ID_PREFIX`, `DEVELOPMENT_TEAM`,
`GOOGLE_CLIENT_ID`, `GOOGLE_REVERSED_CLIENT_ID`.

Deleting the app from the phone also wipes the Keychain. Replacing the build via Run does not.

Do not add the WeatherKit entitlement on a free team — it breaks signing.

## 3. Architecture

```
Model/    pure value types and logic — no UI, no I/O, no Date.now. All unit-tested.
Health/   HealthSource protocol, HealthKit readers behind it, DemoData
Drive/    Google auth, Drive REST, exporter
Coach/    LLM clients, prompt building, ObservableObject models
App/      SwiftUI views, theme, palette
```

**Data comes in through `HealthSource`** (`AppServices.source`). Nothing outside `Health/` holds an
`HKHealthStore` or builds a reader; a new source (FIT import, another device) is a new conformance.
Tests use a fake source — see `HealthSourceTests`.

**Anything that can be a pure function in `Model/` is one.** Date arithmetic takes an injected
`Calendar`; nothing in `Model/` reads `Date.now`. That is what makes the plan engine testable.

`AppServices.shared` (`@MainActor` singleton) owns one instance of each model, injected into the
environment at `CoachBridgeApp`. It exists because background launches start the app with no UI.
`syncSchedule()` = calendar then Watch. `demoModeChanged()` = the only correct way to flip demo mode.

Plan pipeline:
`AthleteProfile` → `PlanBlueprint` (phases counted backward from race day) → `PlanEngine` (applies
commitments, blackouts, `PlanRules`) → `Prescriber` (targets and fuelling) → `PlanModel`.

`PlanModel.engine` is **cached**, keyed on profile, settings, rules, calendar and today; built weeks
and milestones are memoised with it. It used to rebuild on every access and made the month grid take
260 ms a redraw. Still hoist it into a local in a `body`. `DayRecord.dateKey` is hot too — never put
a `DateFormatter()` in anything called per day.

LLM access goes through the `LLMClient` protocol (`stream`, `runTool`). Three forced-tool features:
`PlanAdjuster` (`update_week`), `PlanChangeTool` (`change_plan`), `WorkoutReviewer`
(`review_workout`). All validate and clip their responses rather than trusting them.

## 4. Invariants — raise it rather than quietly changing it

**Cost.** Brandon pays per API call and has complained about waste twice.
- A workout's coach note is generated once and cached. Opening a screen never generates one.
- Plan adjustment is rate-limited to one request/minute; the counter is written *before* the call so
  failures can't be retried faster.
- The plan header's pull gesture has two detents; only the second refreshes.

**Privacy.**
- HealthKit is read-only. Google scope is `drive.file` only.
- Never log metric values — counts and status only.
- Local caches use `.completeFileProtection`.
- Venue photos never leave the phone: not to Drive, not to the LLM.
- No health data in iCloud.

**Demo mode** (`DemoData.isOn`) must not leak either way: nothing generated reaches Drive, the LLM is
told the numbers are fake, and switching goes through `AppServices.demoModeChanged()`.
`DashboardModel` stamps data with the mode it loaded under and refuses the other mode's; a generation
token discards in-flight reads that land after a switch. Real Health numbers staying on screen after
enabling demo mode was a real shipped bug — don't reintroduce it.

**The athlete's own input is never overwritten.** Sessions with `addedByAthlete` are fixed; the LLM
is told to plan around them and `RuleEngine` never touches them.

**Liquid Glass is isolated.** Every iOS 26 API lives in `App/Theme.swift` behind
`if #available(iOS 26.0, *)` with an `.ultraThinMaterial` fallback. One file to fix.

## 5. Conventions

- Comments explain **why**, not what — the bug that prompted the code, the trade-off taken.
- User-facing copy is plain and specific. Section footers say what a setting does and what the
  consequence is. No marketing voice.
- Swift string escapes are `\u{2014}`, not `—`. This has broken a build.
- Swift has no key path to a tuple element — `ForEach(pairs, id: \.0)` doesn't compile. Map to a
  small `Identifiable` struct.
- Persisted stores follow one pattern: `ObservableObject` → JSON in Application Support,
  `.completeFileProtection`, ISO-8601 dates, a `prune(before:)`. See `CustomSessionStore`,
  `RuleStore`, `WorkoutJournal`.
- `SWIFT_STRICT_CONCURRENCY: targeted`, deliberately not `complete` — Google and HealthKit types
  aren't `Sendable` and the noise drowns real warnings.
- Prove invariants rather than eyeballing them. You can run tests; use them.

## 6. Untested surface

- OpenAI provider never run. `HostedClient` is a stub.
- Watch (WorkoutKit) and calendar sync untested since the v2.0 plan rewrite.
- **No human has read a generated training week and judged whether it's sensible.** Tested for
  structure, not coaching quality.
- **No one has seen a real coach's note.** The `review_workout` prompt has never hit a live model,
  and the note's quality is the whole feature.
- Privacy policy still needed before TestFlight external testing.
- `AthleteProfile.startDate` falls back to `Date()` when `startDateISO` is empty: the one place
  `Model/` reads the clock. Known, not yet fixed.

## 7. External constraints

- **Strava is deliberately not integrated.** Its API terms bar AI use of API data and require a paid
  developer subscription. Brandon uses the claude.ai Strava connector separately. Don't add it.
- App Store guideline 5.1.3 bars sharing HealthKit data with third parties — a submission would need
  a redesign and explicit consent flows.
- **HealthKit can't be read while the phone is locked.** Exports happen after the first unlock, not
  at a fixed time. Design for it.
- An LLM subscription is not API access. A beta tester needs their own key or a hosted server.
- Some checks need the real iPhone: background delivery, real Health data, Watch scheduling. The
  simulator covers everything else.

## 8. Keeping the record

`CHANGELOG.md` is the running changelog for Brandon, newest section last — a section per version
saying what changed and why, in the same voice. Keep appending there.

`README.md` is the project's public face: what it is, architecture, privacy, setup, testing,
status. Keep it current (version, test count, verified/unverified list) but never append history
to it.

Longer history lives in the "Fitness Coach" project on claude.ai and is not readable from here:
`coach-bridge-progress.md` (milestone history and the reasoning behind each decision),
`coach-bridge-ui-notes.md` (artwork, light/dark, Liquid Glass, charts),
`coach-bridge-feedback-loop.md` (the v2.7 feel prompt and coach's note),
`coach-bridge-beta-plan.md`. Ask Brandon to paste one in if you need it.
