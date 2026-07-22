import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 15) {
            claudeCard
            antigravityCard
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

            SettingsSectionTitle("Auto-Refresh")
            LabeledField("Background sync interval",
                         help: "Quotas also refresh instantly whenever you open the widget.") {
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
            LabeledField("Alert when session usage reaches",
                         help: "Sends a macOS notification the first time your 5-hour session crosses this level.") {
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
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func instructionLine(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(n).").font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.accentHover)
            Text(text).font(.system(size: 11)).foregroundColor(Theme.textMuted)
        }
    }

    // MARK: - Antigravity card

    private var antigravityCard: some View {
        Card {
            SettingsSectionTitle("Antigravity / Gemini CLI Account")
            Text("Link your local Antigravity or Gemini CLI to track real usage quotas.")
                .font(.system(size: 12))
                .foregroundColor(Theme.textMuted)
                .padding(.bottom, 12)

            Text(app.agAccount != nil ? "CLI Linked (\(app.agAccount?.email ?? ""))" : "Not linked.")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.textMain)
                .padding(.bottom, 12)

            AntigravityLinkControls()
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
            SecureField("Paste sk-ant-sid02-...", text: $key)
                .textFieldStyle(BurnTextFieldStyle())
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
                SecureField("Paste sk-ant-sid02-...", text: $editKey)
                    .textFieldStyle(BurnTextFieldStyle())
                Text("Leave unchanged to keep the existing key.")
                    .font(.system(size: 10)).foregroundColor(Theme.textDimmed)
                HStack {
                    Button("Save") {
                        let l = editLabel.trimmingCharacters(in: .whitespaces)
                        let k = editKey.trimmingCharacters(in: .whitespaces)
                        guard !l.isEmpty, !k.isEmpty else { return }
                        app.updateAccount(id: account.id, label: l, sessionKey: k)
                        editing = false
                    }
                    .buttonStyle(PrimaryButtonStyle()).fixedSize()
                    Button("Cancel") { editing = false }
                        .buttonStyle(SecondaryButtonStyle()).fixedSize()
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
                    Button("Edit") {
                        editLabel = account.label
                        editKey = account.sessionKey
                        editing = true
                    }
                    .buttonStyle(SecondaryButtonStyle()).fixedSize()
                    Button("Remove") { showRemoveConfirm = true }
                        .buttonStyle(DangerButtonStyle())
                }
            }
        }
        .padding(10)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(editing ? Theme.accent.opacity(0.4) : Theme.border, lineWidth: 1))
        .confirmationDialog("Remove account \"\(account.label)\"?",
                            isPresented: $showRemoveConfirm, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { app.removeAccount(id: account.id) }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: - Antigravity link controls

private struct AntigravityLinkControls: View {
    @EnvironmentObject var app: AppState
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 10) {
            if app.agAccount == nil {
                Button(busy ? "Syncing..." : "Sync with Antigravity / Gemini CLI") {
                    busy = true; errorText = nil
                    Task {
                        let err = await app.linkAntigravity()
                        errorText = err
                        busy = false
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(busy)
            } else {
                Button("Remove Account") { app.unlinkAntigravity() }
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

struct BurnTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundColor(Theme.textMain)
            .padding(8)
            .background(Theme.bg)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
    }
}
