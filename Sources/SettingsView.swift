import SwiftUI
import ServiceManagement

enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var isEnabled: Bool { status == .enabled || status == .requiresApproval }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

/// Login-item state for the Settings window.
@MainActor
final class LoginItemState: ObservableObject {
    static let shared = LoginItemState()

    @Published private(set) var isEnabled = LoginItem.isEnabled
    @Published private(set) var message: String?

    var binding: Binding<Bool> {
        Binding(get: { self.isEnabled }, set: { self.set($0) })
    }

    func set(_ enabled: Bool) {
        if enabled != LoginItem.isEnabled {
            try? LoginItem.set(enabled)
        }
        refresh()
    }

    func refresh() {
        isEnabled = LoginItem.isEnabled
        message = LoginItem.status == .requiresApproval
            ? "Allow DailySpread in System Settings to open it at login."
            : nil
    }
}

@MainActor
struct SettingsView: View {
    @EnvironmentObject var controller: WallpaperController
    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var login: LoginItemState

    var body: some View {
        Form {
            sourcesSection
            topicsSection
            wallhavenSection
            displaysSection
            layoutSection
            scheduleSection
            generalSection
            actionsSection
        }
        .formStyle(.grouped)
        .frame(width: 580, height: 860)
        .onAppear { login.refresh() }
    }

    // MARK: - Sources

    private var sourcesSection: some View {
        Section("Sources") {
            Toggle(isOn: $prefs.useWallhaven) {
                sourceLabel("Wallhaven", "A big wallpaper library, including photos, art and game shots.")
            }
            Toggle(isOn: $prefs.useCommons) {
                sourceLabel("Wikimedia Commons featured pictures", "Photos voted the best on Wikimedia Commons, freely licensed and often larger than 8K. The photographer is credited in the menu.")
            }
            Toggle(isOn: $prefs.useCommonsQuality) {
                sourceLabel("Wikimedia Commons quality images", "Hundreds of thousands of freely licensed photos that passed Commons' quality review, cars included. The widest choice of the lot.")
            }
            Toggle(isOn: $prefs.useNASA) {
                sourceLabel("NASA Image Library", "Public-domain pictures of space, and of Earth seen from orbit on nature days. Most are well under 8K, so it rarely finds one big enough unless you lower the minimum size.")
            }
            flickrSettings
            Toggle(isOn: $prefs.useFolder) {
                sourceLabel("A folder of your own pictures", "For example photos you download from unsplash.com. DailySpread picks the ones that will look sharpest.")
            }
            if prefs.useFolder {
                LabeledContent("Folder") {
                    HStack {
                        Text(prefs.folderPath.isEmpty ? "None chosen" : (prefs.folderPath as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundColor(prefs.folderPath.isEmpty ? .secondary : .primary)
                        Button("Choose…") { chooseFolder() }
                    }
                }
                HStack {
                    Text("Unsplash's terms don't allow other apps to fetch its photos automatically, but you can download them yourself.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Open Unsplash 8K") {
                        NSWorkspace.shared.open(URL(string: "https://unsplash.com/s/photos/8k-wallpaper")!)
                    }
                }
            }
            Toggle(isOn: $prefs.followOtherApps) {
                sourceLabel("Spread wallpapers from another app", "Keep using Unsplash Wallpapers (or any app) to choose pictures: whenever it sets one, DailySpread spreads it across your displays. DailySpread stops choosing its own while this is on.")
            }
        }
    }

    @ViewBuilder
    private var flickrSettings: some View {
        Toggle(isOn: $prefs.useFlickr) {
            sourceLabel("Flickr", "Creative Commons photos at full size, from Flickr's most interesting. Needs a free Flickr API key, which takes a minute to get with a Flickr account.")
        }
        if prefs.useFlickr {
            LabeledContent("Flickr API key") {
                HStack {
                    SecureField("Key", text: $prefs.flickrKey, prompt: Text("Paste your key"))
                        .textFieldStyle(.roundedBorder)
                    Button("Get a Free Key") {
                        NSWorkspace.shared.open(URL(string: "https://www.flickr.com/services/apps/create/apply/")!)
                    }
                }
            }
            Text(prefs.flickrKey.trimmingCharacters(in: .whitespaces).isEmpty
                 ? "Choose “Apply for a non-commercial key”, then paste the Key here (not the Secret). This product uses the Flickr API but is not endorsed or certified by SmugMug, Inc."
                 : "This product uses the Flickr API but is not endorsed or certified by SmugMug, Inc. Photographers keep their rights; each one is credited in the menu.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sourceLabel(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose a folder of pictures for DailySpread to spread across your displays."
        if !prefs.folderPath.isEmpty { panel.directoryURL = URL(fileURLWithPath: prefs.folderPath) }
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            prefs.folderPath = url.path
        }
    }

    // MARK: - Topics

    private var topicsSection: some View {
        Section("Topics") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4), alignment: .leading, spacing: 8) {
                ForEach(Topic.presets) { topic in
                    Toggle(topic.label, isOn: Binding(
                        get: { prefs.isTopicOn(topic) },
                        set: { prefs.setTopic(topic, on: $0) }
                    ))
                    .toggleStyle(.checkbox)
                }
            }
            .padding(.vertical, 2)
            TextField("Also search for", text: $prefs.customTopics, prompt: Text("e.g. porsche, waterfall, aurora"))
            Picker("With several topics", selection: $prefs.topicOrder) {
                ForEach(TopicOrder.allCases) { order in
                    Text(order.label).tag(order)
                }
            }
            .disabled(prefs.activeTopics.count < 2)
            Text(topicsHint)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var topicsHint: String {
        let names = prefs.activeTopics.map { Topic.label(for: $0) }
        let applies = "Changes apply from the next wallpaper."
        switch names.count {
        case 0:
            return "No topic chosen, so any image can come up. \(applies)"
        case 1:
            return "Every wallpaper will be \(names[0].lowercased()). \(applies)"
        default:
            let list = names.dropLast().joined(separator: ", ") + " and " + names.last!
            let how = prefs.topicOrder == .inTurn ? "takes turns between" : "picks at random from"
            return "Each day DailySpread \(how) \(list.lowercased()), and between your sources. \(applies)"
        }
    }

    // MARK: - Wallhaven and size

    private var wallhavenSection: some View {
        Section("Image size and Wallhaven") {
            Picker("Minimum size", selection: $prefs.minimumWidth) {
                Text("4K · 3840 px").tag(3840)
                Text("5K · 5120 px").tag(5120)
                Text("6K · 6016 px").tag(6016)
                Text("8K · 7680 px").tag(7680)
                Text("10K · 10240 px").tag(10240)
            }
            Text(sizeHint)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Prefer images shaped like my displays", isOn: $prefs.matchDisplayShape)
            LabeledContent("Wallhaven categories") {
                HStack(spacing: 14) {
                    Toggle("General", isOn: $prefs.includeGeneral)
                    Toggle("Anime", isOn: $prefs.includeAnime)
                    Toggle("People", isOn: $prefs.includePeople)
                }
                .toggleStyle(.checkbox)
            }
            Picker("Wallhaven order", selection: $prefs.order) {
                ForEach(PickOrder.allCases) { order in
                    Text(order.label).tag(order)
                }
            }
        }
    }

    /// How wide an image needs to be to show full detail across these displays.
    private var sizeHint: String {
        let need = controller.layout.need
        guard need.canvas.width > 0, need.maxPixelsPerUnit > 0 else { return "" }
        let fullWidth = Int((need.canvas.width * need.maxPixelsPerUnit).rounded())
        let screens = controller.displays.count == 1 ? "your display" : "your displays"
        return "For full detail across \(screens), an image as wide as they are needs about \(fullWidth.formatted()) pixels. DailySpread picks the sharpest image it finds above the minimum; smaller ones are enlarged slightly."
    }

    // MARK: - Displays

    private var displaysSection: some View {
        Section("Displays") {
            ForEach(controller.displays) { display in
                LabeledContent(display.name) {
                    Text(describe(display))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
            Toggle(isOn: $prefs.matchPhysicalSize) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Match real screen sizes")
                    Text("Lays the picture out in millimetres, so it carries on at the same size from one screen to the next even when the screens differ in size and sharpness.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!physicalSizesKnown)
            if prefs.matchPhysicalSize && !controller.layout.isPhysical && controller.displays.count > 1 {
                Text(physicalSizesKnown
                     ? "Real-size layout needs the displays side by side or stacked; using the macOS arrangement instead."
                     : "A display doesn't report its size, so DailySpread uses the macOS arrangement.")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
    }

    private var physicalSizesKnown: Bool {
        controller.displays.allSatisfy { $0.physicalSize != nil }
    }

    private func describe(_ display: DisplaySnapshot) -> String {
        var parts: [String] = []
        if let inches = display.diagonalInches { parts.append(String(format: "%.1f″", inches)) }
        parts.append("\(Int(display.nativePixels.width)) × \(Int(display.nativePixels.height))")
        if let ppi = display.pixelsPerInch { parts.append("\(Int(ppi.rounded())) ppi") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Layout

    private var layoutSection: some View {
        Section("Layout") {
            LayoutPreview(
                displays: controller.displays,
                image: controller.isAligning ? nil : controller.preview,
                imageSize: controller.isAligning ? nil : controller.previewPixelSize,
                focusX: prefs.focusX,
                focusY: prefs.focusY,
                zoom: prefs.zoom,
                showsNames: true
            )
            .frame(height: 150)
            .padding(.vertical, 4)

            if controller.layout.isPhysical {
                valueSlider("Gap between pictures", value: $prefs.gapMillimetres, range: 0...80, step: 0.5) {
                    String(format: "%.1f mm", $0)
                }
                ForEach(Array(controller.displays.dropFirst())) { display in
                    valueSlider(offsetTitle(for: display), value: offsetBinding(for: display), range: -200...200, step: 0.5) {
                        offsetLabel($0)
                    }
                }
            } else {
                valueSlider("Bezel gap", value: $prefs.gapPoints, range: 0...300, step: 1) { "\(Int($0)) pt" }
            }
            valueSlider("Zoom", value: $prefs.zoom, range: 1...2, step: 0.01) { "\(Int(($0 * 100).rounded()))%" }
                .disabled(controller.isAligning || controller.current == nil)
            valueSlider("Horizontal", value: $prefs.focusX, range: 0...1, step: 0.01) { position($0, low: "left", high: "right") }
                .disabled(!room.horizontally)
            valueSlider("Vertical", value: $prefs.focusY, range: 0...1, step: 0.01) { position($0, low: "top", high: "bottom") }
                .disabled(!room.vertically)
            if let note = positionNote {
                Text(note)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top) {
                Text(alignmentHelp)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                VStack(alignment: .trailing) {
                    if controller.isAligning {
                        Button("Done") { controller.stopAligning() }
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button("Show Alignment Grid") { controller.startAligning() }
                            .disabled(controller.displays.count < 2)
                    }
                    Button("Reset Position") {
                        prefs.focusX = 0.5
                        prefs.focusY = 0.5
                        prefs.zoom = 1
                    }
                }
            }
        }
    }

    /// Which ways the current picture can move: only the part hanging over the screens' edges can.
    private var room: (horizontally: Bool, vertically: Bool) {
        guard !controller.isAligning, let size = controller.previewPixelSize else { return (true, true) }
        return Placement.canMove(imageSize: size, canvas: controller.layout.canvas, zoom: prefs.zoom)
    }

    private var positionNote: String? {
        guard !controller.isAligning, controller.previewPixelSize != nil else { return nil }
        let zoomed = prefs.zoom > 1.001
        switch (room.horizontally, room.vertically) {
        case (true, false):
            return "This picture is wider than your screens put together, so it already fills them from top to bottom and can't move up or down. Zoom in to make room to move it vertically."
        case (false, true):
            return "This picture is taller than your screens put together, so it already fills them from side to side and can't move left or right. Zoom in to make room to move it sideways."
        case (false, false):
            return "This picture is exactly the shape of your screens, so there's nothing to move. Zoom in to choose which part to show."
        case (true, true):
            return zoomed ? "Zoom goes back to 100% when the next picture arrives." : nil
        }
    }

    private var alignmentHelp: String {
        if controller.isAligning {
            return controller.layout.isPhysical
                ? "Your screens show a test grid. Change the gap until the diagonal lines meet at the seam without a jump, then the height until the horizontal lines continue straight across."
                : "Your screens show a test grid. Change the gap until the diagonal lines meet at the seam without a jump."
        }
        return "Show the alignment grid to line the picture up across your screens by eye. Position chooses which part of the picture is kept when it's cropped."
    }

    private func offsetTitle(for display: DisplaySnapshot) -> String {
        controller.layout.arrangement == .column ? "\(display.name) sideways" : "\(display.name) height"
    }

    private func offsetBinding(for display: DisplaySnapshot) -> Binding<Double> {
        Binding(
            get: { prefs.displayOffsets[display.key] ?? 0 },
            set: { prefs.displayOffsets[display.key] = $0 }
        )
    }

    private func offsetLabel(_ value: Double) -> String {
        if abs(value) < 0.25 { return "level" }
        let column = controller.layout.arrangement == .column
        let direction = value > 0 ? (column ? "right" : "higher") : (column ? "left" : "lower")
        return String(format: "%.1f mm %@", abs(value), direction)
    }

    private func valueSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        format: @escaping (Double) -> String
    ) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range, step: step)
                Text(format(value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(width: 92, alignment: .trailing)
            }
        }
    }

    private func position(_ value: Double, low: String, high: String) -> String {
        if abs(value - 0.5) < 0.01 { return "centre" }
        return value < 0.5 ? "\(Int(((0.5 - value) * 200).rounded()))% \(low)" : "\(Int(((value - 0.5) * 200).rounded()))% \(high)"
    }

    // MARK: - Schedule and general

    private var scheduleSection: some View {
        Section("Schedule") {
            Toggle("Change the wallpaper every day", isOn: $prefs.dailyChangesEnabled)
                .disabled(prefs.followOtherApps)
            DatePicker("Change at", selection: changeTime, displayedComponents: .hourAndMinute)
                .disabled(!prefs.dailyChangesEnabled || prefs.followOtherApps)
            Text(prefs.followOtherApps
                 ? "While DailySpread is spreading another app's wallpapers, that app decides when they change."
                 : "If your Mac is asleep or off at that time, it changes as soon as it wakes.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var changeTime: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: prefs.changeHour, minute: prefs.changeMinute, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                prefs.changeHour = parts.hour ?? 9
                prefs.changeMinute = parts.minute ?? 0
            }
        )
    }

    private var generalSection: some View {
        Section("General") {
            Toggle("Open at login", isOn: login.binding)
            if let message = login.message {
                HStack {
                    Text(message).font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                }
            }
            Toggle("Keep the wallpaper on every Space", isOn: $prefs.keepOnAllSpaces)
            Toggle("Save a copy of each download in Pictures › DailySpread", isOn: $prefs.saveCopies)
        }
    }

    private var actionsSection: some View {
        Section {
            HStack {
                Button("Get a New Wallpaper Now") { Task { await controller.fetchNew() } }
                    .disabled(controller.isBusy)
                Button("Re-apply") { Task { await controller.reapply() } }
                    .disabled(controller.isBusy || controller.current == nil)
                Spacer()
                if let label = controller.phase.label {
                    ProgressView().controlSize(.small)
                    Text(label).font(.caption).foregroundColor(.secondary)
                }
            }
            if let error = controller.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Pictures belong to their creators. Wikimedia Commons photos are freely licensed; the menu shows each photographer and licence.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A plain window for Settings, since a menu bar app has no Settings menu item to hang one off.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let root = SettingsView()
                .environmentObject(WallpaperController.shared)
                .environmentObject(Preferences.shared)
                .environmentObject(LoginItemState.shared)
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.title = "DailySpread Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
