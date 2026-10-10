# EnviousCooler

**Smart Razer cooling pad control for Mac, by Envious Labs.**

Free and open source under the [MIT license](LICENSE).

Local menu-bar app, dashboard and automatic cooling for the Razer Laptop Cooling Pad (`1532:0f43`). No cloud connection or third-party driver is required.

Open **EnviousCooler** in `~/Applications`, or use the fan icon in the menu bar. The dashboard shows Mac chip temperature, requested fan speed, automatic-mode status and RGB brightness. Closing the dashboard or quitting the menu app leaves automatic cooling running. Both start at login when enabled.

## Controls

Automatic cooling uses the hottest identified Mac chip sensor. On this M5 Max that includes 42 `PMU tdie` readings; they are not separately labelled CPU/GPU core temperatures. Readings outside the valid range or with old reported timestamps are rejected.

Curve: 45 °C → 800 RPM, 55 °C → 1,000, 65 °C → 1,400, 75 °C → 2,200, 85 °C → 3,200. Targets interpolate, then round to 50 RPM steps. Ten-second smoothing and a 100 RPM deadband reduce chatter. Rise is limited to 100 RPM/second. Fall waits twenty seconds, then decreases at up to 50 RPM/second. At 95 °C or critical thermal pressure, maximum cooling is requested immediately.

Normal controls never request below 800 RPM. The original 500 RPM curve coincided with red-light cycling; the user reported stability after stopping it and later with the revised curve. The exact failure threshold and red-light USB signal remain unconfirmed.

The RGB slider changes brightness from 0 to 100% and keeps the current effect. The device setting is read back before success is shown. While automatic cooling runs, lighting commands go through that same controller and do not pause cooling. Manual presets pause automatic cooling.

USB loss is handled through a removal callback and retries. Sensor failure requests maximum cooling where reachable. Sleep requests fan off; wake resets sensor history. Cancelled sleep and a missed wake notification also have recovery paths. Stopping automatic cooling requests 1,500 RPM while awake and reports whether restoration was acknowledged.

## Build and install

Requires an Apple Silicon Mac running macOS 14 or later, Python 3.9 or later, and Xcode Command Line Tools (`xcode-select --install`). Tested on an M5 Max with pad firmware 1.10; other Mac models are not yet physically verified. This is currently a source installation, with a locally signed app rather than a notarized download.

```sh
git clone https://github.com/Envious-Labs-LLC/EnviousCooler.git
cd EnviousCooler
python3 install-menu.py
```

For development and service management:

```sh
python3 build.py
python3 auto-mode.py status
python3 auto-mode.py on
python3 auto-mode.py off
```

The installer builds and tests first, stages and verifies a complete signed bundle, then replaces it. It preserves whether automatic cooling was running and supports rollback to the prior bundle if deployment fails. Executables are replaced through new file inodes. Bundled Python disables bytecode-cache writes so the signature stays intact.

Existing users of the development app named “Razer Cooling Pad” are migrated to EnviousCooler, including runtime data and whether automatic cooling was enabled.

For manual USB commands, stop automatic mode first:

```sh
./enviouscooler status
./enviouscooler sensors
./enviouscooler fan quiet         # 800 RPM requested
./enviouscooler fan balanced      # 1500 RPM requested
./enviouscooler fan max           # 3200 RPM requested
./enviouscooler fan 2000
./enviouscooler brightness get
./enviouscooler brightness 75
./enviouscooler fan balanced --dry-run
```

Fan targets are requested values, not measured RPM. This pad's protocol has no validated tachometer or decoded fault telemetry in this implementation. Razer's firmware readout is 1.10; that does not establish the updater's final revision. Firmware flashing is not implemented.

## Code and validation

- `Core.swift`: packet construction, response validation, input parsing and fan governor.
- `Hardware.swift`: USB ownership, bounded asynchronous I/O and testable transport.
- `Thermals.swift`: native sensor reader and private-API lifetime handling.
- `Automatic.swift`: cooling, lighting queue, signals and power lifecycle.
- `Shared.swift`: expiring typed lighting requests, bounded file reads and clocks.
- `MenuBar.swift`: native UI and controller client.
- `main.swift`: production CLI, with diagnostics compiled only on explicit opt-in.
- `runtime_tools.py`: shared atomic installation helpers.

`build.py` runs 59 native adversarial assertions, nine protocol/governor tests and five service tests and five installer fault/locking tests. Tests use fake device replies and clocks to cover corrupted/truncated responses, disconnection, bounded retries/deadlines, invalid temperatures, malformed/expired requests, stale status and atomic executable replacement. Removing the deadline was mutation-tested and correctly failed the checks. See [the review](REVIEW.md) for evidence and remaining limits.

Installed app: `~/Applications/EnviousCooler.app`. Controller, state, logs and the private lighting queue: `~/Library/Application Support/EnviousCooler/`. Login agents: `~/Library/LaunchAgents/co.enviouslabs.enviouscooler*.plist`. The hardware fan needs the supplied AC adapter.

## Diagnostics

```sh
python3 build.py --diagnostics
./inspect-input --listen 60
./enviouscooler-diagnostic test-rpm 700
```

Only perform low-speed tests on an explicit user request, with automatic cooling off and a person watching the pad. The diagnostic helper schedules recovery to 1,500 RPM after thirty seconds and attempts restoration on termination signals. Recovery can only be confirmed by an acknowledged reply. It is excluded from the installed app. Never infer physical stability from missing USB reports.

The passive recorder listens only to this pad's non-keyboard reports, caps captured data and sends no settings commands. Historical discovery code is archived under `diagnostics/`. `live-discovery.json` contains the serial number and should remain private. Physical sleep/wake, USB reconnect and the exact red-light threshold still need hands-on validation.

Protocol references: [Mac padctl](https://github.com/hbmartin/razer-cooling-pad-mac), [Windows FanControl plugin](https://github.com/Benson5650/FanControl.RazerCoolingPadPlugin), [Razer guide](https://dl.razerzone.com/master-guides/RazerSynapse4/LaptopCoolingPad-00003907-en.pdf) and [Razer FAQ](https://mysupport.razer.com/app/answers/detail/a_id/14672). Razer says flashing red may indicate power delivery; a firsthand forum report links the same symptom to 500 RPM. Neither substitutes for a diagnosis of this individual pad.

EnviousCooler is an independent Envious Labs project and is not affiliated with or endorsed by Razer. Razer is referenced to identify supported hardware. See [credits](CREDITS.md) for protocol sources.
