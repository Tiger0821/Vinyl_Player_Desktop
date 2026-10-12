import AppKit

/// Finds cover art in Apple's public iTunes catalogue. No account or key involved.
@MainActor
final class ArtworkService {
    private struct Response: Decodable {
        let results: [Item]
    }

    private struct Item: Decodable {
        let trackName: String?
        let artistName: String?
        let collectionName: String?
        let artworkUrl100: String?
    }

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }()

    /// Storefronts worth trying, most likely first. A catalogue id only resolves in a
    /// storefront that sells it, and names are listed in each storefront's own language —
    /// so someone on a US system who reads Chinese also needs the Taiwan catalogue.
    private let storefronts: [String] = {
        var codes: [String] = []
        if let region = Locale.current.region?.identifier { codes.append(region) }
        for identifier in Locale.preferredLanguages {
            let language = Locale.Language(identifier: identifier)
            if let region = language.region?.identifier { codes.append(region) }
            // The language's home region, whatever region the system pairs it with.
            let home = Locale.Language(languageCode: language.languageCode, script: language.script).maximalIdentifier
            if let region = Locale.Language(identifier: home).region?.identifier { codes.append(region) }
        }
        codes.append("US")

        var seen = Set<String>()
        return codes.map { $0.lowercased() }.filter { seen.insert($0).inserted }.prefix(4).map { $0 }
    }()

    /// Exact match by catalogue id — the id comes straight from Music, so this cannot pick the wrong cover.
    func artwork(storeID: String) async -> NSImage? {
        for storefront in storefronts {
            let items = await fetch("lookup", ["id": storeID, "country": storefront])
            if let image = await image(from: items.first) { return image }
        }
        return nil
    }

    /// Best-effort match by name, for songs with no catalogue id. Returns nothing rather than a doubtful cover.
    func artwork(title: String, artist: String, album: String) async -> NSImage? {
        guard !title.isEmpty || !album.isEmpty else { return nil }

        for storefront in storefronts {
            if !title.isEmpty {
                let songs = await fetch("search", [
                    "term": "\(artist) \(title)", "entity": "song", "limit": "25", "country": storefront,
                ])
                if let image = await image(from: Self.bestSong(in: songs, title: title, artist: artist, album: album)) {
                    return image
                }
            }
            if !album.isEmpty {
                let albums = await fetch("search", [
                    "term": "\(artist) \(album)", "entity": "album", "limit": "15", "country": storefront,
                ])
                if let image = await image(from: Self.bestAlbum(in: albums, artist: artist, album: album)) {
                    return image
                }
            }
        }
        return nil
    }

    // MARK: - Matching

    private static func bestSong(in items: [Item], title: String, artist: String, album: String) -> Item? {
        let wanted = (title: normalise(title), artist: normalise(artist), album: normalise(album))
        var best: (item: Item, score: Int)?

        for item in items {
            let titleScore = closeness(normalise(item.trackName ?? ""), wanted.title)
            let artistScore = closeness(normalise(item.artistName ?? ""), wanted.artist)
            let albumScore = closeness(normalise(item.collectionName ?? ""), wanted.album)
            // The title must agree, and so must either the artist or the exact album.
            guard titleScore > 0, artistScore > 0 || albumScore == 2 else { continue }

            let score = titleScore * 3 + artistScore * 2 + albumScore * 2
            if score > (best?.score ?? 0) { best = (item, score) }
        }
        return best?.item
    }

    private static func bestAlbum(in items: [Item], artist: String, album: String) -> Item? {
        let wanted = (artist: normalise(artist), album: normalise(album))
        return items.first { item in
            closeness(normalise(item.collectionName ?? ""), wanted.album) == 2
                && closeness(normalise(item.artistName ?? ""), wanted.artist) > 0
        }
    }

    /// 2 for the same text, 1 when one contains the other, 0 otherwise.
    private static func closeness(_ a: String, _ b: String) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 2 }
        return a.contains(b) || b.contains(a) ? 1 : 0
    }

    /// Folds case, accents and width, and drops "(Remastered)"-style asides and punctuation.
    /// Letters of every script survive, so non-Latin titles still compare.
    static func normalise(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let withoutAsides = folded.replacingOccurrences(
            of: #"[\(\[][^\)\]]*[\)\]]"#, with: " ", options: .regularExpression
        )
        let letters = { (source: String) in
            String(String.UnicodeScalarView(source.unicodeScalars.filter(CharacterSet.alphanumerics.contains)))
        }
        let stripped = letters(withoutAsides)
        // A title that is nothing but an aside, e.g. "(Intro)", keeps its text.
        return stripped.isEmpty ? letters(folded) : stripped
    }

    // MARK: - Network

    private func fetch(_ endpoint: String, _ query: [String: String]) async -> [Item] {
        var components = URLComponents(string: "https://itunes.apple.com/\(endpoint)")
        components?.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url else { return [] }

        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
            return try JSONDecoder().decode(Response.self, from: data).results
        } catch {
            Log.debug("artwork: \(endpoint) failed — \(error.localizedDescription)")
            return []
        }
    }

    private func image(from item: Item?) async -> NSImage? {
        guard let thumbnail = item?.artworkUrl100 else { return nil }
        // The catalogue serves any size on request; the listed URL is a 100px thumbnail.
        let large = thumbnail.replacingOccurrences(of: "100x100bb", with: "1200x1200bb")

        for candidate in [large, thumbnail] {
            guard let url = URL(string: candidate),
                  let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = NSImage(data: data), image.isValid
            else { continue }
            return image
        }
        return nil
    }
}
