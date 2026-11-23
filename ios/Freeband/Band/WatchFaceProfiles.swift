import Foundation

/// Device-specific watch-face protocol profile.
/// Add a separate implementation for each family; never fall back to another band's protocol.
enum WatchFaceProfile {
    case band8

    var defaultChunkSize: Int {
        switch self { case .band8: return MiWatchFaceUpload.defaultChunkSize }
    }

    static func resolve(name: String, model: String?) -> WatchFaceProfile? {
        // Keep detection local to this profile registry so protocol-vector tests do not
        // need SwiftData's Band model. A future family gets an explicit, independently
        // validated matcher and profile case.
        let compact = name.lowercased().filter { !$0.isWhitespace }
        let isBand8 = name.range(of: "band ?8(?![0-9])", options: [.regularExpression, .caseInsensitive]) != nil
            && !compact.contains("pro") && !compact.contains("active")
        return isBand8 ? .band8 : nil
    }

    func listCommand() -> Data {
        switch self { case .band8: return MiWatchFaceProtocol.listCommand() }
    }
    func setCommand(id: String) -> Data {
        switch self { case .band8: return MiWatchFaceProtocol.setCommand(id: id) }
    }
    func deleteCommand(id: String) -> Data {
        switch self { case .band8: return MiWatchFaceProtocol.deleteCommand(id: id) }
    }
    func readList(from command: PBMessage) -> [WatchFace]? {
        switch self { case .band8: return MiWatchFaceProtocol.readList(from: command) }
    }
    func acknowledgement(from command: PBMessage) -> Bool? {
        switch self { case .band8: return MiWatchFaceProtocol.acknowledgement(from: command) }
    }
    func installCommand(faceID: String, size: Int) -> Data {
        switch self { case .band8: return MiWatchFaceUpload.installCommand(faceID: faceID, size: size) }
    }
    func uploadRequest(size: Int, md5: Data) -> Data {
        switch self { case .band8: return MiWatchFaceUpload.uploadRequest(size: size, md5: md5) }
    }
    func md5(_ data: Data) -> Data {
        switch self { case .band8: return MiWatchFaceUpload.md5(data) }
    }
    func parts(file: Data, chunkSize: Int, resumePosition: Int) throws -> [Data] {
        switch self { case .band8: return try MiWatchFaceUpload.parts(file: file, chunkSize: chunkSize, resumePosition: resumePosition) }
    }
    func parseFile(_ data: Data) throws -> ImportedWatchFace {
        switch self { case .band8: return try MiWatchFaceUpload.parseFile(data) }
    }
    func preview(_ data: Data) -> MiWatchFacePreview? {
        switch self { case .band8: return MiWatchFacePreview.decode(data) }
    }
}

