import SwiftUI

/// The panel that opens from the menu bar icon.
@MainActor
struct MenuContentView: View {
    @EnvironmentObject var controller: WallpaperController
    @EnvironmentObject var prefs: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LayoutPreview(
                displays: controller.displays,
                image: controller.isAligning ? nil : controller.preview,
                imageSize: controller.isAligning ? nil : controller.previewPixelSize,
                focusX: prefs.focusX,
                focusY: prefs.focusY,
                zoom: prefs.zoom
            )
            .frame(height: 120)

            if controller.isAligning {
                HStack {
                    Text("Your screens are showing the alignment grid.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Done") { controller.stopAligning() }
                }
            }

            details

            if let error = controller.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button {
                    Task { await controller.fetchNew() }
                } label: {
                    Label("New wallpaper", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(controller.isBusy)

                if let label = controller.phase.label {
                    ProgressView().controlSize(.small)
                    Text(label)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            Divider()

            HStack {
                Button("Settings…") { SettingsWindowController.shared.show() }
                Spacer()
                Button("Quit DailySpread") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    @ViewBuilder
    private var details: some View {
        if let current = controller.current {
            VStack(alignment: .leading, spacing: 3) {
                Text(headline(for: current))
                    .font(.headline)
                if let title = current.title, current.sourceKind != .wallhaven {
                    Text(title)
                        .font(.caption)
                        .lineLimit(1)
                }
                if let credit = current.credit {
                    Text(credit)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Text(detailText(for: current))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(scheduleText(applied: current.appliedAt))
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack(spacing: 14) {
                    if !current.pageURL.isEmpty {
                        Button("View on \(current.sourceKind.label)") { controller.openSourcePage() }
                    }
                    Button("Show in Finder") { controller.revealOriginal() }
                }
                .buttonStyle(.link)
                .font(.caption)
                .padding(.top, 2)
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text("No wallpaper yet").font(.headline)
                Text("The first one is on its way, or click New wallpaper.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func headline(for wallpaper: CurrentWallpaper) -> String {
        if wallpaper.sourceKind == .otherApp { return "From another app" }
        guard let topic = wallpaper.topic, !topic.isEmpty else { return wallpaper.sourceKind.label }
        return "\(Topic.label(for: topic)) · \(wallpaper.sourceKind.label)"
    }

    /// Size, and how much detail survives on these displays.
    private func detailText(for wallpaper: CurrentWallpaper) -> String {
        let size = "\(wallpaper.width) × \(wallpaper.height)"
        guard let sharpness = wallpaper.sharpness, sharpness > 0 else { return size }
        if sharpness >= 0.98 { return "\(size) · full detail on your screens" }
        return "\(size) · enlarged \(String(format: "%.1f", 1 / sharpness))× to fill your screens"
    }

    private func scheduleText(applied: Date) -> String {
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let changed = "Changed \(formatter.string(from: applied).lowercasedFirstIfRelative)"
        guard let next = controller.nextChange else {
            return prefs.followOtherApps ? "\(changed) · following your wallpaper app" : "\(changed) · daily changes paused"
        }
        if next <= Date().addingTimeInterval(60) { return "\(changed) · next one due now" }
        return "\(changed) · next \(formatter.string(from: next).lowercasedFirstIfRelative)"
    }
}

private extension String {
    /// "Today at 09:00" reads better mid-sentence as "today at 09:00".
    var lowercasedFirstIfRelative: String {
        for word in ["Today", "Tomorrow", "Yesterday"] where hasPrefix(word) {
            return word.lowercased() + dropFirst(word.count)
        }
        return self
    }
}

/// The menu bar icon; it switches to arrows while a wallpaper is being fetched.
@MainActor
struct MenuBarIcon: View {
    @EnvironmentObject var controller: WallpaperController

    var body: some View {
        Image(systemName: controller.isBusy ? "arrow.triangle.2.circlepath" : "display.2")
    }
}
