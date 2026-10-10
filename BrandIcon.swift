import AppKit

/// The airflow E, simplified for a crisp, appearance-aware menu-bar template.
enum BrandIcon {
  static func menuBarImage() -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
      let path = NSBezierPath()
      path.move(to: NSPoint(x: 12, y: 62))
      path.curve(to: NSPoint(x: 58, y: 23), controlPoint1: NSPoint(x: 12, y: 25),
        controlPoint2: NSPoint(x: 27, y: 21))
      path.curve(to: NSPoint(x: 94, y: 8), controlPoint1: NSPoint(x: 72, y: 24),
        controlPoint2: NSPoint(x: 83, y: 22))
      path.curve(to: NSPoint(x: 20, y: 47), controlPoint1: NSPoint(x: 84, y: 40),
        controlPoint2: NSPoint(x: 44, y: 26))
      path.curve(to: NSPoint(x: 92, y: 43), controlPoint1: NSPoint(x: 34, y: 39),
        controlPoint2: NSPoint(x: 62, y: 54))
      path.curve(to: NSPoint(x: 19, y: 69), controlPoint1: NSPoint(x: 80, y: 68),
        controlPoint2: NSPoint(x: 42, y: 50))
      path.curve(to: NSPoint(x: 93, y: 75), controlPoint1: NSPoint(x: 36, y: 63),
        controlPoint2: NSPoint(x: 66, y: 91))
      path.curve(to: NSPoint(x: 20, y: 87), controlPoint1: NSPoint(x: 73, y: 110),
        controlPoint2: NSPoint(x: 36, y: 86))
      path.curve(to: NSPoint(x: 12, y: 62), controlPoint1: NSPoint(x: 13, y: 87),
        controlPoint2: NSPoint(x: 12, y: 80))
      path.close()
      path.transform(using: AffineTransform(scale: 0.18))
      NSColor.black.setFill()
      path.fill()
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "EnviousCooler"
    return image
  }
}
