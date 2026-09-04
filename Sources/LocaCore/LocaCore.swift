/// Version of the pure-logic core, bumped when a stored or wire format changes.
///
/// The helper and the app both link this library, so a mismatch here is a
/// deployment mistake rather than a runtime condition. `LocaConfig.version`
/// covers on-disk migration and `locaHelperProtocolVersion` covers the XPC
/// handshake; this constant exists so a build can report what it is made of.
public enum LocaCoreVersion {
    public static let current = 1
}
