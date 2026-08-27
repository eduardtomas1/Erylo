<div align="center">

# Erylo

**A calm, useful extension of your MacBook's notch.**

Erylo keeps a Focus Timer close to the top edge and out of the way. Meetings,
music, battery, volume, and file handoffs are planned next.

macOS 14+ · Apple Silicon first · Native Swift · Open source

<img src="docs/images/erylo-timer-expanded.png" width="740" alt="Erylo expanded from the MacBook notch with a focus timer, progress, and cancel action">

<sub>A real Focus Timer running in Erylo's native notch-attached window.</sub>

</div>

## The notch, made useful

Erylo rests as a slim black silhouette joined to the camera area. A click or the
keyboard shortcut opens just enough room for the current activity, then it
settles back into the top edge when you are done.

<p align="center">
  <img src="docs/images/erylo-timer-compact.png" width="500" alt="Erylo's compact timer state wrapping the MacBook notch">
</p>

- **Quiet by default.** No floating card, no permanent dashboard, and no idle
  animation demanding attention.
- **Useful at a glance.** The compact state keeps the essential signal visible;
  the expanded state adds context, progress, and the action that matters.
- **Built for real interruptions.** Activities are ordered, deduplicated, and
  handed off without turning the notch into a notification pile.
- **Motion with purpose.** Expansion uses a restrained spring and follows the
  Mac's Reduce Motion preference.

## Available now

| Utility | What it brings to the notch |
| --- | --- |
| **Focus Timer** | Start a 15, 25, or 50 minute session from the Erylo menu, follow live progress, and cancel from either the notch or menu. |

## Planned utilities

These ideas shape Erylo, but they are not connected to the app yet and do not
run in the background.

| Utility | What it could bring to the notch |
| --- | --- |
| **Now Playing** | Apple Music and Spotify status with playback, seek, and volume capabilities. |
| **Meetings** | A quiet calendar cue when an upcoming meeting becomes relevant. |
| **Battery & charging** | Low-battery awareness and short, useful charging updates. |
| **Volume** | A brief acknowledgement of output level and mute changes. |
| **File Hold** | A safe temporary home for a file you want to keep close while changing tasks. |
| **External activities** | A local way for trusted tools to show and dismiss their own progress. |

## Designed to feel native

Erylo uses public macOS APIs and stays a non-activating accessory, so opening it
does not pull focus away from your work. It adapts to notched and non-notched
displays, supports multiple displays, and can be revealed with
`Control–Option–Command–E`.

The project is local-first: no analytics SDK, no automatic diagnostics upload,
no media history, and no background polling just to keep the surface alive.
Features ask for access only in the context where it is needed.

## Try the Focus Timer

You need macOS 14 or newer and Swift 6 Command Line Tools.

```sh
git clone https://github.com/eduardtomas1/Erylo.git
cd Erylo
swift run Erylo
```

Use Erylo's menu-bar item to start a Focus Timer, cancel it, show or hide the
surface, reopen Settings, or quit. Erylo does not publish a signed end-user
download yet.

<details>
<summary><strong>Building or contributing?</strong></summary>

Start with the [development guide](docs/DEVELOPMENT.md). The
[architecture notes](docs/FOUNDATION.md),
[compatibility matrix](docs/COMPATIBILITY_MATRIX.md), and
[release runbook](docs/RELEASE_RUNBOOK.md) document the deeper engineering and
remaining hardware and signing gates. Contributions are covered by
[CONTRIBUTING.md](CONTRIBUTING.md).

</details>

---

Erylo is available under the [Apache License 2.0](LICENSE).
