# EnviousCooler identity

Approved by Saurabh on 2026-10-10: the **Sharper airflow E** with a
**silver mark on a graphite macOS icon tile**. The three flowing ribbons
suggest moving air while forming the Envious E. Blue and teal were rejected.
The fan-hub and sparkle variations were not selected.

## App icon

![Approved silver app icon](../assets/AppIcon.png)

`assets/AppIcon.png` is the approved full-resolution artwork. The installer
bundles `assets/AppIcon.icns` and declares it through `CFBundleIconFile`.
The icon includes transparent space outside its rounded tile.

To regenerate the macOS size variants after an approved artwork change:

```sh
python3 build-icons.py
```

This uses macOS `sips` and `iconutil`; it needs no image library or cloud service.
Commit both the source PNG and regenerated ICNS.

## Menu-bar icon

`BrandIcon.swift` draws a simplified vector version of the airflow E at
18 points. It is an AppKit template image, so macOS chooses its colour for
light and dark menu bars. Keep the three strokes readable at small sizes;
do not add the graphite tile, metallic texture, sparkle or fan hub here.

The menu-bar drawing is a small-size adaptation rather than a crop of the
silver artwork. It is compiled into the app, so it needs no external asset
lookup and remains sharp on Retina displays.
