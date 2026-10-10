# Credits

EnviousCooler is developed by Envious Labs.

The implementation was informed by the published USB protocol and device work in:

- [hbmartin/razer-cooling-pad-mac (padctl)](https://github.com/hbmartin/razer-cooling-pad-mac), MIT licensed. This provided Mac-specific protocol and sensor-reading references.
- [Benson5650/FanControl.RazerCoolingPadPlugin](https://github.com/Benson5650/FanControl.RazerCoolingPadPlugin). This provided the cooling pad's fan-command layout and RPM-unit reference.
- [OpenRazer](https://github.com/openrazer/openrazer). Its accessory work documents the Razer report structure and lighting protocol.

These projects are independent and retain their own licenses. EnviousCooler uses its own native Swift implementation; it does not bundle their binaries or install their drivers.

“Razer” and device names identify hardware compatibility. No affiliation or endorsement is implied.
