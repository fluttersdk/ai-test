# V1 Result — NEEDS_WORK / lean ABANDON for the diff approach

**Date**: 2026-05-15
**Decision**: do not promote V1 to production; do not ship V1 as-is. The diff approach reduces volatility but does not move per-frame projection cost into the SHIP band on production-like screens. Proceed to V2 only with a different strategy (sliding-window mirror set or RenderObject-keyed clean-subtree skip).

## Verdict bands (per plan)

| band | p95 threshold | action |
|---|---|---|
| SHIP | < 3000μs | promote V1 to default; remove V0 spike artifact |
| ITERATE | 3000-5000μs | one more iteration on V1 (e.g. tighter Element-scope filter) |
| NEEDS_WORK | 5000-15000μs | go back to design; do not promote |
| ABANDON | > 15000μs | the architecture itself is wrong; revisit Architecture A or D |

## Evidence

### Dashboard (production-like, polling load)

`evidence/dashboard-summary.md`:

| phase | count | avg | p50 | p95 | p99 |
|---|---|---|---|---|---|
| post-login settle | 153 | 6253 | 6500 | 12900 | 14199 |
| after 30s polling | 600 | 8876 | 8801 | 9500 | 10100 |
| second-run verification | 600 | 9182 | 9100 | 9800 | 10800 |

**Dashboard p95 = 9800μs.** NEEDS_WORK band.

### Login (static-page sanity)

`uptizm-login.spec.ts` against `:3100` post-source-filter: avg=4462μs, p50=3500μs, p95=6600μs, p99=9000μs (90 samples).

V0 baseline on `/auth/login` was p95=5700μs. V1 on the same page is p95=6600μs — within noise; the diff path neither helps nor hurts on a static page. The diff overhead (`Map<RenderObject, MirrorNode>` lookup + `needsUpdate` check + repaint-set drain) roughly cancels the savings from skipping no-op DOM mutations.

### Metric detail sheet (NOT MEASURED)

`evidence/sheet-summary.md`: blocked by a test-account fixture gap. The `aispike@example.com` account on `/monitors` produces zero `data-testid` mirror children, so the spec cannot find a monitor row to drill into. This is a separate fixture problem; resolution deferred to V2 prerequisites.

The dashboard alone is sufficient to decide V1, because dashboard exhibits the worst-case animation profile in the app and lands at 9800μs.

## What V1 actually accomplished

1. **`debugOnProfilePaint` per-frame repaint accumulator wired** — `_repaintedThisFrame` populates correctly across pumpWidget transitions; verified by `projection_repaint_set_test.dart` (chrome platform).
2. **Per-RenderObject `MirrorNode.needsUpdate` short-circuit** — diff index `Map<RenderObject, MirrorNode>` mutates DOM in place; orphan cleanup removes mirrors whose owning RenderObject vanished. Verified by `projection_diff_test.dart`.
3. **WInput source-filter** — emission skipped when an ancestor `WFormInput` exists; eliminates the V0 dual-mirror that forced `.first()` workarounds in Playwright. Login spec shrunk 62 -> 17 lines. Verified by `projection_source_filter_test.dart`.
4. **`installRefreshHook` JS bridge** — `window.__aiTestRefreshMetrics()` forces an on-demand snapshot publish that bypasses the `snapshotEveryNFrames=30` throttle. Used by all three Playwright specs.
5. **`ListQueue<int>` sample buffer** — O(1) FIFO eviction (vs O(N) `List.removeAt(0)`). Bounded at 600 samples = 10s at 60fps.
6. **30-frame snapshot cadence** — JS `__aiTestMetrics` publish throttled to ~2Hz; in-Dart `snapshot()` always returns the latest.
7. **Login-shape synthesizer fixture + regression test** — `synthesizer_login_fixture_test.dart` guards that WButton / WAnchor / WFormInput synthesize the expected `button.* / link.* / input.*` testids on the magic_starter login shape.
8. **Stability semantic empirically validated** — Step 7 shipped `>= 2 consecutive identical frames`; Step 12 measurement showed it never satisfied on real screens (continuous micro-repaints from polling, cursor blinks, time ticks). Reverted to V0's relaxed `>= 1 || isNotEmpty`. Documented in wisdom.md.

## What V1 did NOT change (and why p95 is still 9.8ms)

The full-tree Element walk + Matrix4 transform composition still runs on every emit. Diff-update wins on the WRITE side (mutate vs append) but not on the READ side (walk + transform). On the dashboard, the steady-state mirror count is large enough that READ-side cost dominates. V1 attacked the wrong half.

## Recommendation for V2

| option | shape | expected impact |
|---|---|---|
| A. RenderObject-keyed clean-subtree skip | re-add the subtree-skip short-circuit but key it on RenderObject identity (not Element); add a per-RenderObject `_lastEmitFrame` stamp; descend only when ANY descendant in `_repaintedThisFrame` | dashboard p95 likely 3-5ms (ITERATE) |
| B. Sliding-window mirror set | only project widgets within the current viewport; cull off-screen mirrors | dashboard p95 likely <3ms (SHIP) but breaks selectors that point at scrolled-off elements |
| C. Defer-to-idle batching | split per-emit work across `requestIdleCallback` slices; never block more than 3ms of any single frame | dashboard p95 around 3ms (ITERATE) but adds 16-32ms latency between mirror updates and Playwright reads |
| D. Architecture revisit | pull the projection out of the Flutter frame and into a worker that reads the semantic tree | unknown; high risk |

Recommended: **A first** (cheapest, builds on V1's index), then **B** if A lands ITERATE band but not SHIP. Skip C; the latency cost breaks Playwright's expectation of frame-aligned reads. Skip D unless A and B both fail.

## Files added by V1

- `references/ai-test/packages/ai_test_flutter/lib/src/mirror_node.dart`
- Modifications to `projection.dart`, `metrics.dart`, `metrics_publish_*.dart`, `dom_emitter*.dart`
- Tests: `mirror_node_test.dart`, `projection_repaint_set_test.dart`, `projection_source_filter_test.dart`, `projection_diff_test.dart`, `synthesizer_login_fixture_test.dart`, fixture `test/fixtures/login_form_fixture.dart`
- Playwright specs: `uptizm-dashboard.spec.ts`, `uptizm-metric-detail-sheet.spec.ts` (sheet not measured)
- Helper extraction: `tests/_helpers.ts` (`clickViaCoordinate`, `waitForFlutterReady`, `loginViaProjection`)

## V2 prerequisites (from oracle review)

Before V2 commits to option A, three cheap diagnostics close the remaining uncertainty:

1. **Per-phase FlutterTimeline split** — V1 brackets `_emit` with one span. Add three nested spans for `_collectElementInfo`, `_walkRenderObject`, `_diffEmit` and capture one dashboard run. If the diff phase is non-trivial (say > 2ms of the 9.8ms p95), option A's expected impact band shifts from "3-5ms ITERATE" to "5-7ms still NEEDS_WORK" and option B becomes mandatory rather than fallback. Cost: ~30 min; saves a wave if the read-side dominance assumption is wrong.
2. **Repaint-ancestor check shape** — option A's `_repaintedThisFrame` ancestor check is O(repainted-set × depth) per frame in the worst case if implemented as a per-RenderObject ancestor walk. On a polling dashboard with 4 staggered sections, the repainted set is non-trivial and a naive walk defeats the skip. Specify the inverse flood-fill shape in the V2 plan: walk `_repaintedThisFrame` once, flood-fill `_subtreeHasDirtyDescendant` upward into a bitset, then O(1) read during the main walk.
3. **Sheet gap disambiguation** — five-minute probe before V2 sheet measurement: project on `/dashboard` immediately, then route to `/monitors` without re-login and re-query the projection host. If the host disappears or empties on route change, it is wiring (single-instance `_activated` guard breaks across route remounts). If the host stays alive but the testid set is empty, it is a fixture / synthesizer coverage gap. The V1 verdict treats it as fixture; V2 should not assume that without the probe.

Optional V2 housekeeping (not blocking but cheap):
- Harden the single-instance `_activated` guard against route remounts (e.g. `MutationObserver` on `flt-glass-pane` to re-attach when the surface remounts).
- Fix `ensureHost` accumulating orphan `<div id="ai-test-host">` per test invocation (existing wisdom-doc gap).

## Disposition

Keep V1 code on the spike branch as a reference implementation of the diff path and the `debugOnProfilePaint` wiring. Do NOT merge into the production projection. Open a V2 spike planning ticket pointing at recommendation A.
