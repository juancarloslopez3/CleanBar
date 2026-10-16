import AppKit
import ScreenCaptureKit

/// A picture of one menu bar item, split so it can be drawn in the window's own colors, the way macOS draws the menu
/// bar: its black-and-white parts become a template image, drawn in the text color, and its colored parts stay as they
/// are.
nonisolated struct ItemPicture: Sendable {
    /// The black-and-white parts, as a template image. Nil when there are none.
    let glyph: NSImage?
    /// The colored parts, such as a green lock. Nil when there are none.
    let color: NSImage?
    /// The item's size in the menu bar, in points.
    let size: CGSize
    /// The part of the picture across that has something drawn, in points from its left edge. Items leave room around
    /// their icon in the menu bar, and how much differs from app to app.
    let drawnSpan: ClosedRange<CGFloat>

    init(glyph: NSImage?, color: NSImage?, size: CGSize) {
        self.glyph = glyph
        self.color = color
        self.size = size
        let images = [glyph, color].compactMap { $0?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        drawnSpan = Self.drawnSpan(of: images, width: size.width)
    }

    /// The columns drawn in any of the images, whatever their resolution, in points across `width`.
    private static func drawnSpan(of images: [CGImage], width: CGFloat) -> ClosedRange<CGFloat> {
        var span: ClosedRange<CGFloat>?
        for image in images {
            guard let pixels = PixelBuffer(image), let columns = pixels.drawnColumns else { continue }
            let scale = width / CGFloat(pixels.width)
            let part = CGFloat(columns.lowerBound) * scale...CGFloat(columns.upperBound + 1) * scale
            span = span.map { min($0.lowerBound, part.lowerBound)...max($0.upperBound, part.upperBound) } ?? part
        }
        return span ?? 0...width
    }
}

/// Takes pictures of menu bar items: one picture of each menu bar strip, cut into one picture per item.
/// Only items that are actually on screen can be captured.
///
/// Only the menu bar's own window is pictured, so the icons come out on a transparent background instead of on the
/// wallpaper behind the menu bar. Items missing from that picture are taken from a picture of the whole screen
/// instead, and what was behind them is taken out afterwards.
///
/// On macOS 27.0.1 the menu bar is a single window of Window Server's, "Menubar", at the main menu window level; the
/// apps' items have no windows of their own.
///
/// macOS slides the icons over when one comes, goes or changes size, and Accessibility reports where they're going
/// straight away (seen on macOS 27.0.1 as CleanBar starts: its own icon comes in and the icons left of it move 38 points
/// at once). A picture taken meanwhile cuts the menu bar in the wrong places, giving an icon half of itself, the gap
/// next to it or its neighbor. So the items are pictured a moment after they're found where they were read, and only
/// those still there afterwards keep their picture.
enum ItemImageCapture {
    /// Long enough for the icons to finish sliding over.
    static let settleTime = Duration.milliseconds(500)

    /// `settle`: how long to wait before taking the picture, for icons that moved just before they were read.
    static func pictures(for items: [MenuBarItem], settle: Duration = settleTime) async -> [String: ItemPicture] {
        var visible = items.filter { $0.isOnScreen && $0.strip != nil }
        guard !visible.isEmpty else { return [:] }
        // Asked off the main thread, which it would hold up for a moment.
        let isAllowed = await Task.detached { Permissions.screenRecordingGranted }.value
        guard isAllowed else { return [:] }
        visible = await stillInPlace(visible)
        guard !visible.isEmpty else { return [:] }
        if settle > .zero {
            try? await Task.sleep(for: settle)
        }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        else { return [:] }

        var result: [String: ItemPicture] = [:]
        for (displayID, group) in Dictionary(grouping: visible, by: { $0.strip!.displayID }) {
            guard let strip = group.first?.strip,
                  let display = content.displays.first(where: { $0.displayID == displayID }),
                  let minX = group.map(\.frame.minX).min(),
                  let maxX = group.map(\.frame.maxX).max()
            else { continue }
            // Relative to the display, with the origin at its top-left corner.
            let region = CGRect(x: minX - strip.frame.minX, y: 0, width: maxX - minX, height: strip.frame.height)
            let span = minX...maxX
            let height = strip.frame.height

            // Going over the pictures pixel by pixel takes a while, and on the main thread it would stall the editor's
            // animations.
            let menuBars = content.windows.filter { isMenuBar($0, of: strip) }
            if !menuBars.isEmpty,
               let image = await capture(SCContentFilter(display: display, including: menuBars), region: region, scale: strip.scale) {
                let pictures = await Task.detached { () -> [String: ItemPicture] in
                    guard let clearShare = PixelBuffer(image)?.clearShare else { return [:] }
                    // Opaque when the menu bar has a background of its own, as with Reduce Transparency.
                    return cut(group, from: image, spanning: span, height: height, isTransparent: clearShare > 0.15)
                }.value
                result.merge(pictures) { _, new in new }
            }
            let missing = group.filter { result[$0.id] == nil }
            if !missing.isEmpty,
               let image = await capture(SCContentFilter(display: display, excludingWindows: []), region: region, scale: strip.scale) {
                let pictures = await Task.detached {
                    cut(missing, from: image, spanning: span, height: height, isTransparent: false)
                }.value
                result.merge(pictures) { _, new in new }
            }
        }
        let unmoved = Set(await stillInPlace(visible).map(\.id))
        return result.filter { unmoved.contains($0.key) }
    }

    /// The items that are still where they were read.
    private static func stillInPlace(_ items: [MenuBarItem]) async -> [MenuBarItem] {
        let frames = await Task.detached { MenuBarScanner.frames(of: items) }.value
        return items.filter { frames[$0.id] == $0.frame }
    }

    /// Cuts each item out of a picture of the menu bar that spans `span` across the screen.
    nonisolated private static func cut(
        _ items: [MenuBarItem], from image: CGImage, spanning span: ClosedRange<CGFloat>, height: CGFloat,
        isTransparent: Bool
    ) -> [String: ItemPicture] {
        let minX = span.lowerBound
        let scale = CGFloat(image.width) / (span.upperBound - minX)
        var result: [String: ItemPicture] = [:]
        for item in items {
            let crop = CGRect(
                x: (item.frame.minX - minX) * scale,
                y: 0,
                width: item.frame.width * scale,
                height: CGFloat(image.height)
            ).integral
            let size = CGSize(width: item.frame.width, height: height)
            if let cropped = image.cropping(to: crop),
               let picture = ItemPicture(cropped, size: size, isTransparent: isTransparent) {
                result[item.id] = picture
            }
        }
        return result
    }

    /// The window macOS draws the menu bar in: as wide as the screen, at its top, in the menu bar's window level.
    private static func isMenuBar(_ window: SCWindow, of strip: MenuBarStrip) -> Bool {
        window.windowLayer == Int(CGWindowLevelForKey(.mainMenuWindow))
            && window.frame.intersects(strip.frame)
            && window.frame.width >= strip.frame.width - 1
    }

    private static func capture(_ filter: SCContentFilter, region: CGRect, scale: CGFloat) async -> CGImage? {
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = region
        configuration.width = Int((region.width * scale).rounded())
        configuration.height = Int((region.height * scale).rounded())
        configuration.showsCursor = false
        // Where the filter leaves out every window, the picture stays transparent. A constant color, because the
        // configuration doesn't keep its color alive.
        configuration.backgroundColor = CGColor.clear
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}

nonisolated extension ItemPicture {
    /// Splits a picture of an item into its black-and-white and colored parts. A transparent picture shows only the
    /// item. An opaque one also shows what was behind it, which is taken out first. Nil when there's nothing drawn.
    init?(_ image: CGImage, size: CGSize, isTransparent: Bool) {
        guard var pixels = PixelBuffer(image) else { return nil }
        if !isTransparent {
            pixels.removeBackground()
        }
        let (glyph, color) = pixels.split()
        guard glyph != nil || color != nil else { return nil }
        let template = glyph.map { image in
            let template = NSImage(cgImage: image, size: size)
            template.isTemplate = true
            return template
        }
        self.init(glyph: template, color: color.map { NSImage(cgImage: $0, size: size) }, size: size)
    }
}

/// A picture as straight (not premultiplied) sRGB colors and alpha, each from 0 to 1, row by row from the top.
nonisolated struct PixelBuffer {
    let width: Int
    let height: Int
    private var red: [Float]
    private var green: [Float]
    private var blue: [Float]
    private var alpha: [Float]

    private static var colorSpace: CGColorSpace { CGColorSpace(name: CGColorSpace.sRGB)! }

    init?(_ image: CGImage) {
        let width = image.width
        let height = image.height
        let count = width * height
        guard count > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: count * 4)
        let isDrawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: Self.colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard isDrawn else { return nil }

        var red = [Float](repeating: 0, count: count)
        var green = red
        var blue = red
        var alpha = red
        for index in 0..<count {
            let a = Float(bytes[index * 4 + 3]) / 255
            alpha[index] = a
            guard a > 0 else { continue }
            red[index] = min(1, Float(bytes[index * 4]) / 255 / a)
            green[index] = min(1, Float(bytes[index * 4 + 1]) / 255 / a)
            blue[index] = min(1, Float(bytes[index * 4 + 2]) / 255 / a)
        }
        self.width = width
        self.height = height
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// The share of pixels that are clear, or nearly.
    var clearShare: Double {
        Double(alpha.count(where: { $0 < 0.1 })) / Double(alpha.count)
    }

    /// The first and last columns with a pixel that's more than faintly drawn. Nil when there's none.
    var drawnColumns: ClosedRange<Int>? {
        let drawn = (0..<width).filter { column in
            (0..<height).contains { row in alpha[row * width + column] > 0.1 }
        }
        guard let first = drawn.first, let last = drawn.last else { return nil }
        return first...last
    }

    /// Takes out what was behind the item, which shows at the picture's left and right ends, where items leave some
    /// room around their icon. Between the two ends it's blended, to follow a wallpaper that changes.
    ///
    /// Each pixel gets the least opacity that explains how it differs from that background. That's exact for the
    /// menu bar's white or black ink, but too faint for colored ink, so the picture is then made as opaque as its most
    /// opaque pixel allows: icons are drawn solid, apart from their edges.
    mutating func removeBackground() {
        guard width >= 4 else { return }
        // Partly transparent pixels count as drawn on black.
        for index in alpha.indices {
            red[index] *= alpha[index]
            green[index] *= alpha[index]
            blue[index] *= alpha[index]
            alpha[index] = 1
        }

        var left: [SIMD3<Float>] = []
        var right: [SIMD3<Float>] = []
        for row in 0..<height {
            let start = row * width
            left.append((color(start) + color(start + 1)) / 2)
            right.append((color(start + width - 2) + color(start + width - 1)) / 2)
        }

        var backgrounds = [SIMD3<Float>](repeating: .zero, count: alpha.count)
        var strongest: Float = 0
        for row in 0..<height {
            for column in 0..<width {
                let index = row * width + column
                let t = Float(column) / Float(width - 1)
                let behind = left[row] * (1 - t) + right[row] * t
                backgrounds[index] = behind
                let pixel = color(index)
                var amount: Float = 0
                for channel in 0..<3 {
                    let difference = pixel[channel] - behind[channel]
                    // How far the ink could go from the background in this direction. Near black or white there's
                    // little room, and a tiny difference there is only the wallpaper's texture.
                    let room = difference > 0 ? 1 - behind[channel] : behind[channel]
                    amount = max(amount, abs(difference) / max(room, 0.2))
                }
                // Ignore the small differences of a wallpaper's texture.
                let a = max(0, (min(amount, 1) - 0.08) / 0.92)
                alpha[index] = a
                strongest = max(strongest, a)
            }
        }

        let boost: Float = strongest > 0.35 ? 1 / strongest : 1
        for index in alpha.indices {
            let a = min(1, alpha[index] * boost)
            alpha[index] = a
            let behind = backgrounds[index]
            let straight = a > 0 ? behind + (color(index) - behind) / a : behind
            red[index] = min(max(straight.x, 0), 1)
            green[index] = min(max(straight.y, 0), 1)
            blue[index] = min(max(straight.z, 0), 1)
        }
    }

    /// The black-and-white parts as a template image (only its alpha counts), and the colored parts. Either is nil
    /// when it's empty. A picture that's mostly colored, like an app's logo, is kept whole as its colored part.
    func split() -> (glyph: CGImage?, color: CGImage?) {
        var colorfulness = [Float](repeating: 0, count: alpha.count)
        var inkLuminance: Float = 0
        var inkWeight: Float = 0
        var coloredWeight: Float = 0
        var totalWeight: Float = 0
        for index in alpha.indices where alpha[index] > 0.02 {
            let pixel = color(index)
            let saturation = pixel.max() - pixel.min()
            // The colors of faint pixels, like the edges of an icon, aren't reliable.
            let colored = Self.smoothstep(0.12, 0.3, saturation) * Self.smoothstep(0.1, 0.35, alpha[index])
            colorfulness[index] = colored
            inkLuminance += alpha[index] * (1 - colored) * Self.luminance(pixel)
            inkWeight += alpha[index] * (1 - colored)
            coloredWeight += alpha[index] * colored
            totalWeight += alpha[index]
        }
        guard totalWeight > 1 else { return (nil, nil) }
        if coloredWeight > totalWeight / 2 {
            return (nil, image(alpha: alpha, colored: true))
        }

        // White ink on a dark menu bar, or black ink on a light one. Parts in the other shade are gaps in the icon.
        let isLightInk = inkWeight == 0 || inkLuminance / inkWeight >= 0.5
        var glyphAlpha = [Float](repeating: 0, count: alpha.count)
        var colorAlpha = [Float](repeating: 0, count: alpha.count)
        for index in alpha.indices where alpha[index] > 0.02 {
            let luminance = Self.luminance(color(index))
            let tone = isLightInk ? luminance : 1 - luminance
            glyphAlpha[index] = alpha[index] * (1 - colorfulness[index]) * tone
            colorAlpha[index] = alpha[index] * colorfulness[index]
        }
        let glyph = glyphAlpha.reduce(0, +) > 1 ? image(alpha: glyphAlpha, colored: false) : nil
        let color = colorAlpha.reduce(0, +) > 1 ? image(alpha: colorAlpha, colored: true) : nil
        return (glyph, color)
    }

    private func color(_ index: Int) -> SIMD3<Float> {
        SIMD3(red[index], green[index], blue[index])
    }

    private func image(alpha values: [Float], colored: Bool) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: values.count * 4)
        for index in values.indices {
            let a = min(max(values[index], 0), 1)
            bytes[index * 4 + 3] = UInt8((a * 255).rounded())
            guard colored else { continue }
            bytes[index * 4] = UInt8((red[index] * a * 255).rounded())
            bytes[index * 4 + 1] = UInt8((green[index] * a * 255).rounded())
            bytes[index * 4 + 2] = UInt8((blue[index] * a * 255).rounded())
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: Self.colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    private static func luminance(_ color: SIMD3<Float>) -> Float {
        0.2126 * color.x + 0.7152 * color.y + 0.0722 * color.z
    }

    private static func smoothstep(_ low: Float, _ high: Float, _ value: Float) -> Float {
        let t = min(max((value - low) / (high - low), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
