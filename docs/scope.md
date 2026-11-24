# Scope — Longevity Direction v1

The complete user-facing feature list for v1, organized by tab. Anything not on this list is out of scope.

---

## Focus tab

The single-screen "what should I do today" view.

- **Biological-age panel** — current bio-age vs chronological age, year delta, trend (improving / holding / aging faster), confidence indicator, biggest lever. Tap to open the full breakdown sheet.
- **Bio-age detail sheet** — per-factor contributions with z-score bars, suppressed-levers section, "sharpen your estimate" suggestions with deep-links into Track / Bloodwork / Apple Health.
- **Top priority hero card** — the one thing to focus on, with why-it-matters rationale, two recommended actions, and a primary CTA (Open Apple Health or Log in app).
- **Secondary priorities row** — up to two compact rows for the next most urgent items.
- **Wins strip** — horizontally scrolling pills celebrating signals that are clearly on track.
- **Contributors section** — top three "working in your favor" and top three "biggest opportunities" pulled from the bio-age engine.
- **All-clear state** — friendly empty state when nothing is urgent.
- **Refresh control** — pull-to-refresh and toolbar refresh button.
- **Settings link** — toolbar leading button → `DataExportView`.

## Train tab

Strength-training log.

- **Exercise log** — entries grouped by date, swipe to edit/delete.
- **Add/edit exercise sheet** — pick from library, set sets/reps/weight, notes.
- **Exercise library** — seeded with default exercises; user can add custom ones with optional AI-generated icons (Gemini 2.5 Flash Image).
- **Empty state** — `ContentUnavailableView` with call-to-action.

## Nutrition tab

Camera-first meal logging with hybrid local/cloud AI.

- **Camera capture** — full-screen camera as the primary entry point.
- **Post-capture sheet** — preview, retake, save.
- **Barcode path** — local Vision barcode detection → OpenFoodFacts lookup.
- **Photo path** — image sent to OpenRouter (Auto Router, `openrouter/auto`, picks the vision model per request) for category fingerprint extraction (plate fractions, plant ingredients, macros and fibre per 100g, typical serving grams). AI never estimates absolute grams; the user confirms the weight.
- **Offline queue** — `NWPathMonitor`-backed pending-meal queue; entries upload when connectivity returns.
- **Food search sheet** — text search via OpenFoodFacts for manual lookup.
- **Intake card** — calories, protein, carbs, fat and fibre consumed today against optional daily targets. The calorie target carries a goal (deficit, maintain, surplus); protein and fibre are minimums, carbs and fat are limits.
- **Tracking window (advanced)** — daily by default, or fixed N-day blocks from an anchor date, or a rolling N-day window. Targets scale with the window length, with a per-day bar strip and the budget left per remaining day. Aimed at intermittent fasting.
- **History by day** — meal history grouped per day with daily calorie totals.
- **Manual edit / detail view** — review and adjust any logged entry, including the portion (nutrients rescale); view fingerprint breakdown.
- **Permission-denied fallback** — clear message with Settings deep-link when camera access is refused.
- **Empty state** — "Snap your first meal to get started."
- **Digestion Insights menu** (only while digestion tracking is on) — toolbar menu with "Log symptom…" (kind, level, onset: now, 1 h ago, 3 h ago or earlier) and "Digestion Insights".
- **Ingredient profile on meals** — EU allergens, traces, ingredients matched to the Open Food Facts taxonomy, free-from labels and alcohol, from Open Food Facts or the meal photo; detected allergens and free-from marks can be corrected.

## Digestion Insights (opt-in, reachable from Nutrition and Settings)

Pattern matching between logged symptoms and logged meals. Off by default; method in [digestion-insights-methodology.md](digestion-insights-methodology.md).

- **Onboarding sheet** — what it does and can't do, what it needs from the user, talk to your doctor before changing your diet; "Start tracking" opens a tracking period.
- **Hub screen** — tracking status (since when, logged days), results per ingredient, symptom log (swipe to delete, tap to edit).
- **Results** — level per ingredient (not enough data, inconclusive, early signal, clear pattern, no link found), effect size with interval, typical delay, main symptom kind, foods that cannot be told apart, rate-ratio-by-delay chart and observed-versus-expected pairs chart. Shown only from converged runs; the last good result stays visible with its date.
- **"How this works" page** — the method in plain language.
- **Export** — doctor report (PDF) and analysis data (JSON, exact engine input and result for reproduction).

## Bloodwork tab

Manual bloodwork panel entry and tracking.

- **Panel list** — chronological list of bloodwork panels.
- **Add panel sheet** — enter individual markers (ApoB, LDL, HDL, triglycerides, hs-CRP, HbA1c, fasting glucose/insulin, homocysteine, eGFR, ALT) with date.
- **Panel detail view** — per-marker values with status coloring.
- **Marker guide** — reference ranges and what each marker means.
- **Cadence summary** — status-dependent text ("Book a baseline panel" / "Next draw recommended in N months").
- **Empty state** — "No panels yet" with CTA + marker-guide link.

## N4x4 tab + Watch companion

Guided heart-rate training on iPhone and Apple Watch. Apple Health stays the source of measured values (distance, calories, route); the app adds live coaching on top.

- **Norwegian 4×4** — default 31-minute protocol: warm-up, four high-intensity rounds, three active recoveries and cooldown. Starts exactly as before; no setup required.
- **Hold heart rate** — hold one target heart rate for a set time (default: 70% of max HR, ±5 bpm, 30 min after a 5-min warm-up). Watch haptics cue when drifting high or low; Finish after 5 minutes saves the session.
- **Heart check** — monthly 11-minute routine at a fixed, repeatable workload: 3 min easy, 6 min at the workload, 2 min standing still. Results: heart rate at the workload (aerobic fitness) and the drop after 1 and 2 minutes (recovery). Compared only with earlier checks at the same workload; "due" card on the start screen and a trend view.
- **Workout settings** — own max heart rate (or the explained automatic estimate), 4×4 structure, zones and tolerance, Hold-HR target, tolerance and duration. Synced to the Watch.
- **Live coaching** — target bands, trailing-HR guidance and distinct haptic cues; clear Liquid Glass metrics card.
- **Apple Health workouts** — equipment maps to the matching Apple workout type (treadmill run/walk, indoor cycle/row, elliptical, stair stepper, outdoor run/walk/cycle) so Health records distance, pace and running metrics; outdoor sessions record a GPS route; each phase is saved as a workout segment.
- **After the workout** — effort rating (saved as Apple's workout effort score), machine distance and treadmill incline corrections (app only; Health keeps the Watch's measurement), notes. Workout details show Apple's measured distance, pace and active calories.
- **Phone/Watch mirroring** — one device owns the session while the other mirrors; a watchdog promotes the mirror if the primary disappears. The running routine travels with every checkpoint.
- **Timer-only degradation** — explicit warnings when HR or target zones are unavailable, with automatic recovery when readings resume.
- **Mock launch mode** — shared `-mockData` contract for simulator demos without HealthKit sensors.

---

## Secondary screens (reachable from tabs)

- **Data export view** (Settings) — Apple Health sync status, OpenRouter API key (Keychain-stored), nutrition & exercise-icon cost tracking, notification scheduler, JSON export, delete-all-data option.
- **Digestion Insights section** (Settings) — "Track digestion" toggle (onboarding on, confirmation before turning off), link to the hub, "Run analysis now" with progress, and the last run's diagnostics (date, duration, attempts, status, R̂, effective sample size, divergences).

---

## Engines (not screens, but part of v1)

- **`BiologicalAgeEngine`** — 24 HealthKit + bloodwork + behavior signals → 10 factors → years-of-age delta. Z-scored against age/sex norms, freshness-weighted, with three layers of cross-signal reasoning (downstream suppression, upstream drivers, top lever).
- **`PriorityEngine`** — impact × friction × status × trend scoring across 12 health domains.
- **`NotificationManager`** — quiet-hours-aware reminders driven by per-domain status (urgent → daily, good-with-baseline → quarterly, etc.).
- **`IntervalEngine`** — deterministic N4x4 timeline, HR target line, dead-band coaching and cross-device failover decision.
- **`DigestionInsightsEngine`** (package `Packages/DigestionInsights`) — Bayesian distributed-lag Poisson model of hourly symptom counts against meal exposures (0–96 h), fitted on device with its own NUTS sampler, nightly while charging; convergence-gated levels with thresholds calibrated by a simulation study.

---

## Anti-scope (explicitly out)

- No backend, no cloud user accounts, no auth.
- No Android / multi-platform port.
- No cloud-synced workout journal; N4x4 history remains device-local while
  completed workouts are also written to Apple Health.
- No on-device LLM (Foundation Models) — deferred until capable hardware is available.
- No AI gram-estimation from text descriptions.
- Digestion Insights: no diagnosis and no mechanism claims (no "intolerance", "FODMAP" or allergy wording); no suggestions to cut out foods or change diet; no effects that build up over more than 96 hours; no logging from widgets, Control Centre, Siri or Apple Watch yet; no amount-based (portion-size) exposure yet; no reminders, check-ins or notifications; nothing about symptoms on main screens.
