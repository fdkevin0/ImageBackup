import SwiftUI
import UIKit

@main
struct ImageBackupApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @State private var engine = BackupEngine()

    @AppStorage("serverURL") private var serverURL = "http://192.168.1.10:5005/PhotoBackup"
    @AppStorage("username") private var username = ""
    @AppStorage("deviceName") private var deviceName = UIDevice.current.name
    // Deliberately @State, not @AppStorage: a persisted "To" would be the date of first launch
    // on every later run, silently skipping everything newer. The range is a per-run choice.
    @State private var rangeStart = Date.now.addingTimeInterval(-30 * 86_400)
    @State private var rangeEnd = Date.now

    @State private var password = Keychain.load("webdavPassword")

    private var config: BackupConfig {
        BackupConfig(serverURL: serverURL,
                     username: username,
                     password: password,
                     deviceName: deviceName)
    }

    private var isRunning: Bool { engine.phase == .running }

    private var recentActivity: [String] {
        Array(engine.activity.reversed())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("WebDAV server") {
                    TextField("Base URL", text: $serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .onChange(of: password) { Keychain.save(password, for: "webdavPassword") }
                    TextField("Device folder", text: $deviceName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Sync range") {
                    DatePicker("From", selection: $rangeStart, displayedComponents: .date)
                    DatePicker("To", selection: $rangeEnd, displayedComponents: .date)
                    HStack {
                        Button("Last month") { setRange(days: 30) }
                        Spacer()
                        Button("Last year") { setRange(days: 365) }
                        Spacer()
                        Button("Everything") { setRange(days: nil) }
                    }
                    .buttonStyle(.borderless)
                    .disabled(isRunning)
                }

                Section {
                    if isRunning {
                        Button("Cancel", role: .destructive) { engine.cancel() }
                    } else {
                        Button("Start backup") {
                            engine.start(config: config,
                                         from: rangeStart,
                                         to: rangeEnd.addingTimeInterval(86_400))
                        }
                    }
                }

                if engine.phase != .idle {
                    Section("Progress") {
                        status
                    }
                }

                if !engine.activity.isEmpty {
                    Section("Activity") {
                        // ponytail: newest first, no paging. Fine for a test run; the engine
                        // already caps the buffer at 200 lines.
                        ForEach(recentActivity.indices, id: \.self) { index in
                            Text(recentActivity[index])
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("ImageBackup")
        }
    }

    @ViewBuilder
    private var status: some View {
        if engine.assetsTotal > 0 {
            ProgressView(value: Double(engine.assetsDone),
                         total: Double(engine.assetsTotal))
            LabeledContent("Assets", value: "\(engine.assetsDone) / \(engine.assetsTotal)")
        }

        if !engine.currentFile.isEmpty {
            LabeledContent("Current", value: engine.currentFile)
                .lineLimit(1)
                .truncationMode(.middle)
        }

        if engine.uploadedBytes > 0 {
            LabeledContent("Uploaded", value: engine.uploadedBytes.formatted(.byteCount(style: .file)))
        }

        switch engine.phase {
        case .running: ProgressView()
        case .done: Text("Finished.").foregroundStyle(.green)
        case .cancelled: Text("Cancelled.").foregroundStyle(.orange)
        case .failed(let message): Text(message).foregroundStyle(.red)
        case .idle: EmptyView()
        }
    }

    private func setRange(days: Int?) {
        rangeEnd = .now
        rangeStart = days.map { Date.now.addingTimeInterval(-Double($0) * 86_400) } ?? .distantPast
    }
}
