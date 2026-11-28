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
    let aodPreviewNote: String?
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
                aodPreviewNote: nil,
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

        let aodResult = inspection.flatMap { composeAODPreview(face.data, inspection: $0, canvasSize: preview.map { WatchFacePreviewSize(width: $0.width, height: $0.height) }) }

        return WatchFaceCompatibilityReport(
            previewSize: size,
            preview: preview,
            aodPreview: aodResult?.preview,
            aodPreviewNote: aodResult?.note,
            warnings: warnings,
            inspection: inspection
        )
    }
    struct AODPreviewResult {
        let preview: MiWatchFacePreview
        let note: String
    }

    /// Reconstructs a conservative AOD preview by placing standalone image resources
    /// referenced by AOD image elements at their declared X/Y coordinates. Widget,
    /// animation, and unknown element types are intentionally skipped rather than guessed.
    static func composeAODPreview(
        _ data: Data,
        inspection: WatchFaceBINInspection,
        canvasSize: WatchFacePreviewSize?
    ) -> AODPreviewResult? {
        guard let canvasSize,
              canvasSize.width > 0, canvasSize.height > 0,
              canvasSize.width <= 4096, canvasSize.height <= 4096,
              canvasSize.width <= 2_000_000 / canvasSize.height,
              let aodFace = inspection.faces.first(where: { $0.role == "AOD" }) else { return nil }

        let width = canvasSize.width
        let height = canvasSize.height
        var canvas = [UInt8](repeating: 0, count: width * height * 4)
        for pixel in 0..<(width * height) { canvas[pixel * 4 + 3] = 255 }

        let imagesByIndex = Dictionary(
            aodFace.images.filter { $0.table == 2 && $0.isValid }.map { ($0.index, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var rendered = 0
        var skipped = 0

        for element in aodFace.elements {
            guard element.referenceType == 2,
                  let resource = imagesByIndex[element.reference],
                  resource.offset >= 0, resource.length >= 12,
                  resource.offset <= data.count,
                  resource.length <= data.count - resource.offset else {
                skipped += 1
                continue
            }

            let block = data.subdata(in: resource.offset..<(resource.offset + resource.length))
            guard let image = MiWatchFacePreview.decodeBlock(block),
                  element.x < width, element.y < height,
                  element.x + image.width > 0, element.y + image.height > 0 else {
                skipped += 1
                continue
            }

            let left = max(0, element.x)
            let top = max(0, element.y)
            let right = min(width, element.x + image.width)
            let bottom = min(height, element.y + image.height)
            let source = [UInt8](image.rgba)
            for y in top..<bottom {
                for x in left..<right {
                    let sourceIndex = ((y - element.y) * image.width + (x - element.x)) * 4
                    let targetIndex = (y * width + x) * 4
                    let alpha = Int(source[sourceIndex + 3])
                    let inverseAlpha = 255 - alpha
                    canvas[targetIndex] = UInt8(min(255, Int(source[sourceIndex]) + Int(canvas[targetIndex]) * inverseAlpha / 255))
                    canvas[targetIndex + 1] = UInt8(min(255, Int(source[sourceIndex + 1]) + Int(canvas[targetIndex + 1]) * inverseAlpha / 255))
                    canvas[targetIndex + 2] = UInt8(min(255, Int(source[sourceIndex + 2]) + Int(canvas[targetIndex + 2]) * inverseAlpha / 255))
                    canvas[targetIndex + 3] = 255
                }
            }
            rendered += 1
        }

        guard rendered > 0 else { return nil }
        let note = skipped > 0
            ? String.localizedStringWithFormat(String(localized: "Reconstructed from %lld image element(s); %lld widget, animation, or unsupported element(s) were not drawn."), Int64(rendered), Int64(skipped))
            : String.localizedStringWithFormat(String(localized: "Reconstructed from %lld image element(s)."), Int64(rendered))
        return AODPreviewResult(
            preview: MiWatchFacePreview(width: width, height: height, rgba: Data(canvas)),
            note: note
        )
    }

}
