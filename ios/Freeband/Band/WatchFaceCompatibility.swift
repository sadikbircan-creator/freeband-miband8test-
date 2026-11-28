import Foundation

/// A pixel size read from an embedded watch-face preview.
struct WatchFacePreviewSize: Equatable {
    let width: Int
    let height: Int

    var description: String { "\(width) × \(height)" }
}

/// Per-device expectations consumed by the shared compatibility analyzer.
/// A nil expectation means that the profile has not defined that check yet.
struct WatchFaceCompatibilityRules {
    let previewReferenceSize: WatchFacePreviewSize?
    let previewReferenceLabel: String?
    let expectedFaceCount: Int?
    let expectedFaceCountLabel: String?
}

enum WatchFaceCompatibilityWarning: Equatable, Identifiable {
    case previewMetadataUnavailable
    case previewDecodeFailed
    case previewDimensionsDiffer(reference: String)
    case faceStyleCountDiffers(expected: String)
    case foreignResourceEncoding(summary: String)
    case structuralIssues(count: Int)
    case unresolvedWidgets(count: Int)

    var id: String {
        switch self {
        case .previewMetadataUnavailable: return "previewMetadataUnavailable"
        case .previewDecodeFailed: return "previewDecodeFailed"
        case .previewDimensionsDiffer: return "previewDimensionsDiffer"
        case .faceStyleCountDiffers: return "faceStyleCountDiffers"
        case .foreignResourceEncoding: return "foreignResourceEncoding"
        case .structuralIssues: return "structuralIssues"
        case .unresolvedWidgets: return "unresolvedWidgets"
        }
    }

    var message: String {
        switch self {
        case .previewMetadataUnavailable:
            return String(localized: "The embedded preview information could not be read. Compatibility cannot be confirmed.")
        case .previewDecodeFailed:
            return String(localized: "Freeband could not decode the embedded preview. The BIN may still be usable.")
        case .previewDimensionsDiffer(let reference):
            return String.localizedStringWithFormat(
                String(localized: "The embedded preview dimensions differ from %@. The file may have been created for another display."),
                reference
            )
        case .faceStyleCountDiffers(let expected):
            return String.localizedStringWithFormat(
                String(localized: "This file does not contain the expected %@. Its always-on screen may be missing or different."),
                expected
            )
        case .foreignResourceEncoding(let summary):
            return String.localizedStringWithFormat(
                String(localized: "The image resources use a different encoding profile: %@. Rendering on this band may differ."),
                summary
            )
        case .structuralIssues(let count):
            return String.localizedStringWithFormat(
                String(localized: "The BIN inspector found %lld structural issue(s). Review the detailed report before installing."),
                Int64(count)
            )
        case .unresolvedWidgets(let count):
            return String.localizedStringWithFormat(
                String(localized: "%lld widget reference(s) could not be resolved. Some displayed data may be missing."),
                Int64(count)
            )
        }
    }
}

struct WatchFaceCompatibilityReport: Equatable {
    let previewSize: WatchFacePreviewSize?
    let preview: MiWatchFacePreview?
    let aodPreview: MiWatchFacePreview?
    let warnings: [WatchFaceCompatibilityWarning]
    let inspection: WatchFaceBINInspection?

    var hasWarnings: Bool { !warnings.isEmpty }

    var previewSummary: String? {
        previewSize.map {
            String(localized: "Embedded preview size") + ": \($0.description)"
        }
    }
}

/// Shared, read-only BIN inspection. It never changes the original data and never blocks
/// installation; the selected device profile supplies only its own reference expectations.
enum WatchFaceCompatibilityAnalyzer {
    static func analyze(
        _ face: ImportedWatchFace,
        rules: WatchFaceCompatibilityRules
    ) -> WatchFaceCompatibilityReport {
        var warnings: [WatchFaceCompatibilityWarning] = []
        let inspection = WatchFaceBINInspector.inspect(face.data, fallbackID: face.id, fallbackName: face.name)
        if let inspection {
            if inspection.issues.count > 0 {
                warnings.append(.structuralIssues(count: inspection.issues.count))
            }
            let unresolved = inspection.faces.flatMap(\.elements).filter { $0.widgetType == "unresolved-widget-reference" }.count
            if unresolved > 0 { warnings.append(.unresolvedWidgets(count: unresolved)) }
            if inspection.resourceEncodingSummary.contains("RAW BGRA32") ||
                inspection.resourceEncodingSummary.contains("RAW-BGRA32") {
                warnings.append(.foreignResourceEncoding(summary: inspection.resourceEncodingSummary))
            }
        }

        if let expected = rules.expectedFaceCount, face.faceCount != expected {
            warnings.append(.faceStyleCountDiffers(
                expected: rules.expectedFaceCountLabel ?? String(expected)
            ))
        }

        guard let metadata = MiWatchFacePreview.inspect(face.data) else {
            warnings.append(.previewMetadataUnavailable)
            return WatchFaceCompatibilityReport(
                previewSize: nil,
                preview: nil,
                aodPreview: nil,
                warnings: warnings,
                inspection: inspection
            )
        }

        let size = WatchFacePreviewSize(width: metadata.width, height: metadata.height)
        if let reference = rules.previewReferenceSize, size != reference {
            warnings.append(.previewDimensionsDiffer(
                reference: rules.previewReferenceLabel ?? reference.description
            ))
        }

        let preview = MiWatchFacePreview.decode(face.data)
        if preview == nil {
            warnings.append(.previewDecodeFailed)
        }

        let aodPreview = inspection.flatMap { decodeAODPreview(face.data, inspection: $0, matching: preview) }



        return WatchFaceCompatibilityReport(
            previewSize: size,
            preview: preview,
            aodPreview: aodPreview,
            warnings: warnings,
            inspection: inspection
        )
    }
    /// Returns an AOD face image only when the BIN contains a complete display-sized
    /// resource for its AOD face. Smaller widget assets are not presented as a screen preview.
    static func decodeAODPreview(
        _ data: Data,
        inspection: WatchFaceBINInspection,
        matching normalPreview: MiWatchFacePreview?
    ) -> MiWatchFacePreview? {
        guard let normalPreview,
              let aodFace = inspection.faces.first(where: { $0.role == "AOD" }) else { return nil }

        for resource in aodFace.images where resource.isValid &&
            resource.width == normalPreview.width && resource.height == normalPreview.height {
            guard resource.offset >= 0, resource.length > 0,
                  resource.offset <= data.count,
                  resource.length <= data.count - resource.offset else { continue }
            let block = data.subdata(in: resource.offset..<(resource.offset + resource.length))
            let frames = resource.table == 2
                ? [MiWatchFacePreview.decodeBlock(block)].compactMap { $0 }
                : MiWatchFacePreview.decodeImageListBlock(block)
            if let frame = frames.first(where: {
                $0.width == normalPreview.width && $0.height == normalPreview.height
            }) {
                return frame
            }
        }
        return nil
    }

}
