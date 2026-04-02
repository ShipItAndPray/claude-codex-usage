import AppKit
import Foundation
import Security

enum ServiceKind: String, Hashable, CaseIterable {
    case claude
    case codex

    var name: String {
        switch self {
        case .claude:
            return "Claude"
        case .codex:
            return "Codex"
        }
    }

    var logoName: String {
        switch self {
        case .claude:
            return "anthropic"
        case .codex:
            return "openai"
        }
    }

    var backgroundColor: NSColor {
        switch self {
        case .claude:
            return NSColor(calibratedRed: 0.39, green: 0.28, blue: 0.23, alpha: 0.98)
        case .codex:
            return NSColor(calibratedRed: 0.05, green: 0.47, blue: 0.34, alpha: 0.98)
        }
    }
}

struct UsageWindow: Codable {
    let label: String
    let utilization: Double?
    let resetAt: Date?
}

struct ServiceSnapshot: Codable {
    let name: String
    let windows: [UsageWindow]
    let error: String?
    let isAvailable: Bool
    let observedAt: Date?
    let retryAfterSeconds: TimeInterval?

    static func failure(name: String, message: String, retryAfterSeconds: TimeInterval? = nil) -> ServiceSnapshot {
        ServiceSnapshot(
            name: name,
            windows: [],
            error: message,
            isAvailable: true,
            observedAt: nil,
            retryAfterSeconds: retryAfterSeconds
        )
    }

    static func unavailable(name: String, message: String) -> ServiceSnapshot {
        ServiceSnapshot(
            name: name,
            windows: [],
            error: message,
            isAvailable: false,
            observedAt: nil,
            retryAfterSeconds: nil
        )
    }

    var hasVisibleValues: Bool {
        windows.contains { $0.utilization != nil }
    }
}

struct DashboardSnapshot: Codable {
    let generatedAt: Date
    let claude: ServiceSnapshot
    let codex: ServiceSnapshot
}

struct AppConfiguration {
    let displayName: String
    let enabledServices: Set<ServiceKind>

    static func load(from bundle: Bundle = .main) -> AppConfiguration {
        let rawServices = bundle.object(forInfoDictionaryKey: "ClaudeCodexUsageServices") as? [String] ?? []
        let parsedServices = Set(rawServices.compactMap { ServiceKind(rawValue: $0.lowercased()) })
        let enabledServices = parsedServices.isEmpty ? Set(ServiceKind.allCases) : parsedServices
        let displayName = (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "Claude Codex Usage"
        return AppConfiguration(displayName: displayName, enabledServices: enabledServices)
    }

    var orderedServices: [ServiceKind] {
        ServiceKind.allCases.filter { enabledServices.contains($0) }
    }

    var namesText: String {
        let names = orderedServices.map(\.name)
        switch names.count {
        case 0:
            return "usage"
        case 1:
            return names[0]
        default:
            return names.joined(separator: " and ")
        }
    }

    var loadingText: String {
        if orderedServices.count == 1, let service = orderedServices.first {
            return "Loading \(service.name)"
        }
        return "Loading..."
    }

    var emptyText: String {
        if orderedServices.count == 1, let service = orderedServices.first {
            return "No \(service.name)"
        }
        return "No usage"
    }
}

struct SecureStorageData: Decodable {
    let claudeAiOauth: ClaudeOAuth?
}

struct ClaudeOAuth: Codable {
    let accessToken: String
    let subscriptionType: String?
    let rateLimitTier: String?
}

struct ClaudeRateLimit: Decodable {
    let utilization: Double?
    let resets_at: String?
}

struct ClaudeUsageResponse: Decodable {
    let five_hour: ClaudeRateLimit?
    let seven_day: ClaudeRateLimit?
}

enum ClaudeCodexUsageError: LocalizedError {
    case missingClaudeCredentials
    case claudeRateLimited(retryAfter: TimeInterval?)
    case claudeRequestFailed(statusCode: Int, body: String)
    case claudeUsageURLInvalid
    case claudeUsageNoData

    var errorDescription: String? {
        switch self {
        case .missingClaudeCredentials:
            return "Claude Code OAuth credentials were not found in the local keychain."
        case .claudeRateLimited:
            return "Claude usage is rate limited. Keeping last known values and retrying later."
        case .claudeRequestFailed(let statusCode, let body):
            let detail = body.isEmpty ? "" : " \(body)"
            return "Claude usage request failed: HTTP \(statusCode)\(detail)"
        case .claudeUsageURLInvalid:
            return "Claude usage URL is invalid."
        case .claudeUsageNoData:
            return "Claude usage request returned no data."
        }
    }
}

private struct CodexSnapshotCandidate {
    let timestamp: String
    let snapshot: ServiceSnapshot
}

final class UsageFetcher {
    private let fileManager = FileManager.default
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init() {
        encoder.outputFormatting = [.sortedKeys]
    }

    func fetchClaudeUsage() -> ServiceSnapshot {
        do {
            let oauth = try readClaudeOAuth()
            let usage = try requestClaudeUsage(accessToken: oauth.accessToken)
            let windows = [
                makeClaudeWindow(label: "5h session", source: usage.five_hour),
                makeClaudeWindow(label: "7d overall", source: usage.seven_day)
            ]

            return ServiceSnapshot(
                name: "Claude",
                windows: windows.compactMap { $0.utilization == nil && $0.resetAt == nil ? nil : $0 },
                error: nil,
                isAvailable: true,
                observedAt: Date(),
                retryAfterSeconds: nil
            )
        } catch ClaudeCodexUsageError.missingClaudeCredentials {
            return .unavailable(name: "Claude", message: ClaudeCodexUsageError.missingClaudeCredentials.localizedDescription)
        } catch ClaudeCodexUsageError.claudeRateLimited(let retryAfter) {
            return .failure(
                name: "Claude",
                message: ClaudeCodexUsageError.claudeRateLimited(retryAfter: retryAfter).localizedDescription,
                retryAfterSeconds: retryAfter
            )
        } catch {
            return .failure(name: "Claude", message: error.localizedDescription)
        }
    }

    func fetchCodexUsage() -> ServiceSnapshot {
        let sessionsRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sessionsRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .unavailable(name: "Codex", message: "No local Codex sessions directory was found.")
        }

        let files = codexSessionFiles(root: sessionsRoot)
        guard !files.isEmpty else {
            return .unavailable(name: "Codex", message: "No Codex session logs were found.")
        }

        if let snapshot = newestCodexSnapshot(in: Array(files.prefix(12))) {
            return snapshot
        }

        if let snapshot = newestCodexSnapshot(in: Array(files.dropFirst(12))) {
            return snapshot
        }

        return .unavailable(name: "Codex", message: "No Codex rate-limit snapshots were found.")
    }

    func readCachedSnapshot() -> DashboardSnapshot? {
        for directory in cacheDirectoryCandidates() {
            let cacheURL = snapshotCacheURL(in: directory)
            guard let data = try? Data(contentsOf: cacheURL) else { continue }
            if let snapshot = try? decoder.decode(DashboardSnapshot.self, from: data) {
                return snapshot
            }
        }
        return nil
    }

    func writeCachedSnapshot(_ snapshot: DashboardSnapshot) throws {
        let cacheDir = preferredCacheDirectoryURL()
        try fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let data = try encoder.encode(snapshot)
        try data.write(to: snapshotCacheURL(in: cacheDir), options: .atomic)
    }

    private func codexSessionFiles(root: URL) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
            files.append(fileURL)
        }
        return files.sorted { lhs, rhs in
            let leftDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rightDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if leftDate != rightDate {
                return leftDate > rightDate
            }
            return lhs.path > rhs.path
        }
    }

    private func newestCodexSnapshot(in files: [URL]) -> ServiceSnapshot? {
        var best: CodexSnapshotCandidate?

        for fileURL in files {
            guard let candidate = latestCodexSnapshotCandidate(in: fileURL) else { continue }
            if let best, candidate.timestamp <= best.timestamp {
                continue
            }
            best = candidate
        }

        return best?.snapshot
    }

    private func latestCodexSnapshotCandidate(in fileURL: URL) -> CodexSnapshotCandidate? {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }

        for line in contents.split(whereSeparator: \.isNewline).reversed() {
            guard line.contains("\"token_count\""), line.contains("\"rate_limits\"") else { continue }
            guard
                let data = line.data(using: .utf8),
                let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let timestamp = root["timestamp"] as? String,
                let payload = root["payload"] as? [String: Any],
                let payloadType = payload["type"] as? String,
                payloadType == "token_count",
                let rateLimits = payload["rate_limits"] as? [String: Any]
            else {
                continue
            }

            return CodexSnapshotCandidate(
                timestamp: timestamp,
                snapshot: ServiceSnapshot(
                    name: "Codex",
                    windows: codexWindows(from: rateLimits),
                    error: nil,
                    isAvailable: true,
                    observedAt: parseISODate(timestamp),
                    retryAfterSeconds: nil
                )
            )
        }

        return nil
    }

    private func codexWindows(from rateLimits: [String: Any]) -> [UsageWindow] {
        [("primary", rateLimits["primary"]), ("secondary", rateLimits["secondary"])]
            .compactMap { _, raw in
                guard let window = raw as? [String: Any] else { return nil }
                let windowMinutes = window["window_minutes"] as? Int
                let label = labelForCodexWindow(minutes: windowMinutes)
                let utilization = (window["used_percent"] as? NSNumber)?.doubleValue
                let resetEpoch = (window["resets_at"] as? NSNumber)?.doubleValue
                let resetAt = resetEpoch.map { Date(timeIntervalSince1970: $0) }
                return UsageWindow(label: label, utilization: utilization, resetAt: resetAt)
            }
            .sorted { lhs, rhs in
                let leftRank = codexWindowRank(for: lhs.label)
                let rightRank = codexWindowRank(for: rhs.label)
                return leftRank < rightRank
            }
    }

    private func codexWindowRank(for label: String) -> Int {
        switch label {
        case "5h session":
            return 0
        case "7d overall":
            return 1
        default:
            return 2
        }
    }

    private func labelForCodexWindow(minutes: Int?) -> String {
        switch minutes {
        case 300:
            return "5h session"
        case 10080:
            return "7d overall"
        case .some(let value):
            if value % 1440 == 0 {
                return "\(value / 1440)d window"
            }
            if value % 60 == 0 {
                return "\(value / 60)h window"
            }
            return "\(value)m window"
        case .none:
            return "usage window"
        }
    }

    private func makeClaudeWindow(label: String, source: ClaudeRateLimit?) -> UsageWindow {
        UsageWindow(
            label: label,
            utilization: source?.utilization,
            resetAt: parseISODate(source?.resets_at)
        )
    }

    private func readClaudeOAuth() throws -> ClaudeOAuth {
        if let envToken = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"], !envToken.isEmpty {
            return ClaudeOAuth(accessToken: envToken, subscriptionType: nil, rateLimitTier: nil)
        }

        if let cached = readCachedClaudeOAuth() {
            return cached
        }

        let username = NSUserName()
        let services = [
            "Claude Code-credentials",
            "Claude Code-staging-oauth-credentials",
            "Claude Code-local-oauth-credentials"
        ]

        for service in services {
            if let data = readGenericPassword(service: service, account: username),
               let payload = try? decoder.decode(SecureStorageData.self, from: data),
               let oauth = payload.claudeAiOauth {
                try? writeCachedClaudeOAuth(oauth)
                return oauth
            }
        }

        throw ClaudeCodexUsageError.missingClaudeCredentials
    }

    private func readGenericPassword(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    private func applicationSupportBaseURL() -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
    }

    private func preferredCacheDirectoryURL() -> URL {
        applicationSupportBaseURL().appendingPathComponent("ClaudeCodexUsage", isDirectory: true)
    }

    private func legacyCacheDirectoryURL() -> URL {
        applicationSupportBaseURL().appendingPathComponent("UsageWatch", isDirectory: true)
    }

    private func cacheDirectoryCandidates() -> [URL] {
        [preferredCacheDirectoryURL(), legacyCacheDirectoryURL()]
    }

    private func cacheFileURL(in directory: URL) -> URL {
        directory.appendingPathComponent("claude-oauth.json")
    }

    private func snapshotCacheURL(in directory: URL) -> URL {
        directory.appendingPathComponent("snapshot.json")
    }

    private func readCachedClaudeOAuth() -> ClaudeOAuth? {
        for directory in cacheDirectoryCandidates() {
            let cacheURL = cacheFileURL(in: directory)
            guard let data = try? Data(contentsOf: cacheURL) else { continue }
            if let oauth = try? decoder.decode(ClaudeOAuth.self, from: data) {
                return oauth
            }
        }
        return nil
    }

    private func writeCachedClaudeOAuth(_ oauth: ClaudeOAuth) throws {
        let cacheDir = preferredCacheDirectoryURL()
        try fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let data = try encoder.encode(oauth)
        try data.write(to: cacheFileURL(in: cacheDir), options: .atomic)
    }

    private func requestClaudeUsage(accessToken: String) throws -> ClaudeUsageResponse {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            throw ClaudeCodexUsageError.claudeUsageURLInvalid
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ClaudeCodexUsage/1.1", forHTTPHeaderField: "User-Agent")

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseError: Error?

        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                responseError = error
                return
            }

            if let httpResponse = response as? HTTPURLResponse, !(200 ..< 300).contains(httpResponse.statusCode) {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                if httpResponse.statusCode == 429 {
                    let retryAfter = httpResponse.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init)
                    responseError = ClaudeCodexUsageError.claudeRateLimited(retryAfter: retryAfter)
                    return
                }
                responseError = ClaudeCodexUsageError.claudeRequestFailed(statusCode: httpResponse.statusCode, body: body)
                return
            }

            responseData = data
        }.resume()

        _ = semaphore.wait(timeout: .now() + 10)

        if let responseError {
            throw responseError
        }

        guard let responseData else {
            throw ClaudeCodexUsageError.claudeUsageNoData
        }

        return try decoder.decode(ClaudeUsageResponse.self, from: responseData)
    }

    private func parseISODate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let date = formatter.date(from: value) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let configuration = AppConfiguration.load()
    private let fetcher = UsageFetcher()
    private let menu = NSMenu()
    private var statusItem: NSStatusItem!
    private var refreshTimer: Timer?
    private var snapshot: DashboardSnapshot?
    private var refreshingServices = Set<ServiceKind>()
    private var nextRefreshAt = [ServiceKind: Date]()
    private var failureCounts = [ServiceKind: Int]()

    private var isRefreshing: Bool {
        !refreshingServices.isEmpty
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        snapshot = fetcher.readCachedSnapshot()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = menu
        configureStatusButton()

        menu.delegate = self
        rebuildMenu()
        for service in configuration.orderedServices {
            nextRefreshAt[service] = Date()
        }
        refresh(force: true)
    }

    func menuWillOpen(_ menu: NSMenu) {
        if snapshot == nil {
            refresh()
        }
    }

    @objc private func refreshNow() {
        for service in configuration.orderedServices {
            nextRefreshAt[service] = Date()
        }
        refresh(force: true)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func refresh(force: Bool = false) {
        let now = Date()
        var startedAny = false
        for service in configuration.orderedServices {
            let dueAt = nextRefreshAt[service] ?? .distantPast
            if force || dueAt <= now {
                refresh(service: service)
                startedAny = true
            }
        }

        if !startedAny {
            scheduleNextRefresh()
        }
    }

    private func refresh(service: ServiceKind) {
        if refreshingServices.contains(service) {
            return
        }

        refreshingServices.insert(service)
        nextRefreshAt[service] = .distantFuture
        rebuildMenu()
        scheduleNextRefresh()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let serviceSnapshot: ServiceSnapshot
            switch service {
            case .claude:
                serviceSnapshot = self.fetcher.fetchClaudeUsage()
            case .codex:
                serviceSnapshot = self.fetcher.fetchCodexUsage()
            }

            DispatchQueue.main.async {
                self.refreshingServices.remove(service)
                self.apply(serviceSnapshot, for: service)
            }
        }
    }

    private func apply(_ incoming: ServiceSnapshot, for service: ServiceKind) {
        let previous = currentSnapshot(for: service)
        let mergedService = merge(current: currentSnapshot(for: service), incoming: incoming)
        let updatedSnapshot = DashboardSnapshot(
            generatedAt: Date(),
            claude: service == .claude ? mergedService : (snapshot?.claude ?? placeholderSnapshot(for: .claude)),
            codex: service == .codex ? mergedService : (snapshot?.codex ?? placeholderSnapshot(for: .codex))
        )

        nextRefreshAt[service] = Date().addingTimeInterval(nextRefreshDelay(for: service, incoming: incoming, merged: mergedService, previous: previous))
        snapshot = updatedSnapshot
        try? fetcher.writeCachedSnapshot(updatedSnapshot)
        rebuildMenu()
        scheduleNextRefresh()
    }

    private func currentSnapshot(for service: ServiceKind) -> ServiceSnapshot? {
        switch service {
        case .claude:
            return snapshot?.claude
        case .codex:
            return snapshot?.codex
        }
    }

    private func merge(current: ServiceSnapshot?, incoming: ServiceSnapshot) -> ServiceSnapshot {
        guard !incoming.hasVisibleValues else { return incoming }
        guard incoming.isAvailable else { return incoming }
        guard incoming.error != nil else { return incoming }
        guard let current, current.hasVisibleValues else { return incoming }

        return ServiceSnapshot(
            name: current.name,
            windows: current.windows,
            error: nil,
            isAvailable: current.isAvailable,
            observedAt: current.observedAt,
            retryAfterSeconds: incoming.retryAfterSeconds
        )
    }

    private func placeholderSnapshot(for service: ServiceKind) -> ServiceSnapshot {
        ServiceSnapshot.unavailable(name: service.name, message: "\(service.name) usage is not configured on this Mac.")
    }

    private func rebuildMenu() {
        updateStatusButton()
        menu.removeAllItems()

        if let snapshot {
            addDisabledItem("Updated \(shortTime(snapshot.generatedAt))")
        }
        for service in configuredSnapshots() {
            addDisabledItem(menuSummary(for: service))
        }

        let refreshItem = NSMenuItem(title: isRefreshing ? "Refreshing…" : "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.isEnabled = true
        menu.addItem(refreshItem)

        let quitItem = NSMenuItem(title: "Quit \(configuration.displayName)", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    private func addDisabledItem(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.toolTip = "\(configuration.namesText) usage"
        button.imagePosition = .imageOnly
        button.image = makeStatusDisplayImage()
        button.title = ""
    }

    private func updateStatusButton() {
        statusItem.button?.image = makeStatusDisplayImage()
        statusItem.button?.title = ""
        statusItem.button?.toolTip = statusTooltip()
    }

    private func logoImage(named name: String) -> NSImage? {
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return makeFallbackLogo(text: name == "anthropic" ? "Cl" : "Cx")
    }

    private func makeStatusDisplayImage() -> NSImage? {
        let blocks = visibleStatusBlocks()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]

        if blocks.isEmpty {
            return makePlaceholderDisplayImage(text: isRefreshing ? configuration.loadingText : configuration.emptyText)
        }

        let spacing: CGFloat = 8
        let blockWidths = blocks.map { 8 + 16 + 6 + textWidth($0.text, attributes: textAttributes) + 8 }
        let width = blockWidths.reduce(0, +) + spacing * CGFloat(max(blockWidths.count - 1, 0))
        let size = NSSize(width: width, height: 20)
        let image = NSImage(size: size)

        image.lockFocus()
        defer { image.unlockFocus() }

        var originX: CGFloat = 0
        for (index, block) in blocks.enumerated() {
            let blockWidth = blockWidths[index]
            let blockTextWidth = textWidth(block.text, attributes: textAttributes)
            drawServiceCapsule(
                originX: originX,
                totalWidth: blockWidth,
                text: block.text,
                textWidth: blockTextWidth,
                background: block.kind.backgroundColor,
                logoName: block.kind.logoName,
                textAttributes: textAttributes
            )
            originX += blockWidth + spacing
        }

        return image
    }

    private func visibleStatusBlocks() -> [(kind: ServiceKind, text: String)] {
        var blocks: [(kind: ServiceKind, text: String)] = []

        for service in configuration.orderedServices {
            guard let snapshot = currentSnapshot(for: service), snapshot.hasVisibleValues else { continue }
            blocks.append((kind: service, text: pairText(for: snapshot)))
        }

        return blocks
    }

    private func makePlaceholderDisplayImage(text: String) -> NSImage? {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let width = 10 + textWidth(text, attributes: textAttributes) + 10
        let size = NSSize(width: width, height: 20)
        let image = NSImage(size: size)

        image.lockFocus()
        defer { image.unlockFocus() }

        let rect = NSRect(x: 0, y: 1, width: width, height: 18)
        let capsule = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
        NSColor(calibratedWhite: 0.28, alpha: 0.98).setFill()
        capsule.fill()
        NSColor.white.withAlphaComponent(0.14).setStroke()
        capsule.lineWidth = 1
        capsule.stroke()

        (text as NSString).draw(
            at: NSPoint(x: 10, y: 3),
            withAttributes: textAttributes
        )

        return image
    }

    private func drawServiceCapsule(
        originX: CGFloat,
        totalWidth: CGFloat,
        text: String,
        textWidth: CGFloat,
        background: NSColor,
        logoName: String,
        textAttributes: [NSAttributedString.Key: Any]
    ) {
        let capsuleRect = NSRect(x: originX, y: 1, width: totalWidth, height: 18)
        let capsule = NSBezierPath(roundedRect: capsuleRect, xRadius: 9, yRadius: 9)
        background.setFill()
        capsule.fill()

        NSColor.white.withAlphaComponent(0.16).setStroke()
        capsule.lineWidth = 1
        capsule.stroke()

        let chipRect = NSRect(x: originX + 4, y: 3, width: 14, height: 14)
        let chip = NSBezierPath(roundedRect: chipRect, xRadius: 7, yRadius: 7)
        NSColor.white.setFill()
        chip.fill()

        logoImage(named: logoName)?.draw(
            in: NSRect(x: chipRect.minX + 2, y: chipRect.minY + 2, width: 10, height: 10),
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0
        )

        (text as NSString).draw(
            at: NSPoint(x: originX + 24, y: 3),
            withAttributes: textAttributes
        )
    }

    private func makeFallbackLogo(text: String) -> NSImage? {
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let rect = NSRect(x: 0, y: 0, width: 14, height: 14)
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        NSColor.labelColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8, weight: .bold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style
        ]
        (text as NSString).draw(in: NSRect(x: 0, y: 2, width: 14, height: 10), withAttributes: attrs)
        return image
    }

    private func usageValue(for service: ServiceSnapshot, label: String) -> String {
        guard let window = service.windows.first(where: { $0.label == label }) else { return "--" }
        guard let utilization = window.utilization else { return "--" }
        return formatUtilization(utilization)
    }

    private func pairText(for service: ServiceSnapshot) -> String {
        let session = usageValue(for: service, label: "5h session")
        let weekly = usageValue(for: service, label: "7d overall")
        return "\(session) \(weekly)"
    }

    private func detailedText(for service: ServiceSnapshot) -> String {
        let session = usageValue(for: service, label: "5h session")
        let weekly = usageValue(for: service, label: "7d overall")
        return "5h session \(session), 7d overall \(weekly)"
    }

    private func scheduleNextRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil

        let pendingDates = configuration.orderedServices.compactMap { service -> Date? in
            guard !refreshingServices.contains(service) else { return nil }
            return nextRefreshAt[service]
        }

        guard let nextDate = pendingDates.min() else { return }
        let interval = max(0.25, nextDate.timeIntervalSinceNow)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.refresh()
        }
    }

    private func nextRefreshDelay(
        for service: ServiceKind,
        incoming: ServiceSnapshot,
        merged: ServiceSnapshot,
        previous: ServiceSnapshot?
    ) -> TimeInterval {
        switch service {
        case .claude:
            return nextClaudeRefreshDelay(incoming: incoming, merged: merged, previous: previous)
        case .codex:
            return nextCodexRefreshDelay(incoming: incoming, merged: merged)
        }
    }

    private func nextClaudeRefreshDelay(
        incoming: ServiceSnapshot,
        merged: ServiceSnapshot,
        previous: ServiceSnapshot?
    ) -> TimeInterval {
        if incoming.hasVisibleValues {
            failureCounts[.claude] = 0
            let highestUtilization = merged.windows.compactMap(\.utilization).max() ?? 0
            let nextReset = merged.windows.compactMap(\.resetAt).min()
            if let nextReset, nextReset.timeIntervalSinceNow <= 15 * 60 {
                return 300
            }
            if highestUtilization >= 85 {
                return 300
            }
            if highestUtilization >= 60 {
                return 420
            }
            return 600
        }

        let failureCount = (failureCounts[.claude] ?? 0) + 1
        failureCounts[.claude] = failureCount

        if let retryAfter = incoming.retryAfterSeconds {
            return max(900, retryAfter)
        }

        if isClaudeRateLimited(incoming) {
            switch failureCount {
            case 1:
                return 900
            case 2:
                return 1800
            default:
                return 3600
            }
        }

        if previous?.hasVisibleValues == true {
            return min(3600, Double(600 * max(1, failureCount)))
        }

        return min(1800, Double(300 * (1 << min(failureCount - 1, 3))))
    }

    private func nextCodexRefreshDelay(incoming: ServiceSnapshot, merged: ServiceSnapshot) -> TimeInterval {
        if incoming.hasVisibleValues {
            failureCounts[.codex] = 0
            if let observedAt = merged.observedAt {
                let age = Date().timeIntervalSince(observedAt)
                if age < 600 {
                    return 20
                }
                if age < 3600 {
                    return 45
                }
            }
            return 90
        }

        let failureCount = (failureCounts[.codex] ?? 0) + 1
        failureCounts[.codex] = failureCount

        if !incoming.isAvailable {
            return 300
        }

        return min(600, Double(30 * (1 << min(failureCount - 1, 4))))
    }

    private func isClaudeRateLimited(_ service: ServiceSnapshot) -> Bool {
        guard let error = service.error?.lowercased() else { return false }
        return error.contains("rate limit")
    }

    private func formatUtilization(_ utilization: Double) -> String {
        let roundedToTenth = (utilization * 10).rounded() / 10
        if abs(roundedToTenth.rounded() - roundedToTenth) < 0.05 {
            return "\(Int(roundedToTenth.rounded()))%"
        }
        return String(format: "%.1f%%", roundedToTenth)
    }

    private func statusTooltip() -> String {
        let visible = visibleStatusBlocks()
        if visible.isEmpty {
            return isRefreshing ? configuration.loadingText : "No \(configuration.namesText) usage data available"
        }
        return configuration.orderedServices.compactMap { service in
            guard let snapshot = currentSnapshot(for: service), snapshot.hasVisibleValues else { return nil }
            return "\(service.name): \(menuStatusText(for: snapshot))"
        }.joined(separator: "   ")
    }

    private func configuredSnapshots() -> [ServiceSnapshot] {
        configuration.orderedServices.compactMap { currentSnapshot(for: $0) }
    }

    private func menuSummary(for service: ServiceSnapshot) -> String {
        if service.hasVisibleValues {
            return "\(service.name): \(menuStatusText(for: service))"
        }
        if !service.isAvailable {
            return "\(service.name): not configured"
        }
        return "\(service.name): checking usage"
    }

    private func menuStatusText(for service: ServiceSnapshot) -> String {
        let base = detailedText(for: service)
        return base
    }

    private func compactStatusMessage(for service: ServiceSnapshot) -> String? {
        guard let error = service.error, !error.isEmpty else { return nil }
        if isClaudeRateLimited(service) {
            return "stale, retrying later"
        }
        return "stale"
    }

    private func textWidth(_ text: String, attributes: [NSAttributedString.Key: Any]) -> CGFloat {
        ceil((text as NSString).size(withAttributes: attributes).width)
    }

    private func makeStatusImage() -> NSImage? {
        if let image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "Claude Codex Usage") {
            image.isTemplate = true
            return image
        }
        return nil
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
