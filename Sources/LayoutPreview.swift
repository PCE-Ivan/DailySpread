import SwiftUI

/// Draws the display arrangement with the image laid across it, exactly as the renderer cuts it.
@MainActor
struct LayoutPreview: View {
    let displays: [DisplaySnapshot]
    let image: NSImage?
    let imageSize: CGSize?
    let focusX: Double
    let focusY: Double
    var zoom: Double = 1
    var showsNames = false

    var body: some View {
        Canvas { context, size in
            let canvas = DisplayLayout.canvas(of: displays)
            guard !displays.isEmpty, !canvas.isNull, canvas.width > 0, canvas.height > 0 else { return }

            let padding: CGFloat = 2
            let scale = min((size.width - padding * 2) / canvas.width, (size.height - padding * 2) / canvas.height)
            let originX = (size.width - canvas.width * scale) / 2
            let originY = (size.height - canvas.height * scale) / 2

            // Layout points point up; the view's coordinates point down.
            func toView(_ rect: CGRect) -> CGRect {
                CGRect(
                    x: originX + (rect.minX - canvas.minX) * scale,
                    y: originY + (canvas.maxY - rect.maxY) * scale,
                    width: rect.width * scale,
                    height: rect.height * scale
                )
            }

            var imageRect: CGRect?
            if let imageSize {
                imageRect = toView(Placement.imageRect(imageSize: imageSize, canvas: canvas, focusX: focusX, focusY: focusY, zoom: zoom))
            }
            let resolved = image.map { context.resolve(Image(nsImage: $0)) }

            for display in displays {
                let rect = toView(display.frame)
                let shape = Path(roundedRect: rect, cornerRadius: 3)
                context.drawLayer { layer in
                    layer.clip(to: shape)
                    if let resolved, let imageRect {
                        layer.draw(resolved, in: imageRect)
                    } else {
                        layer.fill(shape, with: .color(.gray.opacity(0.25)))
                    }
                }
                context.stroke(shape, with: .color(.primary.opacity(0.55)), lineWidth: 1)

                if showsNames {
                    let label = Text(display.name)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                    let point = CGPoint(x: rect.minX + 6, y: rect.maxY - 6)
                    var shadowed = context
                    shadowed.addFilter(.shadow(color: .black.opacity(0.8), radius: 2))
                    shadowed.draw(label, at: point, anchor: .bottomLeading)
                }
            }
        }
        .accessibilityLabel("Preview of the wallpaper across \(displays.count) display\(displays.count == 1 ? "" : "s")")
    }
}
