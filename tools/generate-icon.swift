import AppKit

/// SF Symbol "globe" をアプリアイコン用 PNG (1024x1024) としてレンダリングする。
/// macOS の角丸アイコン規約 (Big Sur 以降) に合わせて青背景 + 白いグローブを描画する。

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "build/icon-source.png"
let canvasSize: CGFloat = 1024

let image = NSImage(size: NSSize(width: canvasSize, height: canvasSize))
image.lockFocus()

// 背景: 角丸の塗り (Big Sur 以降のアイコン角丸比率 ≒ 0.2237)
let cornerRadius = canvasSize * 0.2237
let bgRect = NSRect(x: 0, y: 0, width: canvasSize, height: canvasSize)
let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: cornerRadius, yRadius: cornerRadius)
NSColor(calibratedRed: 0.0, green: 0.48, blue: 1.0, alpha: 1.0).setFill()
bgPath.fill()

// SF Symbol "globe" を白でセンタリング描画
let symbolPointSize = canvasSize * 0.62
let config = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .regular)
guard let symbol = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) else {
    fatalError("Failed to load SF Symbol: globe")
}

let symbolSize = symbol.size
let tinted = NSImage(size: symbolSize)
tinted.lockFocus()
symbol.draw(
    at: .zero,
    from: NSRect(origin: .zero, size: symbolSize),
    operation: .sourceOver,
    fraction: 1.0,
)
NSColor.white.set()
NSRect(origin: .zero, size: symbolSize).fill(using: .sourceIn)
tinted.unlockFocus()

let origin = NSPoint(
    x: (canvasSize - symbolSize.width) / 2,
    y: (canvasSize - symbolSize.height) / 2,
)
tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1.0)

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Failed to encode PNG")
}

let outputURL = URL(fileURLWithPath: outputPath)
try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true,
)
try png.write(to: outputURL)
print("Wrote: \(outputPath)")
