import AppKit

/// 使用系统矢量绘图生成应用图标，不读取屏幕或外部图像。
func drawApplicationIcon(to destination: URL) throws {
    let image = NSImage(size: NSSize(width: 1024, height: 1024))
    image.lockFocus()
    let canvas = NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928), xRadius: 210, yRadius: 210)
    let gradient = NSGradient(starting: NSColor(red: 0.08, green: 0.39, blue: 0.90, alpha: 1),
                              ending: NSColor(red: 0.18, green: 0.72, blue: 0.83, alpha: 1))!
    gradient.draw(in: canvas, angle: 45)
    // 顶部菜单栏和下方收纳面板构成应用识别图形。
    NSColor.white.withAlphaComponent(0.94).setFill()
    NSBezierPath(roundedRect: NSRect(x: 178, y: 574, width: 668, height: 116), xRadius: 45, yRadius: 45).fill()
    NSColor.white.withAlphaComponent(0.96).setFill()
    NSBezierPath(roundedRect: NSRect(x: 362, y: 320, width: 480, height: 206), xRadius: 46, yRadius: 46).fill()
    NSColor(red: 0.10, green: 0.33, blue: 0.65, alpha: 1).setFill()
    for x in [CGFloat(248), 322, 396] {
        NSBezierPath(ovalIn: NSRect(x: x, y: 612, width: 34, height: 34)).fill()
    }
    for x in [CGFloat(482), 531, 580] {
        NSBezierPath(ovalIn: NSRect(x: x, y: 614, width: 28, height: 28)).fill()
    }
    // 使用小型卡片表示被收起的图标，而不是具体第三方应用商标。
    for x in [CGFloat(407), 537, 667] {
        NSColor(red: 0.17, green: 0.50, blue: 0.83, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: 374, width: 90, height: 90), xRadius: 22, yRadius: 22).fill()
    }
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 717, y: 645))
    arrow.line(to: NSPoint(x: 743, y: 619))
    arrow.line(to: NSPoint(x: 769, y: 645))
    arrow.lineWidth = 11
    arrow.lineCapStyle = .round
    NSColor(red: 0.10, green: 0.33, blue: 0.65, alpha: 1).setStroke()
    arrow.stroke()
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: destination, options: .atomic)
}

// 输出位置由构建脚本传入，源码可在任意本机目录构建。
guard CommandLine.arguments.count == 2 else { exit(2) }
try drawApplicationIcon(to: URL(fileURLWithPath: CommandLine.arguments[1]))
