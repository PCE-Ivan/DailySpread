import Foundation

/// One search result from wallhaven.cc.
struct WallhavenWallpaper: Codable, Identifiable, Equatable {
    struct Thumbs: Codable, Equatable {
        let large: String?
        let original: String?
        let small: String?
    }

    let id: String
    /// The wallpaper's page on wallhaven.cc.
    let url: String
    /// The full-size image file.
    let path: String
    let resolution: String
    let dimensionX: Int
    let dimensionY: Int
    let fileSize: Int?
    let thumbs: Thumbs?
}

struct WallhavenPage: Decodable {
    struct Meta: Decodable {
        let lastPage: Int
        let total: Int

        private enum CodingKeys: String, CodingKey {
            case lastPage
            case total
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            lastPage = Meta.flexibleInt(container, .lastPage) ?? 1
            total = Meta.flexibleInt(container, .total) ?? 0
        }

        /// Wallhaven has sent some of these numbers as strings; accept either.
        private static func flexibleInt(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
            if let value = try? container.decode(Int.self, forKey: key) { return value }
            if let text = try? container.decode(String.self, forKey: key) { return Int(text) }
            return nil
        }
    }

    let data: [WallhavenWallpaper]
    let meta: Meta?
}

/// What to search for, turned into a Wallhaven API request.
struct WallhavenQuery {
    var text: String
    var categories: String
    var ratios: [String]
    var minimumWidth: Int
    var minimumHeight: Int
    var order: PickOrder
    var seed: String

    func url(page: Int) -> URL {
        var components = URLComponents(string: "https://wallhaven.cc/api/v1/search")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "categories", value: categories),
            URLQueryItem(name: "purity", value: "100"), // safe for work only
            URLQueryItem(name: "atleast", value: "\(minimumWidth)x\(minimumHeight)"),
            URLQueryItem(name: "page", value: String(page)),
        ]
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { items.append(URLQueryItem(name: "q", value: trimmed)) }
        if !ratios.isEmpty { items.append(URLQueryItem(name: "ratios", value: ratios.joined(separator: ","))) }
        switch order {
        case .random:
            items.append(URLQueryItem(name: "sorting", value: "random"))
            items.append(URLQueryItem(name: "seed", value: seed))
        case .favorites:
            items.append(URLQueryItem(name: "sorting", value: "favorites"))
        case .topYear:
            items.append(URLQueryItem(name: "sorting", value: "toplist"))
            items.append(URLQueryItem(name: "topRange", value: "1y"))
        case .topMonth:
            items.append(URLQueryItem(name: "sorting", value: "toplist"))
            items.append(URLQueryItem(name: "topRange", value: "1M"))
        }
        components.queryItems = items
        return components.url!
    }
}

/// Maps the combined shape of the displays to Wallhaven's aspect-ratio buckets.
enum ShapeMatcher {
    static let buckets: [(name: String, ratio: Double)] = [
        ("9x16", 9.0 / 16.0), ("10x16", 10.0 / 16.0), ("1x1", 1.0), ("5x4", 1.25), ("4x3", 4.0 / 3.0),
        ("3x2", 1.5), ("16x10", 1.6), ("16x9", 16.0 / 9.0), ("21x9", 2.37), ("32x9", 32.0 / 9.0), ("48x9", 48.0 / 9.0),
    ]
    static let landscape = ["16x10", "16x9", "21x9", "32x9", "48x9"]

    /// Buckets within 30% of the displays' shape, or the single closest one.
    static func ratios(forAspect aspect: Double) -> [String] {
        guard aspect > 0 else { return landscape }
        let distance = { (ratio: Double) in abs(log(ratio / aspect)) }
        let close = buckets.filter { distance($0.ratio) <= log(1.3) }.map(\.name)
        if !close.isEmpty { return close }
        let nearest = buckets.min { distance($0.ratio) < distance($1.ratio) }!
        return [nearest.name]
    }

    static func ratio(of name: String) -> Double {
        buckets.first { $0.name == name }?.ratio ?? 16.0 / 9.0
    }

    /// Wallhaven's `atleast` wants a width and a height. The long side gets the minimum; the
    /// other side is set by the widest shape asked for, so no wanted shape is filtered out.
    static func minimumSize(longSide: Int, ratios: [String]) -> (width: Int, height: Int) {
        let widest = ratios.map(ratio(of:)).max() ?? 16.0 / 9.0
        if widest >= 1 {
            return (longSide, Int((Double(longSide) / widest).rounded(.down)))
        }
        return (Int((Double(longSide) * widest).rounded(.down)), longSide)
    }
}

/// wallhaven.cc: a large wallpaper library with an open API, no account needed.
struct WallhavenSource: WallpaperSource {
    let kind = SourceKind.wallhaven
    let maxPages = 2
    let categories: String
    let minimumWidth: Int
    let matchShape: Bool
    let order: PickOrder
    /// Kept for the whole search, so pages of a random order don't repeat each other.
    let seed: String

    init(categories: String, minimumWidth: Int, matchShape: Bool, order: PickOrder) {
        self.categories = categories
        self.minimumWidth = minimumWidth
        self.matchShape = matchShape
        self.order = order
        let characters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        self.seed = String((0..<6).map { _ in characters.randomElement()! })
    }

    /// One page of images shaped like the displays, then one of any landscape image.
    func candidates(topic: String, need: ImageNeed, page: Int) async throws -> [Candidate] {
        var ratioSets: [[String]] = []
        if matchShape { ratioSets.append(ShapeMatcher.ratios(forAspect: need.aspect)) }
        if !ratioSets.contains(ShapeMatcher.landscape) { ratioSets.append(ShapeMatcher.landscape) }

        var results: [Candidate] = []
        for ratios in ratioSets {
            let size = ShapeMatcher.minimumSize(longSide: minimumWidth, ratios: ratios)
            let query = WallhavenQuery(
                text: topic, categories: categories, ratios: ratios,
                minimumWidth: size.width, minimumHeight: size.height, order: order, seed: seed
            )
            let response = try await Downloader.json(WallhavenPage.self, from: query.url(page: page), source: kind, snakeCase: true)
            results += response.data.map { wallpaper in
                Candidate(
                    source: kind,
                    id: wallpaper.id,
                    width: wallpaper.dimensionX,
                    height: wallpaper.dimensionY,
                    fileSize: wallpaper.fileSize,
                    remoteURL: URL(string: wallpaper.path),
                    localFile: nil,
                    pageURL: URL(string: wallpaper.url),
                    title: nil,
                    credit: nil
                )
            }
        }
        return results
    }
}
