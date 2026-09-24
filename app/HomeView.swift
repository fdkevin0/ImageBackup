import SwiftUI

/// The front door: what happened last time, and one button to do it again.
///
/// "Back up everything" sits beside it because a photo taken long ago and imported yesterday falls
/// outside the watermark's reach — the one case the default window cannot cover.
struct HomeView: View {
    @State private var engine = BackupEngine()
    @State private var showingSettings = false

    private var isRunning: Bool { engine.phase == .running }

    /// Everything the user may need to act on, in one number instead of a row per counter.
    private var problems: Int {
        engine.skippedCollisions + engine.unverifiedFiles + engine.failures.count
    }

    private var lastProblems: Int {
        (engine.state.lastRun?.skipped ?? 0) + (engine.state.lastRun?.failed ?? 0)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if isRunning {
                        Button("Cancel", role: .destructive) { engine.cancel() }
                    } else {
                        Button("Back up now") {
                            engine.start(config: .configured(), window: .sinceLastRun)
                        }
                        Button("Back up everything") {
                            engine.start(config: .configured(), window: .everything)
                        }
                    }
                } footer: {
                    if !isRunning, let covered = engine.state.lastRunEnd {
                        Text("Back up now covers everything since \(covered.formatted(date: .abbreviated, time: .shortened)).")
                    }
                }

                if engine.phase != .idle {
                    Section("Backup") { runningSummary }
                } else if let last = engine.state.lastRun {
                    Section("Last backup") {
                        LabeledContent("Uploaded", value: "\(last.uploaded) files")
                        if lastProblems > 0 {
                            Text("\(lastProblems) files need attention. Back up again to retry them.")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .navigationTitle("ImageBackup")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .task { engine.loadState() }
        }
    }

    @ViewBuilder
    private var runningSummary: some View {
        if engine.assetsTotal > 0 {
            LabeledContent("Photos", value: "\(engine.assetsDone) / \(engine.assetsTotal)")
        }

        if !engine.currentFile.isEmpty {
            LabeledContent("Current", value: engine.currentFile)
                .lineLimit(1)
                .truncationMode(.middle)
        }

        if engine.uploadedFiles > 0 {
            LabeledContent("Uploaded", value: "\(engine.uploadedFiles) files")
        }

        // `.limited` means the walk sees only the photos the user picked, which makes a run that
        // looks complete an incomplete backup. It gets to interrupt.
        if engine.hasLimitedAccess {
            Text("Limited photo access — this run covers only your selection.")
                .foregroundStyle(.orange)
        }

        if problems > 0 { problemList }

        switch engine.phase {
        case .running: ProgressView()
        case .done: Text("Finished.").foregroundStyle(engine.failures.isEmpty ? Color.green : Color.orange)
        case .cancelled: Text("Cancelled.").foregroundStyle(.orange)
        case .failed(let message): Text(message).foregroundStyle(.red)
        case .idle: EmptyView()
        }
    }

    /// One list for everything that needs attention. Three separate counters used to be three rows
    /// nobody opened; what matters is being able to see all of it at once.
    private var problemList: some View {
        DisclosureGroup("Problems (\(problems))") {
            if engine.skippedCollisions > 0 {
                Text("\(engine.skippedCollisions) name collisions — nothing was overwritten.")
            }
            if engine.unverifiedFiles > 0 {
                Text("\(engine.unverifiedFiles) unverified — the server reported no size.")
            }
            // ponytail: the first ten, no paging. A list long enough to need paging means the
            // server is down, and that is what the message above is for.
            ForEach(Array(engine.failures.prefix(10)), id: \.self) { path in
                Text(path)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if engine.failures.count > 10 {
                Text("…and \(engine.failures.count - 10) more")
            }
        }
    }
}
