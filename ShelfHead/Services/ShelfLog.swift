import Foundation
import os

/// Central, privacy-conscious logging for ShelfHead.
///
/// Wraps `os.Logger` with fixed categories and a redaction helper so tokens, passwords
/// and authenticated URLs never reach the logs. Also keeps a small in-memory ring buffer
/// of recent (already-redacted) events for the "Export Diagnostics" action in Settings.
enum ShelfLog {
    enum Category: String, CaseIterable {
        case auth, network, playback, downloads, storage, sync, widgets, carplay, intents, servers, watch
    }

    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.justin.ShelfHead"

    // CRIT-3 step 4 (REVIEW_2026-08-12.md): was `var`, but never mutated after this
    // initializer runs — only ever read via `loggers[category]` in `debug`/`info`/
    // `error` below. A `let` global (`static let` on a value/dictionary type) is safe to
    // access concurrently without any actor isolation, since Swift guarantees its
    // one-time lazy initialization is thread-safe and it's never written to again;
    // the `var` was an unnecessary invitation for a future accidental mutation to
    // become a real data race under strict concurrency checking.
    private static let loggers: [Category: Logger] = {
        Dictionary(uniqueKeysWithValues: Category.allCases.map { ($0, Logger(subsystem: subsystem, category: $0.rawValue)) })
    }()

    // MARK: - Logging

    // `redact()` strips known secret patterns, but log lines can still legitimately
    // contain book titles, author names, and server hostnames — none of which are
    // secrets exactly, but none of which belong in the *unpublished* system log either
    // (persists across the device, surfaces in any sysdiagnose). `privacy: .private`
    // is the os.Logger default anyway; being explicit here documents that this is
    // deliberate, not an oversight. The in-memory diagnostics buffer (`record`, below)
    // is unaffected — that's the opt-in path the user explicitly shares via Export
    // Diagnostics, which additionally redacts hostnames (see `exportDiagnostics`).
    static func debug(_ category: Category, _ message: @autoclosure () -> String) {
        let m = redact(message())
        loggers[category]?.debug("\(m, privacy: .private)")
        record(category, "DEBUG", m)
    }

    static func info(_ category: Category, _ message: @autoclosure () -> String) {
        let m = redact(message())
        loggers[category]?.info("\(m, privacy: .private)")
        record(category, "INFO", m)
    }

    static func error(_ category: Category, _ message: @autoclosure () -> String) {
        let m = redact(message())
        loggers[category]?.error("\(m, privacy: .private)")
        record(category, "ERROR", m)
    }

    // MARK: - Redaction

    /// Strips secrets from a string before it is logged or exported:
    /// `token=…` / `refresh_token=…` query params, and `Bearer …` header values.
    ///
    /// This runs on every `debug`/`info`/`error` call (see above) and again, defensively,
    /// on the whole assembled report in `exportDiagnostics` — so it has to catch secrets
    /// wherever they land in a string, not just ones we deliberately interpolated. That
    /// matters because `error.localizedDescription` is a very common thing to log
    /// (progress-sync failures, login failures, etc.), and for URL-loading errors AVFoundation
    /// and URLSession routinely embed the *full failing URL* — query string and all — in
    /// that description via `NSURLErrorFailingURLStringErrorKey`. If the user has
    /// `streamWithURLToken` enabled (Settings -> Streaming; off by default, see
    /// `AudioPlayerService.assetURL`), that failing URL can contain `?token=<access token>`,
    /// and without this regex running on the error string too, an "export diagnostics" from
    /// a user debugging a playback failure would hand their live access token to whoever
    /// they shared the report with.
    ///
    /// Query-param coverage: `token`, `access_token`, `refresh_token`, `password`, `api_key`
    /// (matched anywhere, since these names are unambiguous) and — added for the OIDC/SSO
    /// login flow — `code` (the OAuth authorization code), which is matched only when it
    /// actually appears as a `?code=`/`&code=` query parameter rather than a bare `code=`
    /// anywhere in the string; `code` alone is too common a word/field name elsewhere (e.g.
    /// `NSError`'s own `"Code=-1009"` in its description) to redact unconditionally without
    /// destroying unrelated, non-secret diagnostic detail.
    static func redact(_ input: String) -> String {
        var s = input
        for pattern in [
            #"(?i)(access[_-]?token|refresh[_-]?token|token|password|api[_-]?key)=([^&\s"']+)"#,
            #"(?i)([?&])(code)=([^&\s"']+)"#,
            #"(?i)(Bearer)\s+[A-Za-z0-9._\-]+"#
        ] {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(s.startIndex..., in: s)
                // Keep the key (and, for the query-param patterns, the leading `?`/`&`
                // separator), replace only the secret value with •••.
                let template: String
                if pattern.contains("Bearer") {
                    template = "$1 •••"
                } else if pattern.contains("[?&]") {
                    template = "$1$2=•••"
                } else {
                    template = "$1=•••"
                }
                s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: template)
            }
        }
        return s
    }

    /// Replaces any `http(s)://host[:port]` authority with `<server>`. Used only for
    /// the *exported* diagnostics report — for a self-hosted user, their server's
    /// hostname (a home domain, a Tailscale address, etc.) is exactly the kind of
    /// thing they wouldn't want to paste into a public GitHub issue.
    private static func redactHosts(_ input: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^/\s"']+"#) else { return input }
        let range = NSRange(input.startIndex..., in: input)
        var result = regex.stringByReplacingMatches(in: input, range: range, withTemplate: "<server>")
        // The regex above only catches the server appearing WITH its `http(s)://`
        // scheme. A log line that mentions just the bare host (e.g. "Connecting to
        // books.example.com", no scheme) would pass through untouched — but rather
        // than guess at a general "looks like a hostname" pattern (which risks
        // redacting things it shouldn't, like abbreviations or version numbers),
        // strip the *actual* configured server's host directly, since that's exactly
        // and only what needs hiding here.
        if let url = URL(string: AuthStore.shared.serverURL), let host = url.host, !host.isEmpty {
            if let port = url.port {
                result = result.replacingOccurrences(of: "\(host):\(port)", with: "<server>")
            }
            result = result.replacingOccurrences(of: host, with: "<server>")
        }
        return result
    }

    // MARK: - Diagnostics buffer

    private struct Event { let date: Date; let category: String; let level: String; let message: String }
    private static let bufferLock = NSLock()
    private static var buffer: [Event] = []
    private static let bufferCap = 250

    private static func record(_ category: Category, _ level: String, _ message: String) {
        bufferLock.lock(); defer { bufferLock.unlock() }
        buffer.append(Event(date: Date(), category: category.rawValue, level: level, message: message))
        if buffer.count > bufferCap { buffer.removeFirst(buffer.count - bufferCap) }
    }

    /// A redacted, shareable diagnostics report. Contains app/OS versions and recent
    /// (already-redacted) log lines — never credentials or audiobook content.
    static func exportDiagnostics(serverVersion: String? = nil) -> String {
        let app = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let df = ISO8601DateFormatter()

        bufferLock.lock()
        let events = buffer
        bufferLock.unlock()

        var lines: [String] = [
            "ShelfHead Diagnostics",
            "App: \(app) (\(build))",
            "OS: \(os)",
            "Audiobookshelf server: \(serverVersion ?? "unknown")",
            "Generated: \(df.string(from: Date()))",
            "",
            "Recent events (redacted, newest last):"
        ]
        lines += events.map { "\(df.string(from: $0.date)) [\($0.level)] \($0.category): \($0.message)" }
        // Defensive: redact the whole report once more, then strip any server hostname.
        return redactHosts(redact(lines.joined(separator: "\n")))
    }
}

// MARK: - Launch timing

/// Polish pass (J2-17): cold-launch timing baseline. Intervals and one-off milestones go to
/// the unified log as signposts (Instruments > os_signpost / Points of Interest, subsystem =
/// the app's bundle id, category "Launch"), and the key milestones are also summed up in a
/// single `ShelfLog.info` line (elapsed ms since process start) so a Console reading is
/// enough without Instruments. `OSSignposter` is iOS 15+ (checked on
/// developer.apple.com/documentation/os/ossignposter); the deployment target is 17.6.
/// Overhead: a signpost is a few hundred ns and is a no-op unless something is recording.
enum LaunchTrace {
    static let signposter = OSSignposter(subsystem: Bundle.main.bundleIdentifier ?? "com.justin.ShelfHead",
                                         category: "Launch")

    /// When this process started (kernel `p_starttime`), falling back to "now" if sysctl fails.
    static let processStart: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let t = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000)
    }()

    /// Milestones that make up the summary line, in the order they're reported.
    static let summaryMilestones = ["appInitEnd", "splashDismissed", "homeFirstShelves", "firstPlayable"]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var marks: [String: Int] = [:]
    nonisolated(unsafe) private static var summaryLogged = false

    /// Touch early (first line of `App.init`) so the process-start lookup isn't first paid later.
    static func prime() { _ = processStart }

    /// Runs `body` inside a signpost interval named `name` (the name must be a literal).
    static func interval<T>(_ name: StaticString, _ body: () async throws -> T) async rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try await body()
    }

    /// Records a one-off milestone (first call per name wins) as a signpost event plus an
    /// elapsed-ms-since-process-start entry, and logs the summary once every milestone is in.
    static func mark(_ name: StaticString) {
        signposter.emitEvent(name)
        let key = "\(name)"
        let ms = Int(Date().timeIntervalSince(processStart) * 1000)
        lock.lock()
        guard marks[key] == nil else { lock.unlock(); return }
        marks[key] = ms
        let complete = !summaryLogged && summaryMilestones.allSatisfy { marks[$0] != nil }
        if complete { summaryLogged = true }
        let snapshot = marks
        lock.unlock()
        guard complete else { return }
        ShelfLog.info(.playback, summaryLine(snapshot))
    }

    /// Pure formatter for the summary line (unit-tested).
    static func summaryLine(_ marks: [String: Int]) -> String {
        let parts = summaryMilestones.compactMap { name in marks[name].map { "\(name)=\($0)ms" } }
        return "Launch (ms since process start): " + parts.joined(separator: " ")
    }
}
