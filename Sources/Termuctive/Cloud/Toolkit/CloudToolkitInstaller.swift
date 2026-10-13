import Foundation

/// The server toolkit bundled in Termuctive's resources.
struct CloudToolkit: Equatable {
    static let resourceName = "termuctive-server"
    /// Where the toolkit is unpacked in the administrator's home folder before installing.
    static let stagingDirectory = ".termuctive-toolkit"

    let directory: URL

    static var bundled: CloudToolkit? {
        bundled(in: Bundle.main.resourceURL)
    }

    static func bundled(in resourceDirectory: URL?) -> CloudToolkit? {
        guard let resourceDirectory else {
            return nil
        }
        let directory = resourceDirectory.appendingPathComponent(resourceName, isDirectory: true)
        let toolkit = CloudToolkit(directory: directory)
        guard FileManager.default.fileExists(atPath: toolkit.bootstrapURL.path),
            toolkit.version != nil
        else {
            return nil
        }
        return toolkit
    }

    var bootstrapURL: URL {
        directory.appendingPathComponent("bootstrap.sh")
    }

    var version: String? {
        (try? String(contentsOf: directory.appendingPathComponent("VERSION"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func archive() async throws -> Data {
        var environment = ProcessInfo.processInfo.environment
        environment["COPYFILE_DISABLE"] = "1"
        let result = try await ProcessRunner.run(
            "/usr/bin/tar",
            [
                "-cz", "--exclude", "__pycache__", "--exclude", ".DS_Store", "-C", directory.path,
                ".",
            ],
            environment: environment
        )
        guard result.succeeded else {
            throw CloudCommandError.failed(
                command: "tar",
                status: result.status,
                message: "Termuctive could not package its server toolkit. \(result.errorText)"
            )
        }
        return result.output
    }
}

struct CloudSetupOptions: Equatable {
    var adminUser: String
    var memberUser: String
    var memberHome: String
    var memberPublicKey: String
    var hostname: String?
    var installsDocker = false
    var installsAWSCLI = true
    var installsClaude = true
    /// Additional setup flags, such as `--container` for test servers.
    var additionalArguments: [String] = []
}

struct CloudToolkitInstaller {
    let runner: any CloudCommandRunning
    let toolkit: CloudToolkit

    static let stagingScript =
        "rm -rf ~/\(CloudToolkit.stagingDirectory)"
        + " && mkdir -p ~/\(CloudToolkit.stagingDirectory)"
        + " && tar -xzf - -C ~/\(CloudToolkit.stagingDirectory)"

    /// Copies the toolkit into the administrator's home folder on the server.
    func upload(toAlias alias: String) async throws {
        let archive = try await toolkit.archive()
        _ = try await runner.output(
            CloudCommand(
                alias: alias, remote: .script(Self.stagingScript), input: archive, timeout: 120)
        )
    }

    /// Replaces the installed toolkit without re-running setup. Needs passwordless sudo.
    func installUploadedToolkit(adminAlias: String) async throws {
        _ = try await runner.output(
            CloudCommand(
                alias: adminAlias,
                remote: .script(
                    "sudo -n sh ~/\(CloudToolkit.stagingDirectory)/bootstrap.sh --install-only"
                ),
                timeout: 120
            )
        )
    }

    /// The command the setup sheet runs in a visible terminal, where the administrator
    /// types their sudo password and can follow every step.
    static func setupCommand(_ options: CloudSetupOptions) -> String {
        var arguments = [
            "--admin-user", options.adminUser,
            "--member", options.memberUser,
            "--member-home", options.memberHome,
            "--member-key", options.memberPublicKey,
        ]
        if let hostname = options.hostname {
            arguments += ["--hostname", hostname]
        }
        if options.installsDocker {
            arguments.append("--with-docker")
        }
        if !options.installsAWSCLI {
            arguments.append("--skip-awscli")
        }
        if !options.installsClaude {
            arguments.append("--skip-claude")
        }
        arguments += options.additionalArguments
        // The bootstrap path relies on the remote shell expanding `~`, so it stays unquoted.
        return "sudo sh ~/\(CloudToolkit.stagingDirectory)/bootstrap.sh "
            + ShellQuoting.command(arguments)
    }
}
