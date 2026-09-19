import AppKit
import CoreGraphics

// 用法：swift make_icon.swift <variant A|B|C> <out.png>
let variant = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "A"
let outPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "icon_\(variant).png"

let size: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha
    ])!
}

func lerp(_ a: UInt32, _ b: UInt32, _ t: CGFloat) -> CGColor {
    func ch(_ v: UInt32, _ s: UInt32) -> CGFloat { CGFloat((v >> s) & 0xFF) / 255 }
    let r = ch(a, 16) + (ch(b, 16) - ch(a, 16)) * t
    let g = ch(a, 8) + (ch(b, 8) - ch(a, 8)) * t
    let bl = ch(a, 0) + (ch(b, 0) - ch(a, 0)) * t
    return CGColor(colorSpace: cs, components: [r, g, bl, 1])!
}

/// macOS 图标网格：1024 画布内 824×824 的连续圆角矩形（超椭圆近似）
func squircle(in rect: CGRect, n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = rect.midX + a * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n)
        let y = rect.midY + b * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func linearGradient(_ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func radialGlow(_ c: UInt32, alpha: CGFloat, center: CGPoint, radius: CGFloat) {
    let g = CGGradient(colorsSpace: cs, colors: [color(c, alpha), color(c, 0)] as CFArray, locations: nil)!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

func roundedBar(_ rect: CGRect, radius: CGFloat, fill: CGColor) {
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setFillColor(fill)
    ctx.fillPath()
}

/// 分段绘制带渐变色的圆弧（CoreGraphics 没有角向渐变）。角度为度，顺时针从 start 扫过 sweep。
func gradientArc(center: CGPoint, radius: CGFloat, width: CGFloat, startDeg: CGFloat, sweepDeg: CGFloat, from: UInt32, to: UInt32) {
    let segments = 360
    // 透明图层：整条弧作为一个整体合成，辉光/抗锯齿不会逐段叠加出接缝和深色端点
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.setLineWidth(width)
    ctx.setLineCap(.butt)
    for i in 0..<segments {
        let t0 = CGFloat(i) / CGFloat(segments), t1 = CGFloat(i + 1) / CGFloat(segments)
        let a0 = (startDeg - sweepDeg * t0) * .pi / 180
        let a1 = (startDeg - sweepDeg * t1) * .pi / 180 - (i == segments - 1 ? 0 : 0.012)
        ctx.setStrokeColor(lerp(from, to, t0))
        ctx.addArc(center: center, radius: radius, startAngle: a0, endAngle: a1, clockwise: true)
        ctx.strokePath()
    }
    // 圆头端点单独画成圆，颜色与两端一致
    for (deg, hex) in [(startDeg, from), (startDeg - sweepDeg, to)] {
        let a = deg * .pi / 180
        ctx.setFillColor(lerp(hex, hex, 0))
        ctx.fillEllipse(in: CGRect(x: center.x + radius * cos(a) - width / 2, y: center.y + radius * sin(a) - width / 2,
                                   width: width, height: width))
    }
    ctx.endTransparencyLayer()
}

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = squircle(in: body)

// 投影
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: color(0x000000, 0.35))
ctx.addPath(shape)
ctx.setFillColor(color(0x101830))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape)
ctx.clip()

let c = CGPoint(x: 512, y: 512)

switch variant {
case "B":
    // 方案 B「信号柱」：明亮蓝青渐变 + 五格信号
    linearGradient([color(0x2F6BFF), color(0x12C6E8)], from: CGPoint(x: 160, y: 900), to: CGPoint(x: 880, y: 140))
    radialGlow(0xFFFFFF, alpha: 0.22, center: CGPoint(x: 330, y: 820), radius: 520)
    let barW: CGFloat = 86, gap: CGFloat = 34
    let heights: [CGFloat] = [130, 215, 300, 385, 470]
    let total = barW * 5 + gap * 4
    var x = c.x - total / 2
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x0A2A66, 0.35))
    for (i, h) in heights.enumerated() {
        roundedBar(CGRect(x: x, y: 290, width: barW, height: h), radius: 26,
                   fill: color(0xFFFFFF, i == 4 ? 0.38 : 1))
        x += barW + gap
    }

case "C":
    // 方案 C「随身路由」：浅色底 + 设备剪影 + 信号弧
    linearGradient([color(0xFBFCFE), color(0xD9E2EF)], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))
    // 信号弧
    let arcCenter = CGPoint(x: 512, y: 470)
    for (i, r) in [CGFloat(130), 215, 300].enumerated() {
        gradientArc(center: arcCenter, radius: r, width: 50, startDeg: 138, sweepDeg: 96,
                    from: [0x2F6BFF, 0x2A8CFF, 0x12C6E8][i], to: [0x2A8CFF, 0x12C6E8, 0x2FE3C0][i])
    }
    // 设备
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x1B2A5C, 0.35))
    let device = CGRect(x: 292, y: 250, width: 440, height: 230)
    ctx.addPath(CGPath(roundedRect: device, cornerWidth: 64, cornerHeight: 64, transform: nil))
    ctx.setFillColor(color(0x18233F))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: device, cornerWidth: 64, cornerHeight: 64, transform: nil))
    ctx.clip()
    linearGradient([color(0x2A3A66), color(0x121A30)], from: CGPoint(x: 512, y: 480), to: CGPoint(x: 512, y: 250))
    ctx.restoreGState()
    // 屏幕上的信号格 + 指示灯
    var bx: CGFloat = 352
    for h in [CGFloat(40), 66, 92, 118] {
        roundedBar(CGRect(x: bx, y: 306, width: 34, height: h), radius: 10, fill: color(0xFFFFFF, 0.95))
        bx += 52
    }
    ctx.setFillColor(color(0x3CF0A0))
    ctx.fillEllipse(in: CGRect(x: 630, y: 340, width: 46, height: 46))

default:
    // 方案 A「用量环」：深海军蓝 + 流量仪表环 + 信号格
    linearGradient([color(0x24356F), color(0x0A0F24)], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))
    radialGlow(0x2E9BFF, alpha: 0.30, center: CGPoint(x: 512, y: 470), radius: 430)

    let radius: CGFloat = 262, width: CGFloat = 66
    // 轨道：270° 开口朝下
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(color(0xFFFFFF, 0.11))
    ctx.addArc(center: c, radius: radius, startAngle: 225 * .pi / 180, endAngle: -45 * .pi / 180, clockwise: true)
    ctx.strokePath()
    // 进度：约 70%
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 30, color: color(0x35D6FF, 0.55))
    gradientArc(center: c, radius: radius, width: width, startDeg: 225, sweepDeg: 270 * 0.70, from: 0x46F2C8, to: 0x2E8BFF)
    ctx.restoreGState()

    // 环内信号格
    let barW: CGFloat = 46, gap: CGFloat = 24
    let heights: [CGFloat] = [72, 124, 176, 228]
    let total = barW * 4 + gap * 3
    var x = c.x - total / 2
    for h in heights {
        roundedBar(CGRect(x: x, y: c.y - 118, width: barW, height: h), radius: 15, fill: color(0xFFFFFF, 0.96))
        x += barW + gap
    }
}

// 顶部高光
linearGradient([color(0xFFFFFF, variant == "C" ? 0.0 : 0.16), color(0xFFFFFF, 0)],
               from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 560))
ctx.restoreGState()

// 细描边，让边缘在深/浅色背景上都清晰
ctx.addPath(shape)
ctx.setStrokeColor(variant == "C" ? color(0x000000, 0.10) : color(0xFFFFFF, 0.10))
ctx.setLineWidth(3)
ctx.strokePath()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
