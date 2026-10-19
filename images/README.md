# Public images

Every picture of the app here is a **real render of the app's own views and drawing code**, made offscreen by the
built app. Nothing is drawn by hand or imitated in HTML. The composites only arrange those renders: rounded outer
corners, a thin edge, a soft shadow, a gradient behind them, and captions in SF Pro. The UI pixels are not edited.

## How to reproduce

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate
xcodebuild -scheme Battery -configuration Debug SYMROOT="$(pwd)/build/sym" build
build/sym/Debug/Battery.app/Contents/MacOS/Battery --render-showcase build/showcase   # renders only; nothing goes on screen
python3 scripts/public-images.py build/showcase images                      # composites + copies
```

`--render-showcase` is in `app/App/RenderHarness/RenderShowcase.swift`. It uses the same offscreen path as the
clip gate (`--render-pages`) but is not part of the gate. Fixture data comes from
`app/App/RenderHarness/RenderFixtures.swift` and `RenderPortFixtures.swift`. The data shows the made-up moment
13:21 on 2026-09-09: 64% on battery, an 80% charge limit with four scheduled changes, and so on.

The composite step needs Python 3 with Pillow (built and checked with Pillow 12.0.0). Captions use SF Pro
(`/System/Library/Fonts/SFNS.ttf`), and fall back to Helvetica Neue if SF Pro is missing.

## The images

| File | Size (px) | What it shows | Source |
|---|---|---|---|
| `hero.png` | 2560 × 1360 | Day, Now and Automation side by side on a dark gradient. The Now popover is raised in the middle. All three come from the one `.showcase` fixture, so their figures agree. | `popover-day`, `popover-now`, `popover-automation` (below) |
| `social-card-1200x675.png` | 1200 × 675 | Card for an X post: the app icon, "Battery", one line of text, and the Now popover at 0.68× running off the bottom edge | `tab-now.png` (the same `.showcase` render as `popover-now.png`) scaled 0.68×, the shipped icon at 112 px |
| `tab-gallery.png` | 2464 × 2540 | All six tabs in rail order, three across and two down, each with its name underneath. All six come from the `.showcase` fixture, so their figures agree; the Devices tile is the wireless-only page | `popover-now`, `-day`, `-energy`, `-health`, `-devices-wireless`, `-automation` |
| `popover-now.png` | 720 × 1050 | Now: the charge ring, time, draw, limit, today's battery and power split, who used the energy, the limit and energy controls, and the health line | `.showcase` fixture |
| `popover-day.png` | 720 × 1050 | Day: the 24-hour battery-level chart with draw and on-power bands, and the last 7 days | `.showcase` |
| `popover-energy.png` | 720 × 1050 | Energy: apps ranked by energy use, power now, and what is keeping the Mac awake | `.showcase` |
| `popover-health.png` | 720 × 1050 | Health: capacity, cycles, hours at the limit and at 100%, lifetime figures, and a capacity chart | `.showcase` |
| `popover-devices.png` | 720 × 1050 | Devices on battery: wireless batteries, "Powered by this Mac" (14.7 W from battery, plus the cost line "≈ 23% of your battery per hour — 1 h 31 m left with them, ≈ 3 h 13 m without", which agrees with Now's 1 h 31 m) and the power adapter | `.showcasePowered` fixture |
| `popover-devices-on-power.png` | 720 × 1050 | The same page on power: a 65 W adapter and "Your Mac charges ≈ 15 W slower" | gated `powered-on-power` fixture |
| `popover-devices-wireless.png` | 720 × 1050 | Devices with only wireless devices (nothing on a cable) | `.showcase` |
| `popover-automation.png` | 720 × 1050 | Automation: today's timeline, the charge schedule plus sleep and wake, and other automations | `.showcase` |
| `menubar-states.png` | 1488 × 1158 | The menu-bar item in eight states, on a light and a dark menu bar, at 4× | the `menubar/` renders scaled to ½ |
| `menubar/glyph-<state>-<light\|dark>.png` | about 632–744 × 192 | One menu-bar item per state at 8× (24 pt tall), copied unchanged: on-battery, charging, charged (full, on power), limit-hold, plugged-but-losing (orange bolt), keep-awake (espresso cup), low (red), low-power-mode (yellow) | `MenuBarBatteryIcon.image` + the title |
| `plug-in-notice.png` | 591 × 112 | The plug-in notice that appears when a device starts drawing power from the Mac ("iPhone · Drawing 9.2 W · ≈ 15% of battery per hour"), on a transparent background | `HUDPillView` |
| `app-icon-1024.png` | 1024 × 1024 | The app icon as shipped | `app/Assets.xcassets/AppIcon.appiconset/icon_1024.png`, copied byte for byte |

Popover renders are at 2× (360 × 525 pt). The 30 PNGs come to 3,151,895 bytes (about 3.2 MB).

## Fixtures

- **`.showcase`** is the gated `parity` fixture with two differences. First, read-back is verified: the Get
  shortcut is listed and returns 80, so setup is `.ready` and the harness runs the popover-open read-back. The `parity` state
  is `.readyDegraded`, which shows the "Read-back is off" banner across the top of Now. Second, `.showcase`
  gets its own calmer history. Today follows the rules that fired: the Mac wakes at 06:45 (the scheduled wake),
  on power and held at its 80% limit, charges toward 100 from 07:31 (the 07:30 rule) to 86% when it is unplugged
  at 08:13, runs down to 41% by 11:02, charges back under the 100 limit and then the 90 limit (the 12:00 rule)
  until the manual set to 80 at 12:21 stops it at 80%, and is at 64% now (1 h 31 m left). Now's today line reads
  "3 h 50 m on battery · 2 h 46 m on power", "38 Wh out 30 Wh in" and "low 41% at 11:02"; Day's 24-hour chart
  and Automation's "06:45 wake" agree with it. Earlier days dip to 29–45%, and no day in the 14-day window falls
  below 20%. The Mac sat at its 80% limit on the older days, with one afternoon at 100% (Sep 2, 14:00–20:00, then
  unplugged; Health shows "At 100% 6 h" in yellow, its colour for any hours at 100%). That afternoon is the last
  full charge, so Health reads "Last full charge Sep 2", outside the 24-hour chart. Capacity eases from about
  88.5% in June to 87% now. The showcase's Devices pages (`popover-devices.png`, `popover-devices-wireless.png`)
  read "as of 13:21", like the rest; `popover-devices-on-power.png` comes from the gated `powered-on-power`
  fixture and reads "as of 13:20". The gated
  fixtures keep the mockups' day, which bottoms out at 1% at 06:52. `.showcase` is not a gate variant: it has no
  `variants` entry and no expected-table row, so `--render-pages` never renders it.
- **Apps in the energy list.** Safari, Photos, Mail, python3 (Terminal's icon) and Music all ship with
  every Mac. The icons are read from `/System/Applications`, plus `/Applications/Safari.app`, which is the system's
  own link into the Safari cryptex and is resolved before the icon is read. So the renders show no third-party
  logos and reproduce on a clean Mac, with one caveat: the icons come from `NSWorkspace` at render time and follow
  that Mac's icon style, so they can look different from one Mac (or one day) to the next. The committed images
  were rendered on 2026-10-18 and show Music as a white tile with a black note; earlier renders on the same Mac,
  with `/System/Applications/Music.app` unchanged, showed it red. AppKit offers no public way to ask for the
  default (unstyled) variant (the bundle's own `AppIcon.icns` is the white tile too), so the render keeps whatever
  the Mac draws. Under "Keeping the Mac awake" the page shows two holders, each as process name,
  pid and how long it has held: `caffeinate` (pid 843, 5 d 22 h) and a generic developer job, `node` (pid 1207,
  2 h 10 m), both marked "system". The fixture names the node job "npm run build", but the page does not show it.
- **`.showcasePowered`** (Devices) is `.showcase` with the gated `powered-on-battery` fixture's devices on
  cables (iPhone 9.2 W, T7 Shield 4.5 W, Magic Keyboard 1.0 W). Its reading shows Now's 64% and 91 minutes to
  empty. The pack's remaining charge is set to 3,641 mAh, a figure chosen so that the cost line's own math (mAh
  at the nominal voltage ÷ the draw: 3,641 mAh × 11.58 V ÷ 27.8 W ≈ 91 min) lands on Now's 91 minutes and reads
  "1 h 31 m left with them". It is not 64% of the 5,435 mAh capacity (that would be about 3,480 mAh). Like `.showcase` it is
  not a gate variant. The gated `powered-on-battery` pair is unchanged. `popover-devices-on-power.png` still comes
  from the gated `powered-on-power` fixture.
- **Health "Low days 0/14", "Deepest none".** The showcase's calmer history has no day below 20% in the 14-day
  window, so Low days reads "0/14" (low days / days with readings) and Deepest reads "none" — a measured answer,
  not the page's "—" for "not read". The gated `parity` fixture keeps the mockups' days and reads "12/14", 1%.
- **No history note on Health.** The showcase's history files all read and write cleanly, so the one-line note
  that appears under the Health figures when history needs attention is not shown. The gated `history-note`
  fixture renders it.

## Known differences from the live app

- **Dimmed native controls.** The offscreen window is never key, so AppKit draws native controls in their inactive
  style. This affects the "Now / Sustained" switch on Energy and the grey track of the "Schedule" switch on
  Automation. On screen they show the active colours.
- **Menu-bar item layout.** The glyph and the "NN%" title are the app's own output, set exactly as
  `updateStatusButton` sets them. They are laid out by a plain `NSButton` with `.imageTrailing`, because the real
  status-bar button can't be rendered offscreen. Its template tint is set to the title colour. The strip behind
  each item is a plain menu-bar colour (#ececee light, #1e1e20 dark), not a capture of a real menu bar.
- **Plug-in notice background.** The notice's background is `.regularMaterial`, a translucent blur over whatever
  sits behind it. Offscreen there is nothing behind it, so the material renders as a solid dark grey (#232323). On
  screen it is translucent.
- **Popover background.** The popover's background material belongs to `NSPopover`, so the harness paints it
  solid #2a2c31. Rounding the corners is the only change the composites make to it.
