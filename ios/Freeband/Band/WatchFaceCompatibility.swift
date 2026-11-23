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

    var id: String {
        switch self {
        case .previewMetadataUnavailable: return "previewMetadataUnavailable"
        case .previewDecodeFailed: return "previewDecodeFailed"
        case .previewDimensionsDiffer: return "previewDimensionsDiffer"
        case .faceStyleCountDiffers: return "faceStyleCountDiffers"
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
        }
    }
}

struct WatchFaceCompatibilityReport: Equatable {
    let previewSize: WatchFacePreviewSize?
    let preview: MiWatchFacePreview?
    let warnings: [WatchFaceCompatibilityWarning]

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
                warnings: warnings
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

        return WatchFaceCompatibilityReport(
            previewSize: size,
            preview: preview,
            warnings: warnings
        )
    }
}
