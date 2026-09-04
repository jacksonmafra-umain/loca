import Foundation

/// One published container port.
public struct DockerContainerPort: Equatable, Hashable, Sendable {
    public var containerName: String
    public var image: String
    public var publicPort: Int
    public var privatePort: Int

    public init(containerName: String, image: String, publicPort: Int, privatePort: Int) {
        self.containerName = containerName
        self.image = image
        self.publicPort = publicPort
        self.privatePort = privatePort
    }
}

/// A row as the inspector shows it: a listening port with whatever we managed
/// to learn about who owns it.
public struct InspectorRow: Equatable, Identifiable, Hashable, Sendable {
    public var id: String
    public var port: Int
    /// A container name when we resolved one, otherwise the process name.
    public var owner: String
    /// Image and private port for a container, `nil` for a plain process.
    public var detail: String?
    public var pid: Int32
    public var isContainer: Bool
    public var family: ListeningPort.Family
    public var address: String
    /// Filled in by the caller from `Project.port`.
    public var domain: String?

    public init(
        id: String,
        port: Int,
        owner: String,
        detail: String? = nil,
        pid: Int32,
        isContainer: Bool,
        family: ListeningPort.Family,
        address: String,
        domain: String? = nil
    ) {
        self.id = id
        self.port = port
        self.owner = owner
        self.detail = detail
        self.pid = pid
        self.isContainer = isContainer
        self.family = family
        self.address = address
        self.domain = domain
    }
}

/// Turns the Docker Engine's container list into port ownership, and uses it to
/// make `lsof` rows legible.
///
/// Without this, every published container port reads as `com.docker.backend`
/// with the same pid, which tells the user nothing about which of their
/// containers is holding 5432.
public enum DockerPortMapper {
    /// The subset of `GET /containers/json` this needs. Everything else in that
    /// response is ignored, so a new Docker release adding fields cannot break
    /// decoding.
    private struct Container: Decodable {
        struct Port: Decodable {
            let privatePort: Int
            let publicPort: Int?
            /// `Type` cannot be a Swift member name, hence the mapping below.
            let transport: String?

            enum CodingKeys: String, CodingKey {
                case privatePort = "PrivatePort"
                case publicPort = "PublicPort"
                case transport = "Type"
            }
        }

        let names: [String]?
        let image: String?
        let ports: [Port]?

        enum CodingKeys: String, CodingKey {
            case names = "Names"
            case image = "Image"
            case ports = "Ports"
        }
    }

    public static func decode(_ data: Data) throws -> [DockerContainerPort] {
        let containers = try JSONDecoder().decode([Container].self, from: data)

        var seen = Set<DockerContainerPort>()
        var rows: [DockerContainerPort] = []

        for container in containers {
            // Docker prefixes every name with a slash; left on, the UI shows
            // "/app-web-1".
            let name = (container.names?.first ?? "").trimmingPrefix("/")
            let image = container.image ?? ""

            for port in container.ports ?? [] {
                // An unpublished port is reachable only inside the Docker
                // network, so it can never explain a host listening socket.
                guard let publicPort = port.publicPort else { continue }
                // The inspector reads listening TCP sockets, so UDP is noise.
                guard port.transport == nil || port.transport == "tcp" else { continue }

                let row = DockerContainerPort(
                    containerName: String(name),
                    image: image,
                    publicPort: publicPort,
                    privatePort: port.privatePort)

                // A dual-stack publish is reported twice, once for 0.0.0.0 and
                // once for `::`. Both describe one mapping.
                guard seen.insert(row).inserted else { continue }
                rows.append(row)
            }
        }

        return rows
    }

    /// Replaces the owner of a `com.docker.backend` row with its container, and
    /// leaves every other row exactly as it was.
    ///
    /// An unmatched docker row keeps the raw process name: Docker may have just
    /// restarted, or the socket may have answered a moment too late, and
    /// inventing an owner would be worse than showing the honest one.
    public static func enrich(
        _ ports: [ListeningPort], with containers: [DockerContainerPort]
    ) -> [InspectorRow] {
        let byPublicPort = Dictionary(
            containers.map { ($0.publicPort, $0) }, uniquingKeysWith: { first, _ in first })

        return ports.map { port in
            if port.isDockerBackend, let container = byPublicPort[port.port] {
                return InspectorRow(
                    id: port.id,
                    port: port.port,
                    owner: container.containerName,
                    detail: "\(container.image) → \(container.privatePort)",
                    pid: port.pid,
                    isContainer: true,
                    family: port.family,
                    address: port.address)
            }

            return InspectorRow(
                id: port.id,
                port: port.port,
                owner: port.command,
                detail: nil,
                pid: port.pid,
                isContainer: false,
                family: port.family,
                address: port.address)
        }
    }
}
