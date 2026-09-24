import SwiftUI

/// Everything the app needs to know that is not a decision made at run time.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var password = Keychain.load("webdavPassword")

    var body: some View {
        NavigationStack {
            Form {
                WebDAVConfigForm(password: $password)

                Section("What gets backed up") {
                    Text("""
                        Originals, Live Photo motion and edit data are uploaded. Edited renders are \
                        not: the NAS keeps the unedited original, whose edit data reproduces it.
                        """)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    // The one place the secret is written. It used to be saved on every keystroke,
                    // and again when a run started.
                    Button("Done") {
                        Keychain.save(password, for: "webdavPassword")
                        dismiss()
                    }
                }
            }
        }
    }
}

/// The four fields shared by onboarding and Settings.
struct WebDAVConfigForm: View {
    @Binding var password: String

    @AppStorage("serverURL") private var serverURL = ""
    @AppStorage("username") private var username = ""
    @AppStorage("deviceName") private var deviceName = ""

    var body: some View {
        Section {
            TextField("Base URL", text: $serverURL)
                .keyboardType(.URL)
            TextField("Username", text: $username)
            SecureField("Password", text: $password)
            TextField("Device folder", text: $deviceName)
        } header: {
            Text("WebDAV server")
        } footer: {
            Text("Leave empty to keep one flat tree.")
        }
        // Both of these are environment values, so they reach every field in the section: three
        // addresses and a folder name are not prose, and autocapitalisation only corrupts them.
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    }
}
