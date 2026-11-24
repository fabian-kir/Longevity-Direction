# Longevity Direction

An iPhone and Apple Watch app for training, nutrition and health data: a gym log with
progression targets, a guided Norwegian 4×4 interval workout, photo and barcode nutrition logging,
and a transparent estimate of how old your physiology looks compared with your actual age.

I built it as a learning project, to find out how far you get with AI coding agents on a real,
non-trivial app and how to steer them well. The parts I use most day to day are the workout
tracking and the nutrition log.

[![CI](https://github.com/fabian-kir/Longevity-Direction/actions/workflows/ci.yml/badge.svg)](https://github.com/fabian-kir/Longevity-Direction/actions/workflows/ci.yml)
![Platform](https://img.shields.io/badge/platform-iOS%2026%20%7C%20watchOS%2026-blue)
![Swift](https://img.shields.io/badge/Swift-SwiftUI%20%2B%20SwiftData-orange)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

> Longevity Direction is a personal learning project. It is not a medical device and gives no medical advice.
> The biological-age figure is a proxy built from wearable and lab values, not a diagnosis.

## Screens

Captured in the iOS simulator with the app's synthetic mock data (`-mockData`).

<p align="center">
  <img src="docs/media/demo.gif" width="320" alt="Walkthrough: Focus tab, bio-age breakdown sheet, nutrition history and a running Norwegian 4×4 session">
</p>

<table>
  <tr>
    <td align="center" width="33%"><img src="docs/media/focus.png" width="260" alt="Focus tab with the biological-age panel and the top priority card"><br>Focus tab: biological age and top priority</td>
    <td align="center" width="33%"><img src="docs/media/bioage.png" width="260" alt="Bio-age detail sheet listing each factor and its years impact"><br>Bio-age breakdown per factor</td>
    <td align="center" width="33%"><img src="docs/media/nutrition.png" width="260" alt="Meal detail with food categories, plant ingredients and nutrients"><br>Logged meal detail</td>
  </tr>
  <tr>
    <td align="center"><img src="docs/media/bloodwork.png" width="260" alt="Bloodwork panel detail with marker values and reference ranges"><br>Bloodwork panel with marker ranges</td>
    <td align="center"><img src="docs/media/n4x4.png" width="260" alt="Running Norwegian 4×4 session in the first high-intensity interval with heart-rate chart"><br>Norwegian 4×4 session, interval 1</td>
    <td align="center"><img src="docs/media/watch.png" width="200" alt="Apple Watch app during the first high-intensity interval"><br>Norwegian 4×4 on Apple Watch, interval 1</td>
  </tr>
</table>

## What it does

- **Biological-age estimate.** One number, the difference in years between estimated and
  chronological age, with a per-factor breakdown and the single change that would move it most.
- **Focus tab.** The most useful thing to do today, with the reasoning behind it.
- **Nutrition.** Take a photo or scan a barcode to log a meal.
- **Bloodwork.** Enter lab panels by hand (ApoB, HbA1c, hs-CRP and others) with reference ranges.
- **Digestion Insights.** Opt-in. Log digestive symptoms from the Nutrition tab; an on-device
  Bayesian model looks for ingredients your symptoms tend to follow, and how many hours later.
  Pattern matching only: no diagnosis, no diet advice, results shown only from converged runs.
- **Training.** A strength log that shows what you lifted last time and suggests today's weight
  and reps. Each exercise gets an AI-generated icon (about $0.04 per icon). Plus a guided
  Norwegian 4×4 session that runs on iPhone and Apple Watch with heart-rate targets, haptics and
  a Live Activity.

There is no backend and there are no accounts. Health data stays on the device. The exceptions are
meal photos, which are sent to a vision model through OpenRouter when you use photo logging, and
exercise names, which are sent through OpenRouter to generate exercise icons. Barcode lookups go to
Open Food Facts. Symptom logs and the Digestion Insights analysis never leave the device.

## The biological-age engine

`BiologicalAgeEngine` fuses noisy, irregularly sampled sensor data into one estimate under explicit
assumptions. Nothing is learned or fitted: every year the engine adds or subtracts comes from one
reading times one weight, and the result can be reproduced by hand with a calculator. The full
derivation is in [docs/biological-age-methodology.md](docs/biological-age-methodology.md).

**Additive model.** The 24 signals are grouped into 10 factors. Each factor is a mean of signed
"years impact" terms, weighted by freshness and data quality, and clamped at a per-factor cap so
that no single noisy sensor can dominate.

```
biologicalAge   = max(0, chronologicalAge + Σ clamp(weightedMean_factor, ±yearsCap_factor))

rawYearsImpact  = −zScore × yearsPerSD        (z-scored against age and sex norms)
effectiveWeight = freshnessWeight × qualityWeight
```

**Smoothing for irregular samples.** Heart-rate variability from HealthKit is noisy from night to
night and arrives at uneven intervals. Instead of a fixed-step exponential average, the engine uses
a continuous-time exponential smoother with a 7-day half-life that weights each sample by its
actual time gap, `e^(−Δt/τ)`, before z-scoring.
([methodology §5](docs/biological-age-methodology.md))

**Sensitivity readout.** The map from signal to result is piecewise linear, so the app can show a
local slope such as "10 % better HRV → −0.4 years". It is computed by finite difference and reads
zero when a factor is at its cap or suppressed.
([methodology §6](docs/biological-age-methodology.md))

**Correlated signals.** Downstream markers suppress the upstream behaviours they already capture,
so the same effect is not counted twice. Upstream drivers and the top lever are still shown in the
interface without changing the number.

## The Digestion Insights engine

`DigestionInsightsEngine` (local package `Packages/DigestionInsights`) fits a Bayesian
distributed-lag Poisson model to one person's hourly symptom counts. Each logged meal contributes
exposures to EU allergens, Open Food Facts ingredients and ingredient groups, weighted by how
reliable the source is. A cubic-spline lag curve over 0–96 hours estimates for each food how
strongly, and how long after eating, symptoms follow. Horseshoe shrinkage keeps the many foods
without an effect near zero.

The engine has its own No-U-Turn sampler written in Swift with Accelerate: four chains, Stan-style
warmup, rank-normalised R̂ and effective sample size. It runs nightly while the phone charges. A
result is shown only when all three fits (full data, first half, second half) pass the convergence
checks.

A simulation study with synthetic users (staples, foods eaten together, sloppy logging, AI
misdetection) calibrated the decision thresholds and measured what the engine can and cannot
find. With typical logging, a ×2 trigger did not reach an early signal in most users within 180
logged days; slow effects (24–60 h after eating) were found, acute ones (within 12 h) were not,
even at ten times the baseline rate. Null users showed a false "clear pattern" in 0 of 208
analyses (95 % interval 0–1.8 %). The results are reported as measured, including what does not
work yet.

The simulation study, its settings and its limits are in
[Packages/DigestionInsights/Simulation/results.md](Packages/DigestionInsights/Simulation/results.md);
the model, priors, levels and validation in
[docs/digestion-insights-methodology.md](docs/digestion-insights-methodology.md).

## Nutrition pipeline

- **Barcode:** detected on the device with `Vision`, then looked up in Open Food Facts
  (data © Open Food Facts contributors, ODbL).
- **Photo:** a vision model picked by OpenRouter's Auto mode (`openrouter/auto`) returns a category
  fingerprint: plate fractions, plant ingredients, macros per 100 g and a typical serving size.
  The model is never asked for absolute grams, which it cannot estimate reliably from a photo.
- **Offline:** captures wait in a queue backed by `NWPathMonitor` and upload when the connection
  returns.

The API key is stored in the Keychain. The cost of each call is tracked and shown in Settings.

## Norwegian 4×4

A 31-minute protocol: warm-up, four high-intensity rounds, three active recoveries and a cooldown.

- Target heart-rate bands derived from maximum heart rate, with coaching and distinct haptic cues.
- One device owns the session and the other mirrors it. If the owner disappears, the mirror takes over.
- When heart-rate readings are missing, the session degrades to a timer with a clear warning and
  recovers when readings return.
- Completed sessions are written to Apple Health.

The timing and state logic lives in the local `IntervalEngine` package, separate from any UI.

## Architecture

| Path | Content |
|---|---|
| `Longevity Compass/Views/` | SwiftUI screens, one folder per tab, plus shared components |
| `Longevity Compass/Models/` | SwiftData models and value types |
| `Longevity Compass/Services/` | Engines and integrations: HealthKit, OpenRouter, OpenFoodFacts, Keychain |
| `Longevity Compass/Config/` | Thresholds and norms |
| `Packages/IntervalEngine/` | Interval state and timing, and the visuals shared by phone and watch |
| `Packages/DigestionInsights/` | Digestion Insights model, NUTS sampler and simulation study |
| `Longevity Watch Watch App/` | Apple Watch companion |
| `N4x4 Live Activity/` | Live Activity for a running session |

| Engine | Responsibility |
|---|---|
| `BiologicalAgeEngine` | 24 signals → 10 factors → difference in years |
| `PriorityEngine` | Ranks 12 health domains by impact, friction, status and trend |
| `IntervalEngine` | Deterministic 4×4 timeline, target bands, coaching and failover |
| `NotificationManager` | Reminders driven by status, respecting quiet hours |
| `DigestionInsightsEngine` | Meals and symptoms → distributed-lag model → pattern level, effect size and delay per ingredient |

Persistence uses SwiftData with lightweight migration. Export is JSON.

Frameworks: SwiftUI, SwiftData, HealthKit, WatchConnectivity, ActivityKit, CoreHaptics, Vision, Network,
BackgroundTasks, Charts, Accelerate.

## Tests

- The app's XCTest target checks the engine against four synthetic profiles (elite endurance,
  metabolic syndrome with and without bloodwork, and a vegan low-exercise case) and asserts that
  each lands in its expected range. It also covers nutrition logic, barcode stabilisation and the
  workout recorder.
- The `IntervalEngine` package has tests for the timeline, targets, control, failover and the
  message format between phone and watch.
- The `DigestionInsights` package tests the sampler against targets with known answers, the
  model gradient against finite differences, the level rules and the simulation tools. A separate
  simulation study (`digestion-sim`) checks calibration and recovery of planted triggers.
- GitHub Actions runs both suites on every push and pull request to `main`.

## Build and run

The Xcode project, targets and schemes still use the project's original working name,
Longevity Compass.


```bash
git clone https://github.com/fabian-kir/Longevity-Direction.git
cd Longevity-Direction
open "Longevity Compass.xcodeproj"
```

Requires Xcode with the iOS 26 and watchOS 26 SDKs.

| Scheme | Use |
|---|---|
| `Longevity Compass` | The app and its tests |
| `Longevity Compass (Mock)` | The app with synthetic data, for the simulator |
| `Longevity Watch Watch App` | The watch companion |

Health data comes from HealthKit. Photo logging needs an OpenRouter API key, entered in Settings.

## Scope

The feature list and what is deliberately left out are in [docs/scope.md](docs/scope.md).

## License

MIT, see [LICENSE](LICENSE). Food data from Open Food Facts is © Open Food Facts contributors,
licensed under the ODbL.

---

Built by Fabian Kirschenmann.
