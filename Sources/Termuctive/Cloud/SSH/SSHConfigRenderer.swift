import Foundation

/// Renders the private ssh_config that every Termuctive ssh invocation uses with `-F`.
///
/// Using a dedicated file keeps the user's ~/.ssh/config (agents, multiplexing,
/// jump hosts) from changing how cloud sessions connect.
enum SSHConfigRenderer {
    static func render(hosts: [CloudHost], paths: SSHPaths) -> String {
        var lines = [
            "# Managed by Termuctive. Changes to this file are overwritten.",
            "",
        ]
        for host in hosts.sorted(by: { $0.alias < $1.alias }) {
            lines += hostBlock(
                alias: host.alias,
                host: host,
                user: host.memberUser,
                identity: paths.memberKeyURL
            )
            if host.hasAdminAccess {
                lines += hostBlock(
                    alias: host.adminAlias,
                    host: host,
                    user: host.adminUser,
                    identity: paths.adminKeyURL
                )
            }
        }
        lines += [
            "Host tmc-*",
            "    IdentitiesOnly yes",
            "    IdentityAgent none",
            "    UserKnownHostsFile \(quoted(paths.knownHostsURL.path))",
            "    StrictHostKeyChecking yes",
            "    ServerAliveInterval 10",
            "    ServerAliveCountMax 3",
            "    ConnectTimeout 10",
            "    ControlPath \(quoted(paths.controlPathTemplate))",
            "    SendEnv COLORTERM TERM_PROGRAM TERM_PROGRAM_VERSION",
            "    LogLevel ERROR",
            "",
        ]
        return lines.joined(separator: "\n")
    }

    private static func hostBlock(
        alias: String,
        host: CloudHost,
        user: String,
        identity: URL
    ) -> [String] {
        [
            "Host \(alias)",
            "    HostName \(host.address)",
            "    Port \(host.port)",
            "    User \(user)",
            "    IdentityFile \(quoted(identity.path))",
            // Both accounts and every address of a server share one pinned host key.
            "    HostKeyAlias \(host.alias)",
            "",
        ]
    }

    private static func quoted(_ value: String) -> String {
        value.contains(" ") ? "\"\(value)\"" : value
    }
}
