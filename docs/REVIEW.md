# Prio code review

Scope: every file in `Sources/PrioCore`, `Sources/PrioAudio` and `Sources/Prio`. I checked each against the swiftui-macos skill areas (observation, concurrency, performance, views, data, platform, scenes, api, accessibility) and against SPEC.md F5–F14.

The deployment target stays at **macOS 13** (R1). Where the skill recommends an API newer than 13, the finding is marked "deferred (needs macOS 14/26)".

Severity: **High** means wrong behaviour on real hardware. **Medium** means a crash risk, a visible glitch, an accessibility failure or wasted work on hot paths. **Low** means hygiene.

---

## Sources/PrioCore/Engine.swift

### 1. Writes judged by an immediate read-back (High, fixed)
**Lines:** `write(_:_:)`, `perform`, `pick`, `undo`.

**Why it matters:** `write` set the default, read it back at once and treated any mismatch as a failure. If the HAL applies the new default a moment after `AudioObjectSetPropertyData` returns, three things go wrong:
- F10 reports a false failure.
- F9 counts the attempt toward loop protection.
- The late default-changed callback no longer matches `lastKnownDefault`, so F7 handles Prio's own echo as an external change. That means a correction, or a manual pick.

Echo suppression of Prio's own writes depended on the write being synchronous.

**Fix:** keep the target as the last known default. When the OS accepted the call but the read-back still differs, verify again after `Engine.verifyGrace` (0.5 s), then report success or failure. `perform`, `pick` and `undo` now finish in the verification callback.
```swift
// before
lastKnownDefault[d] = uid; audio.setDefaultDevice(d, uid: uid)
let actual = audio.defaultDevice(d); lastKnownDefault[d] = actual; return actual == uid
// after
write(d, uid) { applied in applied ? succeed(...) : fail(...) }   // verifies after verifyGrace if needed
```
**Tests (written first, seen failing):**
- "F10/F7: a default the OS applies asynchronously is a success, and its echo is not an external change"
- "F10: verification reads the default back…" now expects no result inside the grace period.

### 2. A failed menu pick cleared an existing pin (Medium, fixed)
**Lines:** `pick(_:_:)`.

**Why it matters:** suppose B is pinned and a pick of C fails. The default stays on B, but `manualPicks[d] = nil` removed B's pin, so the next topology event could switch away from the device the user chose (F6).

**Fix:** a failure no longer touches pins.

**Test:** "F10/F6: a failed menu pick leaves an existing pin in place".

### 3. `DeviceRow.id` was the device UID only (Medium, fixed)
**Lines:** `DeviceRow.id`.

**Why it matters:** a headset has the same UID in the input and output lists. The Devices tab swaps one `ForEach` between the two lists. Equal ids make SwiftUI keep the identity, state and transitions of the old row for a row in the other list.

**Fix:** `id` is now `"direction:uid"`. Selection and picks still use `uid`.

**Test:** "F17: row identity includes the direction…".

### 4. Wall-clock `Date` as the engine time source (Low, accepted)
The real clock uses `Date()`, while its timers use `DispatchTime`. A manual clock change during a 3 s, 5 s or 30 s window could skew one decision.

Switching to uptime would break the user-visible timestamps of actions, because they come from the same clock. The risk is a single misattributed event, so I left it.

## Sources/PrioAudio/CoreAudioSystem.swift

### 5. Device list read ignored the returned size (Low, fixed)
**Lines:** `deviceIDs()`.

**Why it matters:** if a device disappears between `AudioObjectGetPropertyDataSize` and `AudioObjectGetPropertyData`, the array keeps trailing zero IDs. They were filtered out later only by accident.

**Fix:** trim to the `size` that `AudioObjectGetPropertyData` returns.

### 6. CoreAudio OSStatus failures were silent (Low, fixed)
**Lines:** `setDefaultDevice`, `register`, `unregister`.

**Why it matters:** failed sets and listener registrations left no trace, so a broken listener looked like "Prio ignores my device".

**Fix:**
- `os.Logger` (subsystem `io.github.highstat.Prio`) logs failed sets and registrations as errors.
- Removal failures other than `kAudioHardwareBadObjectError` (device already gone) are logged at debug level.
- Read helpers keep returning `nil` or `0`, which the engine treats as "absent".

### Checked and clean
- **Listener delivery:** every listener is registered on `DispatchQueue.main`, so `MainActor.assumeIsolated` in the block is correct. There is no data race and no cross-thread hop.
- **Balanced registration:**
  - Per-device listeners are removed when a device leaves.
  - The mute listener is replaced when the default input changes.
  - `stopListening()` removes everything.
  - Calling `startListening()` twice is guarded.
  - Blocks capture `[weak self]`.
- **Stream access:** no stream is opened (R2). Only property reads, sets and listeners.

## Sources/Prio/AppDelegate.swift + SettingsWindow.swift

### 7. Settings controller released inside `windowWillClose` (Medium, fixed)
**Why it matters:** the window controller owns the window (`isReleasedWhenClosed = false`). Dropping the last reference from the delegate callback can free the window while AppKit is still inside `close()`, which is a use-after-free risk.

**Fix:** release on the next run-loop turn.
```swift
controller.onClose = { [weak self] in DispatchQueue.main.async { self?.settingsWindow = nil } }
```

### 8. Saved window frame overridden (Low, fixed)
`show()` called `center()` every time the recreated window appeared, which defeated `setFrameAutosaveName`.

**Fix:** `setFrameUsingName`, and center only when no frame was saved.

### 9. `activate(ignoringOtherApps:)` is deprecated from macOS 14 (Low, fixed)
**Fix:** `NSApplication.activateIgnoringOtherApps()` calls `activate()` behind `if #available(macOS 14, *)` and falls back on 13.

## Sources/Prio/StatusItemController.swift

### 10. Clicking the icon could reopen the transient popover (Medium, fixed)
**Why it matters:** a transient popover closes on the mouse-down outside it, which includes the status item. The status button acts on mouse-up, so it can see `isShown == false` and reopen. This is most visible with Reduce Motion, where there is no close animation to bridge the gap.

**Fix:** `popoverWillClose` records the uptime, and a toggle within 0.3 s of a close is ignored.

### Checked and clean
- **Content lifetime:** popover content is built on open and set to `nil` on close.
- **Key monitor:** installed only while the popover is open and removed in `popoverDidClose`. It hands only `Sendable` event fields into `MainActor.assumeIsolated`.
- **Retain cycles:** none. The navigator closures capture `[weak self]`, and the model does not reference the navigator.

## Sources/Prio/DevicesTab.swift

### 11. Every row observed the whole model (Medium, fixed)
**Why it matters:** `DeviceSettingsRow` held `@ObservedObject var model` but only used `model.engine`. `ObservableObject` invalidates every observing view on any `@Published` change, such as a mute toggle or the last-action line, so all rows re-rendered on every engine callback.

**Fix:** the row takes `let engine: Engine` and is redrawn only when its `DeviceRow` value changes.

### 12. Informational row exposed a button trait (Low, fixed)
The combined name/status element had `.isButton` but no action, so VoiceOver announced a button that does nothing. Its Move Up / Move Down / Move to Top accessibility actions remain.

### 13. `onChange(of:perform:)` (Low, deferred: needs macOS 14)
The two-parameter `onChange` is macOS 14+. The single-parameter form is correct for a macOS 13 target.

## Sources/Prio/MenuView.swift

### 14. Pinned badge contrast and size (Medium, fixed)
**Why it matters:** teal `#0D9488` text on a light background is about 3.7:1, below 4.5:1 for small text, and `.caption2` is too small to read comfortably.

**Fix:** `.caption` text in `.primary`, with a teal-tinted capsule and a teal outline. Colour is not the only signal.

### 15. Last-action animation attached to the whole menu (Low, fixed)
`.animation(_, value: model.lastAction?.id)` sat on the root, so every change in the same transaction animated, including unrelated rows. It is now scoped to `LastActionView`.

### 16. Object-wide invalidation from `ObservableObject` (Low, deferred: needs macOS 14)
Hover and keyboard highlight changes re-evaluate every `MenuRow`, because `MenuNavigator` is an `ObservableObject`. With about 10 small rows this costs microseconds. Per-property tracking needs `@Observable` (macOS 14).

### 17. Toggle trait on the "Automatic switching" row (Low, deferred: needs macOS 14)
The row exposes a label and an on/off value. The `.isToggle` accessibility trait needs macOS 14.

## Package.swift

### 18. App and audio targets compiled in Swift 5 mode (Low, fixed)
**Fix:** `swiftLanguageMode(.v6)` for both. A forced rebuild produced no concurrency diagnostics, and no `@unchecked Sendable` or `nonisolated(unsafe)` was needed.

## Repository URL

### 19. Placeholders (Low, fixed)
- `AppInfo.sourceURL` is now `https://github.com/highstat/prio`.
- The README clone command is now `git clone https://github.com/highstat/prio.git`.
- `CFBundleIdentifier` is now `io.github.highstat.Prio`.

Storage (`~/Library/Application Support/Prio`) and notification identifiers do not depend on the bundle id.

---

## Clean areas
- **Logic against the spec:** I compared F5–F14 with the engine. Settle timers, loop-protection lift, Undo validity and session reactivation all match the spec and its tests.
- **Shared code:** `Theme.swift`, `MenuNavigator.swift`, `Services.swift` (notification delegate hops to main, login item state) and `GeneralTab.swift` have no findings.
- **Reduce Motion and Increase Contrast:** honoured everywhere animations or highlights exist.

## Prioritized summary
1. **#1:** write verification with a grace period. It removes false failures and echo misattribution on real hardware.
2. **#7:** deferred Settings release (crash risk).
3. **#2 and #3:** pin loss after a failed pick, and per-direction row identity.
4. **#10, #11, #14:** popover reopen, row over-invalidation, badge contrast.
5. Hygiene: #5, #6, #8, #9, #12, #15, #18, #19.

**Totals:** 19 findings: 1 High, 6 Medium, 12 Low. 15 fixed, 3 deferred (needs macOS 14), 1 accepted.
