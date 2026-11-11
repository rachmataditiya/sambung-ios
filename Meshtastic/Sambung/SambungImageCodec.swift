//
//  SambungImageCodec.swift
//  Sambung
//
//  Shrinks a photo until it fits in a handful of LoRa packets. At these sizes the container
//  overhead matters as much as the pixels, so both HEIC and JPEG are tried and the smaller wins.
//
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum SambungImageCodec {
	static let heic: UInt8 = 1
	static let jpeg: UInt8 = 2

	enum Size: Int, CaseIterable, Identifiable {
		case small, medium, large

		var id: Int { rawValue }
		var maxPixel: Int { [96, 144, 208][rawValue] }
		/// Byte budget. The largest equals what the transfer format will carry at all.
		var maxBytes: Int { [1100, 2400, 4600][rawValue] }
		var label: String { [sambungText("Kecil"), sambungText("Sedang"), sambungText("Besar")][rawValue] }
	}

	struct Encoded: Equatable {
		let data: Data
		let codec: UInt8
	}

	/// Nil when the source is not an image, or cannot be squeezed into the size's budget.
	static func encode(_ source: Data, size: Size) -> Encoded? {
		guard let imageSource = CGImageSourceCreateWithData(source as CFData, nil) else { return nil }
		let options: [CFString: Any] = [
			kCGImageSourceCreateThumbnailFromImageAlways: true,
			kCGImageSourceCreateThumbnailWithTransform: true, // bake in the camera orientation
			kCGImageSourceThumbnailMaxPixelSize: size.maxPixel
		]
		guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else { return nil }

		for quality in [0.45, 0.3, 0.2, 0.12, 0.06] {
			let candidates = [
				write(image, type: UTType.heic, quality: quality).map { Encoded(data: $0, codec: heic) },
				write(image, type: UTType.jpeg, quality: quality).map { Encoded(data: $0, codec: jpeg) }
			].compactMap { $0 }
			if let best = candidates.min(by: { $0.data.count < $1.data.count }), best.data.count <= size.maxBytes {
				return best
			}
		}
		return nil
	}

	private static func write(_ image: CGImage, type: UTType, quality: Double) -> Data? {
		let data = NSMutableData()
		guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
		CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
		return CGImageDestinationFinalize(destination) ? data as Data : nil
	}
}
