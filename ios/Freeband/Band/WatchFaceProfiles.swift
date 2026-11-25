import Foundation

/// Device-specific watch-face protocol profile.
/// Add a separate implementation for each family; never fall back to another band's protocol.
enum WatchFaceProfile {
    case band8

    /// Device-family expectations used by the shared, non-blocking BIN analyzer.
    var compatibilityRules: WatchFaceCompatibilityRules {
        switch self {
        case .band8:
            // Mi8WfBinTool serializes wfDef.json's previewImg at the header preview offset.
            // The Band 8 editor documents this asset as 122×310; mismatch remains warning-only.
            return WatchFaceCompatibilityRules(
                previewReferenceSize: WatchFacePreviewSize(width: 122, height: 310),
                previewReferenceLabel: String(localized: "122 × 310 Band 8 editor reference"),
                expectedFaceCount: 2,
                expectedFaceCountLabel: String(localized: "normal and AOD styles")
            )
        }
    }

    func analyze(_ face: ImportedWatchFace) -> WatchFaceCompatibilityReport {
        WatchFaceCompatibilityAnalyzer.analyze(face, rules: compatibilityRules)
    }

    var defaultChunkSize: Int {
        switch self { case .band8: return MiWatchFaceUpload.defaultChunkSize }
    }

    /// The caller uses Band.family(name:model:) so support follows the app's canonical
    /// device-family classification instead of maintaining a second name matcher.
    static func resolve(isBand8: Bool) -> WatchFaceProfile? {
        isBand8 ? .band8 : nil
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
}

