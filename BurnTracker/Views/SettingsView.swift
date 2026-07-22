import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 15) {
            claudeCard
            geminiCard
            antigravityCard
            generalCard
        }
    }

    // MARK: - General (app-wide) card

    private var generalCard: some View {
        Card {
            SettingsSectionTitle("Auto-Refresh")
            LabeledField("Background sync interval",
                         help: "Applies to all providers — Claude, Gemini CLI, and Antigravity. Quotas also refresh instantly whenever you open the widget.") {
                Picker("", selection: Binding(
                    get: { app.refreshMinutes },
                    set: { app.setRefreshMinutes($0) })) {
                    Text("Every 5 minutes").tag(5)
                    Text("Every 10 minutes").tag(10)
                    Text("Every 15 minutes").tag(15)
                    Text("Every 30 minutes").tag(30)
                    Text("Every hour").tag(60)
                }
                .labelsHidden()
            }

            Divider24()

            SettingsSectionTitle("Notifications")
            LabeledField("Alert when 5-hour usage reaches",
                         help: "Sends a macOS notification the first time any provider's 5-hour quota crosses this usage level. For Gemini CLI and Antigravity, usage is measured against their remaining quota.") {
                Picker("", selection: Binding(
                    get: { app.alertThreshold },
                    set: { app.setAlertThreshold($0) })) {
                    Text("Off").tag(0)
                    ForEach([50, 60, 70, 75, 80, 85, 90, 95], id: \.self) { v in
                        Text("\(v)%").tag(v)
                    }
                }
                .labelsHidden()
            }
        }
    }

    // MARK: - Claude accounts card

    private var claudeCard: some View {
        Card {
            SettingsSectionTitle("Claude Accounts")

            if app.accounts.isEmpty {
                Text("No accounts added yet.")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textDimmed)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
            } else {
                VStack(spacing: 8) {
                    ForEach(app.accounts) { account in
                        AccountSettingsRow(account: account)
                    }
                }
            }

            Divider24()

            SettingsSectionTitle("Add Claude Account")
            AddAccountForm()

            Divider24()

            SettingsSectionTitle("How to locate your sessionKey")
            instructions
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 6) {
            instructionLine(1, "Log in to claude.ai in your browser.")
            instructionLine(2, "Right-click the page and select Inspect to open Developer Tools.")
            instructionLine(3, "Open the Application tab (Chrome/Edge/Safari) or Storage tab (Firefox).")
            instructionLine(4, "Expand Cookies and select https://claude.ai.")
            instructionLine(5, "Find the cookie named sessionKey and copy its entire value.")
            instructionLine(6, "Paste the key into the input above, name it, and click Add.")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.glassInset)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func instructionLine(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(n).").font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.accentHover)
            Text(text).font(.system(size: 11)).foregroundColor(Theme.textMuted)
        }
    }

    // MARK: - Gemini CLI card

    private var geminiCard: some View {
        Card {
            SettingsSectionTitle("Gemini CLI Account")
            Text("Link your local Gemini CLI to track real usage quotas via the Cloud Code API.")
                .font(.system(size: 12))
                .foregroundColor(Theme.textMuted)
                .padding(.bottom, 12)

            Text(app.geminiAccount != nil ? "Linked (\(app.geminiAccount?.email ?? ""))" : "Not linked.")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.textMain)
                .padding(.bottom, 12)

            CliLinkControls(
                isLinked: app.geminiAccount != nil,
                linkTitle: "Sync with Gemini CLI",
                link: { await app.linkGemini() },
                unlink: { app.unlinkGemini() })
        }
    }

    // MARK: - Antigravity card

    private var antigravityCard: some View {
        Card {
            SettingsSectionTitle("Antigravity Account")
            Text("Link your local Antigravity app to track real usage quotas from its language server.")
                .font(.system(size: 12))
                .foregroundColor(Theme.textMuted)
                .padding(.bottom, 12)

            Text(app.agAccount != nil ? "Linked (\(app.agAccount?.email ?? ""))" : "Not linked.")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.textMain)
                .padding(.bottom, 12)

            CliLinkControls(
                isLinked: app.agAccount != nil,
                linkTitle: "Sync with Antigravity",
                link: { await app.linkAntigravity() },
                unlink: { app.unlinkAntigravity() })
        }
    }
}

// MARK: - Add account form

private struct AddAccountForm: View {
    @EnvironmentObject var app: AppState
    @State private var label = ""
    @State private var key = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FieldLabel("Account Label")
            TextField("e.g. Personal, Work, Client A", text: $label)
                .textFieldStyle(BurnTextFieldStyle())

            FieldLabel("Session Key (sessionKey)")
            RevealableSecureField(placeholder: "Paste sk-ant-sid02-...", text: $key)
            Text("Your sessionKey cookie value from claude.ai")
                .font(.system(size: 10))
                .foregroundColor(Theme.textDimmed)

            Button("Add Account") {
                let l = label.trimmingCharacters(in: .whitespaces)
                let k = key.trimmingCharacters(in: .whitespaces)
                guard !l.isEmpty, !k.isEmpty else { return }
                app.addAccount(label: l, sessionKey: k)
                label = ""; key = ""
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }
}

// MARK: - Account row (view / edit)

private struct AccountSettingsRow: View {
    @EnvironmentObject var app: AppState
    let account: Account

    @State private var editing = false
    @State private var editLabel = ""
    @State private var editKey = ""
    @State private var showRemoveConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if editing {
                FieldLabel("Account Label")
                TextField("e.g. Personal, Work, Client A", text: $editLabel)
                    .textFieldStyle(BurnTextFieldStyle())
                FieldLabel("Session Key (sessionKey)")
                RevealableSecureField(placeholder: "Paste sk-ant-sid02-...", text: $editKey)
                Text("Leave unchanged to keep the existing key.")
                    .font(.system(size: 10)).foregroundColor(Theme.textDimmed)
                HStack(spacing: 8) {
                    Button("Save") {
                        let l = editLabel.trimmingCharacters(in: .whitespaces)
                        let k = editKey.trimmingCharacters(in: .whitespaces)
                        guard !l.isEmpty, !k.isEmpty else { return }
                        app.updateAccount(id: account.id, label: l, sessionKey: k)
                        editing = false
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    Button("Cancel") { editing = false }
                        .buttonStyle(SecondaryButtonStyle())
                }
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.label)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.textMain)
                        Text(account.maskedKey)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Theme.textDimmed)
                    }
                    Spacer()
                    Button {
                        editLabel = account.label
                        editKey = account.sessionKey
                        editing = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(IconActionButtonStyle())
                    .help("Edit account")

                    Button { showRemoveConfirm = true } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(IconActionButtonStyle(danger: true))
                    .help("Remove account")
                }
            }
        }
        .padding(10)
        .background(Theme.glassInset)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(editing ? Theme.accent.opacity(0.4) : Theme.glassBorder, lineWidth: 1))
        .confirmationDialog("Remove account \"\(account.label)\"?",
                            isPresented: $showRemoveConfirm, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { app.removeAccount(id: account.id) }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: - CLI link controls (shared by Gemini CLI + Antigravity)

private struct CliLinkControls: View {
    let isLinked: Bool
    let linkTitle: String
    let link: () async -> String?
    let unlink: () -> Void

    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 10) {
            if !isLinked {
                Button(busy ? "Syncing..." : linkTitle) {
                    busy = true; errorText = nil
                    Task {
                        let err = await link()
                        errorText = err
                        busy = false
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(busy)
            } else {
                Button("Remove Account") { unlink() }
                    .buttonStyle(SecondaryButtonStyle())
            }
            if let errorText {
                Text(errorText).font(.system(size: 11)).foregroundColor(Theme.error)
            }
        }
    }
}

// MARK: - Small shared building blocks

private struct SettingsSectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(Theme.textMain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 10)
    }
}

private struct FieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundColor(Theme.textMuted)
    }
}

private struct LabeledField<Content: View>: View {
    let title: String
    let help: String
    @ViewBuilder let content: Content
    init(_ title: String, help: String, @ViewBuilder content: () -> Content) {
        self.title = title; self.help = help; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(title)
            content
            Text(help).font(.system(size: 10)).foregroundColor(Theme.textDimmed)
        }
    }
}

private struct Divider24: View {
    var body: some View {
        Rectangle().fill(Theme.border).frame(height: 1).padding(.vertical, 12)
    }
}

/// A masked key field with an eye toggle to reveal/hide the value. Styled to
/// match `BurnTextFieldStyle`.
struct RevealableSecureField: View {
    let placeholder: String
    @Binding var text: String
    @State private var revealed = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if revealed {
                    TextField(placeholder, text: $text)
                } else {
                    SecureField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundColor(Theme.textMain)
            .focused($focused)

            Button {
                revealed.toggle()
                focused = true
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textMuted)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(revealed ? "Hide key" : "Show key")
        }
        .padding(8)
        .background(Theme.glassInset)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.glassBorder, lineWidth: 1))
    }
}

struct BurnTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundColor(Theme.textMain)
            .padding(8)
            .background(Theme.glassInset)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.glassBorder, lineWidth: 1))
    }
}
