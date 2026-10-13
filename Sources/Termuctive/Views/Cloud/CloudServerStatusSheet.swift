import SwiftUI

/// Health of a cloud server, toolkit updates, and sessions no pane uses anymore.
struct CloudServerStatusSheet: View {
    @ObservedObject var cloud: CloudSessionCoordinator
    @ObservedObject var cloudStore: CloudStore
    @ObservedObject var store: WorkspaceStore
    let hostID: UUID
    @Environment(\.dismiss) private var dismiss

    @State private var status: CloudServerStatus?
    @State private var orphans: [(slug: String, session: RemoteSession)] = []
    @State private var isLoading = false
    @State private var isUpdating = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(host?.name ?? "Server")
                .font(.title2.weight(.semibold))
            if let status {
                details(status)
            } else if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack {
                Button("Refresh") {
                    Task {
                        await load()
                    }
                }
                .disabled(isLoading || isUpdating)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 600, height: 560)
        .task {
            await load()
        }
    }

    private var host: CloudHost? {
        cloudStore.host(withID: hostID)
    }

    private var bundledVersion: String? {
        CloudToolkit.bundled?.version
    }

    private func details(_ status: CloudServerStatus) -> some View {
        Form {
            Section("Server") {
                LabeledContent("Address", value: host?.address ?? "")
                LabeledContent("System", value: "\(status.os) · \(status.arch)")
                LabeledContent(
                    "Memory",
                    value: "\(Self.size(status.memory.availableBytes)) free of "
                        + Self.size(status.memory.totalBytes)
                )
                LabeledContent(
                    "Disk",
                    value: "\(Self.size(status.disk.freeBytes)) free of "
                        + Self.size(status.disk.totalBytes)
                )
                ForEach(status.gpus, id: \.name) { gpu in
                    LabeledContent(
                        "GPU",
                        value: "\(gpu.name) · \(gpu.utilizationPercent)% busy · "
                            + "\(gpu.memoryUsedMB) of \(gpu.memoryTotalMB) MB"
                    )
                }
                if status.rebootRequired {
                    Label(
                        "Restart the server to finish installing updates.",
                        systemImage: "arrow.clockwise")
                }
            }
            Section("Termuctive toolkit") {
                LabeledContent("Installed", value: status.toolkit.version)
                if let bundledVersion, bundledVersion != status.toolkit.version {
                    HStack {
                        Text("Version \(bundledVersion) is available.")
                        Spacer()
                        Button(isUpdating ? "Updating..." : "Update Server") {
                            Task {
                                await updateToolkit()
                            }
                        }
                        .disabled(isUpdating)
                    }
                }
            }
            if !orphans.isEmpty {
                Section("Sessions without a pane") {
                    ForEach(orphans, id: \.session.pane) { orphan in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(orphan.session.command)
                                Text(orphan.session.cwd)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Button("End") {
                                Task {
                                    await end(orphan.session.pane, slug: orphan.slug)
                                }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func load() async {
        guard let host else {
            return
        }
        isLoading = true
        failure = nil
        defer {
            isLoading = false
        }
        do {
            await cloud.control.ensureMaster(alias: host.alias)
            let status = try await cloud.client.status(alias: host.alias)
            self.status = status
            let knownPanes = store.document.terminalIDs
            var orphans: [(String, RemoteSession)] = []
            for project in status.projects {
                let sessions = try await cloud.client.listSessions(
                    alias: host.alias,
                    slug: project.slug
                )
                orphans += sessions.filter { !knownPanes.contains($0.pane) }.map {
                    (project.slug, $0)
                }
            }
            self.orphans = orphans
        } catch {
            failure = error.localizedDescription
        }
    }

    private func updateToolkit() async {
        guard var host, let toolkit = CloudToolkit.bundled else {
            return
        }
        isUpdating = true
        defer {
            isUpdating = false
        }
        do {
            let installer = CloudToolkitInstaller(runner: cloud.runner, toolkit: toolkit)
            try await installer.upload(toAlias: host.adminAlias)
            try await installer.installUploadedToolkit(adminAlias: host.adminAlias)
            _ = try await cloud.runner.output(
                CloudCommand(
                    alias: host.alias,
                    remote: .arguments([TMCClient.executable, "claude", "install-hooks"])
                )
            )
            host.toolkitVersion = toolkit.version
            cloudStore.addOrUpdate(host)
            cloud.reconnectAll()
            await load()
        } catch {
            failure = "The update did not finish. \(error.localizedDescription)"
        }
    }

    private func end(_ paneID: UUID, slug: String) async {
        guard let host else {
            return
        }
        try? await cloud.client.killSession(alias: host.alias, slug: slug, paneID: paneID)
        await load()
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }
}
