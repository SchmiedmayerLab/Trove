// This source file is part of the Trove open-source project
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import AppKit
import Foundation


// Safari-style chrome around an unmodified page capture; transparent outside the window.
// Usage: swift scripts/frame-screenshot.swift input.png output.png "Study Configuration" light|dark
guard CommandLine.arguments.count == 5, ["light", "dark"].contains(CommandLine.arguments[4]) else {
    fatalError("Usage: frame-screenshot.swift input.png output.png title light|dark")
}
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let dark = CommandLine.arguments[4] == "dark"
guard let source = NSImage(contentsOf: input),
      let representation = source.representations.first else {
    fatalError("Cannot decode source capture")
}
let width = CGFloat(representation.pixelsWide)
let height = CGFloat(representation.pixelsHigh)
// Proportions follow the reference Safari window, normalized to the 1440 px page captures.
// Leave room for the native-style shadow to fade without clipping its lower edge.
let padding: CGFloat = 72
let toolbar: CGFloat = 50
let tabBar: CGFloat = 36
let size = NSSize(width: width + 2 * padding, height: height + 2 * padding + toolbar + tabBar)
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size.width),
    pixelsHigh: Int(size.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Cannot allocate frame")
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
NSColor.clear.setFill()
NSRect(origin: .zero, size: size).fill(using: .copy)
let window = NSRect(x: padding, y: padding, width: width, height: height + toolbar + tabBar)
let outline = NSBezierPath(roundedRect: window, xRadius: 16, yRadius: 16)
func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
    NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
}
let chromeColor = dark ? rgb(58, 55, 54) : rgb(252, 252, 252)
let textColor = NSColor(white: dark ? 0.87 : 0.26, alpha: 1)
let secondaryColor = NSColor(white: dark ? 0.86 : 0.20, alpha: 1)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.70 : 0.40)
shadow.shadowBlurRadius = 40
shadow.shadowOffset = NSSize(width: 0, height: -16)
shadow.set()
chromeColor.setFill()
outline.fill()
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.saveGraphicsState()
outline.addClip()
chromeColor.setFill()
window.fill()
source.draw(in: NSRect(x: padding, y: padding, width: width, height: height))
let toolbarY = window.maxY - toolbar
let controlCenterY = toolbarY + 25
let trafficColors: [(NSColor, NSColor)] = dark ? [
    (rgb(246, 93, 80), rgb(239, 104, 97)),
    (rgb(251, 180, 0), rgb(253, 207, 50)),
    (rgb(45, 194, 0), rgb(82, 194, 59))
] : [
    (rgb(252, 109, 100), rgb(247, 141, 133)),
    (rgb(252, 187, 44), rgb(255, 212, 74)),
    (rgb(100, 207, 53), rgb(157, 221, 127))
]
for (index, colors) in trafficColors.enumerated() {
    let circle = NSBezierPath(ovalIn: NSRect(
        x: padding + 25 + CGFloat(index * 22) - 6.75, y: controlCenterY - 6.75, width: 13.5, height: 13.5
    ))
    NSGradient(starting: colors.0, ending: colors.1)?.draw(in: circle, angle: -90)
    NSColor.black.withAlphaComponent(0.12).setStroke()
    circle.lineWidth = 0.6
    circle.stroke()
}
func symbol(_ name: String, centerX: CGFloat, centerY: CGFloat, size: CGFloat = 17, disabled: Bool = false) {
    let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        .applying(.init(paletteColors: [secondaryColor.withAlphaComponent(disabled ? 0.4 : 1)]))
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) else {
        fatalError("Unavailable toolbar symbol: \(name)")
    }
    // SF Symbols include optical padding. Keep their native point-size dimensions rather than scaling them twice.
    image.draw(in: NSRect(
        x: centerX - image.size.width / 2,
        y: centerY - image.size.height / 2,
        width: image.size.width,
        height: image.size.height
    ))
}
func label(_ text: String, in rect: NSRect, size: CGFloat, color: NSColor) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    style.lineBreakMode = .byTruncatingTail
    NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: size),
        .foregroundColor: color, .paragraphStyle: style
    ]).draw(in: rect)
}
func capsule(in rect: NSRect, isTab: Bool = false) {
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
    NSGradient(
        starting: dark ? rgb(85, 83, 82) : rgb(249, 249, 249),
        ending: dark ? rgb(88, 86, 85) : rgb(251, 251, 251)
    )?.draw(in: path, angle: -90)
    NSColor(white: dark ? 1 : 0, alpha: dark ? 0.12 : 0.08).setStroke()
    path.lineWidth = 0.75
    path.stroke()
    if isTab {
        let inset = NSBezierPath(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5), xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor(white: dark ? 1 : 0, alpha: dark ? 0.07 : 0.06).setStroke()
        inset.lineWidth = 0.75
        inset.stroke()
    }
}
let controlY = controlCenterY - 17
capsule(in: NSRect(x: padding + 91, y: controlY, width: 60, height: 34))
symbol("sidebar.left", centerX: padding + 109, centerY: controlCenterY, size: 16)
symbol("chevron.down", centerX: padding + 134, centerY: controlCenterY, size: 9)
capsule(in: NSRect(x: padding + 159, y: controlY, width: 70, height: 34))
symbol("chevron.left", centerX: padding + 177, centerY: controlCenterY, disabled: true)
symbol("chevron.right", centerX: padding + 212, centerY: controlCenterY, disabled: true)
NSColor(white: dark ? 1 : 0, alpha: 0.16).setFill()
NSRect(x: padding + 193.5, y: controlCenterY - 9, width: 0.75, height: 18).fill()
let address = NSRect(x: window.midX - width * 0.205, y: controlY, width: width * 0.41, height: 34)
capsule(in: address)
symbol("text.alignleft", centerX: address.minX + 20, centerY: controlCenterY, size: 13)
label("trove", in: NSRect(x: address.minX + 35, y: address.minY + 7, width: address.width - 70, height: 20), size: 14, color: textColor)
symbol("arrow.clockwise", centerX: address.maxX - 20, centerY: controlCenterY, size: 13)
capsule(in: NSRect(x: window.maxX - 113, y: controlY, width: 105, height: 34))
symbol("square.and.arrow.up", centerX: window.maxX - 93, centerY: controlCenterY, size: 16)
symbol("plus", centerX: window.maxX - 60, centerY: controlCenterY, size: 16)
symbol("square.on.square", centerX: window.maxX - 26, centerY: controlCenterY)
let tab = NSRect(x: padding + 8, y: padding + height + 6, width: width - 16, height: 28)
capsule(in: tab, isTab: true)
label("Trove — \(CommandLine.arguments[3])", in: NSRect(x: tab.minX + 20, y: tab.minY + 5, width: tab.width - 40, height: 18), size: 12, color: textColor)
NSColor(white: dark ? 1 : 0, alpha: 0.12).setFill()
NSRect(x: padding, y: padding + height, width: width, height: 0.5).fill()
NSGraphicsContext.restoreGraphicsState()
NSColor(white: dark ? 1 : 0, alpha: dark ? 0.20 : 0.14).setStroke()
outline.lineWidth = 0.5
outline.stroke()
NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Cannot encode frame")
}
try png.write(to: output, options: .atomic)
