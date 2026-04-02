import AppKit
import Foundation
import Security

struct UsageWindow {
    let label: String
    let utilization: Double?
    let resetAt: Date?
}

struct ServiceSnapshot {
    let name: String
    let detail: String?
    let windows: [UsageWindow]
    let error: String?

    static func failure(name: String, message: String) -> ServiceSnapshot {
        ServiceSnapshot(name: name, detail: nil, windows: [], error: message)
    }
}

struct DashboardSnapshot {
    let generatedAt: Date
    let claude: ServiceSnapshot
    let codex: ServiceSnapshot
}

struct SecureStorageData: Decodable {
    let claudeAiOauth: ClaudeOAuth?
}

struct ClaudeOAuth: Decodable {
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

final class UsageFetcher {
    private let fileManager = FileManager.default
    private let decoder = JSONDecoder()

    func fetchAll() -> DashboardSnapshot {
        DashboardSnapshot(
            generatedAt: Date(),
            claude: fetchClaudeUsage(),
            codex: fetchCodexUsage()
        )
    }

    private func fetchClaudeUsage() -> ServiceSnapshot {
        do {
            let oauth = try readClaudeOAuth()
            let usage = try requestClaudeUsage(accessToken: oauth.accessToken)
            let windows = [
                makeClaudeWindow(label: "5h session", source: usage.five_hour),
                makeClaudeWindow(label: "7d overall", source: usage.seven_day)
            ]

            return ServiceSnapshot(
                name: "Claude",
                detail: nil,
                windows: windows.compactMap { $0.utilization == nil && $0.resetAt == nil ? nil : $0 },
                error: nil
            )
        } catch {
            return .failure(name: "Claude", message: error.localizedDescription)
        }
    }

    private func fetchCodexUsage() -> ServiceSnapshot {
        let sessionsRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
        guard let enumerator = fileManager.enumerator(at: sessionsRoot, includingPropertiesForKeys: nil) else {
            return .failure(name: "Codex", message: "No local Codex sessions directory was found.")
        }

        var latestTimestamp = ""
        var latestPlanType: String?
        var latestWindows: [UsageWindow] = []

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }

            for line in contents.split(whereSeparator: \.isNewline) {
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

                if timestamp < latestTimestamp {
                    continue
                }

                latestTimestamp = timestamp
                latestPlanType = rateLimits["plan_type"] as? String
                latestWindows = codexWindows(from: rateLimits)
            }
        }

        if latestTimestamp.isEmpty {
            return .failure(name: "Codex", message: "No Codex rate-limit snapshots were found.")
        }

        return ServiceSnapshot(
            name: "Codex",
            detail: nil,
            windows: latestWindows,
            error: nil
        )
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
                return oauth
            }
        }

        throw NSError(
            domain: "ClaudeCodexUsage",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Claude Code OAuth credentials were not found in the local keychain."]
        )
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

    private func requestClaudeUsage(accessToken: String) throws -> ClaudeUsageResponse {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            throw NSError(domain: "ClaudeCodexUsage", code: 2, userInfo: [NSLocalizedDescriptionKey: "Claude usage URL is invalid."])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ClaudeCodexUsage/1.2", forHTTPHeaderField: "User-Agent")

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
                responseError = NSError(
                    domain: "ClaudeCodexUsage",
                    code: httpResponse.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "Claude usage request failed: HTTP \(httpResponse.statusCode) \(body)"]
                )
                return
            }

            responseData = data
        }.resume()

        _ = semaphore.wait(timeout: .now() + 10)

        if let responseError {
            throw responseError
        }

        guard let responseData else {
            throw NSError(
                domain: "ClaudeCodexUsage",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Claude usage request returned no data."]
            )
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

    private func friendlyTitle(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { word in
                if word.allSatisfy({ $0.isUppercase || $0.isNumber }) {
                    return String(word)
                }
                return word.prefix(1).uppercased() + word.dropFirst().lowercased()
            }
            .joined(separator: " ")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let fetcher = UsageFetcher()
    private let menu = NSMenu()
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var snapshot: DashboardSnapshot?
    private var isRefreshing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = menu
        configureStatusButton()

        menu.delegate = self
        rebuildMenu()
        refresh()

        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if snapshot == nil || !isRefreshing {
            refresh()
        }
    }

    @objc private func refreshNow() {
        refresh(force: true)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func refresh(force: Bool = false) {
        if isRefreshing && !force {
            return
        }

        isRefreshing = true
        rebuildMenu()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let snapshot = self.fetcher.fetchAll()
            DispatchQueue.main.async {
                self.snapshot = snapshot
                self.isRefreshing = false
                self.rebuildMenu()
            }
        }
    }

    private func rebuildMenu() {
        updateStatusButton()
        menu.removeAllItems()

        addDisabledItem("Claude Codex Usage")
        if let snapshot {
            addDisabledItem("Updated \(shortTime(snapshot.generatedAt))")
        } else if isRefreshing {
            addDisabledItem("Refreshing…")
        } else {
            addDisabledItem("Waiting for first refresh…")
        }

        menu.addItem(.separator())
        addServiceSection(snapshot?.claude ?? ServiceSnapshot(name: "Claude", detail: nil, windows: [], error: isRefreshing ? "Refreshing…" : "No data yet."))

        menu.addItem(.separator())
        addServiceSection(snapshot?.codex ?? ServiceSnapshot(name: "Codex", detail: nil, windows: [], error: isRefreshing ? "Refreshing…" : "No data yet."))

        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: isRefreshing ? "Refreshing…" : "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.isEnabled = !isRefreshing
        menu.addItem(refreshItem)

        let quitItem = NSMenuItem(title: "Quit Claude Codex Usage", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func addServiceSection(_ service: ServiceSnapshot) {
        addDisabledItem(service.name)

        if let error = service.error {
            addDisabledItem(trimmedError(error))
            return
        }

        if service.windows.isEmpty {
            addDisabledItem("No usage windows found.")
            return
        }

        for window in service.windows {
            addDisabledItem(windowLine(window))
        }
    }

    private func windowLine(_ window: UsageWindow) -> String {
        let percent = formattedPercent(window.utilization)
        let reset = formattedReset(window.resetAt)
        return "\(window.label)  \(percent)  •  \(reset)"
    }

    private func formattedPercent(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        if value.rounded() == value {
            return "\(Int(value))%"
        }
        return String(format: "%.1f%%", value)
    }

    private func formattedReset(_ date: Date?) -> String {
        guard let date else { return "reset unknown" }

        if Calendar.current.isDateInToday(date) {
            return "resets \(timeOnly(date))"
        }

        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "EEE h:mm a"
        return "resets \(formatter.string(from: date))"
    }

    private func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    private func timeOnly(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    private func trimmedError(_ value: String) -> String {
        let flat = value.replacingOccurrences(of: "\n", with: " ")
        if flat.count <= 96 {
            return flat
        }
        let index = flat.index(flat.startIndex, offsetBy: 93)
        return flat[..<index] + "..."
    }

    private func addDisabledItem(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.title = "Usage"
        button.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        button.image = nil
        button.toolTip = "Claude Codex Usage"
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }
        button.title = isRefreshing ? "Usage…" : "Usage"
        button.toolTip = "Claude Codex Usage"
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
