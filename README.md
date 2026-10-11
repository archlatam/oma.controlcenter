# Control Panel (`oma.controlpanel`)

A Dank-Material-style **control center** for the Omarchy bar: a popup anchored
to its bar button with a grid of quick toggles and sliders, so the things you
reach for most often are one click away instead of spread across the individual
audio / network / bluetooth / power panels.

## What's in the panel

| Section | Control |
|---------|---------|
| Quick | **Network** — connected network, Wi-Fi radio toggle when a Wi-Fi card is present; click the tile body to open the [Network detail page](#network-detail-page) |
| Quick | **Bluetooth** — adapter on/off, connected-device count; click the tile body to open the [Bluetooth detail page](#bluetooth-detail-page) |
| Quick | **Night Light** — on/off |
| Quick | **Do Not Disturb** — on/off |
| Audio | Output volume slider + right-click to mute |
| Display | Brightness slider |
| Power | Battery level/state + AC/Battery power profile (when available) |

The panel refreshes its polled state (connection name, brightness, night light,
DND, power profile) when it opens and every 4 seconds while it is open. Live
state (Wi-Fi enabled, Bluetooth, audio volume, battery) comes straight from
Quickshell services and needs no polling.

### Network detail page

Clicking the body of the **Network** tile (the switch, when present, still
toggles Wi-Fi) opens a detail page inside the same popup, with a back button or
`Esc` to return:

| Row | Source |
|-----|--------|
| Connection | `omarchy-network-status` |
| IP address + gateway | `omarchy-network-status --verbose` |
| Latency | `internet_ping_ms` |
| Link speed | negotiated link rate |
| **Speed test** | `omarchy-network-speedtest down\|up` |

The **Run speed test** button measures download for a few seconds, then upload,
showing live Mbps (the same engine the built-in `omarchy.speedtest` uses). It
runs on demand and stops automatically when you leave the page or close the
panel, so it never saturates the link in the background.

### Bluetooth detail page

Clicking the body of the **Bluetooth** tile (the switch, when present, still
toggles the adapter) opens its detail page, with a back button or `Esc` to
return:

- An **adapter** row: icon, on/off state and the same switch as the tile.
- **Connected** devices: click a row to disconnect.
- **Paired** devices: click a row to connect.
- **Available** devices (discovered while the page is open): click to pair.
- Battery percentage is shown for connected devices that report one.

Left-click acts on a device; **right-click forgets** a connected or paired one.
Only devices with a real name are listed — BlueZ often exposes entries whose
name is just a UUID or the raw address, and those are hidden. Scanning starts
when the page opens and stops when you leave it or close the panel, so the
radio is not held scanning in the background. Actions go through
`omarchy-bluetooth-device`, matching the built-in Bluetooth panel.


## Install (manual)

```bash
mkdir -p ~/.config/omarchy/plugins
cp -r oma.controlpanel ~/.config/omarchy/plugins/
omarchy-shell shell rescanPlugins
omarchy plugin enable oma.controlpanel
```

Add it to the bar and place it (the manifest asks for the right section by
default):

```bash
omarchy bar move oma.controlpanel --section right
```

Open it from the bar button (glyph 󰕮), or bind a key to the IPC route:

```bash
omarchy-shell oma.controlpanel toggle
```

## Dependencies

Only standard Omarchy tooling, all present on a stock install:

- `omarchy-network-status`
- `omarchy-network-speedtest` (for the Network detail page's speed test)
- `omarchy-bluetooth-power`
- `omarchy-bluetooth-device` (connect / disconnect / pair / forget)
- `omarchy-toggle-nightlight`
- `omarchy-brightness-display`
- `omarchy-shell notifications` (DND state / toggle)
- `powerprofilesctl` (optional; the Power section hides the profile picker if absent)

Plus Quickshell services: `Networking`, `Bluetooth`, `Services.Pipewire`,
`Services.UPower`.

## Notes

- **Wi-Fi toggle** only appears when a Wi-Fi device exists. On wired-only
  machines the Network tile shows the connection and hides the switch.
- **Brightness** reads and writes through `omarchy brightness display`, so it
  follows the focused display exactly like the brightness keys do.
- **Battery / power profile** rows appear only when the hardware reports a
  battery and `powerprofilesctl` answers.

## License

MIT — see [LICENSE](LICENSE).
