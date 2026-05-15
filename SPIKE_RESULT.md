# SPIKE_RESULT.md — Architecture B (Shadow DOM Projection)

## Bottom Line: ITERATE

Architecture B is structurally sound: Phase 0 and Phase 1 both pass. The per-frame projection cost (p95 = 5700 μs) falls in the ITERATE band (3000-8000 μs), above the 3000 μs SHIP threshold. Identity-keyed diff-based DOM updates are the required V1 change before Architecture B can ship.

---

## Phase 0 Result: PASS

Canvas click reaches a Flutter widget handler through the CanvasKit canvas in headless Chromium. Oracle Finding #3 (existential assumption) is verified.

- Evidence: `.ac/plans/flutter-spike-architecture-b-shadow/evidence/14-phase0-result.txt` — content: `PASS`
- Detail: `.ac/plans/flutter-spike-architecture-b-shadow/evidence/14-phase0-summary.md`
- Build: `flutter build web --release` (dart2js, CanvasKit); served via `php -S 127.0.0.1:5050`
- Playwright wait shape: `waitForSelector('flt-glass-pane', { state: 'attached' })` + 800 ms paint settle
- Spec: `references/playwright-cli/tests/ai-test-phase0.spec.ts`

---

## Phase 1 Result: PASS (with one app-side caveat)

All projection-owned steps verified:

| Step | Outcome |
|---|---|
| Mirror DOM emits inside `flt-glass-pane.shadowRoot` | PASS (241 mirror divs at capture time) |
| `getByTestId('input.email')` resolves | PASS |
| `getByTestId('input.password')` resolves | PASS |
| `getByTestId('button.sign_in')` resolves | PASS |
| Coordinate-click forwards through canvas to Flutter input focus | PASS |
| `keyboard.type` reaches focused canvas input | PASS |
| Login POST reaches backend | PASS (HTTP 200 + token confirmed in `13-laravel-serve.log` + direct curl) |
| URL advances away from `/auth/login` after login | FAIL (app-side, not projection-side) |

The URL-change assertion timed out at 15 s. Investigation shows the click did forward and the backend accepted the credentials, but the uptizm-app post-login `navigateTo(MagicStarterConfig.homeRoute())` hook does not advance the browser URL. This is an app-level navigation issue, not an Architecture B failure. Every step that the projection layer is responsible for passed.

- Evidence: `.ac/plans/flutter-spike-architecture-b-shadow/evidence/13-summary.md`
- Playwright report: `.ac/plans/flutter-spike-architecture-b-shadow/evidence/phase1-results-final/`
- Spec: `references/playwright-cli/tests/uptizm-login.spec.ts`

---

## Phase 2 Measurement

Build: profile mode (dart2js, no debug overhead). Browser: chromium-headless via Playwright. Renderer: CanvasKit. Screen: `/auth/login` (static; V0 worst-case, no diff).

| Metric | Value (μs) |
|---|---|
| avg | 3779 |
| p50 | 3599 |
| **p95** | **5700** |
| p99 | 6400 |
| Sample count | 39 |

Threshold check: p95 < 3000 μs → **FAIL** (5700 μs exceeds threshold by 90 %).

Decision band: 3000-8000 μs → **ITERATE**.

- Evidence: `.ac/plans/flutter-spike-architecture-b-shadow/evidence/13-metrics.json`

---

## Oracle Findings Status

| # | Finding | Severity | Status |
|---|---|---|---|
| 1 | `addPersistentFrameCallback` fires pre-paint; must use `addPostFrameCallback` re-registered each frame | CRITICAL | Addressed — projection uses `addPostFrameCallback` re-registration; verified by `grep addPersistentFrameCallback lib/src/projection.dart` = 0 lines |
| 2 | Mirror DOM must mount inside `flt-glass-pane.shadowRoot`, not `document.body` | CRITICAL | Addressed — `GlasspaneMount.ensureHost()` appends into `shadowRoot`; verified by `grep "document.body" lib/src/projection.dart` = 0 lines |
| 3 | Canvas-click forwarding unverified in headless Chromium | CRITICAL | Addressed — Phase 0 PASS confirms `page.mouse.click(x,y)` reaches the Flutter handler |
| 4 | Per-frame DOM re-emit under animation creates GC pressure; p95 budget risk | IMPORTANT | Outstanding — V0 re-emits all nodes every frame; p95 = 5700 μs confirms this is the bottleneck; diff-based updates deferred to V1 |
| 5 | Implicit-animation staleness needs `window.__aiTestStable` gate | IMPORTANT | Addressed — stability heartbeat implemented in `projection.dart`; Playwright spec gates every click on `waitForFunction(() => window.__aiTestStable)` |

---

## Recommendation

Next plan: `/ac:plan ai-test V1: incremental diff projection + animated-screen validation`

V0 measured p95 = 5.7 ms against a 3 ms target on a static screen with full re-emit (241 nodes/frame); the V1 plan introduces identity-keyed diff updates to skip unchanged subtrees and expects a 5-10x reduction, which projects p95 to roughly 0.6-1.1 ms, within the SHIP band. V1 also exercises animated screens (route transitions, ripple) to validate the stability-gate semantics under real conditions and resolves the open caveat that `/auth/login` is best-case.

---

## Cost Summary

| Item | Detail |
|---|---|
| Plan steps executed | 15 of 15 |
| Waves completed | 9 of 9 (plus Final Verification Wave) |
| Plan revisions during execution | 3 (dev_dependencies lint → `dependencies:`; `kDebugMode` → `!kReleaseMode` for profile builds; runtime gate → compile-time `if (!kReleaseMode)` at call site for tree-shake) |
| Key decisions | Phase 0 GATE: PASS (continue); Phase 1 navigation timeout: accepted as app-side issue (user-confirmed); p95 verdict: ITERATE band |
| Architecture B verdict | Structurally valid; performance requires one targeted fix before ship |
