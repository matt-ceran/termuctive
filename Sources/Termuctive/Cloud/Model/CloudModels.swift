import Foundation

/// A server that runs Termuctive cloud sessions.
struct CloudHost: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    /// The address Termuctive currently connects to: a Tailscale name or a LAN address.
    var address: String
    var port: Int
    var adminUser: String
    var memberUser: String
    var lanAddress: String?
    var tailscaleName: String?
    var toolkitVersion: String?

    init(
        id: UUID = UUID(),
        name: String,
        address: String,
        port: Int = 22,
        adminUser: String,
        memberUser: String,
        lanAddress: String? = nil,
        tailscaleName: String? = nil,
        toolkitVersion: String? = nil
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.port = port
        self.adminUser = adminUser
        self.memberUser = memberUser
        self.lanAddress = lanAddress
        self.tailscaleName = tailscaleName
        self.toolkitVersion = toolkitVersion
    }

    /// The SSH configuration alias for the member account.
    var alias: String {
        "tmc-" + id.uuidString.prefix(8).lowercased()
    }

    /// The SSH configuration alias for the administrator account.
    var adminAlias: String {
        alias + "-admin"
    }

    /// Collaborators reach a server through their own account only.
    var hasAdminAccess: Bool {
        !adminUser.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case address
        case port
        case adminUser
        case memberUser
        case lanAddress
        case tailscaleName
        case toolkitVersion
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        address = try container.decode(String.self, forKey: .address)
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 22
        adminUser = try container.decode(String.self, forKey: .adminUser)
        memberUser = try container.decode(String.self, forKey: .memberUser)
        lanAddress = try container.decodeIfPresent(String.self, forKey: .lanAddress)
        tailscaleName = try container.decodeIfPresent(String.self, forKey: .tailscaleName)
        toolkitVersion = try container.decodeIfPresent(String.self, forKey: .toolkitVersion)
    }
}

enum CloudProjectRole: String, Codable {
    case owner
    case member
}

/// Links a sidebar project to a project folder on a cloud server.
struct CloudProjectBinding: Codable, Equatable {
    let projectID: UUID
    var hostID: UUID
    var slug: String
    var remoteRoot: String
    var role: CloudProjectRole
    /// Folders outside the project that moved with it and are shared with collaborators.
    var sharedPaths: [String]

    private enum CodingKeys: String, CodingKey {
        case projectID
        case hostID
        case slug
        case remoteRoot
        case role
        case sharedPaths
    }

    init(
        projectID: UUID,
        hostID: UUID,
        slug: String,
        remoteRoot: String,
        role: CloudProjectRole,
        sharedPaths: [String] = []
    ) {
        self.projectID = projectID
        self.hostID = hostID
        self.slug = slug
        self.remoteRoot = remoteRoot
        self.role = role
        self.sharedPaths = sharedPaths
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try container.decode(UUID.self, forKey: .projectID)
        hostID = try container.decode(UUID.self, forKey: .hostID)
        slug = try container.decode(String.self, forKey: .slug)
        remoteRoot = try container.decode(String.self, forKey: .remoteRoot)
        role = try container.decodeIfPresent(CloudProjectRole.self, forKey: .role) ?? .owner
        sharedPaths = try container.decodeIfPresent([String].self, forKey: .sharedPaths) ?? []
    }
}

struct CloudState: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var hosts: [CloudHost]
    var bindings: [CloudProjectBinding]

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        hosts: [CloudHost] = [],
        bindings: [CloudProjectBinding] = []
    ) {
        self.schemaVersion = schemaVersion
        self.hosts = hosts
        self.bindings = bindings
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case hosts
        case bindings
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion =
            try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Self.currentSchemaVersion
        hosts = try container.decodeIfPresent([CloudHost].self, forKey: .hosts) ?? []
        bindings =
            try container.decodeIfPresent([CloudProjectBinding].self, forKey: .bindings) ?? []
    }

    func host(withID id: UUID) -> CloudHost? {
        hosts.first { $0.id == id }
    }

    func binding(forProjectID projectID: UUID) -> CloudProjectBinding? {
        bindings.first { $0.projectID == projectID }
    }
}

enum CloudSlug {
    /// A server-safe project identifier derived from a display name.
    static func make(from name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
        var slug = ""
        var previousWasSeparator = true
        for scalar in folded.unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                slug.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                slug.append("-")
                previousWasSeparator = true
            }
        }
        while slug.hasSuffix("-") {
            slug.removeLast()
        }
        let trimmed = String(slug.prefix(40))
        return trimmed.isEmpty ? "project" : trimmed
    }

    static func isValid(_ slug: String) -> Bool {
        slug.range(of: #"^[a-z0-9][a-z0-9-]{0,39}$"#, options: .regularExpression) != nil
    }
}
