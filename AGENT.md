# LLM Agent Bootstrap Guide for ai-test V3

> Practical guide for LLM agents (Claude, Cursor, Windsurf) driving uptizm-app via ai-test MCP.
> For architecture see [V3_OVERVIEW.md](V3_OVERVIEW.md).

## 1. Quick Start

The typical flow is three steps in a loop:

1. **Get routes** to discover navigation options:
   ```
   → flutter_get_routes
   ← { routes: ["/auth/login", "/monitors", "/monitors/:id", ...], currentRoute: "/auth/login" }
   ```

2. **Take a snapshot** to see the current screen structure:
   ```
   → flutter_snapshot { depth: 2 }
   ← { refs: {"e0": "Container", "e5": "WButton", "e11": "TextFormField", ...}, 
       tree: {...semantic hierarchy...}, magicFormFields: {...} }
   ```

3. **Choose a ref and interact** (tap, type, navigate):
   ```
   → flutter_tap { ref: "e5" }
   ← { ref: "e5" }  # OK
   → flutter_navigate { route: "/monitors" }
   ← { ref: "navigate_1" }  # OK
   ```

Repeat snapshot after interactions to see state changes. Use `depth: 2` for overviews, `depth: 5+` for complex nested forms.

## 2. Tool Selection Guide

| Intent | Tool | Notes |
|--------|------|-------|
| **See what is on screen** | `flutter_snapshot` | Returns YAML semantic tree + refs. Use `depth` param to cap tree depth (default: full tree, ~600ms latency). |
| **See what is on screen as image** | `flutter_screenshot` | JPEG q70 by default; add `format: "png"` for lossless. Optional `ref + rect` crops to region. |
| **Tap a button** | `flutter_tap` | Returns OK immediately after dispatch; navigation/modal opens happen in next rebuild (not an error). |
| **Fill a form field** | `flutter_type` | Syncs `TextEditingController.text`. Does NOT auto-submit; use `flutter_press_key {key: "Enter"}` after. |
| **Press a keyboard key** | `flutter_press_key` | Dispatch HardwareKeyboard event. Common: `"Enter"`, `"Escape"`, `"Backspace"`. |
| **Scroll a list** | `flutter_scroll` | Takes `element: <ref>`, `dy: <pixels>`, `duration: <ms>`. Positive dy scrolls down. |
| **Navigate to a route** | `flutter_navigate` | Route string like `"/monitors/create"`. Auto-dismisses modals before pushing (Wave 3+). |
| **Go back** | `flutter_navigate_back` | Equivalent to native back button. Harmless if no route to pop. |
| **Wait for text to appear** | `flutter_wait_for` | Polls tree every 200ms. Returns when text found or timeout. Common for async UI updates. |
| **Wait for network call to finish** | `flutter_wait_for_request` | Preferred over snapshot+poll loops. Match by `urlPattern` (regex), optional `method`, `minStatus`, `maxStatus`, `timeoutMs`. |
| **Dismiss a modal sheet** | `flutter_dismiss_modals` | Pops all ModalRoute stacks (BottomSheet, Dialog, etc.). Returns count popped. |
| **Inspect Dart state** | `flutter_evaluate` | Eval arbitrary Dart: `"Magic.find<MonitorController>().rxState.value.toString()"`. Use for assertions. |
| **See network requests** | `flutter_network_requests` | Returns ring buffer (50 entries max) of recent HTTP calls: method, URL, status, body, timing. |
| **Mock an HTTP response** | `flutter_mock_http` | Intercept future request by urlPattern + method; return custom `status`, `body`, `delayMs`. |

## 3. Snapshot Reading

Snapshots are YAML with semantic node hierarchy. Key patterns:

**Ref format**: `[ref=eN]` where N is a stable ID for this semantic node. Refs are unique PER snapshot; do not reuse after taking a new snapshot.

**Depth parameter**: 
- Omitted or 0: full tree (slowest, ~600ms; use for initial exploration).
- `depth: 2`: root + one level + leaves (fast, ~100ms; ideal for navigation loops).
- `depth: 5`: mid-range; captures form structure + section headers.

**Form fields**:
```yaml
e5: TextFormField
    magicFormField: "email"        # MagicFormData field name; use for flutter_type
    label: "Email Address"
    hintText: "your@email.com"
```

When you see `magicFormField: <name>`, use that in `flutter_type {field: "name", text: "..."}`.

**Typical navigation snapshot** (Monitor list):
```yaml
  e0: Scaffold
    e1: AppBar
        e2: WText [Monitor list]
    e3: SingleChildScrollView
        e4: Column
            e8: WButton [ref=e8]
                label: "Add monitor"
            e12: ListTile [ref=e12]
                title: "Production API"
```

Tap e8 for add, e12 for detail.

## 4. Envelope Semantics

Every tool returns a JSON envelope: success or error.

**OK envelope**:
```json
{ "ref": "e12" }
```
Returned by `flutter_tap`, `flutter_type`, `flutter_navigate`, etc. immediately after dispatch. The ref confirms the tool found and executed against the correct element.

**Error envelope**:
```json
{ "error": "RefRegistry.lookup('e12') returned null — stale ref" }
```
Returned BEFORE dispatch if element not found, rect is zero (off-screen), or injection failed. Hard failures; navigation did not happen.

**Post-dispatch rebuilds are NOT errors**: if a tap triggers `Navigator.push()`, the tree rebuilds but the tap envelope still returns OK. Next `flutter_snapshot` shows the new route. This is expected.

**Tap on disabled button is silent OK**: no error envelope, just returns `{ref: ...}`. Button did not fire `onTap` but ref was valid.

## 5. Modal Handling

Modals (BottomSheet, Dialog, AlertDialog) stack on top of the current route. They do NOT navigate; they overlay.

**Before Wave 3 (auto-dismiss in flutter_navigate)**: explicitly dismiss modals before navigating:
```
flutter_dismiss_modals
← { "popped": 2 }  # two modals were on the stack
flutter_navigate { route: "/monitors" }
```

**After Wave 3 (auto-dismiss enabled)**: `flutter_navigate` auto-pops modals before pushing:
```
flutter_navigate { route: "/monitors" }  # implicitly dismisses open modals
← { "ref": "navigate_1" }
```

**To dismiss without navigating**: `flutter_dismiss_modals` alone returns the count popped. Useful for "close sheet and stay on this route" flows.

**Modal refs in snapshot**: when a BottomSheet is open, the snapshot includes BOTH the sheet tree AND the underlying page tree. Look for `"Scrim"` ref in the sheet's parent to identify the modal boundary.

## 6. Network Waits

Two patterns: snapshot+poll (legacy) vs `flutter_wait_for_request` (preferred).

**Bad pattern** (3 snapshots + manual timing):
```
flutter_tap { ref: "e5" }  # trigger POST
← { "ref": "e5" }
<sleep 100ms>
flutter_network_requests
← last entry shows 0 requests yet
<sleep 500ms>
flutter_network_requests
← last entry shows { method: "POST", status: 201, url: "/metrics" }
```

**Good pattern** (single wait tool):
```
flutter_tap { ref: "e5" }  # trigger POST
← { "ref": "e5" }
flutter_wait_for_request { urlPattern: ".*/metrics", method: "POST", minStatus: 200, timeoutMs: 5000 }
← { "matched": true, "status": 201, "url": "/metrics", "durationMs": 247 }
```

Use `flutter_wait_for_request` for any flow where you need to know when an async request completes. Buffer limit is 50 entries; on very chatty pages, monitor `"recentCount"` in the response.

## 7. Common Pitfalls

- **Refs accumulate across snapshots**: after `flutter_snapshot`, all e0, e5, e12 refs are valid. After a second `flutter_snapshot`, old refs (e0, e5) are stale. Always re-snapshot after navigation or state change before reusing refs.

- **Stale ref after navigation**: navigating to a new route rebuilds the tree. Old snapshot refs from before the navigation are invalid. Re-snapshot to get fresh refs for the new route.

- **Modal sheets include underlying page**: when a BottomSheet is open, `flutter_snapshot` returns both sheet and page trees. Identify the sheet by looking for a `PopupRoute` ancestor or `Scrim` widget label in the ref list.

- **Tap on disabled button returns OK, not error**: a button with `enabled: false` still has a valid rect; tap envelope is OK but `onTap` did not fire. Check the snapshot to confirm button state (e.g., `disabled: true` in the semantic label).

- **Navigation triggers rebuilds immediately after dispatch**: if a tap calls `Navigator.push()`, the envelope returns OK but the next frame renders the new route. Snapshot immediately after to see the new state.

- **Hot-restart loses VM Service token**: after typing `R` in flutter run, the recorded VM service token becomes stale. Restart the MCP server (`dart run ai_test_flutter:ai_test_flutter stop && start`) to re-bootstrap. The CLI's doctor command warns if token mismatch detected.

- **Bottom sheet refs go stale on scroll**: if you tap a ref inside a scrollable BottomSheet, then the user scrolls, the ref's position changes. For stable interaction inside scrolls, re-snapshot and choose fresh refs after scroll.

