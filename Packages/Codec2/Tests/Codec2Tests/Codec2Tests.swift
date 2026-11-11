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
}
