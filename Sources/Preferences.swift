import Foundation
import CoreGraphics
import Combine

/// How the next image is chosen from the matching Wallhaven results.
enum PickOrder: String, CaseIterable, Identifiable {
    case random
    case favorites
    case topYear
    case topMonth

    var id: String { rawValue }

    var label: String {
        switch self {
        case .random: return "Random"
        case .favorites: return "Most favourited first"
        case .topYear: return "Top of the past year"
        case .topMonth: return "Top of the past month"
        }
    }
}

/// A ready-made subject to pick wallpapers from.
struct Topic: Identifiable, Hashable {
    /// The Wallhaven tag searched for: single tags match far more 8K images than phrases do.
    let query: String
    let label: String
    /// What to search Wikimedia Commons for, whose files are described in prose rather than tagged.
    let commonsQuery: String
    var id: String { query }

    static let presets: [Topic] = [
        Topic(query: "nature", label: "Nature", commonsQuery: "landscape OR mountain OR forest OR lake OR waterfall OR valley"),
        Topic(query: "car", label: "Cars", commonsQuery: "car OR automobile OR \"sports car\""),
        Topic(query: "landscape", label: "Landscapes", commonsQuery: "landscape OR panorama"),
        Topic(query: "mountains", label: "Mountains", commonsQuery: "mountain OR mountains OR alps OR peak"),
        Topic(query: "forest", label: "Forests", commonsQuery: "forest OR woods"),
        Topic(query: "sea", label: "Sea", commonsQuery: "sea OR ocean OR coast OR beach"),
        Topic(query: "space", label: "Space", commonsQuery: "nebula OR galaxy OR \"milky way\" OR \"night sky\""),
        Topic(query: "city", label: "Cities", commonsQuery: "city OR skyline OR cityscape"),
        Topic(query: "architecture", label: "Architecture", commonsQuery: "architecture OR cathedral OR building"),
        Topic(query: "animals", label: "Animals", commonsQuery: "animal OR wildlife OR bird"),
        Topic(query: "abstract", label: "Abstract", commonsQuery: "abstract OR pattern"),
        Topic(query: "minimalism", label: "Minimal", commonsQuery: "minimalism OR minimal"),
    ]

    /// The name to show for a search term: a preset's label, or the term itself, capitalised.
    static func label(for query: String) -> String {
        if query.isEmpty { return "Anything" }
        return presets.first { $0.query == query }?.label ?? query.capitalized
    }

    static func commonsQuery(for query: String) -> String {
        presets.first { $0.query == query }?.commonsQuery ?? query
    }

    /// What to search NASA's library for: space itself, or Earth seen from orbit. Nil for
    /// topics NASA has nothing for, such as cars.
    static func nasaQuery(for query: String) -> String? {
        switch query {
        case "", "nature", "landscape": return ["earth from space", "aurora from space", "earth observatory"].randomElement()
        case "mountains": return "mountains from space"
        case "forest": return "forest from space"
        case "sea": return "ocean from space"
        case "space": return ["nebula", "galaxy", "star cluster", "webb telescope"].randomElement()
        case "city": return "city lights from space"
        case "car", "architecture", "animals", "abstract", "minimalism": return nil
        default: return query
        }
    }
}

/// With several topics, whether each change takes the next one or any one.
enum TopicOrder: String, CaseIterable, Identifiable {
    case inTurn
    case random

    var id: String { rawValue }

    var label: String {
        switch self {
        case .inTurn: return "Take turns"
        case .random: return "Mix at random"
        }
    }
}

/// User settings. Every change is written straight to UserDefaults.
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let store = UserDefaults.standard

    // Schedule
    @Published var dailyChangesEnabled: Bool { didSet { store.set(dailyChangesEnabled, forKey: "dailyChangesEnabled") } }
    @Published var changeHour: Int { didSet { store.set(changeHour, forKey: "changeHour") } }
    @Published var changeMinute: Int { didSet { store.set(changeMinute, forKey: "changeMinute") } }

    // Sources
    @Published var useWallhaven: Bool { didSet { store.set(useWallhaven, forKey: "useWallhaven") } }
    @Published var useCommons: Bool { didSet { store.set(useCommons, forKey: "useCommons") } }
    @Published var useCommonsQuality: Bool { didSet { store.set(useCommonsQuality, forKey: "useCommonsQuality") } }
    @Published var useNASA: Bool { didSet { store.set(useNASA, forKey: "useNASA") } }
    @Published var useFlickr: Bool { didSet { store.set(useFlickr, forKey: "useFlickr") } }
    /// The user's own free Flickr API key.
    @Published var flickrKey: String { didSet { store.set(flickrKey, forKey: "flickrKey") } }
    @Published var useFolder: Bool { didSet { store.set(useFolder, forKey: "useFolder") } }
    /// A folder of the user's own pictures, e.g. photos downloaded from unsplash.com.
    @Published var folderPath: String { didSet { store.set(folderPath, forKey: "folderPath") } }
    /// Spread whatever another app (such as Unsplash Wallpapers) puts on the desktop, instead of picking.
    @Published var followOtherApps: Bool { didSet { store.set(followOtherApps, forKey: "followOtherApps") } }

    // Topics and search
    /// Queries of the preset topics turned on, in preset order.
    @Published var topics: [String] { didSet { store.set(topics, forKey: "topics") } }
    /// Extra search terms, separated by commas.
    @Published var customTopics: String { didSet { store.set(customTopics, forKey: "customTopics") } }
    @Published var topicOrder: TopicOrder { didSet { store.set(topicOrder.rawValue, forKey: "topicOrder") } }
    @Published var includeGeneral: Bool { didSet { store.set(includeGeneral, forKey: "includeGeneral") } }
    @Published var includeAnime: Bool { didSet { store.set(includeAnime, forKey: "includeAnime") } }
    @Published var includePeople: Bool { didSet { store.set(includePeople, forKey: "includePeople") } }
    /// Long side of the image, in pixels. 7680 is 8K.
    @Published var minimumWidth: Int { didSet { store.set(minimumWidth, forKey: "minimumWidth") } }
    @Published var matchDisplayShape: Bool { didSet { store.set(matchDisplayShape, forKey: "matchDisplayShape") } }
    @Published var order: PickOrder { didSet { store.set(order.rawValue, forKey: "order") } }

    // Layout
    /// Lay displays out by their real size in millimetres rather than by macOS points.
    @Published var matchPhysicalSize: Bool { didSet { store.set(matchPhysicalSize, forKey: "matchPhysicalSize") } }
    /// Space at each seam for the frames between the pictures, in millimetres (real-size layout).
    @Published var gapMillimetres: Double { didSet { store.set(gapMillimetres, forKey: "gapMillimetres") } }
    /// The same, in points, for the macOS-arrangement layout.
    @Published var gapPoints: Double { didSet { store.set(gapPoints, forKey: "gapPoints") } }
    /// How far each secondary display's picture sits above (+) or below (−) where the
    /// arrangement puts it, in millimetres, keyed by `DisplaySnapshot.key`.
    @Published var displayOffsets: [String: Double] { didSet { store.set(displayOffsets, forKey: "displayOffsets") } }
    /// 0 shows the left edge of the image, 1 the right edge.
    @Published var focusX: Double { didSet { store.set(focusX, forKey: "focusX") } }
    /// 0 shows the top of the image, 1 the bottom.
    @Published var focusY: Double { didSet { store.set(focusY, forKey: "focusY") } }
    /// Enlarges the picture beyond just filling the screens, so it can be moved both ways.
    /// 1 means just filling them. Goes back to 1 with each new picture.
    @Published var zoom: Double { didSet { store.set(zoom, forKey: "zoom") } }

    // General
    @Published var keepOnAllSpaces: Bool { didSet { store.set(keepOnAllSpaces, forKey: "keepOnAllSpaces") } }
    @Published var saveCopies: Bool { didSet { store.set(saveCopies, forKey: "saveCopies") } }

    private init() {
        let defaults = UserDefaults.standard
        func read<T>(_ key: String, _ fallback: T) -> T { defaults.object(forKey: key) as? T ?? fallback }

        dailyChangesEnabled = read("dailyChangesEnabled", true)
        changeHour = read("changeHour", 9)
        changeMinute = read("changeMinute", 0)
        useWallhaven = read("useWallhaven", true)
        useCommons = read("useCommons", true)
        useCommonsQuality = read("useCommonsQuality", true)
        // Off by default: most of NASA's library is well under 8K.
        useNASA = read("useNASA", false)
        useFlickr = read("useFlickr", false)
        flickrKey = read("flickrKey", "")
        useFolder = read("useFolder", false)
        folderPath = read("folderPath", "")
        followOtherApps = read("followOtherApps", false)
        // Nature and cars to start with; changed in Settings › Topics.
        topics = read("topics", ["nature", "car"])
        // The first version had a single search box; carry what was typed there over.
        customTopics = read("customTopics", read("searchQuery", ""))
        topicOrder = TopicOrder(rawValue: read("topicOrder", TopicOrder.inTurn.rawValue)) ?? .inTurn
        includeGeneral = read("includeGeneral", true)
        includeAnime = read("includeAnime", false)
        includePeople = read("includePeople", false)
        minimumWidth = read("minimumWidth", 7680)
        matchDisplayShape = read("matchDisplayShape", true)
        order = PickOrder(rawValue: read("order", PickOrder.random.rawValue)) ?? .random
        matchPhysicalSize = read("matchPhysicalSize", true)
        gapMillimetres = read("gapMillimetres", 0.0)
        gapPoints = read("gapPoints", 0.0)
        displayOffsets = read("displayOffsets", [String: Double]())
        focusX = read("focusX", 0.5)
        focusY = read("focusY", 0.5)
        zoom = read("zoom", 1.0)
        keepOnAllSpaces = read("keepOnAllSpaces", true)
        saveCopies = read("saveCopies", false)
    }

    /// Every search term in use: the preset topics turned on, then the custom ones.
    /// Empty means anything goes.
    var activeTopics: [String] {
        let presets = Topic.presets.map(\.query).filter { topics.contains($0) }
        let custom = customTopics
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        return (presets + custom).filter { seen.insert($0).inserted }
    }

    func isTopicOn(_ topic: Topic) -> Bool { topics.contains(topic.query) }

    func setTopic(_ topic: Topic, on: Bool) {
        var chosen = Set(topics)
        if on { chosen.insert(topic.query) } else { chosen.remove(topic.query) }
        topics = Topic.presets.map(\.query).filter { chosen.contains($0) }
    }

    /// The online and local sources DailySpread picks from itself, in a fixed order.
    var enabledSources: [SourceKind] {
        var sources: [SourceKind] = []
        if useWallhaven { sources.append(.wallhaven) }
        if useCommons { sources.append(.commons) }
        if useCommonsQuality { sources.append(.commonsQuality) }
        if useNASA { sources.append(.nasa) }
        if useFlickr && !flickrKey.trimmingCharacters(in: .whitespaces).isEmpty { sources.append(.flickr) }
        if useFolder && !folderPath.isEmpty { sources.append(.folder) }
        return sources
    }

    var layoutOptions: LayoutOptions {
        LayoutOptions(
            matchPhysicalSize: matchPhysicalSize,
            gapPoints: CGFloat(gapPoints),
            gapMillimetres: CGFloat(gapMillimetres),
            offsets: displayOffsets
        )
    }

    /// Wallhaven's category bitmask (general, anime, people). Never all off.
    var categoriesParameter: String {
        let mask = (includeGeneral ? "1" : "0") + (includeAnime ? "1" : "0") + (includePeople ? "1" : "0")
        return mask == "000" ? "100" : mask
    }
}
