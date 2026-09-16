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
    let initialSection: String?
    private enum Section: String, CaseIterable {
        case general = "General", accounts = "Accounts", signature = "Signature", outbox = "Outbox", advanced = "Advanced"
    }
    @State private var section: Section = .general
    @State private var profiles: [MailProfile] = []
    @State private var editingAccount: Account?
    @State private var editingName = ""
    @State private var editingProfile = ""
    @State private var accountBusy = false
    @State private var accountError: String?
    @State private var removingAccount: Account?
    @State private var showingNewProfile = false
    @State private var newProfileName = ""
    @State private var newProfileKey = ""
    @State private var profileError: String?
    @State private var removingProfile: String?
    @State private var signatureDraft: NSAttributedString = NSAttributedString()
    @State private var showingSignatureEditor = false
    @State private var signatureOriginal = ""
    @State private var signatureError: String?
    @State private var signatureLoading = false
    @State private var confirmDiscardSignature = false
    @State private var signatureAccount: String?
    @State private var signatureSaving: Bool = false
    @State private var signatureSaved: Date?
    @State private var signatureEditorHandle = RichTextEditorHandle()
    @State private var launchAtLoginEnabled: Bool = false
    @State private var launchAtLoginNeedsApproval: Bool = false
    @State private var launchAtLoginError: String?
    @State private var apiKeyProfile: String?
    @State private var apiKeyDraft: String = ""
    @State private var apiKeySaving: Bool = false
    @State private var apiKeyStatus: String?
    @State private var outboxEntries: [OutboxEntry] = []
    @State private var outboxLoading: Bool = false
    @State private var outboxStatus: String?
    @State private var cliToolStatus: EmailCLI.CommandLineToolStatus?
    @State private var cliToolInstalling: Bool = false
    @State private var showingAddAccount = false
    @State private var addAccountEmail = ""
    @State private var addAccountProfile = ""
    @State private var addAccountAsDefault = false
    @State private var addAccountSaving = false
    @State private var addAccountError: ActionableError?
    @AppStorage(SettingsKey.syncIntervalSeconds) private var syncInterval: Int = 60
    @AppStorage(MetricsManager.enabledKey) private var diagnosticsEnabled: Bool = true

    private let intervalOptions: [(label: String, seconds: Int)] = [
        ("30 seconds", 30),
        ("1 minute", 60),
        ("2 minutes", 120),
        ("5 minutes", 300),
        ("15 minutes", 900),
    ]

    init(initialSection: String? = nil) {
        self.initialSection = initialSection
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.25)
            if let error = state.inbox.error {
                ErrorBanner(error: error)
            }
            Picker("Settings section", selection: $section) {
                ForEach(Section.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(height: 24)
            .padding(12)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch section {
                    case .general:
                        syncSection
                        launchAtLoginSection
                        notificationsSection
                    case .accounts:
                        accountsSection
                        Divider()
                        apiKeySection
                    case .signature: signatureSection
                    case .outbox: outboxSection
                    case .advanced:
                        commandLineToolSection
                        diagnosticsSection
                        aboutSection
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .onChange(of: initialSection) { _, value in
            if value == "outbox" { section = .outbox }
        }
        .onAppear {
            if initialSection == "outbox" { section = .outbox }
            loadSignatureForCurrentAccount()
            Task { await loadProfiles() }
            loadLaunchAtLoginState()
            loadAPIKeyProfile()
            Task { await refreshCommandLineToolStatus() }
            Task { await loadOutbox() }
        }
        .sheet(isPresented: $showingAddAccount) { addAccountSheet }
        .sheet(item: $editingAccount) { account in accountEditor(account) }
        .sheet(isPresented: $showingNewProfile) { newProfileSheet }
        .sheet(isPresented: $showingSignatureEditor) { signatureEditor }
        .confirmationDialog("Remove \(removingAccount?.email ?? "account") from this Mac?", isPresented: Binding(
            get: { removingAccount != nil }, set: { if !$0 { removingAccount = nil } }
        ), titleVisibility: .visible) {
            Button("Remove Account and Local Mail", role: .destructive) {
                if let account = removingAccount { Task { await removeAccount(account) } }
            }
            Button("Cancel", role: .cancel) { removingAccount = nil }
        } message: {
            Text("This removes its downloaded messages and saved drafts from Minimail. Mail on Resend stays unchanged. Accounts with unfinished deliveries must be resolved in Outbox first.")
        }
        .confirmationDialog("Remove profile \(removingProfile ?? "")?", isPresented: Binding(
            get: { removingProfile != nil }, set: { if !$0 { removingProfile = nil } }
        ), titleVisibility: .visible) {
            Button("Remove Profile", role: .destructive) {
                if let name = removingProfile { Task { await removeProfile(name) } }
            }
            Button("Cancel", role: .cancel) { removingProfile = nil }
        } message: {
            Text("Removes the saved API key from this Mac. The key is not revoked at Resend. Profiles used by an account cannot be removed.")
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
        .fixedSize(horizontal: false, vertical: true)
    }

    // ── Accounts ─────────────────────────────────────────────────────────

    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Accounts", subtitle: "Manage sender identities and the default for All Accounts")
            VStack(spacing: 8) {
                ForEach(state.session.accounts) { account in
                    HStack(spacing: 10) {
                        AccountAvatar(email: account.email)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(account.display_name.flatMap { $0.isEmpty ? nil : $0 } ?? account.email)
                                .font(.body.weight(.medium))
                            Text(account.email + " · " + account.profile_name)
                                .font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        if account.is_default == true {
                            Image(systemName: "star.fill").foregroundStyle(.yellow).help("Default sender")
                        }
                        Menu {
                            Button("Edit Account…") {
                                editingName = account.display_name ?? ""
                                editingProfile = account.profile_name
                                accountError = nil
                                editingAccount = account
                            }
                            Button("Make Default Sender") { Task { await setDefault(account) } }
                                .disabled(account.is_default == true)
                            Divider()
                            Button("Remove Account…", role: .destructive) { removingAccount = account }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .accessibilityLabel("Manage \(account.email)")
                        .disabled(accountBusy)
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            if let accountError { Text(accountError).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button {
                    prepareAddAccount()
                } label: {
                    Label("Add Account", systemImage: "plus")
                }
                .disabled(availableProfiles.isEmpty || accountBusy)
                .controlSize(.small)
            }
        }
    }

    private var addAccountSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Account")
                .font(.headline)

            Form {
                TextField("Email address", text: $addAccountEmail)
                    .textContentType(.emailAddress)
                Picker("Profile", selection: $addAccountProfile) {
                    ForEach(availableProfiles, id: \.self) { profile in
                        Text(profile).tag(profile)
                    }
                }
                Toggle("Make default for sending", isOn: $addAccountAsDefault)
            }
            .formStyle(.grouped)
            .frame(height: 132)

            if state.session.accounts.contains(where: { $0.email.caseInsensitiveCompare(addAccountEmail.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame }) {
                Text("This account is already added. Use Edit Account to change it.").font(.caption).foregroundStyle(.secondary)
            }
            if let addAccountError {
                Text(addAccountError.message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if addAccountSaving {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Cancel", role: .cancel) {
                    showingAddAccount = false
                }
                .disabled(addAccountSaving)
                Button("Add") {
                    Task { await addAccount() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAddAccount || addAccountSaving)
            }
        }
        .padding(20)
        .frame(width: 380)
        .interactiveDismissDisabled(addAccountSaving)
        .onChange(of: addAccountEmail) { _, _ in addAccountError = nil }
        .onChange(of: addAccountProfile) { _, _ in addAccountError = nil }
    }

    private var canAddAccount: Bool {
        let email = addAccountEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        return email.looksLikeEmail && availableProfiles.contains(addAccountProfile)
            && !state.session.accounts.contains { $0.email.caseInsensitiveCompare(email) == .orderedSame }
    }

    private func prepareAddAccount() {
        addAccountEmail = ""
        addAccountProfile = state.session.currentAccount?.profile_name ?? availableProfiles.first ?? ""
        addAccountAsDefault = false
        addAccountError = nil
        showingAddAccount = true
    }

    private func addAccount() async {
        let email = addAccountEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.looksLikeEmail, availableProfiles.contains(addAccountProfile) else { return }
        addAccountSaving = true
        defer { addAccountSaving = false }
        do {
            try await state.addMailAccount(
                email: email,
                profile: addAccountProfile,
                makeDefault: addAccountAsDefault
            )
            showingAddAccount = false
        } catch {
            addAccountError = ActionableError.classify(error)
        }
    }

    private func loadProfiles() async {
        do {
            profiles = try await state.mailProfiles()
            if !availableProfiles.contains(apiKeyProfile ?? "") {
                apiKeyProfile = availableProfiles.first
            }
        } catch { state.inbox.error = ActionableError.classify(error) }
    }

    private func accountEditor(_ account: Account) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Account").font(.headline)
            Text(account.email).foregroundStyle(.secondary).textSelection(.enabled)
            Form {
                TextField("Sender name", text: $editingName)
                Picker("Profile", selection: $editingProfile) {
                    ForEach(availableProfiles, id: \.self) { Text($0).tag($0) }
                }
            }
            .formStyle(.grouped)
            .frame(height: 108)
            Text("Your sender name appears in outgoing messages. Changing the profile verifies that its API key can send for this domain.")
                .font(.caption).foregroundStyle(.secondary)
            if let accountError { Text(accountError).font(.caption).foregroundStyle(.red) }
            HStack {
                if accountBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { editingAccount = nil }.disabled(accountBusy)
                Button("Save") { Task { await saveAccount(account) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(accountBusy || editingProfile.isEmpty)
            }
        }
        .padding(20).frame(width: 380)
        .interactiveDismissDisabled(accountBusy)
    }

    private func saveAccount(_ account: Account) async {
        accountBusy = true
        accountError = nil
        defer { accountBusy = false }
        do {
            try await state.editMailAccount(email: account.email, name: editingName.trimmingCharacters(in: .whitespacesAndNewlines), profile: editingProfile)
            editingAccount = nil
        } catch { accountError = ActionableError.classify(error).message }
    }

    private func removeAccount(_ account: Account) async {
        accountBusy = true
        accountError = nil
        defer { accountBusy = false; removingAccount = nil }
        do {
            try await state.removeMailAccount(account.email)
            if signatureAccount == account.email { loadSignatureForCurrentAccount() }
        } catch { accountError = ActionableError.classify(error).message }
    }

    private var newProfileSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Profile").font(.headline)
            Text("Connect a Resend workspace, then add its email addresses as accounts.")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                TextField("Profile name", text: $newProfileName)
                SecureField("Resend API key", text: $newProfileKey)
            }
            .formStyle(.grouped).frame(height: 108)
            if let profileError { Text(profileError).font(.caption).foregroundStyle(.red) }
            HStack {
                if apiKeySaving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { newProfileKey = ""; showingNewProfile = false }
                    .disabled(apiKeySaving)
                Button("Test and Add") { Task { await createProfile() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(apiKeySaving || newProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newProfileKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 380)
        .interactiveDismissDisabled(apiKeySaving)
    }

    private func createProfile() async {
        let name = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !availableProfiles.contains(name) else {
            profileError = "This profile already exists. Select it in Accounts to replace its key."
            return
        }
        apiKeySaving = true
        profileError = nil
        defer { apiKeySaving = false }
        do {
            try await state.saveMailProfile(name: name, apiKey: newProfileKey.trimmingCharacters(in: .whitespacesAndNewlines))
            newProfileKey = ""
            await loadProfiles()
            apiKeyProfile = name
            showingNewProfile = false
        } catch { profileError = ActionableError.classify(error).message }
    }

    private func removeProfile(_ name: String) async {
        apiKeySaving = true
        defer { apiKeySaving = false; removingProfile = nil }
        do {
            try await state.removeMailProfile(name)
            apiKeyDraft = ""
            await loadProfiles()
            apiKeyStatus = "Profile removed"
        } catch { state.inbox.error = ActionableError.classify(error) }
    }

    // ── Command line tool ────────────────────────────────────────────────

    private var commandLineToolSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Command line tool", subtitle: "Make email-cli available to agents and Terminal")

            VStack(alignment: .leading, spacing: 4) {
                cliPathRow("Bundled", cliToolStatus?.bundledPath ?? state.session.cliPath ?? "Not found")
                cliPathRow("Terminal", cliToolStatus?.shellPath ?? "Not installed on PATH")
                if let version = cliToolStatus?.shellVersion {
                    cliPathRow("Version", version)
                }
                if let installPath = cliToolStatus?.installPath {
                    cliPathRow("Install to", installPath)
                }
            }

            if let warning = cliToolStatus?.pathWarning {
                Text(warning)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                if cliToolInstalling { ProgressView().controlSize(.small) }
                Spacer()
                Button {
                    Task { await refreshCommandLineToolStatus() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh CLI status")
                .accessibilityLabel("Refresh CLI status")

                Button {
                    Task { await installCommandLineTool() }
                } label: {
                    Label("Install", systemImage: "terminal")
                }
                .disabled(cliToolInstalling || cliToolStatus?.bundledPath == nil)
                .controlSize(.small)
            }
        }
    }

    private func cliPathRow(_ key: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(key)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(width: 48, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func refreshCommandLineToolStatus() async {
        cliToolStatus = await state.commandLineToolStatus()
    }

    private func installCommandLineTool() async {
        cliToolInstalling = true
        defer { cliToolInstalling = false }
        do {
            cliToolStatus = try await state.installCommandLineTool()
        } catch {
            state.inbox.error = ActionableError.classify(error)
            await refreshCommandLineToolStatus()
        }
    }

    private func setDefault(_ account: Account) async {
        do {
            try await state.setDefaultMailAccount(account.email)
        } catch {
            state.inbox.error = ActionableError.classify(error)
        }
    }

    // ── Resend key ───────────────────────────────────────────────────────

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Profiles", subtitle: "Each profile holds a Resend API key. New keys are tested before replacing a working key.")
            if availableProfiles.isEmpty {
                Text("No profiles configured")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Picker("", selection: Binding(
                        get: { apiKeyProfile ?? availableProfiles.first ?? "" },
                        set: { apiKeyProfile = $0; apiKeyStatus = nil; apiKeyDraft = "" }
                    )) {
                        ForEach(availableProfiles, id: \.self) { profile in
                            Text(profile).tag(profile)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    .disabled(apiKeySaving)

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
                    Button("Test Saved Key") {
                        Task { await testAPIKeyProfile() }
                    }
                    .disabled(apiKeySaving)
                    .controlSize(.small)
                    Button("Test and Save") {
                        Task { await saveAPIKey() }
                    }
                    .disabled(apiKeySaving || apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .controlSize(.small)
                }
            }
            HStack {
                Button("Add Profile…") {
                    newProfileName = ""; newProfileKey = ""; profileError = nil
                    showingNewProfile = true
                }
                Spacer()
                if let profile = apiKeyProfile ?? availableProfiles.first {
                    Button("Remove Profile…", role: .destructive) { removingProfile = profile }
                        .disabled(state.session.accounts.contains { $0.profile_name == profile })
                        .help("Remove attached accounts before removing their profile")
                }
            }
            .controlSize(.small)
            .disabled(apiKeySaving)
        }
    }

    private var availableProfiles: [String] {
        Array(Set(profiles.map(\.name) + state.session.accounts.map(\.profile_name))).sorted()
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
            try await state.saveMailProfile(name: profile, apiKey: key)
            apiKeyDraft = ""
            apiKeyStatus = "Saved"
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
            try await state.testMailProfile(name: profile)
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

            Text(signatureDraft.string.isEmpty ? "No signature" : signatureDraft.string)
                .font(.body).foregroundStyle(.secondary)
                .lineLimit(8).textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                .padding(12)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            Text("Added automatically when sending, including saved drafts and replies.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if signatureLoading { ProgressView().controlSize(.small) }
                if signatureSaved != nil { Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                Spacer()
                Button("Edit Signature…") {
                    signatureOriginal = SignatureFormatting.storageString(from: signatureDraft)
                    signatureError = nil
                    showingSignatureEditor = true
                }
                .disabled(signatureAccount == nil || signatureLoading)
            }
        }
        .task(id: signatureAccount) {
            guard let signatureAccount else { return }
            await loadSignature(for: signatureAccount)
        }
    }

    private var signatureEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Signature").font(.headline)
            Text(signatureAccount ?? "").font(.callout).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                RichTextToolbar(textViewProvider: { signatureEditorHandle.textView })
                Divider()
                RichTextEditor(attributedText: $signatureDraft, onEdit: { signatureSaved = nil }, handle: signatureEditorHandle)
                    .frame(height: 160)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            if let signatureError { Text(signatureError).font(.caption).foregroundStyle(.red) }
            HStack {
                if signatureSaving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) {
                    if SignatureFormatting.storageString(from: signatureDraft) != signatureOriginal {
                        confirmDiscardSignature = true
                    } else { showingSignatureEditor = false }
                }.disabled(signatureSaving)
                Button("Save") { Task { await saveSignature() } }
                    .keyboardShortcut(.defaultAction).disabled(signatureSaving)
            }
        }
        .padding(20).frame(width: 380)
        .interactiveDismissDisabled()
        .confirmationDialog("Discard signature changes?", isPresented: $confirmDiscardSignature, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) {
                signatureDraft = SignatureFormatting.attributed(from: signatureOriginal)
                showingSignatureEditor = false
            }
            Button("Keep Editing", role: .cancel) {}
        }
    }

    private func loadSignatureForCurrentAccount() {
        signatureAccount = state.session.currentAccount?.email
            ?? state.session.accounts.first(where: { $0.is_default == true })?.email
            ?? state.session.accounts.first?.email
    }

    private func loadSignature(for account: String) async {
        signatureLoading = true
        defer { if signatureAccount == account { signatureLoading = false } }
        do {
            let stored = (try await state.mailSignature(for: account)) ?? ""
            guard signatureAccount == account else { return }
            signatureDraft = SignatureFormatting.attributed(from: stored)
            signatureSaved = nil
        } catch {
            guard signatureAccount == account, !Task.isCancelled else { return }
            state.inbox.error = ActionableError.classify(error)
        }
    }

    private func saveSignature() async {
        guard let account = signatureAccount else { return }
        signatureSaving = true
        defer { signatureSaving = false }
        do {
            let stored = SignatureFormatting.storageString(from: signatureDraft)
            try await state.setMailSignature(
                stored,
                isHTML: SignatureFormatting.isHTML(stored),
                for: account
            )
            guard signatureAccount == account else { return }
            signatureSaved = Date()
            showingSignatureEditor = false
            Task {
                try? await Task.sleep(for: .seconds(2))
                if signatureSaved != nil, Date().timeIntervalSince(signatureSaved!) >= 1.9 {
                    signatureSaved = nil
                }
            }
            await state.refreshAccounts()
        } catch {
            signatureError = ActionableError.classify(error).message
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

            // Registered-but-unapproved is its own state: the toggle reads ON
            // (the item *is* in the user's Login Items list) but macOS won't
            // launch it until the user approves it. Tell them, and give a
            // one-click path to the right System Settings pane.
            if launchAtLoginNeedsApproval {
                HStack(spacing: 6) {
                    Text("Needs approval in System Settings to launch at login.")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Login Items") { LaunchAtLogin.openSystemSettings() }
                        .font(.system(size: 10))
                        .buttonStyle(.link)
                }
            }

            if let launchAtLoginError {
                Text(launchAtLoginError)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
    }

    private func loadLaunchAtLoginState() {
        let state = LaunchAtLogin.state
        launchAtLoginEnabled = state != .disabled
        launchAtLoginNeedsApproval = state == .requiresApproval
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            let state = try LaunchAtLogin.set(enabled)
            // Reflect the *real* resulting state rather than the requested one:
            // register() can land in .requiresApproval, in which case the
            // toggle stays ON but we must show the approval hint.
            launchAtLoginEnabled = state != .disabled
            launchAtLoginNeedsApproval = state == .requiresApproval
            launchAtLoginError = nil
        } catch {
            let state = LaunchAtLogin.state
            launchAtLoginEnabled = state != .disabled
            launchAtLoginNeedsApproval = state == .requiresApproval
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
                Button("Send Pending") {
                    Task { await flushOutbox() }
                }
                .disabled(outboxLoading || !outboxEntries.contains(where: \.isPending))
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
        .id("outbox")
    }

    private func loadOutbox(clearStatus: Bool = true) async {
        outboxLoading = true
        defer { outboxLoading = false }
        do {
            outboxEntries = try await state.mailOutboxEntries()
                .filter { $0.isFailed || $0.isPending }
            if clearStatus { outboxStatus = nil }
        } catch {
            outboxStatus = "Could not load"
            state.inbox.error = ActionableError.classify(error)
        }
    }

    private func retryOutbox(_ entry: OutboxEntry) async {
        outboxLoading = true
        defer { outboxLoading = false }
        do {
            try await state.retryMailOutboxEntry(id: entry.id)
            await loadOutbox(clearStatus: false)
            outboxStatus = "Retry started"
        } catch {
            outboxStatus = "Retry failed"
            state.inbox.error = ActionableError.classify(error)
        }
    }

    private func flushOutbox() async {
        outboxLoading = true
        defer { outboxLoading = false }
        do {
            let result = try await state.sendPendingMail()
            await loadOutbox(clearStatus: false)
            outboxStatus = "Sent \(result.sent), failed \(result.failed)"
        } catch {
            outboxStatus = "Send failed"
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
