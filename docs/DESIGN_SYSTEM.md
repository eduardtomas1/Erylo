# Erylo product design system

This document is a binding implementation contract for the production surface.
Native macOS conventions are the quality floor; Erylo's identity is the quiet
signal surface at the top edge of the display.

## Product posture

- Show one useful value or action, then disappear.
- Compact states communicate; expanded states exist only when they add detail
  or a real action.
- The physical notch is an attachment point, not a reason to imitate iPhone UI.
- Unavailable utilities and controls are absent from production UI.
- Every visible affordance must work. Never mount placeholder drag targets,
  disabled roadmap modules, or controls whose preference is not applied.

## Signature device

Every activity owns one semantic accent and may project it into a thin signal
line along the lower edge of the surface. The line appears only for validated
scalar or timestamp progress; it is not decoration and never animates while idle.

- Physical-notch silhouette: opaque black so it remains continuous with the
  camera housing.
- Notchless display: system HUD material with a subtle semantic stroke and
  shadow. Do not render a floating pure-black slab.
- Use one accent per activity. Destructive color is reserved for destructive
  controls and actionable failures.
- Use semantic/adaptive system colors outside the physical-notch silhouette.

The product mark is the same top-edge surface silhouette in the status menu and
first-run UI. It is drawn from shared vector geometry in code, uses the current
system tint, and never falls back to an unrelated activity or medical symbol.

## Typography

- Settings, onboarding, menus, and ordinary copy use semantic system text styles
  and must remain usable with the user's text-size and accessibility settings.
- The compact top-edge HUD has a fixed physical envelope. Its hero values may
  use reviewed fixed point sizes to preserve geometry; do not claim full Dynamic
  Type scaling for that surface. Provide a complete VoiceOver value, protect
  essential digits from truncation, and verify the largest supported system
  accessibility configuration instead.
- Use `monospacedDigit()` only for changing numeric values.
- Do not use monospaced text for prose, filenames, device names, or status copy.
- Do not use tracked uppercase category labels in activity layouts.
- The most useful datum is the visual hero: remaining time for Timer, level for
  Volume, percentage for Battery, and file previews for File Hold.

## Activity compositions

The shell owns geometry, clipping, hit testing, motion policy, and accessibility.
Each activity declares which compact, Peek, or Expanded compositions add value.
Do not force every activity through a symbol-title-detail-progress-card template.

### Focus Timer

- Compact: timer symbol, live remaining time, and progress signal.
- Hover does not create a larger copy of the same countdown.
- Expanded: 42–48 pt remaining time, quiet "Focus" context, progress signal,
  and one secondary Cancel action.
- Completion: concise acknowledgement with a routed Done dismissal and a named
  VoiceOver dismiss action; disappear automatically when untouched.
- Persist only the immutable session identity and absolute start/end dates.
  Relaunch restores the same deadline; quit never manufactures a new duration.

### Volume

- Compact only: speaker state, direct level meter, and value when relevant.
- Output changes may show the bounded device name as secondary text.
- Volume acknowledgements never enter Peek or Expanded.
- Passive acknowledgements remain click-through and have no hover affordance.
- Never show generic category and event labels such as "VOLUME / Output changed".

### Battery

- Ordinary readings stay hidden.
- Charging and low-battery events show the percentage as the primary datum.
- Power acknowledgements never enter Peek or Expanded.
- Persistent low-battery state must remain calm and must not animate repeatedly.
- Power acknowledgements remain click-through and never impersonate a control.

### File Hold

- The surface must accept the drop before presenting a drop affordance.
- Show actual file thumbnails/names, ownership mode, expiry, and failures.
- The minimum complete loop is drop, explicit copy/reference semantics, drag out,
  quit/relaunch persistence, remove, and expiry.

## Motion

- Preserve the identity and position of useful values between compact and
  expanded states; avoid whole-surface replacement fades.
- Shape opening uses a restrained, interruptible 220 ms smooth curve with no
  extra bounce. Content settles only after geometry begins its transition.
- Order a new window while its rendered state is Hidden, then commit Compact
  after one 60 Hz display frame. Render Hidden before delayed physical order-out.
- Crossfade identity handoffs briefly when geometry is unchanged; do not flash
  through Hidden between valid activities.
- Countdown digits use a numeric content transition where supported.
- Hover entry waits 120 ms; exit uses a 300 ms corridor delay.
- Reduce Motion updates geometry immediately and disables scale, numeric motion,
  blur, and hover emphasis; it never substitutes another spatial effect.
- No display link, repeating visual timer, or perpetual animation is permitted
  while the surface is hidden or idle.

## Interaction and accessibility

- The AppKit hit region must update in the same transaction as every visual
  geometry change, including content changes that keep the same presentation
  state.
- Controls revealed by a growing surface keep their layout space but remain
  invisible, inert, and absent from accessibility until the exact AppKit hit
  region settles. Reduce Motion settles that region immediately.
- Hover and automatic HUD arrival never activate the app. Control-free Compact
  and Peek remain non-key. Compact/Peek with a real launcher or acknowledgement
  action are key-eligible only after a deliberate shortcut or direct control
  interaction; automatic completion never requests focus. Pointer-driven
  expansion stays nonactivating. A deliberate `Control-Command-E` route waits
  for geometry and hit testing to settle before making a control-bearing panel
  key.
- Expanded alone owns paired local/global mouse-down monitors. A click outside
  its current exact AppKit hit region collapses it; inside clicks pass through
  unchanged to the intended action. The monitors are removed on every collapse,
  hide, close, and release. There is no global keyboard monitor or Accessibility
  permission dependency.
- Click toggles expansion. Escape collapses only while Expanded owns key
  interaction.
- Hover enters Peek only when a standard activity adds distinct detail. A click
  expands only when the destination adds detail, queue context, or a real action.
  Passive system acknowledgements ignore both transitions. Escape and outside
  click collapse expanded content.
- Replacing the exact expanded activity revision collapses to compact; removing
  it hides the surface. Broker updates cannot strand an empty Expanded panel or
  cancel an already pending hover exit.
- Ordering a panel out, sleeping, or changing Spaces retires Peek/Expanded before
  any later presentation. A still-valid activity returns only as Compact.
- Expose explicit accessibility expand, collapse, dismiss, and primary actions.
- Live numeric accessibility values must derive from the same temporal projection
  as the visible value. Timestamp-backed timers use one visible-only Timeline
  snapshot for digits, progress, and the root VoiceOver value; visual descendants
  do not publish a second stale timer label.
- A notched completion Peek reserves at least 40 points below the camera housing,
  keeping the real Done target visible and reachable.

## Settings

- Use native macOS sections, controls, materials, and window behavior.
- Show only production capabilities. Roadmap items belong in documentation.
- First run is a focused welcome surface, not the full settings form. It explains
  the three shipping promises and offers one useful, permission-free primary
  action: start a 25-minute Focus Timer. A secondary Continue to Settings path
  must remain equally clear; completing setup never requires starting work.
- Focus Timer presets live in one native submenu. Idle menus omit Cancel and
  active menus put remaining time in the submenu title. Instructional shortcut
  reminders do not occupy disabled menu rows.
- Permission and diagnostic copy must describe behavior that exists in the build.

## Review gates

- Verify screenshots on notched and notchless displays in light and dark desktop
  contexts, plus onboarding and the populated Settings form in both appearances;
  the surface itself may remain black only where physically attached.
- Record compact-to-expanded and interruption behavior at 60 Hz and 120 Hz.
- Test exact hit regions, hover hysteresis, Escape, outside click, keyboard,
  VoiceOver, Reduce Motion, fullscreen, Spaces, dock/undock, and sleep/wake.
- A visual change is incomplete until its deterministic render and accessibility
  contract are covered by the surface harness.
