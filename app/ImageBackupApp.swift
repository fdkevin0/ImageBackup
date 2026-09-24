import SwiftUI

@main
struct ImageBackupApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

/// Two states, decided once at launch: configured, or not yet.
///
/// There is no "has onboarded" flag anywhere — an empty server address *is* the condition, so the
/// two cannot disagree. The decision is taken once and held in memory, because deriving it live
/// would dismiss the welcome screen halfway through typing the address.
struct RootView: View {
    // Reads only the key it needs: going through `BackupConfig.configured()` would pull the Keychain
    // and three more defaults on every construction of this view.
    @State private var needsSetup = (UserDefaults.standard.string(forKey: "serverURL") ?? "").isEmpty

    var body: some View {
        if needsSetup {
            OnboardingView { needsSetup = false }
        } else {
            HomeView()
        }
    }
}

/// First run: what this app does, the four fields, and the one prompt that will appear.
///
/// The explanation is not decoration — research §8.1: a connection attempted while the local-network
/// privilege is still undetermined is denied silently, so the first one has to happen here, in the
/// foreground, with the user expecting it.
struct OnboardingView: View {
    var onFinish: () -> Void

    @AppStorage("serverURL") private var serverURL = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("""
                        ImageBackup copies your photo library to your own NAS over WebDAV. The photos \
                        go to the address you enter here and nowhere else.
                        """)
                }

                WebDAVConfigForm(password: $password)

                Section {
                    Button("Continue") {
                        Keychain.save(password, for: "webdavPassword")
                        onFinish()
                    }
                    .disabled(serverURL.isEmpty)
                } footer: {
                    Text("The first upload asks for local-network access; denying it leaves the NAS unreachable.")
                }
            }
            .navigationTitle("Welcome")
        }
    }
}
