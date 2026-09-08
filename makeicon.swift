import AppKit

// 1024x1024 画布，几何量按「自上而下」书写，最后用 P() 转成 y-up。
let S: CGFloat = 1024
let SS: CGFloat = 824                    // squircle 边长（Apple 图标模板：1024 网格中图形占 824）
let CX: CGFloat = S / 2
let CY: CGFloat = S / 2

func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: S - y) }

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

// 超椭圆：Apple 的图标外形是「连续曲率」的 squircle，n≈5 时最接近
func squirclePath(cx: CGFloat, cy: CGFloat, size: CGFloat, n: CGFloat = 5.0) -> NSBezierPath {
    let a = size / 2
    let e = 2.0 / n
    let steps = 900
    let path = NSBezierPath()
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c >= 0 ? 1 : -1) * pow(abs(c), e)
        let y = cy + a * (s >= 0 ? 1 : -1) * pow(abs(s), e)
        let pt = P(x, y)
        if i == 0 { path.move(to: pt) } else { path.line(to: pt) }
    }
    path.close()
    return path
}

// 任意圆角多边形（points 自上而下），radii 与 points 一一对应
func roundedPolygon(_ points: [CGPoint], radii: [CGFloat]) -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: P(points[0].x, points[0].y))
    for i in 1..<points.count {
        let corner = P(points[i].x, points[i].y)
        let nextIdx = (i + 1) % points.count
        let next = P(points[nextIdx].x, points[nextIdx].y)
        path.appendArc(from: corner, to: next, radius: radii[i])
    }
    path.close()
    return path
}

let bgTop = rgb(154, 166, 255)
let bgBottom = rgb(50, 62, 208)
let paperTop = rgb(255, 255, 255)
let paperBottom = rgb(231, 237, 249)
let foldTop = rgb(214, 222, 240)
let foldBottom = rgb(178, 192, 226)
let lineColor = rgb(163, 175, 212)
let titleColor = rgb(96, 110, 212)

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let shape = squirclePath(cx: CX, cy: CY, size: SS)

// 1. 底色渐变 + 顶部内高光 + 底部内阴影
NSGraphicsContext.saveGraphicsState()
shape.setClip()
NSGradient(colors: [bgTop, bgBottom])!
    .draw(from: P(CX, CY - SS / 2), to: P(CX, CY + SS / 2), options: [])
NSGradient(colors: [rgb(255, 255, 255, 0.30), rgb(255, 255, 255, 0)])!
    .draw(from: P(CX, CY - SS / 2), to: P(CX, CY - SS / 2 + SS * 0.46), options: [])
NSGradient(colors: [rgb(0, 0, 0, 0), rgb(0, 0, 0, 0.20)])!
    .draw(from: P(CX, CY + SS / 2 - SS * 0.42), to: P(CX, CY + SS / 2), options: [])
NSGraphicsContext.restoreGraphicsState()

// 2. 内侧一圈细高光边
NSGraphicsContext.saveGraphicsState()
shape.setClip()
rgb(255, 255, 255, 0.28).setStroke()
let rim = shape.copy() as! NSBezierPath
rim.lineWidth = 7
rim.stroke()
NSGraphicsContext.restoreGraphicsState()

// 3. 便签卡片
let cardW: CGFloat = 430
let cardH: CGFloat = 520
let cardX = CX - cardW / 2
let cardY = CY - cardH / 2 + 4
let fold: CGFloat = 112
let r: CGFloat = 54

let cardPoints: [CGPoint] = [
    CGPoint(x: cardX, y: cardY),
    CGPoint(x: cardX + cardW - fold, y: cardY),
    CGPoint(x: cardX + cardW, y: cardY + fold),
    CGPoint(x: cardX + cardW, y: cardY + cardH),
    CGPoint(x: cardX, y: cardY + cardH),
]
let card = roundedPolygon(cardPoints, radii: [r, 16, 16, r, r])

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = rgb(20, 26, 70, 0.30)
shadow.shadowBlurRadius = 26
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
card.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
card.setClip()
NSGradient(colors: [paperTop, paperBottom])!
    .draw(from: P(CX, cardY), to: P(CX, cardY + cardH), options: [])
NSGraphicsContext.restoreGraphicsState()

// 4. 折角
let foldPoints: [CGPoint] = [
    CGPoint(x: cardX + cardW - fold, y: cardY),
    CGPoint(x: cardX + cardW, y: cardY + fold),
    CGPoint(x: cardX + cardW - fold, y: cardY + fold),
]
let flap = roundedPolygon(foldPoints, radii: [12, 12, 12])
NSGraphicsContext.saveGraphicsState()
flap.setClip()
NSGradient(colors: [foldTop, foldBottom])!
    .draw(from: P(cardX + cardW - fold, cardY), to: P(cardX + cardW, cardY + fold), options: [])
NSGraphicsContext.restoreGraphicsState()

// 5. 标题线 + 正文线
let pad: CGFloat = 44
let lineX = cardX + pad
let lineW = cardW - pad * 2

func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: NSColor) {
    let p = roundedPolygon([
        CGPoint(x: x, y: y),
        CGPoint(x: x + w, y: y),
        CGPoint(x: x + w, y: y + h),
        CGPoint(x: x, y: y + h),
    ], radii: [h / 2, h / 2, h / 2, h / 2])
    color.setFill()
    p.fill()
}

// 标题：稍粗、带一点强调色
bar(lineX, cardY + 92, 176, 34, titleColor)

// 正文：四行，末行留白收尾
for i in 0..<4 {
    let y = cardY + 172 + CGFloat(i) * 76
    let w = (i == 3) ? lineW * 0.55 : lineW
    bar(lineX, y, w, 28, lineColor)
}

NSGraphicsContext.restoreGraphicsState()

// ---- 自检 ----
if ProcessInfo.processInfo.environment["ASCII"] != nil {
    let N = 56
    let ramp = Array(" .:-=+*#%@")
    var out = ""
    for r in 0..<N {
        var line = ""
        for c in 0..<N {
            let px = Int((CGFloat(c) + 0.5) * S / CGFloat(N))
            let py = Int((CGFloat(r) + 0.5) * S / CGFloat(N))
            let col = rep.colorAt(x: px, y: py)!
            if col.alphaComponent < 0.15 {
                line += " "
            } else {
                let l = 0.299 * col.redComponent + 0.587 * col.greenComponent + 0.114 * col.blueComponent
                line += String(ramp[min(Int(l * CGFloat(ramp.count)), ramp.count - 1)])
            }
        }
        out += line + "\n"
    }
    print(out)
}

let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("已写入 \(CommandLine.arguments[1])")
