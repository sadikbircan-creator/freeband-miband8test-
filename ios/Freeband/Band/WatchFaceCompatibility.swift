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

    /// Reconstructs an AOD layout from its own face definitions and resources.
    /// Numeric and image-list widgets use clearly documented sample values; the preview is
    /// a structural rendering, not a live reading of the watch's current data.
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
        let bytes = [UInt8](data)
        var canvas = [UInt8](repeating: 0, count: width * height * 4)
        for pixel in 0..<(width * height) { canvas[pixel * 4 + 3] = 255 }

        func u16(_ offset: Int) -> Int? {
            guard offset >= 0, offset <= bytes.count - 2 else { return nil }
            return Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
        }
        func i16(_ offset: Int) -> Int? {
            guard let value = u16(offset) else { return nil }
            return Int(Int16(bitPattern: UInt16(value)))
        }
        func u24(_ offset: Int) -> Int? {
            guard offset >= 0, offset <= bytes.count - 3 else { return nil }
            return Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8) | (Int(bytes[offset + 2]) << 16)
        }
        func block(_ resource: WatchFaceBINInspection.ImageResource) -> Data? {
            guard resource.isValid, resource.offset >= 0, resource.length >= 12,
                  resource.offset <= data.count, resource.length <= data.count - resource.offset else { return nil }
            return data.subdata(in: resource.offset..<(resource.offset + resource.length))
        }
        func singleImage(_ index: Int) -> MiWatchFacePreview? {
            guard let resource = aodFace.images.first(where: { $0.table == 2 && $0.index == index }),
                  let raw = block(resource) else { return nil }
            return MiWatchFacePreview.decodeBlock(raw)
        }
        func imageList(_ index: Int) -> [MiWatchFacePreview] {
            guard let resource = aodFace.images.first(where: { $0.table == 3 && $0.index == index }),
                  let raw = block(resource) else { return [] }
            return MiWatchFacePreview.decodeImageListBlock(raw)
        }
        func draw(_ image: MiWatchFacePreview, at originX: Int, _ originY: Int) -> Bool {
            guard image.width > 0, image.height > 0,
                  originX < width, originY < height,
                  originX + image.width > 0, originY + image.height > 0 else { return false }
            let left = max(0, originX)
            let top = max(0, originY)
            let right = min(width, originX + image.width)
            let bottom = min(height, originY + image.height)
            let source = [UInt8](image.rgba)
            guard source.count == image.width * image.height * 4 else { return false }
            for y in top..<bottom {
                for x in left..<right {
                    let sourceIndex = ((y - originY) * image.width + (x - originX)) * 4
                    let targetIndex = (y * width + x) * 4
                    let alpha = Int(source[sourceIndex + 3])
                    let inverseAlpha = 255 - alpha
                    canvas[targetIndex] = UInt8(min(255, Int(source[sourceIndex]) + Int(canvas[targetIndex]) * inverseAlpha / 255))
                    canvas[targetIndex + 1] = UInt8(min(255, Int(source[sourceIndex + 1]) + Int(canvas[targetIndex + 1]) * inverseAlpha / 255))
                    canvas[targetIndex + 2] = UInt8(min(255, Int(source[sourceIndex + 2]) + Int(canvas[targetIndex + 2]) * inverseAlpha / 255))
                    canvas[targetIndex + 3] = 255
                }
            }
            return true
        }
        func sampleValue(_ source: String) -> Int {
            let key = String(source.prefix(4)).uppercased()
            switch key {
            case "0811": return 12       // hour
            case "1011": return 34       // minute
            case "0812": return 2026     // year
            case "1012": return 11       // month
            case "1812": return 28       // day
            case "2012": return 6        // weekday
            case "0841": return 75       // battery
            case "0821": return 1234     // steps
            case "0822": return 72       // heart rate
            default: return 0
            }
        }

        let widgetDefinitions = Dictionary(
            (aodFace.tables.first(where: { $0.id == 7 })?.records ?? [])
                .filter { $0.isValid }.map { ($0.index, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let animationDefinitions = Dictionary(
            (aodFace.tables.first(where: { $0.id == 4 })?.records ?? [])
                .filter { $0.isValid }.map { ($0.index, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var rendered = 0
        var skipped = 0
        for element in aodFace.elements {
            var didRender = false
            switch element.referenceType {
            case 2:
                if let image = singleImage(element.reference) {
                    didRender = draw(image, at: element.x, element.y)
                }
            case 4:
                if let definition = animationDefinitions[element.reference],
                   let listIndex = u24(definition.offset),
                   let frame = imageList(listIndex).first {
                    didRender = draw(frame, at: element.x, element.y)
                }
            case 7:
                guard let definition = widgetDefinitions[element.reference],
                      definition.length >= 12,
                      definition.offset >= 0,
                      definition.offset <= bytes.count - min(definition.length, bytes.count) else {
                    skipped += 1
                    continue
                }
                let p = definition.offset
                let kind = Int(bytes[p + 3]) & 0xF0
                let source = String(format: "%02X%02X", bytes[p], bytes[p + 1])
                let listIndex = u24(p + 8) ?? -1
                let frames = imageList(listIndex)
                let value = sampleValue(source)

                if kind == 0x10, frames.count >= 10 {
                    let digitCount = max(1, min(8, Int(bytes[p + 2])))
                    let align = Int(bytes[p + 3]) & 0x03
                    let leadingZero = ((Int(bytes[p + 3]) >> 2) & 1) == 1
                    let spacing = definition.length > 13 ? (Int(bytes[p + 13]) < 128 ? Int(bytes[p + 13]) : Int(bytes[p + 13]) - 256) : 0
                    let formatted = leadingZero
                        ? String(format: "%0*d", digitCount, value)
                        : String(value)
                    let glyphs = formatted.compactMap { character -> MiWatchFacePreview? in
                        if character == "-" { return frames.count > 10 ? frames[10] : frames[0] }
                        guard let digit = character.wholeNumberValue, digit >= 0, digit < 10 else { return nil }
                        return frames[digit]
                    }
                    let totalWidth = glyphs.reduce(0) { $0 + $1.width } + max(0, glyphs.count - 1) * spacing
                    var x = element.x
                    if align == 0 { x -= totalWidth }       // right anchored
                    else if align == 2 { x -= totalWidth / 2 } // centered
                    var drawnAny = false
                    for glyph in glyphs {
                        drawnAny = draw(glyph, at: x, element.y) || drawnAny
                        x += glyph.width + spacing
                    }
                    didRender = drawnAny

                    if definition.length >= 20, bytes[p + 19] == 2,
                       let unitIndex = u24(p + 16), let unit = singleImage(unitIndex) {
                        didRender = draw(unit, at: x, element.y) || didRender
                    }
                } else if kind == 0x20, !frames.isEmpty {
                    let mappedCount = max(0, min(256, (definition.length - 16) / 4))
                    var selected = min(max(value, 0), frames.count - 1)
                    if mappedCount > 0 {
                        var bestValue = Int.min
                        for item in 0..<min(mappedCount, frames.count) {
                            guard let mapped = i16(p + 16 + item * 4) else { continue }
                            if mapped <= value && mapped >= bestValue {
                                bestValue = mapped
                                selected = item
                            }
                        }
                    }
                    didRender = draw(frames[selected], at: element.x, element.y)
                }
            default:
                break
            }
            if didRender { rendered += 1 } else { skipped += 1 }
        }

        guard rendered > 0 else { return nil }
        let note = String.localizedStringWithFormat(
            String(localized: "Reconstructed from %lld AOD element(s); %lld unsupported or unavailable element(s) were omitted. Numeric widgets use sample values."),
            Int64(rendered), Int64(skipped)
        )
        return AODPreviewResult(
            preview: MiWatchFacePreview(width: width, height: height, rgba: Data(canvas)),
            note: note
        )
    }

}
