import Foundation

/// Read-only structural view of a Xiaomi watch-face BIN. Unknown table records are retained
/// verbatim so inspection/export never requires rewriting or normalizing the source file.
struct WatchFaceBINInspection: Codable, Equatable {
    struct Header: Codable, Equatable {
        let signature: String
        let fileSize: Int
        let faceCount: Int
        let styleCount: Int
        let previewOffset: Int
        let faceLayout: String
        let id: String
        let name: String
        let raw: Data
    }

    struct TableRecord: Codable, Equatable, Identifiable {
        let id: String
        let index: Int
        let type: Int
        let offset: Int
        let length: Int
        let isValid: Bool
        let raw: Data
    }

    struct Table: Codable, Equatable, Identifiable {
        let id: Int
        let name: String
        let count: Int
        let offset: Int
        let isValid: Bool
        let records: [TableRecord]
    }

    struct Element: Codable, Equatable, Identifiable {
        let id: String
        let reference: Int
        let referenceType: Int
        let x: Int
        let y: Int
        let widgetType: String?
        let dataSource: String?
        let raw: Data
    }

    struct ImageResource: Codable, Equatable, Identifiable {
        let id: String
        let table: Int
        let index: Int
        let offset: Int
        let length: Int
        let width: Int?
        let height: Int?
        let frameCount: Int?
        let encoding: String
        let isValid: Bool
    }

    struct Face: Codable, Equatable, Identifiable {
        let id: Int
        let headerOffset: Int
        let name: String?
        let role: String
        let tables: [Table]
        let elements: [Element]
        let images: [ImageResource]
        let rawHeader: Data

        var widgetCount: Int { elements.filter { $0.widgetType != nil }.count }
    }

    struct UnknownBlock: Codable, Equatable, Identifiable {
        let id: String
        let faceIndex: Int
        let tableID: Int
        let recordIndex: Int
        let offset: Int
        let raw: Data
    }

    let header: Header
    let faces: [Face]
    let unknownBlocks: [UnknownBlock]
    let issues: [String]
    let resourceEncodingSummary: String

    var elementCount: Int { faces.reduce(0) { $0 + $1.elements.count } }
    var widgetCount: Int { faces.reduce(0) { $0 + $1.widgetCount } }
    var imageCount: Int { faces.reduce(0) { $0 + $1.images.count } }

    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

/// Parses the documented 0xA8 main header, 0x58 face headers and 16-byte definition tables.
/// A table is accepted only when its entire record range is inside the source file.
enum WatchFaceBINInspector {
    private struct TableSpec {
        let id: Int
        let name: String
        let countOffset: Int
        let pointerOffset: Int
    }

    private static let mainHeaderSize = 0xA8
    private static let faceHeaderSize = 0x58
    private static let namedFaceBlockSize = 0x48
    private static let maximumFaces = 16
    private static let maximumTableRecords = 4096
    private static let maximumDecodedPixels = 2_000_000

    private static let tableSpecs: [TableSpec] = [
        .init(id: 0, name: "Elements", countOffset: 0x08, pointerOffset: 0x0C),
        .init(id: 1, name: "Unknown table 1", countOffset: 0x10, pointerOffset: 0x14),
        .init(id: 2, name: "Images", countOffset: 0x18, pointerOffset: 0x1C),
        .init(id: 3, name: "Image lists", countOffset: 0x20, pointerOffset: 0x24),
        .init(id: 4, name: "Animations", countOffset: 0x28, pointerOffset: 0x2C),
        .init(id: 5, name: "JavaScript resources", countOffset: 0x30, pointerOffset: 0x34),
        .init(id: 6, name: "Unknown table 6", countOffset: 0x38, pointerOffset: 0x3C),
        .init(id: 7, name: "Widget definitions", countOffset: 0x40, pointerOffset: 0x44),
        .init(id: 8, name: "Editable definitions", countOffset: 0x48, pointerOffset: 0x4C),
        .init(id: 9, name: "Extended definitions", countOffset: 0x50, pointerOffset: 0x54)
    ]

    static func inspect(_ data: Data, fallbackID: String = "", fallbackName: String = "") -> WatchFaceBINInspection? {
        let bytes = [UInt8](data)
        guard bytes.count >= mainHeaderSize,
              Array(bytes[0..<4]) == [0x5A, 0xA5, 0x34, 0x12] else { return nil }

        let faceCount = readU16(bytes, 0x1C)
        let styleCount = readU16(bytes, 0x1E)
        guard faceCount > 0, faceCount <= maximumFaces else { return nil }

        let namedLayout = hasNamedFaceRecords(bytes, faceCount: faceCount)
        let layoutName = namedLayout ? "named-face-records" : "legacy-face-records"
        let previewOffset = readU32(bytes, 0x20) ?? 0
        let id = readCString(bytes, 0x28, 0x40) ?? fallbackID
        let name = readCString(bytes, 0x68, 0x3C) ?? fallbackName

        var issues: [String] = []
        var unknown: [WatchFaceBINInspection.UnknownBlock] = []
        var faces: [WatchFaceBINInspection.Face] = []
        var encodings: [String] = []

        for faceIndex in 0..<faceCount {
            let headerOffset = faceHeaderOffset(faceIndex, named: namedLayout)
            guard isRangeValid(headerOffset, faceHeaderSize, bytes.count) else {
                issues.append("Face \(faceIndex + 1): header is outside the file.")
                continue
            }

            let faceName: String? = namedLayout
                ? readCString(bytes, headerOffset + faceHeaderSize, namedFaceBlockSize)
                : nil
            var tables: [WatchFaceBINInspection.Table] = []
            var recordsByTable: [Int: [WatchFaceBINInspection.TableRecord]] = [:]

            for spec in tableSpecs {
                let count = readU32(bytes, headerOffset + spec.countOffset) ?? Int.max
                let offset = readU32(bytes, headerOffset + spec.pointerOffset) ?? -1
                let tableValid = count <= maximumTableRecords &&
                    (count == 0 || (offset >= mainHeaderSize && isRangeValid(offset, count * 16, bytes.count)))
                if !tableValid {
                    issues.append("Face \(faceIndex + 1), \(spec.name): invalid table bounds (count \(count), offset \(offset)).")
                }

                var records: [WatchFaceBINInspection.TableRecord] = []
                if tableValid && count > 0 {
                    records.reserveCapacity(count)
                    for recordIndex in 0..<count {
                        let recordOffset = offset + recordIndex * 16
                        let recordIndexValue = readU16(bytes, recordOffset) ?? recordIndex
                        let recordType = Int(bytes[recordOffset + 3])
                        let resourceOffset = readU32(bytes, recordOffset + 8) ?? -1
                        let resourceLength = readU32(bytes, recordOffset + 12) ?? -1
                        let resourceValid = resourceOffset >= 0 && resourceLength >= 0 &&
                            isRangeValid(resourceOffset, resourceLength, bytes.count)
                        let raw = Data(bytes[recordOffset..<(recordOffset + 16)])
                        let record = WatchFaceBINInspection.TableRecord(
                            id: "\(faceIndex)-\(spec.id)-\(recordIndex)",
                            index: recordIndexValue,
                            type: recordType,
                            offset: resourceOffset,
                            length: resourceLength,
                            isValid: resourceValid,
                            raw: raw
                        )
                        records.append(record)

                        if !resourceValid {
                            issues.append("Face \(faceIndex + 1), \(spec.name) record \(recordIndex + 1): resource range is invalid.")
                        } else if ![0, 2, 3, 4, 5, 7, 8, 9].contains(spec.id), resourceLength > 0 {
                            unknown.append(.init(
                                id: "\(faceIndex)-\(spec.id)-\(recordIndex)",
                                faceIndex: faceIndex,
                                tableID: spec.id,
                                recordIndex: recordIndex,
                                offset: resourceOffset,
                                raw: Data(bytes[resourceOffset..<(resourceOffset + resourceLength)])
                            ))
                        }
                    }
                }
                recordsByTable[spec.id] = records
                tables.append(.init(
                    id: spec.id,
                    name: spec.name,
                    count: count == Int.max ? 0 : count,
                    offset: offset,
                    isValid: tableValid,
                    records: records
                ))
            }

            var widgetRecords: [Int: WatchFaceBINInspection.TableRecord] = [:]
            for record in (recordsByTable[7] ?? []) where record.isValid {
                if widgetRecords[record.index] == nil {
                    widgetRecords[record.index] = record
                } else {
                    issues.append("Face \\(faceIndex + 1): duplicate widget definition index \\(record.index).")
                }
            }
            var elements: [WatchFaceBINInspection.Element] = []
            for (elementIndex, record) in (recordsByTable[0] ?? []).enumerated() where record.isValid && record.length >= 8 {
                let p = record.offset
                let reference = readU24(bytes, p) ?? 0
                let referenceType = Int(bytes[p + 3])
                let x = readU16(bytes, p + 4) ?? 0
                let y = readU16(bytes, p + 6) ?? 0
                let widget = referenceType == 7 ? widgetRecords[reference] : nil
                var widgetType: String?
                var dataSource: String?
                if let widget, widget.isValid, widget.length >= 4 {
                    let wp = widget.offset
                    dataSource = String(format: "%02X%02X%02X", bytes[wp], bytes[wp + 1], bytes[wp + 2])
                    let kind = Int(bytes[wp + 3]) & 0xF0
                    widgetType = [
                        0x10: "digit-widget",
                        0x20: "image-list-widget",
                        0x30: "pointer-widget"
                    ][kind] ?? "process-or-unknown-widget"
                } else if referenceType == 7 {
                    widgetType = "unresolved-widget-reference"
                    issues.append("Face \(faceIndex + 1): element \(elementIndex + 1) references missing widget definition \(reference).")
                }
                elements.append(.init(
                    id: "\(faceIndex)-element-\(elementIndex)",
                    reference: reference,
                    referenceType: referenceType,
                    x: x,
                    y: y,
                    widgetType: widgetType,
                    dataSource: dataSource,
                    raw: Data(bytes[p..<(p + min(record.length, 64))])
                ))
            }

            var images: [WatchFaceBINInspection.ImageResource] = []
            for tableID in [2, 3] {
                for record in recordsByTable[tableID] ?? [] where record.isValid && record.length >= 12 {
                    let p = record.offset
                    let sign = Int(bytes[p])
                    let frameCount = tableID == 3 ? Int(bytes[p + 1]) : nil
                    let width = readU16(bytes, p + 4) ?? 0
                    let height = readU16(bytes, p + 6) ?? 0
                    let payloadLength = readU32(bytes, p + 8) ?? -1
                    let payloadStart = p + 12
                    let payloadValid = payloadLength >= 0 && payloadLength <= record.length - 12
                    let isRLE = payloadValid && payloadLength >= 4 &&
                        bytes[payloadStart] == 0xE0 && bytes[payloadStart + 1] == 0x21 &&
                        bytes[payloadStart + 2] == 0xA5 && bytes[payloadStart + 3] == 0x5A
                    let encoding: String
                    if !payloadValid { encoding = "unknown-or-invalid" }
                    else if isRLE { encoding = "RLE" }
                    else {
                        switch sign {
                        case 3: encoding = "RGB565"
                        case 6: encoding = "RGB565A"
                        case 9: encoding = "indexed-4-bit"
                        case 10, 16: encoding = "indexed-8-bit"
                        case 14: encoding = "grayscale-8-bit"
                        default: encoding = "RAW-BGRA32"
                        }
                    }
                    if tableID == 2 { encodings.append(encoding) }
                    images.append(.init(
                        id: "\(faceIndex)-\(tableID)-\(record.index)",
                        table: tableID,
                        index: record.index,
                        offset: p,
                        length: record.length,
                        width: width > 0 ? width : nil,
                        height: height > 0 ? height : nil,
                        frameCount: frameCount,
                        encoding: encoding,
                        isValid: payloadValid && width > 0 && height > 0 &&
                            width * height <= maximumDecodedPixels
                    ))
                }
            }

            faces.append(.init(
                id: faceIndex,
                headerOffset: headerOffset,
                name: faceName,
                role: isAODFace(index: faceIndex, styleCount: styleCount, faceCount: faceCount) ? "AOD" : "normal/style",
                tables: tables,
                elements: elements,
                images: images,
                rawHeader: Data(bytes[headerOffset..<(headerOffset + faceHeaderSize)])
            ))
        }

        let uniqueEncodings = Set(encodings)
        let encodingSummary: String
        if uniqueEncodings.isEmpty { encodingSummary = "No image resource encoding could be identified." }
        else if uniqueEncodings.count == 1 && uniqueEncodings.contains("RLE") { encodingSummary = "RLE-compressed image resources (Band 8 reference-like)." }
        else if uniqueEncodings.count == 1 && uniqueEncodings.contains("RAW-BGRA32") { encodingSummary = "RAW BGRA32 image resources (Band 10 reference-like)." }
        else { encodingSummary = "Mixed image resource encodings: " + uniqueEncodings.sorted().joined(separator: ", ") + "." }

        return WatchFaceBINInspection(
            header: .init(
                signature: "5A A5 34 12",
                fileSize: bytes.count,
                faceCount: faceCount,
                styleCount: styleCount,
                previewOffset: previewOffset,
                faceLayout: layoutName,
                id: id,
                name: name,
                raw: Data(bytes[0..<mainHeaderSize])
            ),
            faces: faces,
            unknownBlocks: unknown,
            issues: issues,
            resourceEncodingSummary: encodingSummary
        )
    }

    private static func readU16(_ bytes: [UInt8], _ offset: Int) -> Int? {
        guard isRangeValid(offset, 2, bytes.count) else { return nil }
        return Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
    }

    private static func readU24(_ bytes: [UInt8], _ offset: Int) -> Int? {
        guard isRangeValid(offset, 3, bytes.count) else { return nil }
        return Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8) | (Int(bytes[offset + 2]) << 16)
    }

    private static func readU32(_ bytes: [UInt8], _ offset: Int) -> Int? {
        guard isRangeValid(offset, 4, bytes.count) else { return nil }
        let value = UInt64(bytes[offset]) | (UInt64(bytes[offset + 1]) << 8) |
            (UInt64(bytes[offset + 2]) << 16) | (UInt64(bytes[offset + 3]) << 24)
        guard value <= UInt64(Int.max) else { return nil }
        return Int(value)
    }

    private static func isRangeValid(_ offset: Int, _ length: Int, _ total: Int) -> Bool {
        offset >= 0 && length >= 0 && offset <= total && length <= total - offset
    }

    private static func readCString(_ bytes: [UInt8], _ offset: Int, _ length: Int) -> String? {
        guard isRangeValid(offset, length, bytes.count) else { return nil }
        let field = bytes[offset..<(offset + length)]
        let end = field.firstIndex(of: 0) ?? field.endIndex
        guard end > field.startIndex else { return nil }
        let value = String(decoding: field[..<end], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func isAODFace(index: Int, styleCount: Int, faceCount: Int) -> Bool {
        guard faceCount > styleCount else { return false }
        if index == 1 { return faceCount > 1 }
        return styleCount > 1 && index >= styleCount - 1
    }

    private static func faceHeaderOffset(_ index: Int, named: Bool) -> Int {
        mainHeaderSize + index * faceHeaderSize + (named ? index * namedFaceBlockSize : 0)
    }

    private static func hasNamedFaceRecords(_ bytes: [UInt8], faceCount: Int) -> Bool {
        guard faceCount > 1 else { return false }
        let candidate = faceHeaderOffset(1, named: true)
        return looksLikeFaceHeader(bytes, at: candidate)
    }

    private static func looksLikeFaceHeader(_ bytes: [UInt8], at offset: Int) -> Bool {
        guard isRangeValid(offset, faceHeaderSize, bytes.count) else { return false }
        let marker = Int(bytes[offset + 3])
        guard marker == 0 || marker == 0x80 else { return false }
        var previousPointer = mainHeaderSize
        for spec in tableSpecs {
            guard let count = readU32(bytes, offset + spec.countOffset),
                  let pointer = readU32(bytes, offset + spec.pointerOffset),
                  count <= maximumTableRecords else { return false }
            if count > 0 && (pointer < mainHeaderSize || !isRangeValid(pointer, count * 16, bytes.count)) {
                return false
            }
            if pointer > 0 {
                guard pointer >= previousPointer else { return false }
                previousPointer = pointer
            }
        }
        return true
    }
}
