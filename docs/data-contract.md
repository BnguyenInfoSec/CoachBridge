# The data contract — fixed, do not change

The app writes one JSON file per day to Google Drive at `/Coach/health/YYYY-MM-DD.json`. A separate
claude.ai artifact (the "Road to Sacramento" coach page) reads these files and merges them into its
own log. **The field names and units are a contract with something outside this repo.** Renaming a
key or changing a unit silently breaks the page.

`Model/DayRecord.swift` and `Health/DayRecordBuilder.swift` implement this.
`CoachBridgeTests/ContractTests.swift` guards it.

## Shape

```json
{
  "schema": 1,
  "source": "coach-bridge",
  "date": "2026-09-22",
  "exportedAt": "2026-09-22T07:41:10-07:00",
  "metrics": {
    "rhr": 46, "hrv": 58, "sleep": 7.4, "resp": 14.2, "wristTemp": 0.2, "spo2": 97,
    "vo2": 44.1, "cardioRecovery": 28, "walkHR": 92,
    "weight": 172.5, "bodyFat": 15.8,
    "activeCal": 640, "exerciseMin": 52, "steps": 9120,
    "runPower": 245, "gct": 262, "vosc": 8.9, "stride": 1.05
  }
}
```

## Rules

- **Omit any metric with no data. Never write `0` for missing.** The page and the LLM treat an
  absent key as "not logged"; a `0` reads as a real measurement of zero.
- Never emit `-0`.
- JSON is hand-serialised for fixed key order and per-key decimal places (0, 1 or 2 dp as shown
  above). Don't swap in `JSONEncoder` — the page's diffing depends on stable output.
- `date` is the **local calendar day the check-in belongs to** (the morning), not the export time.
- Re-exporting a day overwrites that day's file. The export is idempotent.
- Days with no metrics at all are skipped, not written as empty files.

## How each metric is computed

The "sleep window" below means 6 pm the previous day to noon on `date`.

| Key | HealthKit type | Unit | How to compute |
|---|---|---|---|
| `rhr` | `restingHeartRate` | bpm | Most recent sample dated that day |
| `hrv` | `heartRateVariabilitySDNN` | ms | Mean of samples in the sleep window |
| `sleep` | `sleepAnalysis` (category) | hours, 1 dp | Sum of asleepCore + asleepDeep + asleepREM + asleepUnspecified over the sleep window. Exclude inBed and awake. Prefer Apple Watch samples when sources overlap |
| `resp` | `respiratoryRate` | breaths/min | Mean over the sleep window |
| `wristTemp` | `appleSleepingWristTemperature` | °F **change from baseline** | HealthKit gives an absolute °C value. Convert to °F, then subtract the 28-day rolling median. Omit until 7 nights of history exist |
| `spo2` | `oxygenSaturation` | % | Mean over the sleep window, ×100 |
| `vo2` | `vo2Max` | ml/kg/min | Latest in the last 7 days |
| `cardioRecovery` | `heartRateRecoveryOneMinute` | bpm | Latest in the last 7 days |
| `walkHR` | `walkingHeartRateAverage` | bpm | Latest for the previous day |
| `weight` | `bodyMass` | lb, 1 dp | Latest in the last 7 days |
| `bodyFat` | `bodyFatPercentage` | %, 1 dp | Latest in the last 7 days, ×100 |
| `activeCal` | `activeEnergyBurned` | kcal | Cumulative sum for the **previous** calendar day (`HKStatisticsQuery`, which dedupes sources) |
| `exerciseMin` | `appleExerciseTime` | min | Cumulative sum, previous day |
| `steps` | `stepCount` | count | Cumulative sum, previous day |
| `runPower` | `runningPower` | W | Mean over the most recent run, if within the last 2 days |
| `gct` | `runningGroundContactTime` | ms | Same window as `runPower` |
| `vosc` | `runningVerticalOscillation` | cm | Same |
| `stride` | `runningStrideLength` | m, 2 dp | Same |

## Not the bridge's job

"How you feel", "drinks last night" and free-text notes stay manual on the coach page. The page's
import must never overwrite `feel`, `drinks` or `note`, and the app must never write them.

## Known data hazards

- **Sleep is the usual source of bugs.** Overlapping Watch and iPhone sources, and `inBed` samples
  being counted as asleep. Verify against the Health app by hand on a real device.
- Brandon does **not** wear the Watch to sleep, so `sleep`, `resp`, `spo2` and `wristTemp` are
  normally absent and `hrv` comes from sparse evening and morning samples. Absent values here are
  correct behaviour, not a failure. The sleep maths remains unverified against real Watch sleep data.
- A workout that never ended once produced a ~900-hour session and broke the weekly-hours chart.
  `Stats.maxSessionHours = 18` and `isPlausibleSession` filter these, and the UI reports how many
  were ignored. **Don't remove that filter.**

## Why `drive.file`

The Google scope is `drive.file` only, so the app can only see files it created — which means it
creates and uses its own `Coach/health` folders and cannot see folders it didn't create. The coach
page imports from any folder Brandon owns named `health` or `Coach Bridge`. This was built in M2 and
verified on device on 21 Sept 2026.
