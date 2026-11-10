import Foundation

/// §8 decomposition (REVIEW_2026-08-12.md): the review's proposed `DownloadPaths` type
/// — "pure and injectable... the single place SEC-1 is fixed and tested." `DownloadManager`
/// (1,800+ lines) still owns the filesystem-URL-building side of this (`downloadsRoot()`,
/// `downloadDirectory(for:)`, `currentScopeKey()`), since those depend on live singletons
/// (`AuthStore`, `AccountStore`) and the instance's `FileManager` — extracting those too
/// would mean either injecting those dependencies through a much wider surface or
/// duplicating singleton access in a second type, neither of which is a safe change to
/// make blind, with no compiler available this session to catch a mistake in code this
/// behaviorally critical.
///
/// What genuinely IS pure, dependency-free string manipulation — and so what's safe to
/// mechanically move into its own type with zero behavior risk — is extracted here:
/// deriving a filesystem-safe scope key from a server+account pair, and sanitizing a
/// server-supplied item id into a single safe path component (SEC-1's fix). Every one of
/// these functions has no side effects and no dependency on `self`.
///
/// `DownloadManager`'s own `scopeKey(serverURL:accountId:)`, `sanitizedPathComponent(_:)`,
/// `strictPathComponentEncode(_:)`, and `safeIdentifierHash(_:)` now forward to this type
/// — their signatures, and every existing call site (including `DownloadPathsTests.swift`,
/// which exercises them via `DownloadManager.shared`), are unchanged.
enum DownloadPaths {
    /// Filesystem/pipe-safe key for a (server, account) pair. Base64 of `"<serverURL>|<accountId>"`,
    /// with the three characters base64 can produce that aren't safe unescaped in a path
    /// component (`/`, `+`, `=`) replaced/stripped.
    static func scopeKey(serverURL: String, accountId: String) -> String {
        let raw = "\(serverURL)|\(accountId)"
        return Data(raw.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Collapses a server-supplied id into something safe to use as a single path
    /// component: percent-encodes it, then also flattens any remaining `/` (which
    /// percent-encoding of `.urlPathAllowed` doesn't escape, since `/` is a valid path
    /// separator character for that character set) so it can't be read as multiple path
    /// segments (e.g. a crafted id containing `../`).
    ///
    /// SEC-1: `.` and `..` survive that flattening unchanged (`.urlPathAllowed`
    /// explicitly permits `.` unescaped, and neither string contains a `/` to begin
    /// with) — so `itemId == ".."` previously resolved to the downloads root's own
    /// parent directory, and removing it deleted every account's downloads; `itemId ==
    /// "."` resolved to the scope root itself and wiped the current account's entire
    /// download folder plus its `.paused` resume state. Both (and an empty result) are
    /// rejected explicitly, falling back to a collision-resistant encoding of the raw id
    /// instead of ever returning something that could be interpreted as "here" or "up
    /// one level."
    static func sanitizedPathComponent(_ itemId: String) -> String {
        let flattened = percentEncodedPathComponent(itemId).replacingOccurrences(of: "/", with: "_")
        guard !flattened.isEmpty, flattened != ".", flattened != ".." else {
            return "id_" + safeIdentifierHash(itemId)
        }
        return flattened
    }

    /// Base64-encodes `value` into a string that's always safe as a single path
    /// component — `sanitizedPathComponent`'s fallback for an id that would otherwise
    /// sanitize to `.`, `..`, or empty. Not reversible-in-practice back to the original
    /// id (nor does anything need it to be); just collision-resistant and filesystem-safe.
    static func safeIdentifierHash(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Percent-encodes a value for use as exactly one URL path segment — stricter than
    /// the shared `percentEncodedPathComponent` (`Extensions.swift`), which uses
    /// `.urlPathAllowed` and deliberately leaves `/` un-escaped, since that helper is
    /// meant for building a path that's *allowed* to span multiple segments. A request
    /// URL built by substituting a server-supplied id into a single path segment (e.g.
    /// `.../file/<ino>/download`) must escape `/` (or `../`), not read it as a path
    /// separator, or a compromised/malicious server response could redirect the request
    /// somewhere other than the intended endpoint. Removing `/` from the allowed set
    /// (vs. reusing `.urlPathAllowed` as-is) is the only difference.
    static func strictPathComponentEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
