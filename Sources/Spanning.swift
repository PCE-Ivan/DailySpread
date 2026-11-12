import AppKit
import CoreImage
import ImageIO

/// One connected display, captured as plain values so rendering can run off the main thread.
struct DisplaySnapshot: Identifiable {
    let id: CGDirectDisplayID
    let name: String
    /// Stable across reconnects: vendor, model and serial number.
    let key: String
    /// Where the macOS arrangement puts the display, in points (y up).
    let pointFrame: CGRect
    /// Where the display sits in the layout the image is fitted to: millimetres in the
    /// real-size layout, points otherwise. y points up.
    let frame: CGRect
    /// The size macOS draws the desktop at (its backing store), in pixels.
    let pixelWidth: Int
    let pixelHeight: Int
    /// Pixels on the physical panel.
    let nativePixels: CGSize
    /// Panel size reported by the display, in millimetres; nil if it reports none.
    let physicalSize: CGSize?
    let colorSpace: CGColorSpace?

    /// Panel pixels per layout unit: how much image detail this display can show.
    var nativePixelsPerUnit: CGFloat { frame.width > 0 ? nativePixels.width / frame.width : 0 }

    var diagonalInches: Double? {
        guard let size = physicalSize else { return nil }
        return Double(hypot(size.width, size.height)) / 25.4
    }

    var pixelsPerInch: Double? {
        guard let size = physicalSize, size.width > 0 else { return nil }
        return Double(nativePixels.width) / (Double(size.width) / 25.4)
    }

    var layoutKey: String {
        "\(id):\(frame.minX),\(frame.minY),\(frame.width),\(frame.height)@\(pixelWidth)x\(pixelHeight)"
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

struct LayoutOptions: Equatable {
    var matchPhysicalSize: Bool
    var gapPoints: CGFloat
    var gapMillimetres: CGFloat
    var offsets: [String: Double]
}

/// How the displays sit relative to each other.
enum Arrangement {
    case single
    case row      // side by side
    case column   // stacked
    case other
}

/// What it takes for an image to look sharp across the displays.
struct ImageNeed {
    /// Size of the area the image is fitted to, in layout units.
    let canvas: CGSize
    /// The most panel pixels any display has per layout unit.
    let maxPixelsPerUnit: CGFloat

    var aspect: Double { canvas.height > 0 ? Double(canvas.width / canvas.height) : 16.0 / 9.0 }

    /// Image pixels per panel pixel on the sharpest display once the image fills the canvas.
    /// 1 or more means nothing gets enlarged.
    func sharpness(width: Int, height: Int) -> Double {
        guard width > 0, height > 0, canvas.width > 0, canvas.height > 0, maxPixelsPerUnit > 0 else { return 0 }
        let unitsPerImagePixel = max(canvas.width / CGFloat(width), canvas.height / CGFloat(height))
        return Double(1 / (unitsPerImagePixel * maxPixelsPerUnit))
    }

    /// The share of the image cut away to fit the canvas's shape.
    func crop(width: Int, height: Int) -> Double {
        guard width > 0, height > 0 else { return 1 }
        let imageAspect = Double(width) / Double(height)
        return 1 - min(imageAspect, aspect) / max(imageAspect, aspect)
    }

    /// Higher is better: full detail first, then as little cropping as possible.
    func score(width: Int, height: Int) -> Double {
        min(sharpness(width: width, height: height), 1) - 0.3 * crop(width: width, height: height)
    }
}

struct Layout {
    let displays: [DisplaySnapshot]
    /// True when laid out by real size in millimetres, false when by macOS points.
    let isPhysical: Bool
    let arrangement: Arrangement

    var canvas: CGRect { DisplayLayout.canvas(of: displays) }
    var unit: String { isPhysical ? "mm" : "pt" }
    var key: String { displays.map(\.layoutKey).sorted().joined(separator: "|") }

    var need: ImageNeed {
        let canvas = self.canvas
        return ImageNeed(
            canvas: canvas.isNull ? .zero : canvas.size,
            maxPixelsPerUnit: displays.map(\.nativePixelsPerUnit).max() ?? 0
        )
    }

    static let empty = Layout(displays: [], isPhysical: false, arrangement: .single)
}

enum DisplayLayout {
    private struct ScreenInfo {
        let id: CGDirectDisplayID
        let name: String
        let key: String
        let pointFrame: CGRect
        let scale: CGFloat
        let colorSpace: CGColorSpace?
        let physical: CGSize?
        let native: CGSize
    }

    @MainActor
    static func current(_ options: LayoutOptions) -> Layout {
        let infos = NSScreen.screens.map(info(for:))
        guard !infos.isEmpty else { return .empty }
        let pointFrames = infos.map(\.pointFrame)
        let arrangement = arrangement(of: pointFrames)

        var frames: [CGRect]?
        if options.matchPhysicalSize {
            frames = physicalFrames(infos, arrangement: arrangement, gap: options.gapMillimetres, offsets: options.offsets)
        }
        let isPhysical = frames != nil
        let layoutFrames = frames ?? spaced(pointFrames, gap: options.gapPoints)

        let displays = zip(infos, layoutFrames).map { info, frame in
            DisplaySnapshot(
                id: info.id,
                name: info.name,
                key: info.key,
                pointFrame: info.pointFrame,
                frame: frame,
                pixelWidth: Int((info.pointFrame.width * info.scale).rounded()),
                pixelHeight: Int((info.pointFrame.height * info.scale).rounded()),
                nativePixels: info.native,
                physicalSize: info.physical,
                colorSpace: info.colorSpace
            )
        }
        return Layout(displays: displays, isPhysical: isPhysical, arrangement: arrangement)
    }

    @MainActor
    private static func info(for screen: NSScreen) -> ScreenInfo {
        let id = screen.displayID
        let frame = screen.frame
        let landscape = frame.width >= frame.height
        let backing = CGSize(width: frame.width * screen.backingScaleFactor, height: frame.height * screen.backingScaleFactor)
        let native = oriented(nativePixelSize(id) ?? backing, landscape: landscape)
        let reported = CGDisplayScreenSize(id)
        let physical = isPlausible(reported) ? oriented(reported, landscape: landscape) : nil
        let key = "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
        return ScreenInfo(
            id: id, name: screen.localizedName, key: key, pointFrame: frame,
            scale: screen.backingScaleFactor, colorSpace: screen.colorSpace?.cgColorSpace,
            physical: physical, native: native
        )
    }

    /// The panel's own resolution: the mode macOS marks as native, or failing that the largest 1× mode.
    private static func nativePixelSize(_ id: CGDirectDisplayID) -> CGSize? {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode], !modes.isEmpty else { return nil }
        let nativeFlag: UInt32 = 0x0200_0000 // kDisplayModeNativeFlag
        if let native = modes.first(where: { $0.ioFlags & nativeFlag != 0 }) {
            return CGSize(width: native.pixelWidth, height: native.pixelHeight)
        }
        let oneToOne = modes.filter { $0.pixelWidth == $0.width }
        if let largest = oneToOne.max(by: { $0.pixelWidth < $1.pixelWidth }) {
            return CGSize(width: largest.pixelWidth, height: largest.pixelHeight)
        }
        return nil
    }

    private static func oriented(_ size: CGSize, landscape: Bool) -> CGSize {
        (size.width >= size.height) == landscape ? size : CGSize(width: size.height, height: size.width)
    }

    /// Some displays report no size, or a nonsense one.
    private static func isPlausible(_ millimetres: CGSize) -> Bool {
        guard millimetres.width > 0, millimetres.height > 0 else { return false }
        let inches = Double(hypot(millimetres.width, millimetres.height)) / 25.4
        return inches >= 9 && inches <= 100
    }

    static func arrangement(of frames: [CGRect]) -> Arrangement {
        guard frames.count > 1 else { return .single }
        let tolerance: CGFloat = 1
        let byX = frames.sorted { $0.minX < $1.minX }
        if zip(byX, byX.dropFirst()).allSatisfy({ $1.minX >= $0.maxX - tolerance }) { return .row }
        let byY = frames.sorted { $0.minY < $1.minY }
        if zip(byY, byY.dropFirst()).allSatisfy({ $1.minY >= $0.maxY - tolerance }) { return .column }
        return .other
    }

    /// Lays the displays out by real size: each panel takes its width in millimetres, with
    /// `gap` between pictures, and keeps the arrangement's offset across the seam (converted
    /// at the main display's scale) plus the user's correction. Nil when a display reports
    /// no size or the displays aren't in a single row or column.
    private static func physicalFrames(_ infos: [ScreenInfo], arrangement: Arrangement, gap: CGFloat, offsets: [String: Double]) -> [CGRect]? {
        guard infos.allSatisfy({ $0.physical != nil }), let main = infos.first, let mainSize = main.physical else { return nil }
        let millimetresPerPoint = mainSize.width / main.pointFrame.width
        var frames = Array(repeating: CGRect.zero, count: infos.count)

        switch arrangement {
        case .single:
            return [CGRect(origin: .zero, size: mainSize)]
        case .row:
            var x: CGFloat = 0
            for index in infos.indices.sorted(by: { infos[$0].pointFrame.minX < infos[$1].pointFrame.minX }) {
                let info = infos[index]
                let size = info.physical!
                let offset = index == 0 ? 0 : CGFloat(offsets[info.key] ?? 0)
                let centreY = (info.pointFrame.midY - main.pointFrame.midY) * millimetresPerPoint + offset
                frames[index] = CGRect(x: x, y: centreY - size.height / 2, width: size.width, height: size.height)
                x += size.width + gap
            }
            return frames
        case .column:
            var y: CGFloat = 0
            for index in infos.indices.sorted(by: { infos[$0].pointFrame.minY < infos[$1].pointFrame.minY }) {
                let info = infos[index]
                let size = info.physical!
                let offset = index == 0 ? 0 : CGFloat(offsets[info.key] ?? 0)
                let centreX = (info.pointFrame.midX - main.pointFrame.midX) * millimetresPerPoint + offset
                frames[index] = CGRect(x: centreX - size.width / 2, y: y, width: size.width, height: size.height)
                y += size.height + gap
            }
            return frames
        case .other:
            return nil
        }
    }

    /// Pushes displays apart so the image carries on behind the bezels: each seam a display
    /// sits beyond, horizontally or vertically, moves it one `gap` further out.
    static func spaced(_ frames: [CGRect], gap: CGFloat) -> [CGRect] {
        guard gap > 0, frames.count > 1 else { return frames }
        let tolerance: CGFloat = 1
        return frames.enumerated().map { index, frame in
            var columnSeams = Set<Int>()
            var rowSeams = Set<Int>()
            for (otherIndex, other) in frames.enumerated() where otherIndex != index {
                if other.maxX <= frame.minX + tolerance { columnSeams.insert(Int(other.maxX.rounded())) }
                if other.maxY <= frame.minY + tolerance { rowSeams.insert(Int(other.maxY.rounded())) }
            }
            return frame.offsetBy(dx: CGFloat(columnSeams.count) * gap, dy: CGFloat(rowSeams.count) * gap)
        }
    }

    /// The rectangle covering every display: the one image is fitted to this.
    static func canvas(of displays: [DisplaySnapshot]) -> CGRect {
        displays.reduce(CGRect.null) { $0.union($1.frame) }
    }
}

enum Placement {
    /// Where the whole image sits, in layout units, when it fills `canvas` without distortion.
    /// `focusX` 0 keeps the left edge in view and 1 the right; `focusY` 0 keeps the top and 1 the bottom.
    /// `zoom` above 1 enlarges it further, leaving room to move it both ways.
    static func imageRect(imageSize: CGSize, canvas: CGRect, focusX: Double, focusY: Double, zoom: Double = 1) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, !canvas.isNull, canvas.width > 0, canvas.height > 0 else {
            return .zero
        }
        let scale = max(canvas.width / imageSize.width, canvas.height / imageSize.height) * CGFloat(max(zoom, 1))
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        let x = canvas.minX + (canvas.width - width) * CGFloat(focusX)
        // Layout coordinates point up, so keeping the top in view means aligning the image's top edge.
        let y = canvas.minY + (canvas.height - height) * CGFloat(1 - focusY)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Whether the picture has room to move sideways and up or down: only the part that
    /// overhangs the screens can be brought into view.
    static func canMove(imageSize: CGSize, canvas: CGRect, zoom: Double) -> (horizontally: Bool, vertically: Bool) {
        let rect = imageRect(imageSize: imageSize, canvas: canvas, focusX: 0.5, focusY: 0.5, zoom: zoom)
        guard rect.width > 0, rect.height > 0 else { return (false, false) }
        return (rect.width - canvas.width > canvas.width * 0.002,
                rect.height - canvas.height > canvas.height * 0.002)
    }
}

enum SpanError: LocalizedError {
    case unreadableImage
    case renderFailed
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .unreadableImage: return "The image couldn't be opened."
        case .renderFailed: return "The wallpaper couldn't be drawn for one of the displays."
        case .writeFailed: return "The wallpaper file couldn't be saved."
        }
    }
}

/// Cuts one image into a slice per display. Safe off the main thread.
enum SpanRenderer {
    /// Pixel size of an image file, with its EXIF orientation applied, without decoding it.
    static func pixelSize(at url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    /// Decodes the image with its orientation applied, no larger than `maxPixelSize` on its
    /// long side: huge originals are scaled down while decoding to save memory.
    static func loadImage(at url: URL, maxPixelSize: Int? = nil) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw SpanError.unreadableImage }
        let size = pixelSize(at: url) ?? .zero
        let longSide = Int(max(size.width, size.height))
        if longSide > 0 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: min(longSide, maxPixelSize ?? longSide),
            ]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return image
            }
        }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, options) else { throw SpanError.unreadableImage }
        return image
    }

    /// A small, correctly oriented copy for previews.
    static func thumbnail(at url: URL, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Cuts `image` into one PNG per display and returns where each was written.
    static func renderSlices(
        _ image: CGImage,
        imageRect: CGRect,
        displays: [DisplaySnapshot],
        folder: URL,
        stamp: Int
    ) throws -> [CGDirectDisplayID: URL] {
        var result: [CGDirectDisplayID: URL] = [:]
        for display in displays {
            let slice = try render(image, imageRect: imageRect, on: display)
            // A new name every time: macOS caches desktop pictures by file URL.
            let url = folder.appendingPathComponent("display-\(display.id)-\(stamp).png")
            try writePNG(slice, to: url)
            result[display.id] = url
        }
        return result
    }

    /// Draws the part of `image` that falls on `display`, at the display's full pixel size,
    /// resampled with Lanczos and converted to the display's colour space.
    static func render(_ image: CGImage, imageRect: CGRect, on display: DisplaySnapshot) throws -> CGImage {
        let width = display.pixelWidth
        let height = display.pixelHeight
        guard width > 0, height > 0, display.frame.width > 0, display.frame.height > 0 else { throw SpanError.renderFailed }

        let pixelsPerUnitX = CGFloat(width) / display.frame.width
        let pixelsPerUnitY = CGFloat(height) / display.frame.height
        let target = CGRect(
            x: (imageRect.minX - display.frame.minX) * pixelsPerUnitX,
            y: (imageRect.minY - display.frame.minY) * pixelsPerUnitY,
            width: imageRect.width * pixelsPerUnitX,
            height: imageRect.height * pixelsPerUnitY
        )
        let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let space = display.colorSpace ?? srgb

        if let output = renderWithLanczos(image, into: target, width: width, height: height, space: space) {
            return output
        }
        return try renderWithCoreGraphics(image, into: target, width: width, height: height, space: space, fallback: srgb)
    }

    private static func renderWithLanczos(_ image: CGImage, into target: CGRect, width: Int, height: Int, space: CGColorSpace) -> CGImage? {
        guard space.model == .rgb, let filter = CIFilter(name: "CILanczosScaleTransform") else { return nil }
        let scale = target.width / CGFloat(image.width)
        let aspect = (target.height / CGFloat(image.height)) / scale
        // Clamping first keeps Lanczos from blending the picture's edges with transparency.
        let source = CIImage(cgImage: image).clampedToExtent()
        filter.setValue(source, forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue(aspect, forKey: kCIInputAspectRatioKey)
        guard let scaled = filter.outputImage else { return nil }
        let placed = scaled
            .cropped(to: CGRect(x: 0, y: 0, width: target.width, height: target.height))
            .transformed(by: CGAffineTransform(translationX: target.minX, y: target.minY))
        let output = CGRect(x: 0, y: 0, width: width, height: height)
        let background = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: output)
        let context = CIContext(options: [.outputColorSpace: space, .cacheIntermediates: false])
        return context.createCGImage(placed.composited(over: background), from: output, format: .RGBA8, colorSpace: space)
    }

    private static func renderWithCoreGraphics(_ image: CGImage, into target: CGRect, width: Int, height: Int, space: CGColorSpace, fallback: CGColorSpace) throws -> CGImage {
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue
        func makeContext(_ space: CGColorSpace) -> CGContext? {
            CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: 0, space: space, bitmapInfo: bitmapInfo)
        }
        guard let context = makeContext(space) ?? makeContext(fallback) else { throw SpanError.renderFailed }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: target)
        guard let output = context.makeImage() else { throw SpanError.renderFailed }
        return output
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw SpanError.writeFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw SpanError.writeFailed }
    }

    /// A test card the exact shape of the canvas: a grid, diagonals and circles that should
    /// run straight and unbroken across every seam once the gap and offsets are right.
    static func alignmentPattern(canvas: CGRect, isPhysical: Bool, pixelsPerUnit: CGFloat) -> CGImage? {
        guard canvas.width > 0, canvas.height > 0 else { return nil }
        let k = max(1, min(pixelsPerUnit, 12000 / canvas.width))
        let width = Int(canvas.width * k)
        let height = Int(canvas.height * k)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let unit = isPhysical ? CGFloat(1) : CGFloat(2.5) // one millimetre, or roughly one in points
        let step = 20 * unit * k
        let w = CGFloat(width)
        let h = CGFloat(height)

        context.setFillColor(CGColor(red: 0.07, green: 0.08, blue: 0.11, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // Grid: a line every 20 mm, a brighter one every 100 mm.
        var i = 0
        var y: CGFloat = 0
        while y <= h {
            let major = i % 5 == 0
            context.setStrokeColor(CGColor(gray: major ? 0.85 : 0.35, alpha: 1))
            context.setLineWidth((major ? 1.2 : 0.5) * unit * k)
            context.strokeLineSegments(between: [CGPoint(x: 0, y: y), CGPoint(x: w, y: y)])
            y += step
            i += 1
        }
        i = 0
        var x: CGFloat = 0
        while x <= w {
            let major = i % 5 == 0
            context.setStrokeColor(CGColor(gray: major ? 0.6 : 0.25, alpha: 1))
            context.setLineWidth((major ? 1.0 : 0.4) * unit * k)
            context.strokeLineSegments(between: [CGPoint(x: x, y: 0), CGPoint(x: x, y: h)])
            x += step
            i += 1
        }

        // Diagonals at 30° each way: any vertical or sideways mismatch at a seam shows as a kink.
        context.setLineWidth(1.5 * unit * k)
        let rise = tan(CGFloat.pi / 6)
        let spacing = 5 * step
        var start = -w * rise
        while start < h + w * rise {
            context.setStrokeColor(CGColor(red: 1, green: 0.55, blue: 0.1, alpha: 1))
            context.strokeLineSegments(between: [CGPoint(x: 0, y: start), CGPoint(x: w, y: start + w * rise)])
            context.setStrokeColor(CGColor(red: 0.2, green: 0.8, blue: 1, alpha: 1))
            context.strokeLineSegments(between: [CGPoint(x: 0, y: start + w * rise), CGPoint(x: w, y: start)])
            start += spacing
        }

        // Circles centred on the canvas.
        context.setStrokeColor(CGColor(red: 0.6, green: 1, blue: 0.4, alpha: 1))
        context.setLineWidth(1.5 * unit * k)
        var radius = 2 * spacing
        while radius < max(w, h) {
            context.strokeEllipse(in: CGRect(x: w / 2 - radius, y: h / 2 - radius, width: radius * 2, height: radius * 2))
            radius += 2 * spacing
        }
        return context.makeImage()
    }
}
