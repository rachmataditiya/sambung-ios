import Codec2
import XCTest

final class Codec2Tests: XCTestCase {
	/// 700C: 40 ms frames (320 samples at 8 kHz) packed into 4 bytes, and a tone survives a round trip.
	func testMode700CRoundTrip() throws {
		let codec = try XCTUnwrap(codec2_create(CODEC2_MODE_700C))
		defer { codec2_destroy(codec) }
		let samplesPerFrame = Int(codec2_samples_per_frame(codec))
		let bytesPerFrame = Int(codec2_bytes_per_frame(codec))
		XCTAssertEqual(samplesPerFrame, 320)
		XCTAssertEqual(bytesPerFrame, 4)

		var input = (0..<samplesPerFrame * 25).map { Int16(8000 * sin(2 * Double.pi * 300 * Double($0) / 8000)) }
		var encoded = [UInt8](repeating: 0, count: bytesPerFrame * 25)
		var output = [Int16](repeating: 0, count: input.count)
		for frame in 0..<25 {
			input.withUnsafeMutableBufferPointer { samples in
				encoded.withUnsafeMutableBufferPointer { bytes in
					codec2_encode(codec, bytes.baseAddress! + frame * bytesPerFrame, samples.baseAddress! + frame * samplesPerFrame)
				}
			}
		}
		for frame in 0..<25 {
			output.withUnsafeMutableBufferPointer { samples in
				encoded.withUnsafeMutableBufferPointer { bytes in
					codec2_decode(codec, samples.baseAddress! + frame * samplesPerFrame, bytes.baseAddress! + frame * bytesPerFrame)
				}
			}
		}
		// One second of audio in 100 bytes, and the decoder produced sound, not silence.
		XCTAssertEqual(encoded.count, 100)
		let energy = output.suffix(4000).reduce(0.0) { $0 + Double($1) * Double($1) } / 4000
		XCTAssertGreaterThan(energy.squareRoot(), 500)
	}

	/// One second of a made-up signal built from whole numbers only, so the Android app can build the
	/// very same samples. Both apps keep what this codec makes of it as their shared reference.
	static func sharedClip() -> [Int16] {
		(0..<8000).map { i in
			let saw = ((i * 37) % 200 - 100) * 60
			let rough = ((i * i) % 61 - 30) * 40
			let pulse = (i / 80) % 2 == 0 ? 2000 : -2000
			return Int16(saw + rough + pulse)
		}
	}

	static func encode(_ samples: [Int16]) -> [UInt8] {
		let codec = codec2_create(CODEC2_MODE_700C)!
		defer { codec2_destroy(codec) }
		var input = samples
		var encoded = [UInt8](repeating: 0, count: samples.count / 320 * 4)
		for frame in 0..<samples.count / 320 {
			input.withUnsafeMutableBufferPointer { speech in
				encoded.withUnsafeMutableBufferPointer { bytes in
					codec2_encode(codec, bytes.baseAddress! + frame * 4, speech.baseAddress! + frame * 320)
				}
			}
		}
		return encoded
	}

	static func decode(_ encoded: [UInt8]) -> [Int16] {
		let codec = codec2_create(CODEC2_MODE_700C)!
		defer { codec2_destroy(codec) }
		var input = encoded
		var output = [Int16](repeating: 0, count: encoded.count / 4 * 320)
		for frame in 0..<encoded.count / 4 {
			output.withUnsafeMutableBufferPointer { speech in
				input.withUnsafeMutableBufferPointer { bytes in
					codec2_decode(codec, speech.baseAddress! + frame * 320, bytes.baseAddress! + frame * 4)
				}
			}
		}
		return output
	}

	/// The bytes the Android app's tests decode (sambung-android core/codec2). If this changes, the
	/// two apps no longer agree on what a voice clip is. Set SAMBUNG_FIXTURE_DIR to write the
	/// encoded and decoded clip out again for the Android repo.
	func testSharedClipEncodesToTheBytesAndroidExpects() throws {
		let encoded = Self.encode(Self.sharedClip())
		if let directory = ProcessInfo.processInfo.environment["SAMBUNG_FIXTURE_DIR"] {
			let decoded = Self.decode(encoded)
			try Data(encoded).write(to: URL(fileURLWithPath: directory).appendingPathComponent("codec2-700c-clip.enc"))
			try decoded.withUnsafeBufferPointer { Data(buffer: $0) }
				.write(to: URL(fileURLWithPath: directory).appendingPathComponent("codec2-700c-clip.dec"))
		}
		XCTAssertEqual(encoded.map { String(format: "%02x", $0) }.joined(), Self.sharedClipEncodedHex)
	}

	static let sharedClipEncodedHex = "a29af400e3b97400ceeeb400e3c0b400ce863c00fa397800e3913800f740b800e3c0b400f7563800ce8f7c00358df800359af400aab73c00ee8df8009a8e3800fa65fc00e3b6f400a28df400aae47c00cef4b800a2bf780035b6f4008efc3800ce8774a0"
}
