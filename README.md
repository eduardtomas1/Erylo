<div align="center">

# Erylo

### Your focus, one glance away.

Erylo turns the quiet space around your MacBook's notch into a useful part of
your day—present when it matters, invisible when it does not.

<p>
  <img alt="macOS 14 or newer" src="https://img.shields.io/badge/macOS-14%2B-111111?style=flat-square&logo=apple&logoColor=white">
  <img alt="Native Swift 6" src="https://img.shields.io/badge/Swift-6-F6A23C?style=flat-square&logo=swift&logoColor=white">
  <img alt="Local first" src="https://img.shields.io/badge/local--first-no%20analytics-2E8B74?style=flat-square">
  <img alt="Apache 2.0 license" src="https://img.shields.io/badge/license-Apache%202.0-5D88E5?style=flat-square">
</p>

<img src="docs/images/erylo-timer-expanded.png" width="756" alt="Erylo extending from the MacBook notch with a live Focus Timer, progress, and cancel action">

<sub>The real Focus Timer running in Erylo's native notch-attached surface.</sub>

</div>

---

## A timer should not need another window

Deliberately open idle Erylo and choose a 15, 25, or 50 minute Focus Timer from
the compact launcher, or use the same presets in the Erylo menu. Its progress
lives at the top edge of the display, where it can be checked without opening
an app, moving a window, or breaking concentration.

When you want more detail, reveal Erylo with a click or
<kbd>Control</kbd> + <kbd>Option</kbd> + <kbd>Command</kbd> + <kbd>E</kbd>.
Cancel from the expanded surface or directly from the menu. When the session
ends, Erylo briefly opens a readable **Focus complete** acknowledgement, then
disappears.

<p align="center">
  <img src="docs/images/erylo-timer-launcher.png" width="560" alt="Erylo's compact native Focus Timer launcher with 15, 25, and 50 minute presets below MacBook notch geometry">
</p>

<p align="center">
  <img src="docs/images/erylo-timer-compact.png" width="496" alt="Erylo's compact live timer state wrapping the MacBook notch">
  <br>
  <sub>Compact enough to glance at. Quiet enough to forget about.</sub>
</p>

## One small rhythm

<table>
  <tr>
    <td width="33%" valign="top">
      <strong>1 · Start</strong><br><br>
      Choose a focus length from the compact native launcher or Erylo menu.
      Starting again cleanly replaces the current session.
    </td>
    <td width="33%" valign="top">
      <strong>2 · Glance</strong><br><br>
      See the remaining time and live progress in a slim silhouette joined to
      the notch—not in a floating dashboard.
    </td>
    <td width="33%" valign="top">
      <strong>3 · Act</strong><br><br>
      Open Erylo when you need context, cancel from the notch or menu, then let
      the surface settle away.
    </td>
  </tr>
</table>

## Why Erylo feels different

<table>
  <tr>
    <td width="50%" valign="top">
      <strong>Attached, not overlaid</strong><br>
      The shape grows from the top edge and visually belongs to the notch. It is
      not a card hovering below it.
    </td>
    <td width="50%" valign="top">
      <strong>Calm by default</strong><br>
      No idle animation, permanent dashboard, or hover-triggered opening. Erylo
      waits for deliberate interaction.
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <strong>Useful without stealing focus</strong><br>
      The activity surface is non-activating and supports a global shortcut,
      menu commands, and VoiceOver-friendly actions.
    </td>
    <td width="50%" valign="top">
      <strong>Designed for the whole Mac</strong><br>
      Erylo is built for notched and non-notched displays, multiple displays,
      Spaces, sleep, wake, and the system's Reduce Motion setting. The complete
      hardware matrix remains a release gate.
    </td>
  </tr>
</table>

> **Local first, by design.** Erylo has no analytics SDK, automatic diagnostics
> upload, media history, or background polling just to keep the surface alive.
> Browsing Settings starts no utility, permission request, socket, file access,
> media automation, or network work.

## Available today

### Focus Timer

- Start a **15, 25, or 50 minute** session from the idle notch launcher or Erylo menu.
- Follow useful `MM:SS` or `H:MM:SS` remaining time and live progress from the compact notch surface.
- Expand for context and a clear **Cancel timer** action.
- Cancel from the menu when keyboard or VoiceOver navigation is preferable.
- Replace a running session safely by starting another preset.
- Let a short **Focus complete** acknowledgement disappear without leaving timer work or ownership behind.

### Battery and charging

- Enable it explicitly in Settings; persisted enablement restores at app startup
  without a permission prompt.
- Keep an ordinary first reading quiet, briefly acknowledge later power changes,
  and retain an ambient warning only while an unplugged battery is at or below 20%.
- Use local IOPowerSources notifications with no polling or network work.

### Volume

- Enable it explicitly in Settings; it needs no permission or network access.
- Treat the current default-output state at enable/restore as a quiet baseline,
  then briefly acknowledge later volume, mute, and output-device changes.
- Use CoreAudio property listeners and cancellable 1.8-second presentations, not
  polling or a permanent HUD.

These are the complete live utilities today. The screenshots above show the real
Focus Timer; Battery and Volume still require the manual hardware validation
listed in the compatibility matrix before a signed release.

## What Erylo is growing into

The activity foundation already anticipates more small, time-sensitive moments.
These utilities are planned, but they are **not connected to the app and do not
run in the background**:

| Next utility | The moment it should simplify |
| --- | --- |
| **Now Playing** | See and control Apple Music or Spotify without leaving the current task. |
| **Meetings** | Notice an upcoming meeting only when it becomes relevant. |
| **File Hold** | Keep one file close while moving between tasks. |
| **External activities** | Let trusted local tools show and dismiss their own progress. |

## Run Erylo

Erylo currently ships source-first. You need macOS 14 or newer and Swift 6
Command Line Tools.

```sh
git clone https://github.com/eduardtomas1/Erylo.git
cd Erylo
swift run Erylo
```

Look for **Erylo** in the menu bar. From there you can start or cancel a Focus
Timer, show or hide the surface, open Settings to enable Battery or Volume, check
for updates when a signed feed is configured, or quit cleanly.

> Erylo does not publish a signed end-user download yet. The release pipeline is
> in place, but real Developer ID signing, notarization, and update publication
> remain explicit release gates.

<details>
<summary><strong>Building, testing, or contributing?</strong></summary>

The product README stays intentionally human. The deeper material lives here:

- [Development guide](docs/DEVELOPMENT.md)
- [Architecture notes](docs/FOUNDATION.md)
- [Glance provider lifecycle](docs/GLANCE_LIFECYCLE.md)
- [Compatibility and hardware gates](docs/COMPATIBILITY_MATRIX.md)
- [Release runbook](docs/RELEASE_RUNBOOK.md)
- [Contribution guide](CONTRIBUTING.md)
- [Security policy](SECURITY.md)

</details>

---

<div align="center">

**Glance. Act. Disappear.**

Erylo is open source under the [Apache License 2.0](LICENSE).

</div>
