import SwiftUI

struct MoveToCloudSheet: View {
    @ObservedObject var cloud: CloudSessionCoordinator
    @ObservedObject var cloudStore: CloudStore
    @StateObject private var projectMove: ProjectMove
    @Environment(\.dismiss) private var dismiss
    @State private var serverFreeBytes: Int64?

    init(
        cloud: CloudSessionCoordinator,
        cloudStore: CloudStore,
        projectID: UUID,
        store: WorkspaceStore,
        sessions: TerminalSessionPool,
        notes: NoteSessionPool
    ) {
        self.cloud = cloud
        self.cloudStore = cloudStore
        let existing = cloud.activeMove.flatMap { $0.projectID == projectID ? $0 : nil }
        _projectMove = StateObject(
            wrappedValue: existing
                ?? ProjectMove(
                    projectID: projectID,
                    store: store,
                    sessions: sessions,
                    notes: notes,
                    cloud: cloud
                )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Move \(projectName) to the Cloud")
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
            footer
        }
        .padding(24)
        .frame(width: 720, height: 640)
    }

    private var projectName: String {
        projectMove.project?.name ?? "Project"
    }

    private var subtitle: String {
        switch projectMove.step {
        case .chooseServer:
            "Termuctive copies the project, its worktrees and .env files, related folders, "
                + "Claude history and your settings. The copy on this Mac stays as it is."
        case .scanning:
            "Looking at what belongs to the project. Nothing changes yet."
        case .review:
            "Choose what to copy. Dependency folders such as node_modules are rebuilt on the "
                + "server instead of copied."
        case .copying:
            "You can keep working while Termuctive copies. Closing this window keeps it going."
        case .readyToSwitch:
            "Everything is copied. Switching stops the terminals in \(projectName) on this Mac, "
                + "copies the last changes and opens \(projectName) (Cloud)."
        case .switching:
            "Switching to the cloud..."
        case .done:
            "\(projectName) (Cloud) is ready and runs on \(projectMove.host?.name ?? "the server")."
        case .failed:
            "The move stopped."
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch projectMove.step {
        case .chooseServer:
            chooseServer
            Spacer(minLength: 0)
        case .scanning(let message), .switching(let message):
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(message)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        case .review:
            review
        case .copying, .readyToSwitch:
            if let engine = projectMove.engine {
                TransferProgressView(engine: engine)
            }
            Spacer(minLength: 0)
        case .done:
            finished
            Spacer(minLength: 0)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var chooseServer: some View {
        if cloudStore.hosts.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Set up a server first.")
                Button("Set Up Server...") {
                    cloud.presentedFlow = .setUpServer
                }
            }
        } else if let message = projectMove.alreadyMovedMessage {
            Label(message, systemImage: "icloud")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Form {
                Picker("Server", selection: $projectMove.hostID) {
                    ForEach(cloudStore.hosts) { host in
                        Text(host.name).tag(Optional(host.id))
                    }
                }
                TextField("Project name on the server", text: $projectMove.slug)
                if let project = projectMove.project {
                    LabeledContent("Folder on the server", value: project.rootDirectory)
                }
            }
            .formStyle(.grouped)
        }
    }

    @ViewBuilder
    private var review: some View {
        if let manifest = projectMove.manifest {
            List {
                ForEach(TransferItem.Group.allCases, id: \.self) { group in
                    let items = sorted(manifest.items(in: group))
                    if !items.isEmpty {
                        Section {
                            ForEach(items) { item in
                                itemRow(item)
                            }
                        } header: {
                            groupHeader(group, items: items)
                        }
                    }
                }
            }
            .listStyle(.inset)
            totals(manifest)
        }
    }

    private func groupHeader(_ group: TransferItem.Group, items: [TransferItem]) -> some View {
        HStack {
            Text(group.title)
            Spacer()
            if group == .project {
                Button("Only Worktrees Used This Week") {
                    projectMove.selectWorktrees(usedWithin: 7 * 24 * 60 * 60)
                }
                .buttonStyle(.link)
                .font(.caption)
                Button("All Worktrees") {
                    projectMove.selectWorktrees(usedWithin: .infinity)
                }
                .buttonStyle(.link)
                .font(.caption)
            } else {
                Button(items.allSatisfy(\.selected) ? "Deselect All" : "Select All") {
                    projectMove.setSelected(!items.allSatisfy(\.selected), forGroup: group)
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }

    private func itemRow(_ item: TransferItem) -> some View {
        Toggle(
            isOn: Binding(
                get: { item.selected },
                set: { projectMove.setSelected($0, forItemID: item.id) }
            )
        ) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let detail = item.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                Text(Self.size(item.bytes))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(item.kind == .project)
    }

    private func totals(_ manifest: TransferManifest) -> some View {
        let selected = manifest.selectedBytes
        let tooLarge = serverFreeBytes.map { Double(selected) > Double($0) * 0.85 } ?? false
        return HStack {
            Text("Selected: \(Self.size(selected))")
            if let serverFreeBytes {
                Text("· Free on server: \(Self.size(serverFreeBytes))")
                    .foregroundStyle(tooLarge ? .red : .secondary)
            }
            Spacer()
        }
        .font(.callout)
        .task {
            guard serverFreeBytes == nil, let host = projectMove.host else {
                return
            }
            serverFreeBytes = try? await cloud.client.status(alias: host.alias).disk.freeBytes
        }
    }

    private var finished: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                "The Cloud Setup tab installs dependencies and lists what still needs "
                    + "signing in, such as Claude Code and GitHub.",
                systemImage: "checklist"
            )
            Label(
                "Your Claude history moved too. Run claude --continue in a terminal to pick up "
                    + "your last conversation.",
                systemImage: "bubble.left.and.text.bubble.right"
            )
            Label(
                "The copy on this Mac is unchanged. Its terminals were stopped and can be "
                    + "restarted any time.",
                systemImage: "laptopcomputer"
            )
            if let engine = projectMove.engine, !engine.notes.isEmpty {
                Divider()
                ForEach(engine.notes, id: \.self) { note in
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Spacer()
            switch projectMove.step {
            case .chooseServer:
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Scan Project") {
                    Task {
                        await projectMove.scan()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    projectMove.host == nil || !CloudSlug.isValid(projectMove.slug)
                        || projectMove.alreadyMovedMessage != nil
                )
            case .review:
                Button("Back") {
                    projectMove.step = .chooseServer
                }
                Button("Start Copying") {
                    Task {
                        await projectMove.startCopy()
                    }
                }
                .keyboardShortcut(.defaultAction)
            case .copying:
                Button("Stop Copying", role: .destructive) {
                    projectMove.cancel()
                }
                Button("Hide") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            case .readyToSwitch:
                Button("Later") {
                    dismiss()
                }
                Button("Switch to Cloud") {
                    Task {
                        await projectMove.switchToCloud()
                    }
                }
                .keyboardShortcut(.defaultAction)
            case .scanning, .switching:
                EmptyView()
            case .done:
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            case .failed:
                Button("Close", role: .cancel) {
                    dismiss()
                }
                Button("Try Again") {
                    projectMove.step = projectMove.manifest == nil ? .chooseServer : .review
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Helpers

    private func sorted(_ items: [TransferItem]) -> [TransferItem] {
        items.sorted { lhs, rhs in
            if lhs.kind != rhs.kind {
                return lhs.order < rhs.order
            }
            switch (lhs.lastActivity, rhs.lastActivity) {
            case (let left?, let right?):
                return left > right
            default:
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        }
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct TransferProgressView: View {
    @ObservedObject var engine: TransferEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: engine.fractionComplete) {
                Text(engine.currentTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } currentValueLabel: {
                Text(
                    "\(MoveToCloudSheet.size(engine.completedBytes)) of "
                        + "\(MoveToCloudSheet.size(engine.totalBytes))"
                )
            }
            if let file = engine.currentFile {
                Text(file)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            ForEach(engine.notes, id: \.self) { note in
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
