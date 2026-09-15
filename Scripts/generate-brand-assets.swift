#!/usr/bin/env swift
// Rebuild the original apple artwork and every icon size without external dependencies.
import AppKit

enum Segment {
    case move(CGFloat, CGFloat)
    case curve(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)
    case close
}

let fruit: [Segment] = [
    .move(50, 32),
    .curve(37, 21, 17, 27, 15, 45),
    .curve(12, 62, 24, 88, 37, 88),
    .curve(43, 88, 45, 84, 50, 84),
    .curve(55, 84, 58, 88, 64, 88),
    .curve(77, 88, 88, 62, 85, 45),
    .curve(82, 27, 63, 21, 50, 32),
    .close,
]
let leaf: [Segment] = [
    .move(50, 26),
    .curve(49, 14, 61, 6, 74, 9),
    .curve(73, 21, 63, 29, 50, 26),
    .close,
]
func path(_ segments: [Segment]) -> CGPath {
    let p = CGMutablePath()
    for segment in segments {
        switch segment {
        case .move(let x, let y): p.move(to: CGPoint(x: x, y: y))
        case .curve(let x1, let y1, let x2, let y2, let x, let y):
            p.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: x1, y: y1), control2: CGPoint(x: x2, y: y2))
        case .close: p.closeSubpath()
        }
    }
    return p
}
func svgPath(_ segments: [Segment]) -> String {
    segments.map {
        switch $0 {
        case .move(let x, let y): "M\(x) \(y)"
        case .curve(let a, let b, let c, let d, let x, let y): "C\(a) \(b) \(c) \(d) \(x) \(y)"
        case .close: "Z"
        }
    }.joined(separator: " ")
}
func color(_ hex: UInt32) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 255) / 255,
        green: CGFloat((hex >> 8) & 255) / 255,
        blue: CGFloat(hex & 255) / 255,
        alpha: 1
    )
}
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
func write(_ text: String, _ relative: String) throws {
    try (text + "\n").write(to: root.appendingPathComponent(relative), atomically: true, encoding: .utf8)
}
let mark = "<path d=\"\(svgPath(fruit))\"/><path d=\"\(svgPath(leaf))\"/>"
let iconSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" role="img" aria-label="iMCP apple icon">
      <defs><linearGradient id="apple" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#36ad71"/><stop offset="1" stop-color="#16764e"/></linearGradient></defs>
      <rect x="4" y="4" width="92" height="92" rx="22" fill="#f3f6ef"/>
      <g transform="translate(12 10) scale(.76)" fill="url(#apple)">\(mark)</g>
    </svg>
    """
try write(iconSVG, "Assets/app-icon.svg")
try write(
    """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" role="img" aria-label="iMCP menu icon">
      <g fill="#218a59">\(mark)</g>
    </svg>
    """,
    "Assets/icon.svg"
)
try write(
    """
    <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 100 100">
      <g fill="#000">\(mark)</g>
    </svg>
    """,
    "App/Assets.xcassets/MenuIcon-On.imageset/MenuIcon.svg"
)
let off = """
    <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 100 100">
      <g fill="none" stroke="#000" stroke-width="6" stroke-linejoin="round">\(mark)</g>
    </svg>
    """
try write(off, "App/Assets.xcassets/MenuIcon-Off.imageset/MenuIcon - Light.svg")
try write(off, "App/Assets.xcassets/MenuIcon-Off.imageset/MenuIcon - Dark.svg")

for size in [16, 32, 64, 128, 256, 512, 1024] {
    let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: size * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.scaleBy(x: CGFloat(size) / 100, y: CGFloat(size) / 100)
    context.translateBy(x: 0, y: 100)
    context.scaleBy(x: 1, y: -1)
    context.setFillColor(color(0xf3f6ef))
    context.addPath(
        CGPath(
            roundedRect: CGRect(x: 4, y: 4, width: 92, height: 92),
            cornerWidth: 22,
            cornerHeight: 22,
            transform: nil
        )
    )
    context.fillPath()
    context.translateBy(x: 12, y: 10)
    context.scaleBy(x: 0.76, y: 0.76)
    context.addPath(path(fruit))
    context.addPath(path(leaf))
    context.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [color(0x36ad71), color(0x16764e)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(gradient, start: CGPoint(x: 15, y: 10), end: CGPoint(x: 85, y: 88), options: [])
    let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
    let filename = size == 1024 ? "Icon-macOS-512x512@2x.png" : "Icon-macOS-\(size)x\(size).png"
    try bitmap.representation(using: .png, properties: [:])!.write(
        to: root.appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset/\(filename)")
    )
}
for dark in [false, true] {
    let background = dark ? "#15251f" : "#f2f6ef"
    let foreground = dark ? "#edf5ef" : "#193d2c"
    let muted = dark ? "#a6bdb0" : "#597364"
    let card = dark ? "#213c2e" : "#ffffff"
    let border = dark ? "#355543" : "#dce8dc"
    let names = ["WeChat", "Calendar", "Messages", "Contacts", "Maps", "Shortcuts"]
    let pills = names.enumerated().map { index, name in
        let x = 690 + (index % 2) * 210
        let y = 160 + (index / 2) * 66
        return """
            <rect x="\(x)" y="\(y)" width="190" height="50" rx="14" fill="\(card)" stroke="\(border)"/>
            <circle cx="\(x + 22)" cy="\(y + 25)" r="5" fill="#36ad71"/>
            <text x="\(x + 40)" y="\(y + 31)" font-size="17" fill="\(foreground)">\(name)</text>
            """
    }.joined(separator: "\n")
    try write(
        """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1200 420" role="img" aria-labelledby="title desc">
          <title id="title">iMCP — Your apps. One conversation.</title>
          <desc id="desc">Connect WeChat and macOS services to your AI clients, with access you control.</desc>
          <rect width="1200" height="420" rx="28" fill="\(background)"/>
          <g font-family="-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif">
            <g transform="translate(52 40) scale(.6)" fill="#36ad71">\(mark)</g>
            <text x="125" y="83" font-size="28" font-weight="700" fill="\(foreground)">iMCP</text>
            <text x="60" y="186" font-size="52" font-weight="700" letter-spacing="-2" fill="\(foreground)">Your apps.</text>
            <text x="60" y="245" font-size="52" font-weight="700" letter-spacing="-2" fill="\(foreground)">One conversation.</text>
            <text x="62" y="300" font-size="19" fill="\(muted)">WeChat + macOS, connected to your AI.</text>
            <text x="62" y="357" font-size="14" fill="\(muted)">LOCAL APP  /  EXPLICIT PERMISSIONS  /  OPEN SOURCE</text>
            <text x="690" y="119" font-size="13" letter-spacing="2" fill="\(muted)">YOUR EVERYDAY, CONNECTED</text>
            \(pills)
          </g>
        </svg>
        """,
        dark ? "Assets/hero-dark.svg" : "Assets/hero-light.svg"
    )
}
try write(
    """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" role="img" aria-label="WeChat">
      <rect width="64" height="64" rx="16" fill="#e8f6ed"/>
      <path d="M41 26C41 17 33 11 24 11C14 11 6 17 6 26C6 31 9 36 13 38L11 45L19 41C21 42 23 42 25 42C34 42 41 35 41 26Z" fill="#289e5d"/>
      <path d="M59 39C59 31 52 25 43 25C34 25 27 31 27 39C27 47 34 53 43 53C45 53 47 53 49 52L56 55L54 48C57 46 59 43 59 39Z" fill="#78ce92" stroke="#e8f6ed" stroke-width="2"/>
      <g fill="#fff"><circle cx="18" cy="25" r="2"/><circle cx="29" cy="25" r="2"/><circle cx="38" cy="38" r="1.6"/><circle cx="48" cy="38" r="1.6"/></g>
    </svg>
    """,
    "Assets/wechat.svg"
)
try write(
    """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1200 350" role="img" aria-labelledby="title desc">
      <title id="title">WeChat: authorize, archive, query</title>
      <desc id="desc">Choose an account and save its key locally. Approve individual conversations on your Mac. Query their historical archive through an MCP client. Real-time synchronization is not enabled.</desc>
      <rect width="1200" height="350" rx="24" fill="#f2f6ef"/>
      <g font-family="-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif">
        <text x="40" y="50" font-size="14" letter-spacing="2" fill="#597364">WECHAT · ACCESS YOU CONTROL</text>
        <g fill="#fff" stroke="#dce8dc">
          <rect x="40" y="80" width="340" height="168" rx="18"/>
          <rect x="430" y="80" width="340" height="168" rx="18"/>
          <rect x="820" y="80" width="340" height="168" rx="18"/>
        </g>
        <g fill="#218a59" font-size="14" font-weight="700">
          <text x="64" y="113">01 / CONNECT LOCALLY</text>
          <text x="454" y="113">02 / APPROVE ACCESS</text>
          <text x="844" y="113">03 / ASK YOUR AI</text>
        </g>
        <g fill="#193d2c" font-size="24" font-weight="700">
          <text x="64" y="157">Choose your account</text>
          <text x="454" y="157">Select conversations</text>
          <text x="844" y="157">Query the archive</text>
        </g>
        <g fill="#597364" font-size="16">
          <text x="64" y="192">Read-only source access.</text>
          <text x="64" y="217">Database key in local Keychain.</text>
          <text x="454" y="192">Confirm on your Mac.</text>
          <text x="454" y="217">Revoke access in Settings.</text>
          <text x="844" y="192">Search, filter, and read context.</text>
          <text x="844" y="217">Retrieve available media.</text>
        </g>
        <g fill="none" stroke="#218a59" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
          <path d="M394 163h21m-7-7 7 7-7 7"/>
          <path d="M784 163h21m-7-7 7 7-7 7"/>
        </g>
        <circle cx="48" cy="299" r="5" fill="#ba8025"/>
        <text x="64" y="305" font-size="16" fill="#735625">Historical archive only. Real-time synchronization is not enabled.</text>
      </g>
    </svg>
    """,
    "Assets/wechat-workflow.svg"
)
print("Generated apple app/menu icons and README artwork.")
