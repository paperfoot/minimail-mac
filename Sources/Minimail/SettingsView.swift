import SwiftUI
import AppKit
import ServiceManagement

/// Keys used for persisted settings. UserDefaults + @AppStorage binds cleanly.
enum SettingsKey {
    static let syncIntervalSeconds = "minimail.syncIntervalSeconds"
    /// Per-account mute flag (bool) keyed `minimail.mute.<email>`.
    static func muteKey(for email: String) -> String {
        "minimail.mute.\(email)"
    }
}

extension MinimailNotifier {
    /// Returns true when Settings → Notifications has muted this account.
    static func isMuted(_ email: String) -> Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.muteKey(for: email))
    }
}

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @State private var signatureDraft: NSAttributedString = NSAttributedString()
    @State private var signatureAccount: String?
    @State private var signatureSaving: Bool = false
    @State private var signatureSaved: Date?
    @State private var signatureEditorHandle = RichTextEditorHandle()
    @State private var launchAtLoginEnabled: Bool = false
    @State private var launchAtLoginError: String?
    @State private var apiKeyProfile: String?
    @State private var apiKeyDraft: String = ""
    @State private var apiKeySaving: Bool = false
    @State private var apiKeyStatus: String?
    @State private var outboxEntries: [OutboxEntry] = []
    @State private var outboxLoading: Bool = false
    @State private var outboxStatus: String?
    @AppStorage(SettingsKey.syncIntervalSeconds) private var syncInterval: Int = 60
    @AppStorage(MetricsManager.enabledKey) private var diagnosticsEnabled: Bool = true

    private let intervalOptions: [(label: String, seconds: Int)] = [
        ("30 seconds", 30),
        ("1 minute", 60),
        ("2 minutes", 120),
        ("5 minutes", 300),
        ("15 minutes", 900),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.25)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    accountsSection
                    Divider().opacity(0.15)
                    apiKeySection
                    Divider().opacity(0.15)
                    signatureSection
                    Divider().opacity(0.15)
                    syncSection
                    Divider().opacity(0.15)
                    launchAtLoginSection
                    Divider().opacity(0.15)
                    notificationsSection
                    Divider().opacity(0.15)
                    outboxSection
                    Divider().opacity(0.15)
                    diagnosticsSection
                    Divider().opacity(0.15)
                    aboutSection
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
        }
        .onAppear {
            loadSignatureForCurrentAccount()
            loadLaunchAtLoginState()
            loadAPIKeyProfile()
            Task { await loadOutbox() }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button { state.router.currentView = .inbox } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(IconButtonStyle())
            .keyboardShortcut(.escape, modifiers: [])
            .help("Back to inbox (esc)")
            .accessibilityLabel("Back to inbox")
            Text("Settings").font(.system(size: 13, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // ── Accounts ─────────────────────────────────────────────────────────

    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Accounts", subtitle: "Tap to set as default — outgoing mail uses this identity")
            VStack(spacing: 4) {
                ForEach(state.session.accounts) { acct in
                    AccountSettingRow(
                        account: acct,
                        isDefault: acct.is_default == true,
                        isCurrent: state.session.currentAccount?.email == acct.email
                    ) {
                        Task { await setDefault(acct) }
                    }
                }
            }
            // Command is copy-pastable — monospaced, tappable to copy
            // to the clipboard. Onboarding sends the user here for
            // add-account help, so this needs to be friendly and
            // unambiguous about what to run. Once the full app ships an
            // in-app add/remove flow the Terminal path can retire.
            VStack(alignment: .leading, spacing: 4) {
                Text("To add another account, run this in Terminal:")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                // Use the bundled email-cli path so the command works for
                // every widget install — not just users who happen to have
                // email-cli on PATH via Homebrew or cargo. The full bundled
                // path is ugly but reliable. When the user's shell PATH
                // already has email-cli, `email-cli account add …` also
                // works — both commands are equivalent.
                let bundledCLI = "/Applications/Minimail.app/Contents/MacOS/email-cli"
                let profile = state.session.accounts.first?.profile_name ?? "default"
                let addCommand = "\"\(bundledCLI)\" account add you@your-domain.com --profile \(profile)"
                HStack(spacing: 6) {
                    Text(addCommand)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(addCommand, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .help("Copy command")
                    .accessibilityLabel("Copy Terminal command to clipboard")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(.top, 4)
        }
    }

    private func setDefault(_ account: Account) async {
        do {
            try await EmailCLI.shared.setDefaultAccount(account.email)
            await state.refreshAccounts()
            state.session.currentAccount = state.session.accounts.first { $0.email == account.email }
        } catch {
            state.inbox.error = ActionableError.classify(error)
        }
    }

    // ── Resend key ───────────────────────────────────────────────────────

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Resend key", subtitle: "Repair or rotate the API key for a profile")
            if availableProfiles.isEmpty {
                Text("No profiles configured")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Picker("", selection: Binding(
                        get: { apiKeyProfile ?? availableProfiles.first ?? "" },
                        set: { apiKeyProfile = $0; apiKeyStatus = nil }
                    )) {
                        ForEach(availableProfiles, id: \.self) { profile in
                            Text(profile).tag(profile)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)

                    SecureField("re_…", text: $apiKeyDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }

                HStack(spacing: 8) {
                    if apiKeySaving { ProgressView().controlSize(.small) }
                    if let apiKeyStatus {
                        Text(apiKeyStatus)
                            .font(.system(size: 10))
                            .foregroundStyle(apiKeyStatus == "Saved" || apiKeyStatus == "Works" ? .green : .secondary)
                    }
                    Spacer()
                    Button("Test") {
                        Task { await testAPIKeyProfile() }
                    }
                    .disabled(apiKeySaving)
                    .controlSize(.small)
                    Button("Save") {
                        Task { await saveAPIKey() }
                    }
                    .disabled(apiKeySaving || apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .controlSize(.small)
                }
            }
        }
    }

    private var availableProfiles: [String] {
        Array(Set(state.session.accounts.map(\.profile_name))).sorted()
    }

    private func loadAPIKeyProfile() {
        if apiKeyProfile == nil {
            apiKeyProfile = state.session.currentAccount?.profile_name ?? availableProfiles.first
        }
    }

    private func saveAPIKey() async {
        guard let profile = apiKeyProfile ?? availableProfiles.first else { return }
        let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        apiKeySaving = true
        defer { apiKeySaving = false }
        do {
            try await EmailCLI.shared.addProfile(name: profile, apiKey: key)
            try await EmailCLI.shared.testProfile(name: profile)
            apiKeyDraft = ""
            apiKeyStatus = "Saved"
            await state.refreshAccounts()
        } catch {
            apiKeyStatus = "Failed"
            state.inbox.error = ActionableError.classify(error)
        }
    }

    private func testAPIKeyProfile() async {
        guard let profile = apiKeyProfile ?? availableProfiles.first else { return }
        apiKeySaving = true
        defer { apiKeySaving = false }
        do {
            try await EmailCLI.shared.testProfile(name: profile)
            apiKeyStatus = "Works"
        } catch {
            apiKeyStatus = "Failed"
            state.inbox.error = ActionableError.classify(error)
        }
    }

    // ── Signature ────────────────────────────────────────────────────────

    private var signatureSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Signature", subtitle: "Appears at the bottom of outgoing mail")

            Menu {
                ForEach(state.session.accounts) { acct in
                    Button(acct.email) {
                        signatureAccount = acct.email
                        Task { await loadSignature(for: acct.email) }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    AccountAvatar(email: signatureAccount ?? "?")
                    Text(signatureAccount ?? "—")
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)

            VStack(spacing: 0) {
                RichTextToolbar(textViewProvider: { signatureEditorHandle.textView })
                Divider().opacity(0.12)
                RichTextEditor(
                    attributedText: $signatureDraft,
                    handle: signatureEditorHandle
                )
                .frame(height: 84)
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 8) {
                if signatureSaving { ProgressView().controlSize(.small) }
                if let _ = signatureSaved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                }
                Spacer()
                Button("Save") {
                    Task { await saveSignature() }
                }
                .disabled(signatureAccount == nil || signatureSaving)
                .controlSize(.small)
            }
        }
    }

    private func loadSignatureForCurrentAccount() {
        signatureAccount = state.session.currentAccount?.email
        if let acct = signatureAccount {
            Task { await loadSignature(for: acct) }
        }
    }

    private func loadSignature(for account: String) async {
        do {
            let stored = (try await EmailCLI.shared.signature(for: account)) ?? ""
            signatureDraft = SignatureFormatting.attributed(from: stored)
            signatureSaved = nil
        } catch {
            state.inbox.error = ActionableError.classify(error)
        }
    }

    private func saveSignature() async {
        guard let account = signatureAccount else { return }
        signatureSaving = true
        defer { signatureSaving = false }
        do {
            let stored = SignatureFormatting.storageString(from: signatureDraft)
            try await EmailCLI.shared.setSignature(
                stored,
                isHTML: SignatureFormatting.isHTML(stored),
                for: account
            )
            signatureSaved = Date()
            Task {
                try? await Task.sleep(for: .seconds(2))
                if signatureSaved != nil, Date().timeIntervalSince(signatureSaved!) >= 1.9 {
                    signatureSaved = nil
                }
            }
            await state.refreshAccounts()
        } catch {
            state.inbox.error = ActionableError.classify(error)
        }
    }

    // ── Sync interval ────────────────────────────────────────────────────

    private var syncSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Check for mail", subtitle: "How often Minimail polls Resend in the background")
            Picker("", selection: $syncInterval) {
                ForEach(intervalOptions, id: \.seconds) { opt in
                    Text(opt.label).tag(opt.seconds)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .onChange(of: syncInterval) { _, _ in
                NotificationCenter.default.post(name: .minimailSyncIntervalChanged, object: nil)
            }
        }
    }

    // ── Launch at login ─────────────────────────────────────────────────

    private var launchAtLoginSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Launch at login", subtitle: "Open Minimail automatically when you sign in")
            Toggle(isOn: Binding(
                get: { launchAtLoginEnabled },
                set: { enabled in setLaunchAtLogin(enabled) }
            )) {
                Text("Open Minimail at login")
                    .font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if let launchAtLoginError {
                Text(launchAtLoginError)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
    }

    private func loadLaunchAtLoginState() {
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginEnabled = enabled
            launchAtLoginError = nil
        } catch {
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
            launchAtLoginError = ActionableError.classify(error).message
        }
    }

    // ── Notifications ────────────────────────────────────────────────────

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Notifications", subtitle: "macOS banner alerts for new incoming mail")
            ForEach(state.session.accounts) { acct in
                AccountMuteToggle(email: acct.email)
            }
            HStack {
                Image(systemName: "bell.badge")
                    .foregroundStyle(.tertiary)
                Text("Manage permissions in System Settings")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
            .padding(.top, 4)
        }
    }

    // ── Outbox ──────────────────────────────────────────────────────────

    private var outboxSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Outbox", subtitle: "Failed and pending sends stay here until delivered")

            HStack(spacing: 8) {
                if outboxLoading { ProgressView().controlSize(.small) }
                if let outboxStatus {
                    Text(outboxStatus)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") {
                    Task { await loadOutbox() }
                }
                .controlSize(.small)
                Button("Flush") {
                    Task { await flushOutbox() }
                }
                .disabled(outboxLoading || outboxEntries.isEmpty)
                .controlSize(.small)
            }

            if outboxEntries.isEmpty {
                Text("No pending or failed sends")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 4) {
                    ForEach(outboxEntries) { entry in
                        HStack(spacing: 8) {
                            Image(systemName: entry.isFailed ? "exclamationmark.triangle.fill" : "clock.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(entry.isFailed ? .orange : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.account_email)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                                Text(entry.last_error ?? "\(entry.status), attempts \(entry.attempts)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            if entry.isFailed {
                                Button("Retry") {
                                    Task { await retryOutbox(entry) }
                                }
                                .controlSize(.small)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
    }

    private func loadOutbox() async {
        outboxLoading = true
        defer { outboxLoading = false }
        do {
            outboxEntries = try await EmailCLI.shared.outboxList()
                .filter { $0.isFailed || $0.isPending }
            outboxStatus = nil
        } catch {
            outboxStatus = "Could not load"
            state.inbox.error = ActionableError.classify(error)
        }
    }

    private func retryOutbox(_ entry: OutboxEntry) async {
        outboxLoading = true
        defer { outboxLoading = false }
        do {
            try await EmailCLI.shared.outboxRetry(id: entry.id)
            outboxStatus = "Retried"
            await loadOutbox()
        } catch {
            outboxStatus = "Retry failed"
            state.inbox.error = ActionableError.classify(error)
        }
    }

    private func flushOutbox() async {
        outboxLoading = true
        defer { outboxLoading = false }
        do {
            let result = try await EmailCLI.shared.outboxFlush()
            outboxStatus = "Sent \(result.sent), failed \(result.failed)"
            await loadOutbox()
        } catch {
            outboxStatus = "Flush failed"
            state.inbox.error = ActionableError.classify(error)
        }
    }

    // ── Diagnostics ──────────────────────────────────────────────────────

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Diagnostics",
                         subtitle: "Local crash and performance data — nothing is uploaded")
            Toggle(isOn: $diagnosticsEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Collect local diagnostics")
                        .font(.system(size: 12))
                    Text("Uses Apple's MetricKit. Data stays on this Mac and is never sent to us or third parties. Turn off to stop collection entirely.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .onChange(of: diagnosticsEnabled) { _, _ in
                MetricsManager.shared.applyCurrentSetting()
            }

            HStack {
                Image(systemName: "folder")
                    .foregroundStyle(.tertiary)
                Text("Show diagnostics folder")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open") {
                    if let url = MetricsManager.diagnosticsDirectoryURL() {
                        try? FileManager.default.createDirectory(
                            at: url, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
            .padding(.top, 2)
        }
    }

    // ── About ────────────────────────────────────────────────────────────

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("About", subtitle: nil)
            kv("Version", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0")
            kv("Author", "Paperfoot AI (SG) Pte. Ltd.")
            kv("Engine", state.session.cliPath ?? "email-cli not located")
        }
    }

    // ── Helpers ─────────────────────────────────────────────────────────

    private func sectionTitle(_ title: String, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 12, weight: .semibold))
            if let subtitle {
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }

    private func kv(_ key: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(key).font(.system(size: 11)).foregroundStyle(.tertiary).frame(width: 50, alignment: .leading)
            Text(value).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }
}

struct AccountSettingRow: View {
    let account: Account
    let isDefault: Bool
    let isCurrent: Bool
    let onTap: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                AccountAvatar(email: account.email)
                VStack(alignment: .leading, spacing: 0) {
                    Text(account.email).font(.system(size: 12))
                    if isDefault {
                        Text("Default")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                if isDefault {
                    Image(systemName: "star.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.yellow)
                }
                if isCurrent {
                    Image(systemName: "eye.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(hovered ? Color.primary.opacity(0.05) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

extension Notification.Name {
    static let minimailSyncIntervalChanged = Notification.Name("ai.paperfoot.minimail.syncIntervalChanged")
}

/// Per-account notification toggle row. Reads/writes a boolean keyed by the
/// account address so the notifier can pick it up via `MinimailNotifier.isMuted`.
/// UI polarity is "Notifications: ON/OFF" — persisted as `muted` (inverted).
struct AccountMuteToggle: View {
    let email: String
    @State private var muted: Bool

    init(email: String) {
        self.email = email
        self._muted = State(initialValue:
            UserDefaults.standard.bool(forKey: SettingsKey.muteKey(for: email))
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            AccountAvatar(email: email)
            VStack(alignment: .leading, spacing: 1) {
                Text(email).font(.system(size: 12))
                Text(muted ? "Muted" : "Notify on new mail")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { !muted },
                set: { newVal in
                    muted = !newVal
                    UserDefaults.standard.set(muted, forKey: SettingsKey.muteKey(for: email))
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
        }
        .padding(.vertical, 2)
    }
}
