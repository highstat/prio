# Prio — Functional Specification

Prio is a free, open-source macOS menu bar utility that keeps the Mac on the
audio devices the user prefers. The user ranks microphones and outputs once;
Prio keeps the highest-ranked connected device selected as the system default
input and system default output, across plug/unplug, Bluetooth reconnects,
wake from sleep, and login.

This document describes **what** Prio does. It does not prescribe internal
architecture, except where a macOS requirement forces it (section 9).

Each requirement has an ID. Acceptance criteria (AC) are written so they can be
checked by a unit test against a simulated device system, or by a manual test.

---

## 1. Glossary

- **Direction** — `input` (microphones) or `output` (speakers, headphones).
  Every rule below applies to each direction independently unless stated.
- **Device** — any audio device macOS exposes that is eligible to be a system
  default device in that direction. A physical device with both a mic and
  speakers (e.g. a headset) appears independently in both lists.
- **Device identity** — the stable persistent unique identifier macOS gives a
  device (not its display name, which can collide). Two identical-model
  devices are two different entries.
- **Connected** — currently present in the system.
- **Ranked list** — per-direction ordered list of known devices (connected or
  not). Position 1 is most preferred.
- **Avoided** — a per-direction flag on a list entry. Avoided devices are only
  used as a last resort (F5).
- **Target** — the device Prio wants selected right now in a direction (F3).
- **Manual pick** — a device the user explicitly chose (F6). Overrides ranking
  temporarily.
- **Correction** — Prio changing the default *away from* a device that macOS
  (or another app) selected without the user's intent.
- **Settling window** — a short delay after device-topology changes during
  which Prio waits before acting (F8).

---

## 2. Device lists

### F1 — Separate ranked lists per direction
- Prio maintains one ranked list for input and one for output. Reordering one
  never changes the other.
- Speakers and headphones share the single output list; there are no separate
  groups or modes.
- **AC:** Moving a headset's input entry to #1 leaves its output entry's
  position unchanged.

### F2 — Learning devices
- On first launch, both lists are seeded from currently connected devices:
  the current system default first, then the rest in the order macOS reports.
- When a never-seen device connects, it is added to the list of every
  direction it supports:
  - **Output, headphone-like** (see F2a) → inserted at position 1.
  - **Everything else** → appended at the bottom.
- Known devices keep their position while disconnected; they are shown as
  not connected and still occupy their rank.
- The user can remove (forget) a disconnected device from a list. If it
  reconnects later it is treated as new.
- Devices that macOS marks as not eligible to be a default device are not
  listed. Hidden/private devices are not listed.
- Aggregate, virtual (software driver) and AirPlay devices are listed like any
  other device if eligible.
- **AC:** A new USB microphone connects → appears last in the input list. New
  Bluetooth headphones connect → appear first in the output list and (unless
  F6 pins something else) become the output.

### F2a — Headphone-like classification (for insertion only)
A new output device is headphone-like if any of:
1. Its transport is Bluetooth / Bluetooth LE **and** its name does not match a
   speaker keyword (case-insensitive: `speaker`, `soundbar`, `sound bar`,
   `stanmore`, `sync`, `boom`, `flip`, `charge`, `soundlink flex`, `homepod`,
   `tv`, `display`, `monitor`, `car`).
2. Its name contains a headphone keyword (case-insensitive: `headphone`,
   `headset`, `airpods`, `earbuds`, `buds`, `beats`, `jabra`, `wh-`, `wf-`,
   `qc`, `quietcomfort`, `elite`, `evolve`), regardless of transport.
3. It is the built-in output and its active data source reports "headphones"
   (wired jack).

Speaker keywords win over rule 1, headphone keywords (rule 2) win over speaker
keywords. Misclassification only affects initial placement; the user fixes it
by reordering. The classifier must be a pure, unit-tested function.

### F3 — Target selection
Given a direction's ranked list, the set of connected devices, avoided flags,
and an optional manual pick, the target is:
1. If a manual pick exists and is still valid (F6) → the manual pick.
2. Else the highest-ranked connected, non-avoided device.
3. Else (all connected devices are avoided) the highest-ranked connected
   avoided device — a **last resort** (F5).
4. Else (no listed device connected) → no target; Prio does nothing.

This must be a pure, deterministic, unit-tested function.

---

## 3. Switching behaviour

### F4 — Automatic switching
- While automatic switching is on and the user session is active, Prio makes
  the system default equal to the target whenever any of these happen:
  device connected, device disconnected, system default changed, ranking or
  avoid flags edited, Prio launched, Mac woke from sleep, user session became
  active again.
- When the default already equals the target, Prio does nothing (no
  notification, no last-action update).
- A switch caused by a ranking change (e.g. higher-ranked device connects,
  user drags a device to #1 in Settings) is a **switch**, not a correction: it
  updates the last-action line (F10) but does not post a notification unless
  "Notify on every switch" is enabled (F14).

### F5 — Avoided devices
- Avoid is per direction: avoiding a headset's microphone does not avoid its
  speakers.
- Avoided devices are skipped whenever any non-avoided listed device is
  connected.
- If only avoided devices are connected, Prio uses the highest-ranked one as a
  last resort and posts **exactly one** notification saying so (not one per
  event; not a second notification for the same last-resort episode). The
  episode ends when a non-avoided device becomes the target.
- If the user avoids the device that is currently their manual pick, the
  manual pick is cleared.
- UI copy must never claim avoided devices are "never" used.
- **AC:** Ranked [A(avoided), B]; only A connected → A selected, one
  notification. B connects → B selected, no last-resort notification.

### F6 — Manual pick
- Choosing a device from Prio's menu makes it the manual pick for that
  direction and selects it immediately (even if avoided).
- The manual pick stays selected until **either** that device disconnects
  **or** a device ranked higher than it connects (a device ranked higher that
  was already connected does not end it). Then normal ranking resumes.
- The manual pick is marked in the menu with a short badge (wording chosen by
  the implementer) and survives relaunch only if the device is still
  connected at launch.
- Turning automatic switching off and on again clears manual picks.
- **AC:** Ranked [A, B, C], A not connected, B and C connected. User picks C →
  C stays through unrelated events. A connects → A selected, pick cleared.
  Alternatively C disconnects → B selected, pick cleared.

### F7 — Changes made outside Prio (System Settings, Control Center, other apps)
macOS gives no direct signal of who changed the default. Prio applies this
deterministic rule to a default-device change it did not initiate itself:

1. If a device connect/disconnect happened in that direction within the last
   **3 seconds**, or the Mac woke within the last **5 seconds**, the change is
   attributed to macOS → Prio **corrects** it back to the target and posts a
   correction notification (F14) with Undo.
2. Otherwise, it is attributed to the user:
   - **Output:** if "Respect output changes made outside Prio" is on (default
     **on**), the new device becomes the manual pick (F6). No notification.
   - **Input:** if "Respect input changes made outside Prio" is on (default
     **off**), same as output. Otherwise Prio corrects it (rule 1 behaviour).
     Rationale: macOS often silently moves the input to a Bluetooth headset's
     low-quality mic without any topology change; correcting it is the main
     point of the input side.
- Changes Prio initiated itself must never be mistaken for external changes
  (Prio must track its own pending writes and ignore their echo).
- **AC:** each branch above covered by tests on the pure decision logic,
  using an injected clock.

### F8 — Settling
- After a connect or disconnect event, Prio waits for events to quiet down
  before evaluating: **0.5 s** after the last event for wired/virtual devices,
  **2.0 s** after the last event if the event involved a Bluetooth device. A
  new event restarts the wait. Bursts of events thus produce a single switch.
- After wake from sleep, Prio waits **2.0 s** before evaluating.
- Prio does not switch to a Bluetooth device that is listed as connected but
  not yet usable (it reappears as an event when it becomes usable).
- **AC:** A Bluetooth device emitting connect/disconnect/connect within 1 s
  results in at most one switch.

### F9 — Loop protection
- If Prio performs **3 corrections in one direction within any 30-second
  window**, it stops correcting that direction and posts one notification
  explaining that another app or macOS keeps changing the device.
- While stopped, external changes in that direction are left alone. Ranking
  edits made by the user and menu picks still work.
- The stop lifts when: 30 seconds pass with no correction attempt **and** a
  device connects or disconnects; or the user toggles automatic switching off
  and on; or the user session becomes active again.
- **AC:** Simulated app flips default 4 times in 10 s → exactly 3 corrections,
  1 loop notification, no 4th correction.

### F10 — Failure detection
- After setting a default, Prio verifies the system default actually changed.
  If not (device vanished, permission or driver refusal), the attempt is
  reported as a failure in the last-action line and is not reported as a
  success. A failed attempt counts toward F9.

### F11 — Pause (automatic switching toggle)
- A single toggle turns automatic switching on/off. Off = Prio never changes
  devices automatically; macOS behaves natively. Manual picks from the menu
  still switch the device once (no persistence while paused).
- The state persists across relaunch.
- Turning it back on clears manual picks and loop-protection state, then
  re-evaluates immediately.

### F12 — Session, sleep and login
- On launch (including at login), Prio evaluates both directions after a
  settling delay of 1 s.
- While the user session is inactive (fast user switching, screen locked to
  login window), Prio does nothing.
- On session reactivation: clear the last action (its Undo is stale), clear
  loop-protection state, re-evaluate.
- On wake: see F8.

---

## 4. Feedback

### F13 — Last action & Undo
- Prio remembers the most recent action it took (switch, correction,
  last-resort, failure) with a short human-readable sentence, e.g. which
  device macOS chose and which device Prio kept, and a relative timestamp.
- **Undo** restores the device that was selected immediately before that
  action and makes it the manual pick for that direction (so Prio does not
  immediately revert it). Undo is available only for the latest action and
  disappears once used, or when the device it would restore is gone, or on
  session reactivation.
- After Undo, the last-action line reflects the undo.

### F14 — Notifications
- Uses the standard macOS user-notification system. Prio requests
  notification authorization on first launch; if denied, everything else
  still works.
- Posted for: corrections (F7 rule 1) — with an **Undo** action button;
  last-resort use (F5, once per episode); loop protection (F9); failures
  (F10).
- Optional (setting, default off): notify on every switch.
- A single setting can turn all notifications off.
- Notification text is short: one line saying what happened, naming the
  devices.

---

## 5. Menu bar

### F15 — Menu bar item
- Prio lives only in the menu bar (no Dock icon, no main window).
- Icon: an original monochrome template glyph that adapts to light/dark menu
  bars (implementer designs it or uses a suitable SF Symbol; must not imitate
  any other product's icon). It shows a distinct "muted" variant when the
  current default input device is muted, and a distinct "paused" variant when
  automatic switching is off.

### F16 — Menu contents (top to bottom)
1. **Automatic switching** toggle (F11).
2. **Input** section: current input device (name + type glyph). Clicking it
   expands the full input list in priority order beneath it; clicking a device
   makes it the manual pick (F6). Only one section (input or output) is
   expanded at a time; long lists scroll. Each row shows: rank number, name,
   active checkmark, manual-pick badge, "avoided" marker. Disconnected devices
   are not shown in the menu.
3. **Output** section: same as input.
4. **Last action** line (F13) with an **Undo** button when available.
5. **Settings…** (⌘,), **Quit Prio** (⌘Q).
- Truncated device names show the full name in a tooltip.
- Picking a device must not cause rows to jump under the pointer (keep order
  stable while the menu is open).
- The menu reflects device changes live while open.

---

## 6. Settings window

Standard macOS settings window with tabs **Devices** and **General**.

### F17 — Devices tab
- A segmented control switches between Input and Output lists.
- Each row: rank number, device type glyph, device name (full name on hover),
  transport label (Built-in, USB, Bluetooth, HDMI/DisplayPort, Thunderbolt,
  AirPlay, Virtual, Aggregate, Other), status (In use / Connected / Not
  connected), and an "Use automatically" checkbox — unchecking it marks the
  device **avoided** for that direction (with a tooltip explaining last-resort
  use).
- Reorder by drag and drop. Dropping gives light haptic feedback on Force
  Touch trackpads.
- Reorder by keyboard: select a row and use ⌥⌘↑ / ⌥⌘↓, plus "Move Up / Move
  Down / Move to Top" in the row's context menu.
- Context menu on disconnected rows: "Forget Device" (F2).
- Edits apply immediately (no Save button) and trigger re-evaluation (F4).
- Two devices with the same name are disambiguated in the UI (e.g. "Name (2)").

### F18 — General tab
- Automatic switching (mirrors the menu toggle).
- Launch at login (uses the modern macOS login-item mechanism; reflects the
  real system state, including if the user disables it in System Settings).
- Notifications: on/off; "Notify on every switch".
- Respect output changes made outside Prio (default on), respect input
  changes made outside Prio (default off) — with one-line explanations (F7).
- "Bluetooth headphones keep connecting to this Mac?" helper: one sentence
  explaining that the auto-connect behaviour is a per-device Bluetooth setting
  in macOS, and a button that opens System Settings › Bluetooth.
- "Copy Diagnostics" (F19).
- App name, version, MIT license notice, source code link text (no network
  calls are made by showing it; clicking opens the default browser).

### F19 — Diagnostics
- Shows a preview sheet of a plain-text report, then copies it to the
  clipboard on confirmation. Nothing is ever sent anywhere by Prio.
- Contents: Prio version, macOS version, CPU architecture, settings values,
  both ranked lists with transport type, connected/avoided state, current
  defaults, manual picks, loop-protection state, and the last ~20 actions.
- Device names are replaced by "Input 1", "Output 3" etc. unless the user
  ticks "Include device names" in the preview.

---

## 7. Persistence
- Stored locally per macOS user: both ranked lists (identity, last known
  name, transport, avoided flag), settings, automatic-switching state.
- Survives relaunch and upgrade. Corrupt or missing storage → start fresh with
  seeding (F2) without crashing.
- No account, no cloud sync.

---

## 8. Limitations (document in README; do not try to solve)
- Apps that pin a specific device (conferencing apps, DAWs) bypass the system
  default; the user must set them to "Default"/"Same as System".
- Prio does not repair Bluetooth connections, change codecs, or improve mic
  quality.
- Some USB devices change identity when moved to another port; they then
  appear as a new device.
- macOS cannot disable display speakers; avoiding them is the workaround.
- No guarantee of uninterrupted calls.

---

## 9. macOS & product requirements
- **R1** macOS 13 Ventura or later. Universal binary (Apple silicon + Intel)
  when the toolchain allows; at minimum the native architecture.
- **R2** Never opens an audio input or output stream. Requests no microphone
  permission; the app bundle must not contain a microphone usage description.
- **R3** Zero network code: no telemetry, analytics, crash reporting, update
  checks, licensing, trial, or accounts. Opening a URL in the user's browser
  on explicit click is allowed.
- **R4** Menu bar agent app (no Dock icon).
- **R5** Free, MIT licensed, no keys, no subscriptions.
- **R6** Builds from source with one command on a Mac with only the Xcode
  Command Line Tools installed (no full Xcode required), producing a runnable
  `.app` bundle (ad-hoc signed).
- **R7** The decision logic (F2a, F3, F5–F11, F13 state) is isolated from the
  OS audio APIs and covered by automated tests using a simulated device
  system and an injected clock.
- **R8** Light and dark appearance, system font, accessible (see design
  requirements in the agent brief / README).
- **R9** Low idle CPU: event-driven, no polling loops.

## 10. Out of scope (intentionally omitted)
- Trial, license activation, payments, multi-Mac seat management.
- Telemetry / anonymous measurements.
- In-app auto-updater (users update by rebuilding or downloading a release).
- Per-app audio routing, volume mixer, effects.
- Bluetooth repair / codec control.
- Managing the separate "alert sounds" output device.
