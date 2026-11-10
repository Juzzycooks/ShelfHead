import Foundation

/// Batch 442: Audible's public catalog regions. Each has its own API host (`api.audible.<tld>`,
/// all verified to answer `/1.0/catalog/products` unauthenticated) and web host for
/// "Open in Audible" links.
nonisolated enum AudibleRegion: String, CaseIterable, Codable, Sendable, Identifiable {
    case us, uk, ca, au, de, fr, it, es, jp, `in`

    var id: String { rawValue }

    var tld: String {
        switch self {
        case .us: return "com"
        case .uk: return "co.uk"
        case .ca: return "ca"
        case .au: return "com.au"
        case .de: return "de"
        case .fr: return "fr"
        case .it: return "it"
        case .es: return "es"
        case .jp: return "co.jp"
        case .in: return "in"
        }
    }

    var apiHost: String { "api.audible.\(tld)" }

    /// Web page for a product, e.g. `https://www.audible.co.uk/pd/B0CQDHTSFJ`.
    func productURL(asin: String) -> URL? {
        URL(string: "https://www.audible.\(tld)/pd/\(asin)")
    }

    /// Region picker label (a country name, localised by the system).
    var displayName: String {
        let code: String
        switch self {
        case .us: code = "US"
        case .uk: code = "GB"
        case .ca: code = "CA"
        case .au: code = "AU"
        case .de: code = "DE"
        case .fr: code = "FR"
        case .it: code = "IT"
        case .es: code = "ES"
        case .jp: code = "JP"
        case .in: code = "IN"
        }
        return Locale.current.localizedString(forRegionCode: code) ?? code
    }

    /// Default from the device region, falling back to the US store.
    static func `default`(for locale: Locale = .current) -> AudibleRegion {
        let code = (locale.region?.identifier ?? "US").uppercased()
        switch code {
        case "GB", "IE": return .uk
        case "CA": return .ca
        case "AU", "NZ": return .au
        case "DE", "AT", "CH": return .de
        case "FR": return .fr
        case "IT": return .it
        case "ES": return .es
        case "JP": return .jp
        case "IN": return .in
        default: return .us
        }
    }
}

/// Batch 442: one catalog product, decoded leniently (every field optional on the wire).
nonisolated struct CatalogProduct: Codable, Equatable, Sendable {
    struct SeriesRef: Codable, Equatable, Sendable {
        var asin: String?
        var title: String?
        /// Audible sends `"5"`, `"3.5"` or `""`.
        var sequence: Double?
    }

    var asin: String
    var title: String?
    var subtitle: String?
    var authors: [String]
    var formatType: String?
    var language: String?
    /// `yyyy-MM-dd`, in the future for pre-orders.
    var releaseDate: String?
    var series: [SeriesRef]
    var coverURL: String?

    init(asin: String, title: String? = nil, subtitle: String? = nil, authors: [String] = [],
         formatType: String? = nil, language: String? = nil, releaseDate: String? = nil,
         series: [SeriesRef] = [], coverURL: String? = nil) {
        self.asin = asin; self.title = title; self.subtitle = subtitle; self.authors = authors
        self.formatType = formatType; self.language = language; self.releaseDate = releaseDate
        self.series = series; self.coverURL = coverURL
    }

    fileprivate struct Wire: Decodable {
        struct Author: Decodable { let name: String? }
        struct Series: Decodable {
            let asin: String?
            let title: String?
            let sequence: String?
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: Keys.self)
                asin = (try? c.decodeIfPresent(String.self, forKey: .asin)) ?? nil
                title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil
                if let s = (try? c.decodeIfPresent(String.self, forKey: .sequence)) ?? nil {
                    sequence = s
                } else if let d = (try? c.decodeIfPresent(Double.self, forKey: .sequence)) ?? nil {
                    sequence = String(d)
                } else { sequence = nil }
            }
            enum Keys: String, CodingKey { case asin, title, sequence }
        }
        let asin: String?
        let title: String?
        let subtitle: String?
        let authors: [Author]?
        let format_type: String?
        let language: String?
        let release_date: String?
        let series: [Series]?
        let product_images: [String: String]?
    }

    /// Decodes the Audible wire shape (`snake_case`, `authors[].name`, `product_images`).
    init?(wireData data: Data) {
        guard let w = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }
        self.init(wire: w)
    }

    fileprivate init?(wire w: Wire) {
        guard let asin = w.asin, !asin.isEmpty else { return nil }
        // Largest image key (they are pixel sizes, "500").
        let image = w.product_images?.max { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }?.value
        self.init(
            asin: asin, title: w.title, subtitle: w.subtitle,
            authors: (w.authors ?? []).compactMap { $0.name },
            formatType: w.format_type, language: w.language, releaseDate: w.release_date,
            series: (w.series ?? []).map {
                SeriesRef(asin: $0.asin, title: $0.title,
                          sequence: $0.sequence.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) })
            },
            coverURL: image)
    }

    /// Parses a `{"products":[…]}` list response, skipping malformed rows.
    static func decodeList(_ data: Data) -> [CatalogProduct] {
        struct Envelope: Decodable {
            let products: [Lossy]?
            struct Lossy: Decodable {
                let value: CatalogProduct?
                init(from decoder: Decoder) throws {
                    value = (try? Wire(from: decoder)).flatMap { CatalogProduct(wire: $0) }
                }
            }
        }
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data) else { return [] }
        return (env.products ?? []).compactMap { $0.value }
    }

    /// Parses a single `{"product":{…}}` response.
    static func decodeSingle(_ data: Data) -> CatalogProduct? {
        struct Envelope: Decodable { let product: Wire? }
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data), let w = env.product else { return nil }
        return CatalogProduct(wire: w)
    }
}

/// Batch 442: a series product's child (from `response_groups=relationships`).
nonisolated struct CatalogSeriesChild: Equatable, Sendable {
    let asin: String
    let sequence: Double?

    static func decode(_ data: Data) -> [CatalogSeriesChild] {
        struct Envelope: Decodable {
            struct Product: Decodable { let relationships: [Rel]? }
            struct Rel: Decodable {
                let asin: String?
                let relationship_to_product: String?
                let sequence: String?
            }
            let product: Product?
        }
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data) else { return [] }
        return (env.product?.relationships ?? []).compactMap { r in
            guard r.relationship_to_product == "child", let asin = r.asin else { return nil }
            return CatalogSeriesChild(asin: asin, sequence: r.sequence.flatMap { Double($0) })
        }
    }
}

/// Batch 442: unauthenticated client for Audible's public catalog (release radar).
///
/// **Deliberate, documented exception** to "server calls go through `AudiobookshelfAPI`": this
/// talks to Audible, never to the user's Audiobookshelf server, so it must NEVER carry ABS
/// credentials, tokens or per-account custom headers. It uses an ephemeral `URLSession` (no
/// cookies, no cache, no credential storage) and sends only a series/author keyword or an ASIN.
///
/// Endpoints (spiked with curl, 28 Oct 2026):
/// - `GET /1.0/catalog/products/<asin>?response_groups=series`  -> the book's series (asin, title, sequence)
/// - `GET /1.0/catalog/products/<seriesAsin>?response_groups=relationships` -> `child` books + sequences
/// - `GET /1.0/catalog/products?asins=a,b,c&response_groups=series,product_desc,product_attrs,contributors,media`
/// - `GET /1.0/catalog/products?keywords=…&response_groups=…&products_sort_by=-ReleaseDate`
/// `product_desc` + `product_attrs` is what makes `title`/`subtitle` appear; `contributors` gives
/// `authors`, `media` gives `product_images`. Pre-orders appear with a future `release_date`.
actor AudibleCatalogAPI {
    static let productGroups = "series,product_desc,product_attrs,contributors,media"

    private let region: AudibleRegion
    private let session: URLSession

    init(region: AudibleRegion, session: URLSession? = nil) {
        self.region = region
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 30
            config.httpCookieStorage = nil
            config.httpShouldSetCookies = false
            config.urlCredentialStorage = nil
            config.urlCache = nil
            config.waitsForConnectivity = false
            self.session = URLSession(configuration: config)
        }
    }

    enum CatalogError: Error { case badResponse(Int), badURL }

    private func fetch(path: String, query: [String: String]) async throws -> Data {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = region.apiHost
        comps.path = path
        comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = comps.url else { throw CatalogError.badURL }
        var request = URLRequest(url: url)
        request.setValue("ShelfHead (audiobook release radar; contact via App Store)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CatalogError.badResponse(http.statusCode)
        }
        return data
    }

    /// One product with its `series` refs, or nil if Audible doesn't know the ASIN.
    func product(asin: String) async throws -> CatalogProduct? {
        let data = try await fetch(path: "/1.0/catalog/products/\(asin)", query: ["response_groups": "series"])
        return CatalogProduct.decodeSingle(data)
    }

    /// Children (books) of a series product.
    func seriesChildren(seriesASIN: String) async throws -> [CatalogSeriesChild] {
        let data = try await fetch(path: "/1.0/catalog/products/\(seriesASIN)", query: ["response_groups": "relationships"])
        return CatalogSeriesChild.decode(data)
    }

    /// Full product records for up to ~40 ASINs per call.
    func products(asins: [String]) async throws -> [CatalogProduct] {
        var result: [CatalogProduct] = []
        for chunk in stride(from: 0, to: asins.count, by: 40).map({ Array(asins[$0..<min($0 + 40, asins.count)]) }) {
            let data = try await fetch(path: "/1.0/catalog/products", query: [
                "asins": chunk.joined(separator: ","),
                "response_groups": Self.productGroups,
            ])
            result += CatalogProduct.decodeList(data)
        }
        return result
    }

    /// Keyword search, newest first. Used only to find a series ASIN when no library ASIN works.
    func search(keywords: String, results: Int = 25) async throws -> [CatalogProduct] {
        let data = try await fetch(path: "/1.0/catalog/products", query: [
            "keywords": keywords,
            "num_results": String(results),
            "products_sort_by": "-ReleaseDate",
            "response_groups": Self.productGroups,
        ])
        return CatalogProduct.decodeList(data)
    }
}
