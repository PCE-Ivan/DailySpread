import AppKit
import Combine
import os

private let log = Logger(subsystem: "app.dailyspread.DailySpread", category: "wallpaper")

/// The wallpaper on screen now, saved across launches.
struct CurrentWallpaper: Codable, Equatable {
    var id: String
    var pageURL: String
    var width: Int
    var height: Int
    var localPath: String
    var appliedAt: Date
    /// The search term it was found with; empty or missing for "anything".
    var topic: String?
    /// Missing for wallpapers from versions before sources existed, which were all Wallhaven.
    var source: SourceKind?
    var title: String?
    var credit: String?
    /// Image pixels per panel pixel on the sharpest display; 1 or more is full detail.
    var sharpness: Double?

    var localURL: URL { URL(fileURLWithPath: localPath) }
    var sourceKind: SourceKind { source ?? .wallhaven }
}

/// Where DailySpread keeps its files: ~/Library/Application Support/DailySpread.
enum Storage {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DailySpread", isDirectory: true)
    }
    /// Downloaded full-size images.
    static var originals: URL { folder("Originals") }
    /// One slice per display, set as each display's desktop picture.
    static var rendered: URL { folder("Rendered") }

    private static func folder(_ name: String) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Runs the daily schedule: finds an image, downloads it, cuts it per display and sets it.
@MainActor
final class WallpaperController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case searching(SourceKind?)
        case downloading(bytes: Int?)
        case rendering

        var label: String? {
            switch self {
            case .idle: return nil
            case .searching(let source):
                return source.map { "Looking on \($0.label)…" } ?? "Finding an image…"
            case .downloading(let bytes):
                guard let bytes, bytes > 0 else { return "Downloading…" }
                return "Downloading \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))…"
            case .rendering: return "Spreading across displays…"
            }
        }
    }

    static let shared = WallpaperController()

    @Published private(set) var current: CurrentWallpaper?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastError: String?
    @Published private(set) var layout: Layout = .empty
    @Published private(set) var preview: NSImage?
    @Published private(set) var previewPixelSize: CGSize?
    /// While true, the displays show a test grid instead of the photo, for lining them up.
    @Published private(set) var isAligning = false

    var displays: [DisplaySnapshot] { layout.displays }
    var isBusy: Bool { phase != .idle }

    private let prefs = Preferences.shared
    private let defaults = UserDefaults.standard
    private var renderedFiles: [CGDirectDisplayID: URL] = [:]
    private var previousRenderedFiles: [CGDirectDisplayID: URL] = [:]
    /// What the slices on screen were cut for: layout, crop position and grid or photo.
    private var renderedSignature = ""
    private var history: [String] = []
    /// Desktop pictures other apps set that have been spread already.
    private var adoptedPaths: [String] = []
    private var lastFailure: Date?
    private var needsReapply = false
    private var timers: [Timer] = []
    private var screenChangeWork: DispatchWorkItem?
    private var subscriptions = Set<AnyCancellable>()
    private var started = false

    private init() {
        if let data = defaults.data(forKey: "current") {
            current = try? JSONDecoder().decode(CurrentWallpaper.self, from: data)
        }
        history = defaults.stringArray(forKey: "history") ?? []
        adoptedPaths = defaults.stringArray(forKey: "adoptedPaths") ?? []
        renderedSignature = defaults.string(forKey: "renderedSignature") ?? ""
        if let saved = defaults.dictionary(forKey: "renderedFiles") as? [String: String] {
            for (key, path) in saved {
                if let id = UInt32(key) { renderedFiles[id] = URL(fileURLWithPath: path) }
            }
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        refreshLayout()
        loadPreview()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in WallpaperController.shared.screensChanged() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                // Give Wi-Fi a moment to come back before checking whether a change is due.
                try? await Task.sleep(nanoseconds: 20 * 1_000_000_000)
                WallpaperController.shared.checkSchedule()
            }
        }
        workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in WallpaperController.shared.spaceChanged() }
        }
        let schedule = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in
            Task { @MainActor in WallpaperController.shared.checkSchedule() }
        }
        schedule.tolerance = 60
        // Other apps don't announce a new wallpaper, so look every so often.
        let follow = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            Task { @MainActor in WallpaperController.shared.adoptOtherAppsWallpaper() }
        }
        follow.tolerance = 5
        timers = [schedule, follow]

        // Any settings change that moves the picture re-cuts it once things settle.
        prefs.objectWillChange
            .sink { _ in
                Task { @MainActor in WallpaperController.shared.refreshLayout() }
            }
            .store(in: &subscriptions)
        prefs.objectWillChange
            .debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { _ in
                Task { @MainActor in
                    let controller = WallpaperController.shared
                    if controller.signature() != controller.renderedSignature { await controller.reapply() }
                }
            }
            .store(in: &subscriptions)

        // A change that's due re-cuts for the current displays anyway; otherwise re-cut only if
        // the displays changed while DailySpread wasn't running.
        if !checkSchedule(), current != nil, renderedSignature != signature() {
            Task { await reapply() }
        }
    }

    private func refreshLayout() {
        layout = DisplayLayout.current(prefs.layoutOptions)
    }

    /// Everything the slices on screen depend on.
    private func signature() -> String {
        let layout = DisplayLayout.current(prefs.layoutOptions)
        let mode = isAligning ? "grid" : "photo:\(current?.localPath ?? "")"
        return "\(layout.key)|\(prefs.focusX),\(prefs.focusY)x\(prefs.zoom)|\(mode)"
    }

    // MARK: - Schedule

    /// Starts a change if one is due. Returns whether it did.
    @discardableResult
    func checkSchedule() -> Bool {
        // While following another app, that app decides when the picture changes.
        guard prefs.dailyChangesEnabled, !prefs.followOtherApps, !isAligning, !isBusy else { return false }
        // After a failure, wait half an hour before trying again on our own.
        if let lastFailure, Date().timeIntervalSince(lastFailure) < 30 * 60 { return false }
        let due: Bool
        if let applied = current?.appliedAt {
            due = applied < mostRecentChangeTime(before: Date())
        } else {
            due = true
        }
        if due { Task { await fetchNew() } }
        return due
    }

    /// The latest scheduled change time that isn't in the future.
    private func mostRecentChangeTime(before now: Date) -> Date {
        let calendar = Calendar.current
        let today = calendar.date(bySettingHour: prefs.changeHour, minute: prefs.changeMinute, second: 0, of: now) ?? now
        if today <= now { return today }
        return calendar.date(byAdding: .day, value: -1, to: today) ?? today
    }

    /// When the next automatic change will happen, or nil if DailySpread isn't changing it itself.
    var nextChange: Date? {
        guard prefs.dailyChangesEnabled, !prefs.followOtherApps else { return nil }
        let now = Date()
        let last = mostRecentChangeTime(before: now)
        if let applied = current?.appliedAt, applied >= last {
            return Calendar.current.date(byAdding: .day, value: 1, to: last)
        }
        return now
    }

    // MARK: - Finding a new wallpaper

    /// Finds, downloads and applies a new image.
    func fetchNew() async {
        guard !isBusy else { return }
        if isAligning { isAligning = false }
        lastError = nil
        phase = .searching(nil)
        do {
            let layout = DisplayLayout.current(prefs.layoutOptions)
            let need = layout.need
            let attempts = attemptsInOrder()
            if attempts.isEmpty {
                throw SourceError.nothingFound(topics: prefs.activeTopics, minimumWidth: prefs.minimumWidth)
            }

            var found: (candidate: Candidate, topic: String)?
            var lastSourceError: Error?
            for attempt in attempts {
                phase = .searching(attempt.source)
                do {
                    let source = makeSource(attempt.source)
                    if let candidate = try await WallpaperChooser.choose(from: source, topic: attempt.topic, need: need, seen: Set(history)) {
                        found = (candidate, attempt.topic)
                        break
                    }
                } catch {
                    // One source being down shouldn't stop the others.
                    log.error("\(attempt.source.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                    lastSourceError = error
                }
            }
            guard let found else {
                throw lastSourceError ?? SourceError.nothingFound(topics: prefs.activeTopics, minimumWidth: prefs.minimumWidth)
            }
            let pick = found.candidate
            log.info("Picked \(pick.historyKey, privacy: .public) \(pick.width)x\(pick.height) for \(found.topic, privacy: .public)")

            let file: URL
            if let local = pick.localFile {
                file = local
            } else if let remote = pick.remoteURL {
                phase = .downloading(bytes: pick.fileSize)
                let ext = remote.pathExtension.isEmpty ? "jpg" : remote.pathExtension.lowercased()
                file = Storage.originals.appendingPathComponent("\(pick.source.rawValue)-\(Self.safeName(pick.id)).\(ext)")
                try await Downloader.file(from: remote, to: file, source: pick.source)
            } else {
                throw SpanError.unreadableImage
            }

            var wallpaper = CurrentWallpaper(
                id: pick.id, pageURL: pick.pageURL?.absoluteString ?? "",
                width: pick.width, height: pick.height,
                localPath: file.path, appliedAt: Date(), topic: found.topic,
                source: pick.source, title: pick.title, credit: pick.credit
            )
            phase = .rendering
            // Zoom suits one picture; a new one starts out just filling the screens.
            if prefs.zoom != 1 { prefs.zoom = 1 }
            wallpaper.sharpness = try await renderPhoto(file)

            current = wallpaper
            remember(pick.historyKey)
            defaults.set(defaults.integer(forKey: "changeCount") + 1, forKey: "changeCount")
            saveState()
            loadPreview()
            if pick.localFile == nil { pruneOriginals(keeping: file) }
            if prefs.saveCopies && pick.localFile == nil { saveCopy(of: file, wallpaper: wallpaper) }
            lastFailure = nil
        } catch {
            log.error("Fetching a new wallpaper failed: \(String(describing: error), privacy: .public)")
            lastFailure = Date()
            lastError = describe(error)
        }
        finish()
    }

    /// Which source and topic to try, best first. Topics take turns each change; sources take
    /// turns each time the topics come round again, so every topic visits every source. If the
    /// first choice has nothing, the same topic is tried on the other sources before moving on.
    private func attemptsInOrder() -> [(source: SourceKind, topic: String)] {
        let sources = prefs.enabledSources
        guard !sources.isEmpty else { return [] }
        let topics = prefs.activeTopics.isEmpty ? [""] : prefs.activeTopics
        let count = defaults.integer(forKey: "changeCount")
        let topicStart = prefs.topicOrder == .random ? Int.random(in: 0..<topics.count) : count % topics.count
        let sourceStart = (count / topics.count) % sources.count

        var attempts: [(source: SourceKind, topic: String)] = []
        var tried = Set<String>()
        for topic in Self.rotated(topics, from: topicStart) {
            for source in Self.rotated(sources, from: sourceStart) {
                // A folder isn't searched by topic, so it only needs one go.
                let attemptTopic = source == .folder ? "" : topic
                if tried.insert("\(source.rawValue)|\(attemptTopic)").inserted {
                    attempts.append((source, attemptTopic))
                }
            }
        }
        return attempts
    }

    private func makeSource(_ kind: SourceKind) -> WallpaperSource {
        switch kind {
        case .wallhaven, .otherApp:
            return WallhavenSource(
                categories: prefs.categoriesParameter, minimumWidth: prefs.minimumWidth,
                matchShape: prefs.matchDisplayShape, order: prefs.order
            )
        case .commons:
            return CommonsSource(collection: .featured, minimumWidth: prefs.minimumWidth)
        case .commonsQuality:
            return CommonsSource(collection: .quality, minimumWidth: prefs.minimumWidth)
        case .nasa:
            return NASASource(minimumWidth: prefs.minimumWidth)
        case .flickr:
            return FlickrSource(apiKey: prefs.flickrKey.trimmingCharacters(in: .whitespaces), minimumWidth: prefs.minimumWidth)
        case .folder:
            return FolderSource(folder: URL(fileURLWithPath: prefs.folderPath, isDirectory: true))
        }
    }

    private static func rotated<T>(_ items: [T], from start: Int) -> [T] {
        guard !items.isEmpty else { return items }
        let index = ((start % items.count) + items.count) % items.count
        return Array(items[index...] + items[..<index])
    }

    private static func safeName(_ id: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let cleaned = String(id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return String(cleaned.suffix(60))
    }

    // MARK: - Following another app

    /// When another app (Unsplash Wallpapers, System Settings, …) puts a new picture on the
    /// main display, spread that picture across all of them.
    func adoptOtherAppsWallpaper() {
        guard prefs.followOtherApps, !isBusy, !isAligning,
              let screen = NSScreen.screens.first,
              let shown = NSWorkspace.shared.desktopImageURL(for: screen) else { return }
        let path = shown.standardizedFileURL.path
        let ours = Storage.rendered.standardizedFileURL.path
        guard !path.hasPrefix(ours), !adoptedPaths.contains(path),
              FolderSource.imageExtensions.contains(shown.pathExtension.lowercased()),
              let size = SpanRenderer.pixelSize(at: shown) else { return }

        adoptedPaths.append(path)
        if adoptedPaths.count > 200 { adoptedPaths.removeFirst(adoptedPaths.count - 200) }
        defaults.set(adoptedPaths, forKey: "adoptedPaths")

        Task {
            guard !isBusy else { return }
            lastError = nil
            phase = .rendering
            do {
                // The other app may delete its file later; keep a copy to re-cut from.
                let copy = Storage.originals.appendingPathComponent("otherApp-\(Int(Date().timeIntervalSince1970)).\(shown.pathExtension.lowercased())")
                try? FileManager.default.removeItem(at: copy)
                try FileManager.default.copyItem(at: shown, to: copy)
                var wallpaper = CurrentWallpaper(
                    id: path, pageURL: "", width: Int(size.width), height: Int(size.height),
                    localPath: copy.path, appliedAt: Date(), topic: nil, source: .otherApp,
                    title: shown.deletingPathExtension().lastPathComponent, credit: nil
                )
                if prefs.zoom != 1 { prefs.zoom = 1 }
                wallpaper.sharpness = try await renderPhoto(copy)
                current = wallpaper
                saveState()
                loadPreview()
                pruneOriginals(keeping: copy)
            } catch {
                log.error("Spreading another app's wallpaper failed: \(String(describing: error), privacy: .public)")
                lastError = describe(error)
            }
            finish()
        }
    }

    // MARK: - Re-cutting

    /// Re-cuts the current image (or the grid), e.g. after the displays or the layout settings changed.
    func reapply() async {
        guard !isBusy else {
            needsReapply = true
            return
        }
        if isAligning {
            phase = .rendering
            do { try await renderGrid() } catch { lastError = describe(error) }
            finish()
            return
        }
        guard var wallpaper = current, FileManager.default.fileExists(atPath: wallpaper.localPath) else { return }
        phase = .rendering
        do {
            wallpaper.sharpness = try await renderPhoto(wallpaper.localURL)
            current = wallpaper
            saveState()
            lastError = nil
        } catch {
            log.error("Re-applying failed: \(String(describing: error), privacy: .public)")
            lastError = describe(error)
        }
        finish()
    }

    private func finish() {
        phase = .idle
        if needsReapply {
            needsReapply = false
            Task { await reapply() }
        }
    }

    func startAligning() {
        isAligning = true
        Task { await reapply() }
    }

    func stopAligning() {
        isAligning = false
        if current == nil {
            Task { await fetchNew() }
        } else {
            Task { await reapply() }
        }
    }

    // MARK: - Rendering

    private static var desktopOptions: [NSWorkspace.DesktopImageOptionKey: Any] {
        [.imageScaling: NSImageScaling.scaleAxesIndependently.rawValue, .allowClipping: true]
    }

    /// Cuts the photo at `source` for every display and sets the slices. Returns how sharp it looks.
    private func renderPhoto(_ source: URL) async throws -> Double {
        let layout = DisplayLayout.current(prefs.layoutOptions)
        self.layout = layout
        let need = layout.need
        let canvas = layout.canvas
        let displays = layout.displays
        let focusX = prefs.focusX
        let focusY = prefs.focusY
        let zoom = max(prefs.zoom, 1)
        let folder = Storage.rendered
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let signature = signature()

        let (outputs, sharpness): ([CGDirectDisplayID: URL], Double) = try await Task.detached(priority: .userInitiated) {
            // Huge originals are decoded at a little over the size the displays can show.
            let original = SpanRenderer.pixelSize(at: source) ?? .zero
            // Zooming in enlarges the picture, so less of its detail reaches each panel pixel.
            let fullSharpness = need.sharpness(width: Int(original.width), height: Int(original.height)) / zoom
            var maxPixels: Int?
            if fullSharpness > 1.15 {
                maxPixels = Int(Double(max(original.width, original.height)) * 1.15 / fullSharpness)
            }
            let image = try SpanRenderer.loadImage(at: source, maxPixelSize: maxPixels)
            let size = CGSize(width: image.width, height: image.height)
            let rect = Placement.imageRect(imageSize: size, canvas: canvas, focusX: focusX, focusY: focusY, zoom: zoom)
            let slices = try SpanRenderer.renderSlices(image, imageRect: rect, displays: displays, folder: folder, stamp: stamp)
            return (slices, fullSharpness)
        }.value

        try setDesktop(outputs)
        renderedSignature = signature
        saveState()
        return sharpness
    }

    private func renderGrid() async throws {
        let layout = DisplayLayout.current(prefs.layoutOptions)
        self.layout = layout
        let canvas = layout.canvas
        let displays = layout.displays
        let isPhysical = layout.isPhysical
        let pixelsPerUnit = layout.need.maxPixelsPerUnit
        let folder = Storage.rendered
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let signature = signature()

        let outputs: [CGDirectDisplayID: URL] = try await Task.detached(priority: .userInitiated) {
            guard let grid = SpanRenderer.alignmentPattern(canvas: canvas, isPhysical: isPhysical, pixelsPerUnit: pixelsPerUnit) else {
                throw SpanError.renderFailed
            }
            return try SpanRenderer.renderSlices(grid, imageRect: canvas, displays: displays, folder: folder, stamp: stamp)
        }.value

        try setDesktop(outputs)
        renderedSignature = signature
        saveState()
    }

    private func setDesktop(_ outputs: [CGDirectDisplayID: URL]) throws {
        var failures: [String] = []
        for screen in NSScreen.screens {
            guard let url = outputs[screen.displayID] else { continue }
            do {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: Self.desktopOptions)
            } catch {
                log.error("Setting the desktop on \(screen.localizedName, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                failures.append(screen.localizedName)
            }
        }
        if outputs != renderedFiles { previousRenderedFiles = renderedFiles }
        renderedFiles = outputs
        cleanRenderedFolder()
        if !failures.isEmpty {
            lastError = "The wallpaper couldn't be set on \(failures.joined(separator: ", "))."
        }
    }

    private func spaceChanged() {
        // A Space showing a new picture from another app gets that picture spread, not replaced.
        adoptOtherAppsWallpaper()
        keepOnThisSpace()
    }

    /// From Sonoma on, macOS sets a picture for the current Space only, so put ours back
    /// whenever a Space shows something else.
    func keepOnThisSpace() {
        guard prefs.keepOnAllSpaces, !renderedFiles.isEmpty, !isBusy else { return }
        for screen in NSScreen.screens {
            guard let url = renderedFiles[screen.displayID], FileManager.default.fileExists(atPath: url.path) else { continue }
            let shown = NSWorkspace.shared.desktopImageURL(for: screen)?.standardizedFileURL.path
            if shown != url.standardizedFileURL.path {
                try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: Self.desktopOptions)
            }
        }
    }

    private func screensChanged() {
        refreshLayout()
        screenChangeWork?.cancel()
        let work = DispatchWorkItem {
            Task { @MainActor in
                let controller = WallpaperController.shared
                if controller.signature() != controller.renderedSignature {
                    await controller.reapply()
                }
            }
        }
        screenChangeWork = work
        // Displays report several changes in a row while waking or rearranging; wait for them to settle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func loadPreview() {
        guard let current else {
            preview = nil
            previewPixelSize = nil
            return
        }
        let url = current.localURL
        Task.detached(priority: .utility) {
            let thumbnail = SpanRenderer.thumbnail(at: url, maxPixels: 1600)
            let image = thumbnail.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            let size = thumbnail.map { CGSize(width: $0.width, height: $0.height) }
            await MainActor.run {
                let controller = WallpaperController.shared
                controller.preview = image
                controller.previewPixelSize = size
            }
        }
    }

    // MARK: - Opening

    func openSourcePage() {
        guard let page = current?.pageURL, let url = URL(string: page), !page.isEmpty else { return }
        NSWorkspace.shared.open(url)
    }

    func revealOriginal() {
        guard let current else { return }
        NSWorkspace.shared.activateFileViewerSelecting([current.localURL])
    }

    // MARK: - Housekeeping

    private func remember(_ key: String) {
        // Once every match has been shown, the same image comes round again; start the history over.
        if history.contains(key) { history.removeAll() }
        history.append(key)
        if history.count > 2000 { history.removeFirst(history.count - 2000) }
    }

    private func saveState() {
        if let current, let data = try? JSONEncoder().encode(current) {
            defaults.set(data, forKey: "current")
        }
        defaults.set(history, forKey: "history")
        defaults.set(renderedSignature, forKey: "renderedSignature")
        var paths: [String: String] = [:]
        for (id, url) in renderedFiles { paths[String(id)] = url.path }
        defaults.set(paths, forKey: "renderedFiles")
    }

    /// Keeps the current and previous slices, so a Space still showing the last ones isn't left blank.
    private func cleanRenderedFolder() {
        let keep = Set(renderedFiles.values.map(\.lastPathComponent) + previousRenderedFiles.values.map(\.lastPathComponent))
        let folder = Storage.rendered
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where !keep.contains(name) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// Keeps the last week of downloads.
    private func pruneOriginals(keeping file: URL) {
        let folder = Storage.originals
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return }
        let dated = files.map { url -> (URL, Date) in
            let date = (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            return (url, date)
        }
        let doomed = dated.sorted { $0.1 > $1.1 }.dropFirst(7).map { $0.0 }
        for url in doomed where url.lastPathComponent != file.lastPathComponent {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func saveCopy(of file: URL, wallpaper: CurrentWallpaper) {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DailySpread", isDirectory: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let name = "\(formatter.string(from: Date())) \(wallpaper.sourceKind.rawValue)-\(Self.safeName(wallpaper.id)).\(file.pathExtension)"
        do {
            try FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
            let destination = pictures.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.copyItem(at: file, to: destination)
            }
        } catch {
            log.error("Saving a copy to Pictures failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func describe(_ error: Error) -> String {
        if let error = error as? SourceError, let description = error.errorDescription { return description }
        if let error = error as? SpanError, let description = error.errorDescription { return description }
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed:
                return "Couldn't reach the image sources. DailySpread will try again in about half an hour."
            default:
                break
            }
        }
        return error.localizedDescription
    }
}
