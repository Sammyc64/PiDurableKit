import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Limits an image the model sees must keep (pi-durable `ImageLimits`).
public struct ImageLimits: Codable, Sendable, Hashable {
    /// Pixels; default 2000.
    public var maxWidth: Int
    /// Pixels; default 2000.
    public var maxHeight: Int
    /// Bytes of base64; default 4.5 MiB.
    public var maxBytes: Int

    public init(maxWidth: Int = 2000, maxHeight: Int = 2000, maxBytes: Int = 4_718_592) {
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.maxBytes = maxBytes
    }
}

/// An image the model can take: a supported format within the limits (pi-durable `PreparedImage`).
public struct PreparedImage: Codable, Sendable, Hashable {
    public struct Size: Codable, Sendable, Hashable {
        public var width: Int
        public var height: Int
        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    public struct Resize: Codable, Sendable, Hashable {
        public var from: Size
        public var to: Size
        public init(from: Size, to: Size) {
            self.from = from
            self.to = to
        }
    }

    /// Base64 of the image.
    public var data: String
    public var mimeType: String
    /// Set when the image was resized, so the model can map coordinates back.
    public var resized: Resize?
    /// The original format, when it differs from ``mimeType``.
    public var convertedFrom: String?

    public init(data: Data, mimeType: String, resized: Resize? = nil, convertedFrom: String? = nil) {
        self.data = data.base64EncodedString()
        self.mimeType = mimeType
        self.resized = resized
        self.convertedFrom = convertedFrom
    }
}

/// Decodes, orients, resizes, and re-encodes the images pi-durable's `read` tool returns, so the model can take them
/// (pi-durable `ImageProcessor`). Pass one to ``Extension/codingTools(name:shell:images:)``.
public protocol ImageProcessor: Sendable {
    /// The image prepared to fit `limits`, or `nil` when it cannot be decoded or made to fit.
    func prepare(_ image: Data, mimeType: String, limits: ImageLimits) async throws -> PreparedImage?
}

extension ImageProcessor where Self == NativeImageProcessor {
    /// Images prepared with ImageIO.
    public static var native: NativeImageProcessor { NativeImageProcessor() }
}

/// An ``ImageProcessor`` on ImageIO, in place of pi-durable's Photon (WebAssembly) one: an image already upright, in
/// a format providers take inline (PNG, JPEG, GIF, WebP), and within the limits is returned as it is. Otherwise it is
/// turned upright by its EXIF orientation, scaled to the maximum width and height, and encoded as PNG or JPEG at falling
/// qualities (JPEG first for JPEG sources), then at smaller sizes, 3/4 at a time, until its base64 fits.
public struct NativeImageProcessor: ImageProcessor {
    public init() {}

    private static let inline: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]

    public func prepare(_ image: Data, mimeType: String, limits: ImageLimits) async throws -> PreparedImage? {
        guard let source = CGImageSourceCreateWithData(image as CFData, nil), CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        var width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        var height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard width > 0, height > 0 else { return nil }
        if Self.inline.contains(mimeType), orientation == 1, width <= limits.maxWidth, height <= limits.maxHeight,
            Self.base64Length(image.count) <= limits.maxBytes
        {
            return PreparedImage(data: image, mimeType: mimeType)
        }
        // Orientations 5 to 8 swap width and height.
        if orientation >= 5 { swap(&width, &height) }
        let original = PreparedImage.Size(width: width, height: height)
        let fit = min(1, Double(limits.maxWidth) / Double(width), Double(limits.maxHeight) / Double(height))
        var target = max(1, Int((Double(max(width, height)) * fit).rounded(.down)))
        let formats: [(UTType, String, Double?)] =
            mimeType == "image/jpeg"
            ? [(.jpeg, "image/jpeg", 0.85), (.jpeg, "image/jpeg", 0.7), (.jpeg, "image/jpeg", 0.55), (.jpeg, "image/jpeg", 0.4)]
            : [(.png, "image/png", nil), (.jpeg, "image/jpeg", 0.85), (.jpeg, "image/jpeg", 0.7), (.jpeg, "image/jpeg", 0.55)]
        while target >= 1 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: target,
            ]
            guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            for (type, mime, quality) in formats {
                guard let encoded = Self.encode(scaled, as: type, quality: quality) else { continue }
                guard Self.base64Length(encoded.count) <= limits.maxBytes else { continue }
                let size = PreparedImage.Size(width: scaled.width, height: scaled.height)
                return PreparedImage(
                    data: encoded, mimeType: mime,
                    resized: size == original ? nil : PreparedImage.Resize(from: original, to: size),
                    convertedFrom: mime == mimeType ? nil : mimeType)
            }
            if target == 1 { break }
            target = max(1, target * 3 / 4)
        }
        return nil
    }

    static func base64Length(_ count: Int) -> Int { (count + 2) / 3 * 4 }

    private static func encode(_ image: CGImage, as type: UTType, quality: Double?) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        var options: [CFString: Any] = [:]
        if let quality { options[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
