import AppKit
import SwiftUI

struct CloudServerSetupSheet: View {
    @ObservedObject var cloud: CloudSessionCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var name = "Home Server"
    @State private var address = ""
    @State private var port = "22"
    @State private var adminUser = "admin"
    @State private var memberUser = CloudServerSetupSheet.defaultMemberUser
    @State private var tailscaleName = "termuctive"
    @State private var installsDocker = false
    @State private var installsAWSCLI = true
    @State private var installsClaude = true

    @State private var step: Step = .details
    @State private var host: CloudHost?
    @State private var memberPublicKey = ""
    @State private var adminPublicKey = ""
    @State private var tailscaleLoginURL: URL?
    @State private var setupOutput = ""

    private enum Step: Equatable {
        case details
        case preparing
        case installKey
        case uploading
        case setup
        case finishing
        case done(CloudServerStatus, notes: [String])
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            content
            Spacer(minLength: 0)
            footer
        }
        .padding(24)
        .frame(width: 680, height: 600)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Set Up a Cloud Server")
                .font(.title2.weight(.semibold))
            Text(subtitle)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var subtitle: String {
        switch step {
        case .details:
            "Turn an Ubuntu 24.04 machine into a server for your projects. Install Ubuntu Server "
                + "with OpenSSH enabled and an administrator account first."
        case .preparing:
            "Creating Termuctive's keys and checking the connection..."
        case .installKey:
            "Type the \(adminUser) password once. Termuctive then signs in with its own key."
        case .uploading:
            "Copying the Termuctive server toolkit to the server..."
        case .setup:
            "Type the \(adminUser) password when sudo asks. Setup installs packages, creates your "
                + "account and connects the server to Tailscale."
        case .finishing:
            "Checking the server..."
        case .done:
            "The server is ready."
        case .failed:
            "Setup could not finish."
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .details:
            detailsForm
        case .preparing, .uploading, .finishing:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(step == .uploading ? "Uploading toolkit" : "Working")
                    .foregroundStyle(.secondary)
            }
        case .installKey:
            if let host {
                terminalPanel(
                    executable: "/usr/bin/ssh",
                    arguments: installKeyArguments(for: host)
                ) { exit in
                    if exit == .exited(0) {
                        upload()
                    } else {
                        step = .failed(
                            "The server did not accept the password. Check the address, "
                                + "port and \(adminUser) password, then try again."
                        )
                    }
                }
            }
        case .setup:
            if let host {
                VStack(alignment: .leading, spacing: 10) {
                    terminalPanel(
                        executable: "/usr/bin/ssh",
                        arguments: setupArguments(for: host),
                        onOutput: captureSetupOutput
                    ) { exit in
                        if exit == .exited(0) {
                            finish()
                        } else {
                            step = .failed(
                                "Server setup stopped before finishing. Review the output, "
                                    + "fix the problem it describes, then try again."
                            )
                        }
                    }
                    if let tailscaleLoginURL {
                        Button("Open Tailscale Sign-In") {
                            NSWorkspace.shared.open(tailscaleLoginURL)
                        }
                    }
                }
            }
        case .done(let status, let notes):
            summary(status, notes: notes)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var detailsForm: some View {
        Form {
            TextField("Server name", text: $name)
            TextField("Address", text: $address, prompt: Text("192.168.1.50"))
            TextField("SSH port", text: $port)
            TextField("Administrator account", text: $adminUser)
            TextField("Your account on the server", text: $memberUser)
            TextField("Tailscale machine name", text: $tailscaleName)
            Toggle("Install Claude Code", isOn: $installsClaude)
            Toggle("Install the AWS CLI", isOn: $installsAWSCLI)
            Toggle("Install Docker", isOn: $installsDocker)
        }
        .formStyle(.grouped)
    }

    private func terminalPanel(
        executable: String,
        arguments: [String],
        onOutput: @escaping (String) -> Void = { _ in },
        onExit: @escaping (TerminalProcessExit) -> Void
    ) -> some View {
        EmbeddedTerminal(
            executable: executable,
            arguments: arguments,
            onOutput: onOutput,
            onExit: onExit
        )
        .frame(minHeight: 300)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor))
        )
    }

    private func summary(_ status: CloudServerStatus, notes: [String]) -> some View {
        Form {
            LabeledContent("Server", value: "\(status.hostname) · \(status.os)")
            LabeledContent(
                "Hardware",
                value: "\(status.cpuCount) cores · "
                    + "\(Self.gigabytes(status.memory.totalBytes)) memory · "
                    + "\(Self.gigabytes(status.disk.freeBytes)) free"
            )
            if let gpu = status.gpus.first {
                LabeledContent("GPU", value: gpu.name)
            }
            LabeledContent("Your account", value: "\(status.user) (\(status.home))")
            LabeledContent(
                "Tailscale",
                value: status.tailscale.dnsName ?? status.tailscale.state ?? "Not connected"
            )
            LabeledContent(
                "Claude Code",
                value: status.tools.claude == nil ? "Not installed" : "Installed"
            )
            ForEach(notes, id: \.self) { note in
                Label(note, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var footer: some View {
        HStack {
            Spacer()
            switch step {
            case .details:
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Continue") {
                    begin()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!detailsAreValid)
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
                    tailscaleLoginURL = nil
                    setupOutput = ""
                    step = .details
                }
                .keyboardShortcut(.defaultAction)
            default:
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
    }

    // MARK: Steps

    private var detailsAreValid: Bool {
        !trimmed(name).isEmpty
            && !trimmed(address).isEmpty
            && Int(trimmed(port)).map { (1...65535).contains($0) } == true
            && Self.isValidAccount(trimmed(adminUser))
            && Self.isValidAccount(trimmed(memberUser))
            && (trimmed(tailscaleName).isEmpty || CloudSlug.isValid(trimmed(tailscaleName)))
    }

    private func begin() {
        step = .preparing
        Task {
            do {
                try cloud.paths.prepareDirectories()
                memberPublicKey = try await SSHKeyManager.ensureKey(
                    at: cloud.paths.memberKeyURL,
                    comment: SSHKeyManager.comment(for: "member")
                )
                adminPublicKey = try await SSHKeyManager.ensureKey(
                    at: cloud.paths.adminKeyURL,
                    comment: SSHKeyManager.comment(for: "admin")
                )
                let newHost = CloudHost(
                    id: host?.id ?? UUID(),
                    name: trimmed(name),
                    address: trimmed(address),
                    port: Int(trimmed(port)) ?? 22,
                    adminUser: trimmed(adminUser),
                    memberUser: trimmed(memberUser),
                    lanAddress: trimmed(address)
                )
                host = newHost
                cloud.cloudStore.addOrUpdate(newHost)

                let probe = try await cloud.runner.run(
                    CloudCommand(
                        alias: newHost.adminAlias,
                        remote: .script("true"),
                        timeout: 15,
                        options: ["-o", "StrictHostKeyChecking=accept-new"]
                    )
                )
                if probe.succeeded {
                    upload()
                } else {
                    step = .installKey
                }
            } catch {
                step = .failed(error.localizedDescription)
            }
        }
    }

    private func upload() {
        guard let host else {
            return
        }
        guard let toolkit = CloudToolkit.bundled else {
            step = .failed("This Termuctive build is missing its server toolkit.")
            return
        }
        step = .uploading
        Task {
            do {
                try await CloudToolkitInstaller(runner: cloud.runner, toolkit: toolkit)
                    .upload(toAlias: host.adminAlias)
                step = .setup
            } catch {
                step = .failed(error.localizedDescription)
            }
        }
    }

    private func finish() {
        guard var host else {
            return
        }
        step = .finishing
        Task {
            var notes: [String] = []
            do {
                var status = try await cloud.client.status(alias: host.alias)
                host.toolkitVersion = status.toolkit.version
                if let dnsName = status.tailscale.dnsName, !dnsName.isEmpty,
                    dnsName != host.address
                {
                    var tailscaleHost = host
                    tailscaleHost.address = dnsName
                    tailscaleHost.tailscaleName = dnsName
                    cloud.cloudStore.addOrUpdate(tailscaleHost)
                    if let reachable = try? await cloud.client.status(alias: tailscaleHost.alias) {
                        host = tailscaleHost
                        status = reachable
                    } else {
                        host.tailscaleName = dnsName
                        notes.append(
                            "Install Tailscale on this Mac to reach the server away from home. "
                                + "Until then Termuctive uses \(host.address)."
                        )
                    }
                }
                if status.rebootRequired {
                    notes.append(
                        "Restart the server once to finish installing drivers and updates.")
                }
                cloud.cloudStore.addOrUpdate(host)
                self.host = host
                step = .done(status, notes: notes)
            } catch {
                step = .failed(
                    "Setup finished, but Termuctive could not sign in to your account on the "
                        + "server. \(error.localizedDescription)"
                )
            }
        }
    }

    private func captureSetupOutput(_ text: String) {
        setupOutput = String((setupOutput + text).suffix(4_000))
        guard tailscaleLoginURL == nil,
            let range = setupOutput.range(
                of: #"https://login\.tailscale\.com/[A-Za-z0-9/_\-]+"#,
                options: .regularExpression
            )
        else {
            return
        }
        tailscaleLoginURL = URL(string: String(setupOutput[range]))
    }

    // MARK: Commands

    private func installKeyArguments(for host: CloudHost) -> [String] {
        let key = ShellQuoting.quote(adminPublicKey)
        let script =
            "umask 077; mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys"
            + " && (grep -qxF \(key) ~/.ssh/authorized_keys || echo \(key) >> ~/.ssh/authorized_keys)"
            + " && echo 'Termuctive can now sign in with its key.'"
        return [
            "-F", cloud.paths.configURL.path,
            "-tt",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "PubkeyAuthentication=no",
            "-o", "PreferredAuthentications=password,keyboard-interactive",
            "-o", "ControlPath=none",
            host.adminAlias,
            "--",
            script,
        ]
    }

    private func setupArguments(for host: CloudHost) -> [String] {
        let command = CloudToolkitInstaller.setupCommand(
            CloudSetupOptions(
                adminUser: host.adminUser,
                memberUser: host.memberUser,
                memberHome: NSHomeDirectory(),
                memberPublicKey: memberPublicKey,
                hostname: trimmed(tailscaleName).isEmpty ? nil : trimmed(tailscaleName),
                installsDocker: installsDocker,
                installsAWSCLI: installsAWSCLI,
                installsClaude: installsClaude
            )
        )
        return [
            "-F", cloud.paths.configURL.path,
            "-tt",
            "-o", "ControlPath=none",
            host.adminAlias,
            "--",
            command,
        ]
    }

    // MARK: Helpers

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var defaultMemberUser: String {
        let user = NSUserName().lowercased()
        return isValidAccount(user) ? user : ""
    }

    static func isValidAccount(_ value: String) -> Bool {
        value != "root"
            && value.range(of: #"^[a-z_][a-z0-9_-]{0,31}$"#, options: .regularExpression) != nil
    }

    static func gigabytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }
}
