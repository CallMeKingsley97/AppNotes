import AppKit

// 使用 1024 点设计网格，图形坐标从左上角起算。
let canvasSize = 1024

func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
    NSPoint(x: x, y: CGFloat(canvasSize) - y)
}

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func roundedRect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(
        roundedRect: NSRect(origin: point(x, y + height), size: NSSize(width: width, height: height)),
        xRadius: radius, yRadius: radius
    )
}

func gradient(_ colors: [NSColor], from start: NSPoint, to end: NSPoint) {
    // 所有色标均由 sRGB 颜色组成，且至少有两个色标。
    guard let gradient = NSGradient(colors: colors) else {
        preconditionFailure("无效的图标渐变")
    }
    gradient.draw(from: start, to: end, options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation])
}

func clipped(to path: NSBezierPath, draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    path.addClip()
    draw()
}

func outline(of path: NSBezierPath, width: CGFloat) -> NSBezierPath {
    NSBezierPath(cgPath: path.cgPath.copy(
        strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 1
    ))
}

func tileOutline() -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: point(327, 100))
    path.line(to: point(697, 100))
    path.curve(to: point(924, 327), controlPoint1: point(860, 100), controlPoint2: point(924, 164))
    path.line(to: point(924, 697))
    path.curve(to: point(697, 924), controlPoint1: point(924, 860), controlPoint2: point(860, 924))
    path.line(to: point(327, 924))
    path.curve(to: point(100, 697), controlPoint1: point(164, 924), controlPoint2: point(100, 860))
    path.line(to: point(100, 327))
    path.curve(to: point(327, 100), controlPoint1: point(100, 164), controlPoint2: point(164, 100))
    path.close()
    return path
}

func noteOutline(offsetX x: CGFloat, offsetY y: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: point(x + 50, y))
    path.appendArc(from: point(x + 263, y), to: point(x + 386, y + 123), radius: 17)
    path.appendArc(from: point(x + 386, y + 123), to: point(x + 386, y + 466), radius: 17)
    path.appendArc(from: point(x + 386, y + 466), to: point(x, y + 466), radius: 50)
    path.appendArc(from: point(x, y + 466), to: point(x, y), radius: 50)
    path.appendArc(from: point(x, y), to: point(x + 263, y), radius: 50)
    path.close()
    return path
}

func drawIcon() {
    let tile = tileOutline()
    clipped(to: tile) {
        gradient([color(0x293545), color(0x161E2C), color(0x0B111C)],
                 from: point(242, 109), to: point(739, 907))

        let glowCenter = point(451, 363)
        NSGradient(starting: color(0x408CDD, alpha: 0.34), ending: color(0x408CDD, alpha: 0))?
            .draw(fromCenter: glowCenter, radius: 0, toCenter: glowCenter, radius: 550, options: [])

        // 低对比度点阵只在大尺寸下可见。
        color(0xA3CCF4, alpha: 0.14).setFill()
        for row in 0..<13 {
            for column in 0..<13 {
                let origin = point(210 + CGFloat(column) * 50, 214 + CGFloat(row) * 50)
                NSBezierPath(ovalIn: NSRect(origin: origin, size: NSSize(width: 4, height: 4))).fill()
            }
        }

        clipped(to: outline(of: tile, width: 8)) {
            gradient([color(0xC3DBF5, alpha: 0.59), color(0x7199C5, alpha: 0.26), color(0x426087, alpha: 0.35)],
                     from: point(512, 100), to: point(512, 924))
        }
    }

    // 叠放的第二张卡片，用稍暗的蓝色区分深度。
    let rear = noteOutline(offsetX: 352, offsetY: 315)
    clipped(to: rear) {
        gradient([color(0x2B4F70), color(0x18283B)], from: point(379, 340), to: point(719, 789))
    }
    color(0x5C96BE).setStroke()
    rear.lineWidth = 10
    rear.stroke()

    let front = noteOutline(offsetX: 282, offsetY: 240)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x060C17, alpha: 0.8)
    shadow.shadowBlurRadius = 29
    shadow.shadowOffset = NSSize(width: 0, height: -17)
    shadow.set()
    color(0x182A40).setFill()
    front.fill()
    NSGraphicsContext.restoreGraphicsState()

    clipped(to: front) {
        gradient([color(0x365E80), color(0x233D59), color(0x12253C)],
                 from: point(302, 240), to: point(646, 744))

        let fold = NSBezierPath()
        fold.move(to: point(539, 229))
        fold.line(to: point(678, 368))
        fold.appendArc(from: point(539, 368), to: point(539, 229), radius: 22)
        fold.close()
        clipped(to: fold) {
            gradient([color(0x94E8FC), color(0x388FCE)], from: point(539, 246), to: point(650, 373))
        }
    }

    clipped(to: outline(of: front, width: 14)) {
        gradient([color(0xCEF6FF), color(0x7ED8F5), color(0x5F9FD2)],
                 from: point(321, 240), to: point(642, 730))
    }

    color(0xD9F7FF).setFill()
    roundedRect(348, 403, 128, 39, radius: 19.5).fill()
    color(0x89B9DB).setFill()
    roundedRect(348, 483, 252, 32, radius: 16).fill()
    roundedRect(348, 560, 180, 32, radius: 16).fill()
    color(0x82F0FC).setFill()
    NSBezierPath(ovalIn: NSRect(origin: point(562, 596), size: NSSize(width: 40, height: 40))).fill()
}

enum IconError: Error {
    case missingOutputPath
    case imageCreationFailed
}

func renderIcon(to url: URL) throws {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: canvasSize, pixelsHigh: canvasSize,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw IconError.imageCreationFailed
    }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    context.cgContext.clear(CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))
    drawIcon()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw IconError.imageCreationFailed
    }
    try png.write(to: url, options: .atomic)
}

guard CommandLine.arguments.count == 2 else {
    throw IconError.missingOutputPath
}
try renderIcon(to: URL(fileURLWithPath: CommandLine.arguments[1]))
