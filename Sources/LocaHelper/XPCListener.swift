import Foundation
import LocaCore

/// Accepts XPC connections, and only from a client whose code signature
/// satisfies the requirement.
///
/// This gate is the reason the rest of the helper can be simple. Without it,
/// any local process could ask a root daemon to write `/etc/resolver` and
/// proxy domains of its choosing.
final class XPCListener: NSObject, NSXPCListenerDelegate {
    private let listener: NSXPCListener
    private let service: HelperService
    private let requirement: String?

    init(service: HelperService) {
        self.listener = NSXPCListener(machServiceName: locaHelperMachServiceName)
        self.service = service
        self.requirement = CodeSignatureRequirement.forOwnTeam()
        super.init()
        listener.delegate = self
    }

    func start() {
        listener.resume()
        NSLog("loca: helper listening on %@", locaHelperMachServiceName)
    }

    func stop() {
        listener.invalidate()
    }

    func listener(
        _ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        // No requirement means the helper cannot establish its own identity,
        // so it cannot judge anyone else's. Fail closed.
        guard let requirement else {
            NSLog("loca: refusing pid %d, no requirement available", connection.processIdentifier)
            return false
        }

        // setCodeSigningRequirement is the supported way to do this as of
        // macOS 13. It beats inspecting the audit token by hand: no private
        // API, and no window in which a pid could be reused between a check
        // and the call that trusts it.
        //
        // The call reports nothing back. Enforcement is the system's: it
        // invalidates the connection before any message reaches the exported
        // object, so a client that does not match never gets to call a method
        // here even though this returns true. The requirement string was
        // compile-checked at startup, which is where a malformed one is caught.
        connection.setCodeSigningRequirement(requirement)

        connection.exportedInterface = NSXPCInterface(with: LocaHelperProtocol.self)
        connection.exportedObject = service
        connection.resume()

        NSLog("loca: accepted pid %d", connection.processIdentifier)
        return true
    }
}
