# EnviousCooler

Native macOS menu-bar app and local controller for the Razer Laptop Cooling Pad, maintained by Envious Labs.

## Owners

- `README.md`: product behaviour, supported hardware, installation and diagnostics.
- `REVIEW.md`: adversarial review evidence and hardware scenarios not yet physically verified.
- `Core.swift`: protocol validation and the temperature/RPM curve.
- `Hardware.swift`: USB ownership and bounded report exchange.
- `Automatic.swift`: cooling, power lifecycle and brightness request processing.
- `Shared.swift`: the typed request contract and file/clock helpers.
- `install-menu.py`: app packaging, migration from the predecessor and rollback.
- `docs/branding.md`: approved silver airflow E identity and app/menu-bar artwork.

## Validation

Run `python3 build.py` for production builds and offline checks. The checks must not require a connected pad or modify launchd.

Run `python3 install-menu.py` only for an explicitly requested local installation/update. It preserves whether cooling was running and must not reset hardware lighting preferences.

The normal app has an 800 RPM minimum. Low-speed experiments require the separate `python3 build.py --diagnostics` build and an explicit user request. Do not treat missing USB events as proof that the pad did not flash red.

## Release boundaries

The temperature API is private. Verify the actual Mac model before claiming sensor coverage. Commanded RPM is not measured RPM. Physical sleep/reconnect validation remains distinct from fake-device tests.

Keep captured device files, serial numbers, runtime logs and `.review/` records out of public commits. The GitHub workflow uses only standard public-repository runners, no artifact uploads or caches.

The project has no configured Discord session-log script or channel. Do not invent a webhook or post to another project's channel.
