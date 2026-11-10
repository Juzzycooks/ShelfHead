import Foundation
import CryptoKit

/// Batch 458: `shelfhead://mixtape?v=1&d=<base64url of lzfse-compressed JSON>`.
/// Pure encode/decode (no I/O). Compression is `NSData.compressed(using: .lzfse)` (iOS 13+).
nonisolated enum MixtapeLinkError: Error, Equatable {
    case notAMixtapeLink
    case unsupportedVersion
    case malformed
    case noClips
    case tooManyClips
    case tooLong
}

nonisolated struct DecodedMixtapeLink: Equatable, Identifiable, Sendable {
    var mixtape: Mixtape
    /// 16 hex characters of the sender's normalised server host hash.
    var serverFingerprint: String
    var id: UUID { mixtape.id }
}

nonisolated struct EncodedMixtapeLink: Equatable, Sendable {
    var url: URL
    /// Quotes were left out to fit the URL cap.
    var droppedQuotes: Bool
}

nonisolated enum MixtapeLink {
    static let version = 1
    static let maxClips = 25
    static let maxURLLength = 2_000
    /// Longer links are refused outright on decode, before any decompression.
    static let maxDecodeURLLength = 8_000
    static let maxDecompressedBytes = 64 * 1024
    private static let maxTextLength = 200

    // MARK: Fingerprint

    /// Batch 458: the same "same server" fingerprint the household uses (`ServerFingerprint`), so a
    /// mixtape and a household recommendation agree on which books a member can open.
    static func normalisedHost(_ server: String) -> String {
        ServerFingerprint.normalizedHost(server)
    }

    static func fingerprint(forServer server: String) -> String {
        ServerFingerprint.fingerprint(forServerURL: server)
    }

    // MARK: Wire format

    private struct Wire: Codable {
        var t: String
        var f: String
        var c: [Clip]
        struct Clip: Codable {
            var i: String
            var s: Double
            var e: Double
            var l: String?
            var q: String?
            var b: String?
            var a: String?
        }
    }

    private static func tenths(_ x: Double) -> Double { (x * 10).rounded() / 10 }

    static func encode(_ mixtape: Mixtape, serverURL: String) throws -> EncodedMixtapeLink {
        guard !mixtape.clips.isEmpty else { throw MixtapeLinkError.noClips }
        guard mixtape.clips.count <= maxClips else { throw MixtapeLinkError.tooManyClips }
        let fp = fingerprint(forServer: serverURL)
        for dropQuotes in [false, true] {
            let wire = Wire(t: mixtape.title, f: fp, c: mixtape.clips.map {
                Wire.Clip(i: $0.itemId, s: tenths($0.start), e: tenths($0.end), l: $0.label,
                          q: dropQuotes ? nil : $0.quote, b: $0.title, a: $0.author)
            })
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let json = try? encoder.encode(wire),
                  let packed = try? (json as NSData).compressed(using: .lzfse) as Data else { throw MixtapeLinkError.malformed }
            var comps = URLComponents()
            comps.scheme = "shelfhead"
            comps.host = "mixtape"
            comps.queryItems = [URLQueryItem(name: "v", value: String(version)),
                                URLQueryItem(name: "d", value: base64URL(packed))]
            if let url = comps.url, url.absoluteString.count <= maxURLLength {
                return EncodedMixtapeLink(url: url, droppedQuotes: dropQuotes && mixtape.clips.contains { $0.quote != nil })
            }
        }
        throw MixtapeLinkError.tooLong
    }

    static func decode(_ url: URL) throws -> DecodedMixtapeLink {
        guard url.scheme?.lowercased() == "shelfhead", url.host?.lowercased() == "mixtape" else {
            throw MixtapeLinkError.notAMixtapeLink
        }
        guard url.absoluteString.count <= maxDecodeURLLength else { throw MixtapeLinkError.tooLong }
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            throw MixtapeLinkError.malformed
        }
        guard let v = items.first(where: { $0.name == "v" })?.value, let ver = Int(v) else { throw MixtapeLinkError.malformed }
        guard ver == version else { throw MixtapeLinkError.unsupportedVersion }
        guard let d = items.first(where: { $0.name == "d" })?.value, let packed = dataFromBase64URL(d) else {
            throw MixtapeLinkError.malformed
        }
        guard let json = try? (packed as NSData).decompressed(using: .lzfse) as Data,
              json.count <= maxDecompressedBytes,
              let wire = try? JSONDecoder().decode(Wire.self, from: json) else { throw MixtapeLinkError.malformed }
        guard !wire.c.isEmpty else { throw MixtapeLinkError.noClips }
        guard wire.c.count <= maxClips else { throw MixtapeLinkError.tooManyClips }
        var clips: [MixtapeClip] = []
        for c in wire.c {
            guard !c.i.isEmpty, c.i.count <= 100, c.s.isFinite, c.e.isFinite, c.s >= 0, c.e > c.s else {
                throw MixtapeLinkError.malformed
            }
            clips.append(MixtapeClip(itemId: c.i, start: c.s, end: c.e, label: clean(c.l), quote: clean(c.q, limit: 2_000),
                                     title: clean(c.b), author: clean(c.a)))
        }
        let title = clean(wire.t) ?? String(localized: "Mixtape", comment: "Fallback title for an imported mixtape")
        return DecodedMixtapeLink(mixtape: Mixtape(title: title, clips: clips), serverFingerprint: wire.f)
    }

    private static func clean(_ s: String?, limit: Int = maxTextLength) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return String(t.prefix(limit))
    }

    // MARK: base64url (RFC 4648 section 5, no padding)

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func dataFromBase64URL(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b += String(repeating: "=", count: (4 - b.count % 4) % 4)
        return Data(base64Encoded: b)
    }
}

extension MixtapeLink {
    /// Fingerprint of the signed-in account's server.
    @MainActor static func currentFingerprint() -> String { fingerprint(forServer: AuthStore.shared.serverURL) }
}
