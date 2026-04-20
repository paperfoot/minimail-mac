import Foundation
import MetricKit
import os

/// Receives MetricKit payloads (MXMetricPayload, MXDiagnosticPayload) and
/// writes them to a local directory so the user can inspect what's being
/// collected. Nothing is uploaded.
///
/// Default behaviour: collection is ON. The toggle in Settings flips the
/// `minimail.diagnosticsEnabled` UserDefaults key, which causes the
/// manager to `remove(self)` itself from MXMetricManager. Re-enabling
/// re-subscribes.
///
/// MetricKit delivers payloads daily, aggregated over 24h and scrubbed of
/// PII by the OS before they reach us. See Apple's "Improving your app's
/// performance" for the full field list. We never see email content.
@MainActor
final class MetricsManager: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricsManager()

    static let enabledKey = "minimail.diagnosticsEnabled"

    private let logger = Logger(subsystem: "ai.paperfoot.minimail", category: "metrics")
    private var isSubscribed = false

    /// Default ON. A brand-new install collects local diagnostics until the
    /// user opts out in Settings. Nothing is uploaded.
    static func isEnabled() -> Bool {
        if UserDefaults.standard.object(forKey: enabledKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: enabledKey)
    }

    func applyCurrentSetting() {
        if Self.isEnabled() {
            subscribe()
        } else {
            unsubscribe()
        }
    }

    private func subscribe() {
        guard !isSubscribed else { return }
        MXMetricManager.shared.add(self)
        isSubscribed = true
        logger.info("MetricKit subscribed — local diagnostics on")
    }

    private func unsubscribe() {
        guard isSubscribed else { return }
        MXMetricManager.shared.remove(self)
        isSubscribed = false
        logger.info("MetricKit unsubscribed — local diagnostics off")
    }

    // MARK: - MXMetricManagerSubscriber

    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            write(payload.jsonRepresentation(), kind: "metric")
        }
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            write(payload.jsonRepresentation(), kind: "diagnostic")
        }
    }

    // MARK: - Local persistence

    /// Appends one payload as `<dir>/<kind>-<iso-date>.json`. Zero network
    /// calls. The user can delete the directory at any time.
    nonisolated private func write(_ data: Data, kind: String) {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory,
                                       in: .userDomainMask).first
        else { return }
        let dir = appSupport
            .appendingPathComponent("Minimail", isDirectory: true)
            .appendingPathComponent("diagnostics", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("\(kind)-\(stamp).json")
        try? data.write(to: url, options: [.atomic])
    }

    /// Directory shown in Finder by the "Show diagnostics folder" button.
    static func diagnosticsDirectoryURL() -> URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Minimail", isDirectory: true)
            .appendingPathComponent("diagnostics", isDirectory: true)
    }
}
