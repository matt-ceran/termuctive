import SwiftUI

/// Runs an existing project's terminals on a cloud server, in a folder that already
/// holds (or will hold) the project there.
struct ConnectToCloudFolderSheet: View {
    @ObservedObject var cloud: CloudSessionCoordinator
    @ObservedObject var cloudStore: CloudStore
    @ObservedObject var store: WorkspaceStore
    let projectID: UUID
    @Environment(\.dismiss) private var dismiss

    @State private var hostID: UUID?
    @State private var remoteRoot = ""
    @State private var slug = ""
    @State private var isConnecting = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect \(projectName) to a Cloud Folder")
                    .font(.title2.weight(.semibold))
                Text(
                    "Terminals in this project will run on the server and keep running when "
                        + "you quit Termuctive or close your Mac. Open terminals restart."
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if cloudStore.hosts.isEmpty {
                noServer
            } else {
                form
            }

            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Connect") {
                    connect()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canConnect)
            }
        }
        .padding(24)
        .frame(width: 560, height: 400)
        .onAppear(perform: populateDefaults)
    }

    private var noServer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Set up a server first.")
            Button("Set Up Server...") {
                cloud.presentedFlow = .setUpServer
            }
        }
    }

    private var form: some View {
        Form {
            Picker("Server", selection: $hostID) {
                ForEach(cloudStore.hosts) { host in
                    Text(host.name).tag(Optional(host.id))
                }
            }
            TextField("Folder on the server", text: $remoteRoot)
            TextField("Project name on the server", text: $slug)
            Text(
                "Keeping the same folder path as on this Mac lets agent rules, memories and "
                    + "worktree links work unchanged."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .disabled(isConnecting)
    }

    private var project: TerminalProject? {
        store.document.projects.first { $0.id == projectID }
    }

    private var projectName: String {
        project?.name ?? "Project"
    }

    private var canConnect: Bool {
        !isConnecting
            && hostID != nil
            && remoteRoot.hasPrefix("/")
            && CloudSlug.isValid(slug)
    }

    private func populateDefaults() {
        hostID = hostID ?? cloudStore.hosts.first?.id
        if remoteRoot.isEmpty {
            remoteRoot = project?.rootDirectory ?? ""
        }
        if slug.isEmpty {
            slug = CloudSlug.make(from: projectName)
        }
    }

    private func connect() {
        guard let hostID, let host = cloudStore.host(withID: hostID) else {
            return
        }
        isConnecting = true
        failure = nil
        Task {
            do {
                try await cloud.connect(
                    projectID: projectID,
                    host: host,
                    slug: slug,
                    remoteRoot: remoteRoot
                )
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
            isConnecting = false
        }
    }
}
