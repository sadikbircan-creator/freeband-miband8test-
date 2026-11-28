import Foundation

struct MiWatchFacePreview: Equatable {
    let width: Int
    let height: Int
    /// Premultiplied RGBA pixels, row-major.
    let rgba: Data

    struct Metadata: Equatable {
        let width: Int
        let height: Int
    }

    /// Reads the embedded preview header without decoding its pixels.
    /// Dimensions are reported as found; the device profile decides whether they are expected.
    static func inspect(_ data: Data) -> Metadata? {
        let bytes = [UInt8](data)
        guard bytes.count >= 0x24 else { return nil }
        func u16(_ offset: Int) -> Int {
            Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
        }
        func u32(_ offset: Int) -> Int? {
            let value = UInt64(bytes[offset]) | (UInt64(bytes[offset + 1]) << 8) |
                (UInt64(bytes[offset + 2]) << 16) | (UInt64(bytes[offset + 3]) << 24)
            return value <= UInt64(Int.max) ? Int(value) : nil
        }
        guard let offset = u32(0x20), offset > 0, offset <= bytes.count - 12 else { return nil }
        let width = u16(offset + 4)
        let height = u16(offset + 6)
        guard width > 0, height > 0,
              let payloadLength = u32(offset + 8), payloadLength > 0,
              payloadLength <= bytes.count - offset - 12 else { return nil }
        return Metadata(width: width, height: height)
    }

    /// Decodes the main embedded preview into premultiplied RGBA pixels.
    /// Unsupported preview encodings simply produce no preview; the BIN itself remains untouched.
    static func decode(_ data: Data) -> MiWatchFacePreview? {
        let bytes = [UInt8](data)
        guard bytes.count >= 0x24,
              let offset = readU32(bytes, 0x20),
              offset > 0, offset <= bytes.count - 12 else { return nil }
        let payloadLength = readU32(bytes, offset + 8) ?? -1
        guard payloadLength > 0, payloadLength <= bytes.count - offset - 12 else { return nil }
        return decodeBlock(Data(bytes[offset..<(offset + 12 + payloadLength)]))
    }

    /// Decodes a standalone image resource block (12-byte image header + pixel payload).
    static func decodeBlock(_ block: Data) -> MiWatchFacePreview? {
        let b = [UInt8](block)
        guard b.count >= 12 else { return nil }
        let sign = Int(b[0])
        let width = Int(b[4]) | (Int(b[5]) << 8)
        let height = Int(b[6]) | (Int(b[7]) << 8)
        let payloadLength = readU32(b, 8) ?? -1
        guard width > 0, height > 0, width <= 4096, height <= 4096,
              width <= 2_000_000 / height,
              payloadLength > 0, payloadLength <= b.count - 12 else { return nil }

        var pixels = Array(b[12..<(12 + payloadLength)])
        var bytesPerPixel: Int
        if pixels.count >= 8 && Array(pixels[0..<4]) == [0xE0, 0x21, 0xA5, 0x5A] {
            let info = UInt32(pixels[4]) | (UInt32(pixels[5]) << 8) |
                (UInt32(pixels[6]) << 16) | (UInt32(pixels[7]) << 24)
            bytesPerPixel = Int(info & 0x0F)
            let decodedLength = Int(info >> 4)
            guard (1...4).contains(bytesPerPixel), decodedLength > 0, decodedLength <= 8 * 1024 * 1024 else { return nil }
            let encoded = Array(pixels.dropFirst(8))
            if sign == 0x10 || bytesPerPixel == 1 {
                guard let decoded = decodeRLE20(encoded, expected: decodedLength) else { return nil }
                pixels = decoded
            } else {
                guard let decoded = decodeRLE10(encoded, expected: decodedLength, bytesPerPixel: bytesPerPixel) else { return nil }
                pixels = decoded
            }
        } else {
            bytesPerPixel = sign == 14 ? 1 : (sign == 6 ? 3 : (sign == 3 ? 2 : 4))
        }

        let pixelCount = width * height
        var rgba = [UInt8](repeating: 0, count: pixelCount * 4)
        func put(_ index: Int, _ red: UInt8, _ green: UInt8, _ blue: UInt8, _ alpha: UInt8) {
            let p = index * 4
            rgba[p] = UInt8((UInt16(red) * UInt16(alpha)) / 255)
            rgba[p + 1] = UInt8((UInt16(green) * UInt16(alpha)) / 255)
            rgba[p + 2] = UInt8((UInt16(blue) * UInt16(alpha)) / 255)
            rgba[p + 3] = alpha
        }

        if sign == 14 {
            guard pixels.count >= pixelCount else { return nil }
            for i in 0..<pixelCount {
                let gray = pixels[i]
                put(i, gray, gray, gray, 255)
            }
        } else if sign == 9 {
            let paletteBytes = 64
            guard pixels.count >= paletteBytes + (pixelCount + 1) / 2 else { return nil }
            for i in 0..<pixelCount {
                let packed = pixels[paletteBytes + i / 2]
                let paletteIndex = i % 2 == 0 ? Int(packed >> 4) : Int(packed & 0x0F)
                let p = paletteIndex * 4
                put(i, pixels[p + 2], pixels[p + 1], pixels[p], pixels[p + 3])
            }
        } else if sign == 0x10 || sign == 10 || bytesPerPixel == 1 {
            guard pixels.count >= 1024 + pixelCount else { return nil }
            for i in 0..<pixelCount {
                let p = 1024 + i
                let palette = Int(pixels[p]) * 4
                put(i, pixels[palette + 2], pixels[palette + 1], pixels[palette], pixels[palette + 3])
            }
        } else if bytesPerPixel == 4 {
            guard pixels.count >= pixelCount * 4 else { return nil }
            for i in 0..<pixelCount {
                let p = i * 4
                put(i, pixels[p + 2], pixels[p + 1], pixels[p], pixels[p + 3])
            }
        } else if bytesPerPixel == 3 {
            guard pixels.count >= pixelCount * 3 else { return nil }
            for i in 0..<pixelCount {
                let p = i * 3
                let lo = UInt16(pixels[p])
                let hi = UInt16(pixels[p + 1])
                let red = UInt8((hi >> 3) << 3)
                let green = UInt8((((hi & 7) << 3) | (lo >> 5)) << 2)
                let blue = UInt8((lo & 31) << 3)
                put(i, red, green, blue, pixels[p + 2])
            }
        } else {
            guard pixels.count >= pixelCount * 2 else { return nil }
            for i in 0..<pixelCount {
                let p = i * 2
                let lo = UInt16(pixels[p])
                let hi = UInt16(pixels[p + 1])
                let red = UInt8((hi >> 3) << 3)
                let green = UInt8((((hi & 7) << 3) | (lo >> 5)) << 2)
                let blue = UInt8((lo & 31) << 3)
                put(i, red, green, blue, 255)
            }
        }

        return MiWatchFacePreview(width: width, height: height, rgba: Data(rgba))
    }

    /// Decodes the frames in an image-list resource, retaining the original frame order.
    static func decodeImageListBlock(_ block: Data) -> [MiWatchFacePreview] {
        let b = [UInt8](block)
        guard b.count >= 12 else { return [] }
        let sign = b[0]
        let count = Int(b[1])
        let flags = b[2]
        let width = Int(b[4]) | (Int(b[5]) << 8)
        let height = Int(b[6]) | (Int(b[7]) << 8)
        let totalLength = readU32(b, 8) ?? -1
        guard count > 0, count <= 64, width > 0, height > 0,
              width <= 4096, height <= 4096, width <= 2_000_000 / height,
              totalLength > 0, totalLength <= b.count - 12 else { return [] }

        let hasLengthTable = flags == 4 || flags == 8
        let dataStart = 12 + (hasLengthTable ? count * 4 : 0)
        guard dataStart <= b.count else { return [] }
        var cursor = dataStart
        var frames: [MiWatchFacePreview] = []
        for index in 0..<count {
            let length = hasLengthTable ? (readU32(b, 12 + index * 4) ?? -1) : totalLength / count
            guard length > 0, cursor <= b.count, length <= b.count - cursor else { return [] }
            var imageBlock = Data([sign, 0, 0, 0, UInt8(width & 0xFF), UInt8((width >> 8) & 0xFF),
                                   UInt8(height & 0xFF), UInt8((height >> 8) & 0xFF)])
            imageBlock.append(contentsOf: [UInt8(length & 0xFF), UInt8((length >> 8) & 0xFF),
                                          UInt8((length >> 16) & 0xFF), UInt8((length >> 24) & 0xFF)])
            imageBlock.append(contentsOf: b[cursor..<(cursor + length)])
            guard let frame = decodeBlock(imageBlock) else { return [] }
            frames.append(frame)
            cursor += length
        }
        return frames
    }

    private static func readU32(_ bytes: [UInt8], _ offset: Int) -> Int? {
        guard offset >= 0, offset <= bytes.count - 4 else { return nil }
        let value = UInt64(bytes[offset]) | (UInt64(bytes[offset + 1]) << 8) |
            (UInt64(bytes[offset + 2]) << 16) | (UInt64(bytes[offset + 3]) << 24)
        return value <= UInt64(Int.max) ? Int(value) : nil
    }

    private static func decodeRLE10(_ input: [UInt8], expected: Int, bytesPerPixel: Int) -> [UInt8]? {
        var output = [UInt8]()
        output.reserveCapacity(expected)
        var cursor = 0
        while cursor < input.count && output.count < expected {
            let control = Int(input[cursor])
            cursor += 1
            let count = control & 0x7F
            guard count > 0 else { return nil }
            if control & 0x80 == 0 {
                guard cursor + bytesPerPixel <= input.count else { return nil }
                let pixel = Array(input[cursor..<(cursor + bytesPerPixel)])
                cursor += bytesPerPixel
                for _ in 0..<count { output.append(contentsOf: pixel) }
            } else {
                let length = count * bytesPerPixel
                guard cursor + length <= input.count else { return nil }
                output.append(contentsOf: input[cursor..<(cursor + length)])
                cursor += length
            }
            if output.count > expected { return nil }
        }
        return output.count == expected ? output : nil
    }

    private static func decodeRLE20(_ input: [UInt8], expected: Int) -> [UInt8]? {
        var output = [UInt8]()
        output.reserveCapacity(expected)
        var cursor = 0
        while cursor < input.count && output.count < expected {
            let control = Int(input[cursor])
            cursor += 1
            let count = control & 0x7F
            guard count > 0 else { return nil }
            if control & 0x80 != 0 {
                guard cursor + count <= input.count else { return nil }
                output.append(contentsOf: input[cursor..<(cursor + count)])
                cursor += count
            } else {
                guard cursor < input.count else { return nil }
                let value = input[cursor]
                cursor += 1
                output.append(contentsOf: repeatElement(value, count: count))
            }
            if output.count > expected { return nil }
        }
        return output.count == expected ? output : nil
    }
}
