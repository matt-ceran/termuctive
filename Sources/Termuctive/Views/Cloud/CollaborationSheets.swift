import AppKit
import SwiftUI

struct InviteCollaboratorSheet: View {
    @ObservedObject var cloud: CloudSessionCoordinator
    @ObservedObject var store: WorkspaceStore
    let projectID: UUID
    @Environment(\.dismiss) private var dismiss

    @State private var partner = ""
    @State private var partnerHome = ""
    @State private var isWorking = false
    @State private var code: String?
    @State private var expires: Date?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Invite a Collaborator")
                .font(.title2.weight(.semibold))
            if let code {
                inviteReady(code)
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
                if code == nil {
                    Button("Cancel", role: .cancel) {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    Button(isWorking ? "Sharing the Project..." : "Create Invite") {
                        Task {
                            await createInvite()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canInvite)
                } else {
                    Button("Done") {
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 600, height: 520)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                "Your collaborator gets their own account on the server, works in the same "
                    + "project folder, shares Claude memories and .env files, and can watch your "
                    + "sessions. Their Claude Code uses their own subscription."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Label(
                "Only invite someone you would trust with your laptop: a shared project lets "
                    + "each person's agents run code and use the project's keys.",
                systemImage: "hand.raised"
            )
            .fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Their account name", text: $partner, prompt: Text("sam"))
                    .onChange(of: partner) { _, name in
                        if partnerHome.isEmpty || partnerHome.hasPrefix("/Users/") {
                            partnerHome = name.isEmpty ? "" : "/Users/\(name)"
                        }
                    }
                TextField(
                    "Their Mac's home folder", text: $partnerHome, prompt: Text("/Users/sam"))
            }
            .formStyle(.grouped)
            .disabled(isWorking)
            HStack {
                Text("They also need to join your Tailscale network.")
                    .foregroundStyle(.secondary)
                Button("Invite on Tailscale...") {
                    if let url = URL(string: "https://login.tailscale.com/admin/users") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    private func inviteReady(_ code: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                "Send this code to \(partner). In Termuctive they choose Cloud > Join Cloud "
                    + "Project and paste it. It works once"
                    + (expires.map {
                        " and expires \($0.formatted(date: .abbreviated, time: .shortened))"
                    }
                        ?? "")
                    + "."
            )
            .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(code)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 120)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            Button("Copy Invite Code") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
            }
            Label(
                "The code contains a key that lets one person join. Share it privately.",
                systemImage: "lock"
            )
            .foregroundStyle(.secondary)
        }
    }

    private var canInvite: Bool {
        !isWorking
            && CloudServerSetupSheet.isValidAccount(partner)
            && partnerHome.hasPrefix("/")
    }

    private func createInvite() async {
        isWorking = true
        failure = nil
        defer {
            isWorking = false
        }
        do {
            let invite = try await CollaborationService(cloud: cloud, store: store).invite(
                projectID: projectID,
                partner: partner,
                partnerHome: partnerHome
            )
            expires = invite.expires
            code = try invite.encoded()
        } catch {
            failure = error.localizedDescription
        }
    }
}

struct JoinCloudProjectSheet: View {
    @ObservedObject var cloud: CloudSessionCoordinator
    @ObservedObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss

    @State private var codeText = ""
    @State private var isJoining = false
    @State private var joinedProjectID: UUID?
    @State private var failure: String?
    @StateObject private var importer = PartnerImportHolder()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Join a Cloud Project")
                .font(.title2.weight(.semibold))
            if joinedProjectID == nil {
                Text("Paste the invite code you received.")
                    .foregroundStyle(.secondary)
                TextEditor(text: $codeText)
                    .font(.caption.monospaced())
                    .frame(height: 140)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor))
                    )
                    .disabled(isJoining)
            } else {
                joined
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                if joinedProjectID == nil {
                    Button("Cancel", role: .cancel) {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    Button(isJoining ? "Joining..." : "Join") {
                        Task {
                            await join()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isJoining || codeText.isEmpty)
                } else {
                    Button("Done") {
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(importer.isWorking)
                }
            }
        }
        .padding(24)
        .frame(width: 600, height: 520)
    }

    @ViewBuilder
    private var joined: some View {
        Label("You joined the project. It is now in your sidebar.", systemImage: "checkmark.circle")
        Text(
            "Bring your own local copy of the project too: your branches and checkouts (with "
                + "uncommitted work and .env files) become worktrees named after you, and your "
                + "Claude memories join the shared ones."
        )
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        if let run = importer.run {
            PartnerImportProgress(run: run)
        } else {
            Button("Bring My Local Work...") {
                chooseLocalFolder()
            }
        }
    }

    private func join() async {
        isJoining = true
        failure = nil
        defer {
            isJoining = false
        }
        do {
            let code = try InviteCode.decode(codeText)
            joinedProjectID = try await CollaborationService(cloud: cloud, store: store).join(code)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func chooseLocalFolder() {
        guard let projectID = joinedProjectID,
            let binding = cloud.cloudStore.binding(forProjectID: projectID),
            let host = cloud.cloudStore.host(withID: binding.hostID)
        else {
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose your local copy of the project"
        panel.prompt = "Bring This Work"
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        let run = PartnerImport(localRoot: url.path, binding: binding, host: host, cloud: cloud)
        importer.run = run
        Task {
            await run.run()
        }
    }
}

@MainActor
private final class PartnerImportHolder: ObservableObject {
    @Published var run: PartnerImport?

    var isWorking: Bool {
        if case .working = run?.state {
            return true
        }
        return false
    }
}

private struct PartnerImportProgress: View {
    @ObservedObject var run: PartnerImport

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch run.state {
            case .idle, .working:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    if case .working(let message) = run.state {
                        Text(message)
                    }
                }
            case .finished:
                Label(
                    "Your work is on the server in \(run.createdWorktrees.count) worktree(s).",
                    systemImage: "checkmark.circle"
                )
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
            }
            ForEach(run.notes, id: \.self) { note in
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct TeamSheet: View {
    @ObservedObject var cloud: CloudSessionCoordinator
    @ObservedObject var store: WorkspaceStore
    let projectID: UUID
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    @State private var report: TeamReport?
    @State private var tasks: [BoardTask] = []
    @State private var autoRun = true
    @State private var recipient = ""
    @State private var taskTitle = ""
    @State private var taskDetails = ""
    @State private var isSending = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Team")
                    .font(.title2.weight(.semibold))
                Spacer()
                Toggle("Run teammates' tasks automatically", isOn: autoRunBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            if let report {
                List {
                    ForEach(report.members, id: \.user) { member in
                        Section(member.isYou ? "\(member.user) (you)" : member.user) {
                            if member.sessions.isEmpty {
                                Text("No sessions")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(member.sessions, id: \.pane) { session in
                                sessionRow(session, member: member)
                            }
                        }
                    }
                    Section("Tasks") {
                        if tasks.isEmpty {
                            Text("No tasks yet. Agents hand work over with the termuctive tools.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(tasks.reversed()) { task in
                            taskRow(task)
                        }
                    }
                    Section("Send a task") {
                        compose(report)
                    }
                }
            } else if failure == nil {
                ProgressView()
                    .controlSize(.small)
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Refresh") {
                    Task {
                        await load()
                    }
                }
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 620, height: 640)
        .task {
            await load()
        }
    }

    private func sessionRow(_ session: TeamReport.Session, member: TeamReport.Member) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.describe(session.claude))
                if let prompt = session.claude?.lastPrompt {
                    Text(prompt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let cwd = session.cwd {
                    Text(cwd)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            if !member.isYou,
                let target = CollaborationService(cloud: cloud, store: store).watchTarget(
                    projectID: projectID,
                    member: member.user,
                    paneID: session.pane,
                    title: "\(member.user): \(Self.describe(session.claude))"
                )
            {
                Button("Watch") {
                    openWindow(value: target)
                }
            }
        }
    }

    private var autoRunBinding: Binding<Bool> {
        Binding(
            get: { autoRun },
            set: { enabled in
                autoRun = enabled
                Task {
                    try? await service.setAutoRun(enabled, projectID: projectID)
                }
            }
        )
    }

    private var service: CollaborationService {
        CollaborationService(cloud: cloud, store: store)
    }

    private func taskRow(_ task: BoardTask) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(task.title)
                    .lineLimit(2)
                Spacer()
                Text(task.status.capitalized)
                    .font(.caption)
                    .foregroundStyle(task.isOpen ? Color.accentColor : .secondary)
            }
            Text("\(task.from) → \(task.assignee ?? (task.to == "*" ? "anyone" : task.to))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let result = task.result {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
    }

    @ViewBuilder
    private func compose(_ report: TeamReport) -> some View {
        let others = report.members.filter { !$0.isYou }.map(\.user)
        Picker("To", selection: $recipient) {
            ForEach(others, id: \.self) { member in
                Text(member).tag(member)
            }
            Text("Anyone").tag("*")
        }
        .onAppear {
            if recipient.isEmpty {
                recipient = others.first ?? "*"
            }
        }
        TextField("Task", text: $taskTitle, prompt: Text("Add tests for the login retry logic"))
        TextField("Details for the agent", text: $taskDetails, axis: .vertical)
            .lineLimit(3...6)
        HStack {
            Spacer()
            Button(isSending ? "Sending..." : "Send Task") {
                Task {
                    await send()
                }
            }
            .disabled(isSending || taskTitle.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func send() async {
        isSending = true
        defer {
            isSending = false
        }
        do {
            try await service.postTask(
                projectID: projectID,
                to: recipient.isEmpty ? "*" : recipient,
                title: taskTitle,
                details: taskDetails
            )
            taskTitle = ""
            taskDetails = ""
            tasks = try await service.tasks(projectID: projectID)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func load() async {
        failure = nil
        do {
            report = try await service.team(projectID: projectID)
            tasks = try await service.tasks(projectID: projectID)
            autoRun = try await service.autoRun(projectID: projectID)
        } catch {
            failure = error.localizedDescription
        }
    }

    static func describe(_ claude: RemoteSessionReport.Claude?) -> String {
        switch claude?.state {
        case "working":
            "Claude is working"
        case "waiting":
            "Claude is waiting for permission"
        case "idle":
            "Claude is idle"
        default:
            "Terminal"
        }
    }
}

/// A read-only live view of another member's cloud session.
struct CloudWatchView: View {
    let target: CloudWatchTarget
    @State private var ended = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Watching \(target.title)", systemImage: "eye")
                Spacer()
                Text(ended ? "Session ended" : "Read-only")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .frame(height: 26)
            EmbeddedTerminal(
                executable: "/usr/bin/ssh",
                arguments: target.arguments,
                onExit: { _ in ended = true }
            )
        }
        .frame(minWidth: 640, minHeight: 400)
    }
}
