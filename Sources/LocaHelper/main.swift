import Foundation
import LocaCore

// The helper runs as a root LaunchDaemon with KeepAlive, so it must not exit on
// its own. It listens, and it waits.

let buildDescription = "LocaHelper core \(LocaCoreVersion.current)"
let dns = DNSListener()
let service = HelperService(buildDescription: buildDescription, dns: dns)
let listener = XPCListener(service: service)

// launchd sends SIGTERM on bootout. Handling it explicitly means the listener
// is torn down before the process goes, rather than leaving launchd to kill a
// daemon mid-request.
signal(SIGTERM, SIG_IGN)
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termination.setEventHandler {
    NSLog("loca: helper received SIGTERM, shutting down")
    dns.stop()
    listener.stop()
    exit(0)
}
termination.resume()

// DNS comes up first and unconditionally. Resolution has to work whether or
// not the app is running, and it does not depend on any configuration.
dns.start()
listener.start()
RunLoop.main.run()
