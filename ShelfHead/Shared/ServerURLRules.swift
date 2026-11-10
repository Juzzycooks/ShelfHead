import Foundation

/// Server-address normalisation and the plain-HTTP decision, shared by the iOS app and the
/// Watch app (this file is a member of both targets).
///
/// Item 22 (REVIEW-2026-09-09-REMAINING.md, Batch 314): until 10 September 2026 these three
/// pure functions lived in `AuthViewModel` (iOS only) with a byte-for-byte copy in the Watch
/// target's `WatchServerURL.swift`, kept in step by a comment. One definition, two targets,
/// so the private-range list and the rejection rules can't drift. `AuthViewModel` keeps
/// thin static forwarders for its existing callers and tests.
///
/// `nonisolated` on the enum *and* on every member: the Watch target's default actor
/// isolation is `MainActor` (the iOS app's is `nonisolated`), so an unannotated type here
/// would be main-actor-isolated on the Watch and unusable from `nonisolated static` pure
/// decisions such as `WatchStore.signInGate`. These are pure string functions with no
/// shared state, so nonisolated is the truthful contract — the same pinning `AuthStore`,
/// `DiskCoverCache` and `SkipLabels` use.
nonisolated enum ServerURLRules {

    /// Normalises a typed server address, or returns `nil` if it can't be trusted as a
    /// server *base* address:
    /// - trims whitespace; empty is rejected;
    /// - a missing scheme defaults to `https://`, but an explicit non-HTTP scheme is
    ///   rejected outright rather than having `https://` prepended in front of it (which
    ///   would silently produce host `ftp` with path `//books.example.com`);
    /// - userinfo, query and fragment are rejected, not silently dropped — they mean the
    ///   user pasted a deep link or a token-bearing URL, and keeping them would send that on
    ///   every subsequent request built from this string;
    /// - a subpath deployment (`https://host/audiobookshelf`) is preserved, minus any
    ///   trailing slash;
    /// - the host is lowercased (DNS is case-insensitive, but the string is used as a key:
    ///   `DownloadPaths.scopeKey(serverURL:accountId:)` base64-encodes it, so one server
    ///   typed in two cases would otherwise become two download/progress scopes).
    nonisolated static func normalizedServerURL(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let lower = s.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            // An explicit non-HTTP scheme is rejected here rather than falling through to
            // the prepend below. Prepending in front of one produces
            // "https://ftp://books.example.com", which `URLComponents` reads as host
            // "ftp" with path "//books.example.com" — that passes every guard below and
            // returns a silently mangled address the user then can't connect to. The
            // scheme check further down never catches it, because by then the scheme
            // genuinely is "https".
            guard !lower.contains("://") else { return nil }
            s = "https://" + s
        }
        guard let comps = URLComponents(string: s),
              let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = comps.host, !host.isEmpty else {
            return nil
        }
        // Reject rather than silently drop: a userinfo, query, or fragment on a server
        // *base* address almost certainly means the user pasted something other than
        // a plain server root (a deep link, a token-bearing URL, a copy-paste mistake).
        guard (comps.user == nil), (comps.password == nil),
              (comps.queryItems?.isEmpty ?? true), (comps.query?.isEmpty ?? true),
              (comps.fragment?.isEmpty ?? true) else {
            return nil
        }
        var clean = URLComponents()
        clean.scheme = scheme
        // DNS hostnames are case-insensitive, but `URLComponents.host` preserves whatever
        // case was typed. That matters beyond cosmetics: `DownloadPaths.scopeKey(
        // serverURL:accountId:)` base64-encodes this string, so the same server entered
        // as "BOOKS.EXAMPLE.COM" once and "books.example.com" another time would produce
        // two different download/progress scopes for one account.
        clean.host = host.lowercased()
        clean.port = comps.port
        var path = comps.path
        while path.hasSuffix("/") { path = String(path.dropLast()) }
        clean.path = path
        return clean.string
    }


    /// True if `host` is local to this device or on a private network segment — RFC1918
    /// IPv4 ranges, IPv4/IPv6 link-local, IPv6 unique-local, loopback, `localhost`, and
    /// `.local` (mDNS/Bonjour) names — or on a Tailscale tailnet. Used to decide whether a
    /// plain-HTTP connection can be allowed without an explicit "I understand the risk"
    /// confirmation: a LAN address or a tailnet address is the normal, expected way to reach
    /// a self-hosted server without TLS, but a public hostname over HTTP means credentials,
    /// tokens, and audiobook content travel in the clear over the open internet.
    ///
    /// Shared by the iOS app and the Watch (compiled into both targets since Batch 314), so
    /// this one function is the whole rule on both.
    ///
    /// UX-4 follow-up (Batch 355, user decision 28 September 2026): **Tailscale is exempt.**
    /// Traffic to a tailnet address travels inside Tailscale's WireGuard tunnel, which is
    /// encrypted end to end between the two devices, so plain HTTP over it isn't readable on
    /// the networks in between. Two forms are recognised: MagicDNS names ending in `.ts.net`,
    /// and addresses in 100.64.0.0/10, which is where Tailscale assigns tailnet IPs. **Accepted
    /// trade-off:** 100.64.0.0/10 is also the carrier-grade NAT range (RFC 6598), so an ISP's
    /// CGNAT address would be exempted too. That's judged acceptable: a CGNAT address isn't
    /// reachable from outside the carrier, and self-hosters on it are rare. Bare hostnames
    /// (`nas`) still get the alert, since nothing says which network they resolve on.
    nonisolated static func isLocalOrPrivateHost(_ rawHost: String) -> Bool {
        let host = rawHost.lowercased()
        if host == "localhost" || host.hasSuffix(".local") { return true }
        if host.hasSuffix(".ts.net") { return true }                // Tailscale MagicDNS

        var addr4 = in_addr()
        if inet_pton(AF_INET, host, &addr4) == 1 {
            // `s_addr` is already in network byte order, so the raw bytes are the octets
            // in the order they're written (10.1.2.3 → byte0 = 10).
            let bytes = withUnsafeBytes(of: &addr4.s_addr) { Array($0) }
            let b0 = Int(bytes[0]), b1 = Int(bytes[1])
            if b0 == 10 { return true }                     // 10.0.0.0/8
            if b0 == 127 { return true }                     // 127.0.0.0/8 (loopback)
            if b0 == 172, (16...31).contains(b1) { return true } // 172.16.0.0/12
            if b0 == 192, b1 == 168 { return true }          // 192.168.0.0/16
            if b0 == 169, b1 == 254 { return true }          // 169.254.0.0/16 (link-local)
            if b0 == 100, (64...127).contains(b1) { return true } // 100.64.0.0/10 (Tailscale; also CGNAT, see above)
            return false
        }

        var addr6 = in6_addr()
        if inet_pton(AF_INET6, host, &addr6) == 1 {
            let b = withUnsafeBytes(of: &addr6) { Array($0) }
            if b.count == 16 {
                if b[0] == 0xFE, (b[1] & 0xC0) == 0x80 { return true }  // fe80::/10 link-local
                if (b[0] & 0xFE) == 0xFC { return true }                // fc00::/7 unique-local
                if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true } // ::1
            }
            return false
        }

        return false
    }


    /// True when the typed address names its own scheme (`http://…`, `https://…`, or
    /// anything else with `://`). A bare `192.168.1.50:13378` or `nas.local:13378` doesn't,
    /// and only then is `connectionCandidates(for:)` free to pick the scheme itself.
    nonisolated static func hasExplicitScheme(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).contains("://")
    }

    /// `cleanURL` (already through `normalizedServerURL`) with its scheme swapped to plain
    /// `http`, everything else kept — port, subpath, host. `nil` if it isn't an https
    /// address to begin with (there's nothing to downgrade) or can't be parsed.
    nonisolated static func plainHTTPVariant(of cleanURL: String) -> String? {
        guard var comps = URLComponents(string: cleanURL),
              comps.scheme?.lowercased() == "https" else { return nil }
        comps.scheme = "http"
        return comps.string
    }

    /// Critique 2026-10-06 (harden): the addresses to try, in order, for what was typed.
    ///
    /// `normalizedServerURL` prepends `https://` to a scheme-less address, and until this
    /// nothing ever tried anything else — but Audiobookshelf on a home network is usually
    /// plain HTTP (its default `:13378` has no TLS), so `192.168.1.50:13378` failed the
    /// test with a generic "can't reach" for a server that was fine. Now:
    /// - no scheme typed + a local/private host (the same `isLocalOrPrivateHost` rule the
    ///   plain-HTTP acknowledgement exempts) → `[https, http]`: https first, http as the
    ///   fallback the caller uses only if https fails at the transport/TLS level;
    /// - anything else (an explicit scheme, or a public/bare hostname) → just the one
    ///   normalised address. A public host never silently drops to http; the failure copy
    ///   offers it as an explicit choice instead, behind the existing acknowledgement.
    /// - unparseable → `[]`.
    nonisolated static func connectionCandidates(for raw: String) -> [String] {
        guard let primary = normalizedServerURL(raw) else { return [] }
        guard !hasExplicitScheme(raw),
              let host = URLComponents(string: primary)?.host,
              isLocalOrPrivateHost(host),
              let fallback = plainHTTPVariant(of: primary) else {
            return [primary]
        }
        return [primary, fallback]
    }


    /// True when `cleanURL` (already through `normalizedServerURL`) is plain HTTP to a host
    /// that ISN'T local/private — i.e. exactly the case where credentials and tokens would
    /// travel unencrypted over a network an attacker could plausibly observe. Callers must
    /// block the connection until the user explicitly confirms.
    nonisolated static func requiresInsecureConnectionConfirmation(for cleanURL: String) -> Bool {
        guard let comps = URLComponents(string: cleanURL),
              comps.scheme?.lowercased() == "http",
              let host = comps.host else { return false }
        return !isLocalOrPrivateHost(host)
    }
}
