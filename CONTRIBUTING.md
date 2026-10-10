# Contributing

Build and run the offline checks with `python3 build.py`. These checks require macOS and Swift but no cooling pad.

Keep changes focused and explain the user-visible behaviour and validation in your pull request. If testing a real pad, report the Mac model, macOS version and pad firmware. Do not attach serial numbers, private logs or unrelated screen content.

Preserve the 800 RPM minimum in the production app. Low-speed diagnostic tests are opt-in and require a person observing the pad. A successful USB acknowledgement is not a measurement of fan speed, and missing event reports do not establish that no physical fault occurred.

For protocol changes, add independent packet fixtures or fake-device checks. For timing and recovery changes, inject clocks or completion signals rather than adding arbitrary test delays. Keep native behaviour, mocked test results and actual hardware observations distinct.
