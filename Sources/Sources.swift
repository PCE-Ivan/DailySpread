import Foundation
import ImageIO

/// Where a wallpaper came from.
enum SourceKind: String, Codable, CaseIterable, Identifiable {
    case wallhaven
    case commons
    case commonsQuality
    case nasa
    case flickr
    case folder
    case otherApp

    var id: String { rawValue }

    /// The site, as named in the menu ("View on …").
    var label: String {
        switch self {
        case .wallhaven: return "Wallhaven"
        case .commons, .commonsQuality: return "Wikimedia Commons"
        case .nasa: return "NASA"
        case .flickr: return "Flickr"
        case .folder: return "Your folder"
        case .otherApp: return "Another app"
        }
    }
}

/// An image a source offers, before it's downloaded.
struct Candidate {
    var source: SourceKind
    /// Unique within its source.
    var id: String
    var width: Int
    var height: Int
    var fileSize: Int?
    /// Where to download it from, for online sources.
    var remoteURL: URL?
    /// The file itself, for local sources.
    var localFile: URL?
    /// A page about the image, to open from the menu.
    var pageURL: URL?
    var title: String?
    /// Who made it and under what licence.
    var credit: String?

    /// Identifies the image across launches so it isn't shown twice. Wallhaven keeps bare
    /// ids so the history from earlier versions still counts.
    var historyKey: String {
        switch source {
        case .wallhaven: return id
        // Many featured pictures are also quality images; count them as one picture.
        case .commons, .commonsQuality: return "commons:\(id)"
        default: return "\(source.rawValue):\(id)"
        }
    }
}

protocol WallpaperSource {
    var kind: SourceKind { get }
    /// How many pages the chooser may ask for before settling.
    var maxPages: Int { get }
    /// Images for `topic` (empty means anything), in the order the source prefers.
    func candidates(topic: String, need: ImageNeed, page: Int) async throws -> [Candidate]
}

enum SourceError: LocalizedError {
    case badStatus(SourceKind, Int)
    case rateLimited(SourceKind)
    case nothingFound(topics: [String], minimumWidth: Int)
    case folderUnavailable(String)
    case flickr(String)

    var errorDescription: String? {
        switch self {
        case .badStatus(let source, let code):
            return "\(source.label) answered with an error (\(code)). DailySpread will try again later."
        case .rateLimited(let source):
            return "\(source.label) asked DailySpread to slow down. It will try again later."
        case .nothingFound(let topics, let width):
            let names = topics.filter { !$0.isEmpty }.map { Topic.label(for: $0) }
            let subject = names.isEmpty ? "No new images" : "Nothing new for \(names.joined(separator: " or "))"
            return "\(subject) at \(width) px or wider in the sources you've turned on. Try more topics or sources, or a smaller minimum size."
        case .folderUnavailable(let path):
            return "The folder \(path) couldn't be read, or has no pictures in it."
        case .flickr(let message):
            return "Flickr: \(message) Check the API key in Settings › Sources."
        }
    }
}

enum Downloader {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 900 // originals can be 100 MB
        config.httpAdditionalHeaders = ["User-Agent": "DailySpread/1.2 (personal macOS wallpaper app)"]
        return URLSession(configuration: config)
    }()

    static func json<T: Decodable>(_ type: T.Type, from url: URL, source: SourceKind, snakeCase: Bool = false) async throws -> T {
        let (data, response) = try await session.data(from: url)
        try check(response, source: source)
        let decoder = JSONDecoder()
        if snakeCase { decoder.keyDecodingStrategy = .convertFromSnakeCase }
        return try decoder.decode(T.self, from: data)
    }

    /// Downloads `remote` to `destination`, replacing anything already there.
    static func file(from remote: URL, to destination: URL, source: SourceKind) async throws {
        let (temporary, response) = try await session.download(from: remote)
        try check(response, source: source)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    private static func check(_ response: URLResponse, source: SourceKind) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 429 { throw SourceError.rateLimited(source) }
        guard (200..<300).contains(http.statusCode) else { throw SourceError.badStatus(source, http.statusCode) }
    }
}

// MARK: - Wikimedia Commons

/// Wikimedia Commons, freely licensed and often far larger than 8K. Featured pictures are the
/// few thousand the community voted the very best; quality images are hundreds of thousands
/// that passed a technical review, with far more variety (cars included).
struct CommonsSource: WallpaperSource {
    enum Collection {
        case featured
        case quality

        var category: String {
            switch self {
            case .featured: return "Featured_pictures_on_Wikimedia_Commons"
            case .quality: return "Quality_images"
            }
        }
    }

    let collection: Collection
    let minimumWidth: Int
    let maxPages = 2
    var kind: SourceKind { collection == .featured ? .commons : .commonsQuality }

    private struct Response: Decodable {
        struct Query: Decodable { let pages: [Page]? }
        struct Page: Decodable {
            let pageid: Int?
            let title: String
            let imageinfo: [Info]?
        }
        struct Info: Decodable {
            let size: Int?
            let width: Int
            let height: Int
            let url: String
            let descriptionurl: String?
            let mime: String?
            let extmetadata: [String: Meta]?
        }
        struct Meta: Decodable {
            let value: String?
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                value = try? container.decode(String.self, forKey: .value)
            }
            private enum CodingKeys: String, CodingKey { case value }
        }
        struct Failure: Decodable { let code: String?; let info: String? }

        let query: Query?
        let error: Failure?
    }

    func candidates(topic: String, need: ImageNeed, page: Int) async throws -> [Candidate] {
        var search = "incategory:\(collection.category) filew:>\(minimumWidth - 1) filemime:image/jpeg"
        if !topic.isEmpty { search = "\(Topic.commonsQuery(for: topic)) \(search)" }

        var response = try await Downloader.json(Response.self, from: url(search: search, randomOrder: true, offset: 0), source: kind)
        if response.error != nil {
            // Older search back ends don't sort at random; dip in at a random point instead.
            response = try await Downloader.json(Response.self, from: url(search: search, randomOrder: false, offset: Int.random(in: 0..<4) * 40), source: kind)
        }
        let pages = response.query?.pages ?? []
        return pages.compactMap { page -> Candidate? in
            guard let info = page.imageinfo?.first, let remote = URL(string: info.url) else { return nil }
            // Skip enormous files; a 150 MB panorama takes too long to download each morning.
            if let size = info.size, size > 150_000_000 { return nil }
            let meta = info.extmetadata ?? [:]
            let artist = Self.plainText(meta["Artist"]?.value)
            let licence = Self.plainText(meta["LicenseShortName"]?.value)
            let title = Self.plainText(meta["ObjectName"]?.value)
                ?? page.title.replacingOccurrences(of: "File:", with: "").replacingOccurrences(of: "_", with: " ")
            let credit = [artist.map { "Photo: \($0)" }, licence].compactMap { $0 }.joined(separator: " · ")
            return Candidate(
                source: kind,
                id: page.pageid.map(String.init) ?? page.title,
                width: info.width,
                height: info.height,
                fileSize: info.size,
                remoteURL: remote,
                localFile: nil,
                pageURL: info.descriptionurl.flatMap(URL.init(string:)),
                title: title,
                credit: credit.isEmpty ? nil : credit
            )
        }
    }

    private func url(search: String, randomOrder: Bool, offset: Int) -> URL {
        var components = URLComponents(string: "https://commons.wikimedia.org/w/api.php")!
        var items = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2"),
            URLQueryItem(name: "generator", value: "search"),
            URLQueryItem(name: "gsrnamespace", value: "6"),
            URLQueryItem(name: "gsrlimit", value: "40"),
            URLQueryItem(name: "gsrsearch", value: search),
            URLQueryItem(name: "prop", value: "imageinfo"),
            URLQueryItem(name: "iiprop", value: "url|size|mime|extmetadata"),
            URLQueryItem(name: "iiextmetadatafilter", value: "Artist|LicenseShortName|ObjectName"),
        ]
        if randomOrder { items.append(URLQueryItem(name: "gsrsort", value: "random")) }
        if offset > 0 { items.append(URLQueryItem(name: "gsroffset", value: String(offset))) }
        components.queryItems = items
        return components.url!
    }

    /// Commons metadata is HTML; keep just the words.
    private static func plainText(_ html: String?) -> String? {
        guard let html else { return nil }
        var text = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, character) in [("&amp;", "&"), ("&quot;", "\""), ("&#039;", "'"), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return text.count > 80 ? String(text.prefix(77)) + "…" : text
    }
}

// MARK: - NASA

/// NASA's Image and Video Library: public-domain pictures of space, and of Earth from orbit.
/// Search results don't say how big each picture is, so a handful are looked up in detail.
struct NASASource: WallpaperSource {
    let kind = SourceKind.nasa
    let maxPages = 1
    let minimumWidth: Int

    private struct SearchResponse: Decodable {
        struct Collection: Decodable {
            struct Item: Decodable {
                struct Info: Decodable {
                    let nasa_id: String
                    let title: String?
                    let secondary_creator: String?
                    let photographer: String?
                }
                let data: [Info]
            }
            struct Metadata: Decodable { let total_hits: Int? }
            let items: [Item]
            let metadata: Metadata?
        }
        let collection: Collection
    }

    func candidates(topic: String, need: ImageNeed, page: Int) async throws -> [Candidate] {
        guard let query = Topic.nasaQuery(for: topic) else { return [] }
        // Dip into a random page of the matches for variety, falling back to the first.
        var infos = try await search(query, page: Int.random(in: 1...4))
        if infos.isEmpty { infos = try await search(query, page: 1) }
        let sample = Array(infos.shuffled().prefix(12))

        return await withTaskGroup(of: Candidate?.self) { group in
            for info in sample {
                group.addTask { try? await details(for: info) }
            }
            var found: [Candidate] = []
            for await candidate in group {
                if let candidate, max(candidate.width, candidate.height) >= minimumWidth { found.append(candidate) }
            }
            return found
        }
    }

    private func search(_ query: String, page: Int) async throws -> [SearchResponse.Collection.Item.Info] {
        var components = URLComponents(string: "https://images-api.nasa.gov/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "media_type", value: "image"),
            URLQueryItem(name: "page_size", value: "100"),
            URLQueryItem(name: "page", value: String(page)),
        ]
        do {
            let response = try await Downloader.json(SearchResponse.self, from: components.url!, source: kind)
            return response.collection.items.compactMap(\.data.first)
        } catch SourceError.badStatus(_, 400) {
            return [] // asked for a page past the last one
        }
    }

    /// The picture's size and original file, from its metadata and file list.
    private func details(for info: SearchResponse.Collection.Item.Info) async throws -> Candidate? {
        let id = info.nasa_id
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let metadataURL = URL(string: "https://images-assets.nasa.gov/image/\(encoded)/metadata.json"),
              let filesURL = URL(string: "https://images-assets.nasa.gov/image/\(encoded)/collection.json") else { return nil }

        let (metadataData, _) = try await Downloader.session.data(from: metadataURL)
        guard let metadata = try JSONSerialization.jsonObject(with: metadataData) as? [String: Any] else { return nil }
        func number(_ keys: [String]) -> Int? {
            for key in keys {
                if let value = metadata[key] as? Int { return value }
                if let value = metadata[key] as? String, let parsed = Int(value) { return parsed }
            }
            return nil
        }
        var width = number(["File:ImageWidth", "EXIF:ExifImageWidth", "EXIF:ImageWidth", "PNG:ImageWidth", "TIFF:ImageWidth"])
        var height = number(["File:ImageHeight", "EXIF:ExifImageHeight", "EXIF:ImageHeight", "PNG:ImageHeight", "TIFF:ImageHeight"])
        if width == nil || height == nil, let size = metadata["Composite:ImageSize"] as? String {
            // "4000x3000" or "4000 3000"
            let parts = size.split(whereSeparator: { $0 == "x" || $0 == " " }).compactMap { Int($0) }
            if parts.count == 2 { width = parts[0]; height = parts[1] }
        }
        guard let width, let height, max(width, height) >= minimumWidth else { return nil }

        let (filesData, _) = try await Downloader.session.data(from: filesURL)
        guard let files = try JSONSerialization.jsonObject(with: filesData) as? [String],
              let original = files.first(where: { $0.contains("~orig.") }) else { return nil }
        // The file list gives plain http addresses; macOS apps load https only.
        let secure = original.replacingOccurrences(of: "http://", with: "https://")

        let creator = [info.secondary_creator, info.photographer]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? "NASA"
        return Candidate(
            source: kind,
            id: id,
            width: width,
            height: height,
            fileSize: nil,
            remoteURL: URL(string: secure),
            localFile: nil,
            pageURL: URL(string: "https://images.nasa.gov/details/\(encoded)"),
            title: info.title,
            credit: "Image: \(creator) · public domain"
        )
    }
}

// MARK: - Flickr

/// Creative Commons photos on Flickr at their original size. Needs a free API key; only
/// photos whose owners allow downloading the original are offered.
struct FlickrSource: WallpaperSource {
    let kind = SourceKind.flickr
    let maxPages = 2
    let apiKey: String
    let minimumWidth: Int

    /// Flickr's licence numbers for Creative Commons, public domain and no-known-copyright photos.
    static let licences: [String: String] = [
        "1": "CC BY-NC-SA 2.0", "2": "CC BY-NC 2.0", "3": "CC BY-NC-ND 2.0", "4": "CC BY 2.0",
        "5": "CC BY-SA 2.0", "6": "CC BY-ND 2.0", "7": "No known copyright restrictions",
        "8": "United States Government work", "9": "CC0", "10": "Public Domain Mark",
    ]

    private struct Response: Decodable {
        struct Photos: Decodable { let photo: [Photo] }
        struct Photo: Decodable {
            let id: String
            let owner: String
            let title: String?
            let ownername: String?
            let license: String?
            let url_o: String?
            let width_o: FlexibleInt?
            let height_o: FlexibleInt?
        }
        let photos: Photos?
        let stat: String
        let message: String?
    }

    /// Flickr sends some numbers as strings.
    struct FlexibleInt: Decodable {
        let value: Int
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Int.self) { value = number; return }
            value = Int(try container.decode(String.self)) ?? 0
        }
    }

    func candidates(topic: String, need: ImageNeed, page: Int) async throws -> [Candidate] {
        guard !apiKey.isEmpty else { return [] }
        var components = URLComponents(string: "https://www.flickr.com/services/rest/")!
        components.queryItems = [
            URLQueryItem(name: "method", value: "flickr.photos.search"),
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "text", value: topic.isEmpty ? "landscape" : topic),
            URLQueryItem(name: "license", value: Self.licences.keys.sorted().joined(separator: ",")),
            URLQueryItem(name: "media", value: "photos"),
            URLQueryItem(name: "content_type", value: "1"),
            URLQueryItem(name: "safe_search", value: "1"),
            URLQueryItem(name: "sort", value: "interestingness-desc"),
            URLQueryItem(name: "extras", value: "url_o,owner_name,license"),
            URLQueryItem(name: "per_page", value: "100"),
            // A random page of the most interesting matches, for variety.
            URLQueryItem(name: "page", value: String(Int.random(in: 1...8))),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "nojsoncallback", value: "1"),
        ]
        let response = try await Downloader.json(Response.self, from: components.url!, source: kind)
        guard response.stat == "ok", let photos = response.photos?.photo else {
            throw SourceError.flickr(response.message ?? "Flickr didn't accept the request.")
        }
        return photos.compactMap { photo -> Candidate? in
            guard let original = photo.url_o, let url = URL(string: original),
                  let width = photo.width_o?.value, let height = photo.height_o?.value,
                  max(width, height) >= minimumWidth else { return nil }
            let licence = photo.license.flatMap { Self.licences[$0] }
            let credit = [photo.ownername.map { "Photo: \($0)" }, licence].compactMap { $0 }.joined(separator: " · ")
            return Candidate(
                source: kind,
                id: photo.id,
                width: width,
                height: height,
                fileSize: nil,
                remoteURL: url,
                localFile: nil,
                pageURL: URL(string: "https://www.flickr.com/photos/\(photo.owner)/\(photo.id)"),
                title: photo.title,
                credit: credit.isEmpty ? nil : credit
            )
        }
    }
}

// MARK: - Folder

/// Pictures the user keeps in a folder, such as photos downloaded from unsplash.com.
struct FolderSource: WallpaperSource {
    let kind = SourceKind.folder
    let maxPages = 1
    let folder: URL

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp"]

    func candidates(topic: String, need: ImageNeed, page: Int) async throws -> [Candidate] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw SourceError.folderUnavailable(folder.path)
        }
        var found: [Candidate] = []
        for url in enumerator.allObjects.compactMap({ $0 as? URL }) {
            guard Self.imageExtensions.contains(url.pathExtension.lowercased()),
                  let size = SpanRenderer.pixelSize(at: url) else { continue }
            found.append(Candidate(
                source: kind,
                id: url.path,
                width: Int(size.width),
                height: Int(size.height),
                fileSize: nil,
                remoteURL: nil,
                localFile: url,
                pageURL: nil,
                title: url.deletingPathExtension().lastPathComponent,
                credit: nil
            ))
        }
        if found.isEmpty { throw SourceError.folderUnavailable(folder.path) }
        return found.shuffled()
    }
}

// MARK: - Choosing

enum WallpaperChooser {
    /// An image `source` has for `topic` that hasn't been shown before. Images are scored by
    /// how sharp they look on these displays and how little has to be cropped; any image
    /// close to the best score can be picked, at random, so the days don't all look alike.
    /// When every match has been shown already, returns the best of those.
    static func choose(from source: WallpaperSource, topic: String, need: ImageNeed, seen: Set<String>) async throws -> Candidate? {
        var fresh: [(candidate: Candidate, score: Double)] = []
        var seenKeys = Set<String>()
        var bestRepeat: Candidate?
        var bestRepeatScore = -Double.infinity

        for page in 1...max(source.maxPages, 1) {
            let batch = try await source.candidates(topic: topic, need: need, page: page)
            if batch.isEmpty { break }
            for candidate in batch where seenKeys.insert(candidate.historyKey).inserted {
                let score = need.score(width: candidate.width, height: candidate.height)
                if seen.contains(candidate.historyKey) {
                    if score > bestRepeatScore { bestRepeat = candidate; bestRepeatScore = score }
                } else {
                    fresh.append((candidate, score))
                }
            }
            // Enough strong pictures to choose from; no need to ask for more.
            if fresh.filter({ $0.score >= 0.8 }).count >= 6 { break }
        }

        guard let best = fresh.map(\.score).max() else { return bestRepeat }
        let strong = fresh.filter { $0.score >= best - 0.15 }
        return strong.randomElement()?.candidate
    }
}
