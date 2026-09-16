import Foundation

/// Settings-facing operations keep the CLI actor behind AppState, matching
/// the rest of the app's state boundary while leaving presentation concerns
/// in SettingsView.
extension AppState {
    func commandLineToolStatus() async -> EmailCLI.CommandLineToolStatus {
        await cli.commandLineToolStatus()
    }

    func installCommandLineTool() async throws -> EmailCLI.CommandLineToolStatus {
        try await cli.installCommandLineTool()
    }

    func saveMailProfile(name: String, apiKey: String) async throws {
        let visibleAccount = session.currentAccount?.email
        let wasUnified = session.currentAccount == nil
        try await cli.addProfile(name: name, apiKey: apiKey)
        await refreshAccountsPreservingMailbox(
            visibleAccount: visibleAccount,
            wasUnified: wasUnified
        )
    }

    func testMailProfile(name: String) async throws {
        try await cli.testProfile(name: name)
    }

    func mailProfiles() async throws -> [MailProfile] {
        try await cli.listProfiles()
    }

    func editMailAccount(email: String, name: String, profile: String) async throws {
        let visibleAccount = session.currentAccount?.email
        let wasUnified = session.currentAccount == nil
        try await cli.editAccount(email: email, name: name, profile: profile)
        await refreshAccountsPreservingMailbox(visibleAccount: visibleAccount, wasUnified: wasUnified)
    }

    func removeMailAccount(_ email: String) async throws {
        guard pendingSend?.from != email, deliveringSend?.from != email else {
            throw EmailCLI.CLIError.badInput("Wait for the current delivery before removing this account.")
        }
        try await cli.removeAccount(email: email)
        UserDefaults.standard.removeObject(forKey: SettingsKey.muteKey(for: email))
        let wasCurrent = session.currentAccount?.email == email
        if compose.fromOverride?.email == email || composeFromAccount?.email == email { compose.clear() }
        await refreshAccounts()
        if wasCurrent { session.currentAccount = nil }
        persistPreferredAccount()
        reader.inflight?.cancel()
        inbox.selection.removeAll()
        reader.loaded = nil
        reader.thread = []
        await refreshInbox(pull: false)
        await refreshDrafts()
    }

    func removeMailProfile(_ name: String) async throws {
        try await cli.removeProfile(name: name)
    }

    func addMailAccount(
        email: String,
        profile: String,
        makeDefault: Bool
    ) async throws {
        let visibleAccount = session.currentAccount?.email
        let wasUnified = session.currentAccount == nil
        try await cli.addAccount(email: email, profile: profile, makeDefault: makeDefault)
        await refreshAccountsPreservingMailbox(
            visibleAccount: visibleAccount,
            wasUnified: wasUnified
        )
    }

    func setDefaultMailAccount(_ email: String) async throws {
        let visibleAccount = session.currentAccount?.email
        let wasUnified = session.currentAccount == nil
        try await cli.setDefaultAccount(email)
        await refreshAccountsPreservingMailbox(
            visibleAccount: visibleAccount,
            wasUnified: wasUnified
        )
    }

    func mailSignature(for account: String) async throws -> String? {
        try await cli.signature(for: account)
    }

    func setMailSignature(_ value: String, isHTML: Bool, for account: String) async throws {
        try await cli.setSignature(value, isHTML: isHTML, for: account)
    }

    func mailOutboxEntries() async throws -> [OutboxEntry] {
        try await cli.outboxList()
    }

    func retryMailOutboxEntry(id: String) async throws {
        try await cli.outboxRetry(id: id)
    }

    func sendPendingMail() async throws -> (sent: Int, failed: Int) {
        try await cli.outboxFlush()
    }

    private func refreshAccountsPreservingMailbox(
        visibleAccount: String?,
        wasUnified: Bool
    ) async {
        let currentBeforeRefresh = session.currentAccount?.email
        await refreshAccounts()
        // A mailbox switch during the network operation takes precedence.
        guard currentBeforeRefresh == visibleAccount else { return }
        if wasUnified {
            session.currentAccount = nil
        } else if let visibleAccount {
            session.currentAccount = session.accounts.first { $0.email == visibleAccount }
        }
    }
}
