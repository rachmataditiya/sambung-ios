//
//  SambungVoiceCodec.swift
//  Sambung
//
//  Speech squeezed to 100 bytes a second with Codec2's 700C mode, which is what makes a voice
//  clip fit in a few LoRa packets. It sounds like digital radio, not like a phone call.
//
import Codec2
import Foundation

enum SambungVoiceCodec {
	/// Codec id carried in the transfer manifest.
	static let codec2Mode700C: UInt8 = 1
	static let sampleRate = 8000
	static let samplesPerFrame = 320
	static let bytesPerFrame = 4
	/// Ten seconds is 1000 bytes: six packets, about 25 seconds of airtime on LongFast.
	static let maxSeconds = 10

	/// 8 kHz mono samples in, Codec2 frames out. A trailing partial frame is padded with silence.
	static func encode(_ samples: [Int16]) -> Data {
		guard !samples.isEmpty, let codec = codec2_create(CODEC2_MODE_700C) else { return Data() }
		defer { codec2_destroy(codec) }
		let frameCount = (samples.count + samplesPerFrame - 1) / samplesPerFrame
		var input = samples + [Int16](repeating: 0, count: frameCount * samplesPerFrame - samples.count)
		var output = [UInt8](repeating: 0, count: frameCount * bytesPerFrame)
		input.withUnsafeMutableBufferPointer { speech in
			output.withUnsafeMutableBufferPointer { bytes in
				for frame in 0..<frameCount {
					codec2_encode(codec, bytes.baseAddress! + frame * bytesPerFrame, speech.baseAddress! + frame * samplesPerFrame)
				}
			}
		}
		return Data(output)
	}

	/// Whole frames only: bytes past the last complete frame are ignored.
	static func decode(_ data: Data) -> [Int16] {
		let frameCount = data.count / bytesPerFrame
		guard frameCount > 0, let codec = codec2_create(CODEC2_MODE_700C) else { return [] }
		defer { codec2_destroy(codec) }
		var input = [UInt8](data.prefix(frameCount * bytesPerFrame))
		var output = [Int16](repeating: 0, count: frameCount * samplesPerFrame)
		input.withUnsafeMutableBufferPointer { bytes in
			output.withUnsafeMutableBufferPointer { speech in
				for frame in 0..<frameCount {
					codec2_decode(codec, speech.baseAddress! + frame * samplesPerFrame, bytes.baseAddress! + frame * bytesPerFrame)
				}
			}
		}
		return output
	}

	static func seconds(forByteCount count: Int) -> Double {
		Double(count / bytesPerFrame * samplesPerFrame) / Double(sampleRate)
	}

	/// "0:07"
	static func durationText(_ seconds: Double) -> String {
		let whole = Int(seconds.rounded())
		return "\(whole / 60):" + String(format: "%02d", whole % 60)
	}

	static func placeholder(seconds: Double) -> String { sambungText("🎤 Pesan suara %@", durationText(seconds)) }

	/// The decoded samples as a WAV file in memory, which is what the audio player takes.
	static func wav(_ samples: [Int16]) -> Data {
		var data = Data()
		func put32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
		func put16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
		let byteCount = UInt32(samples.count * 2)
		data.append(contentsOf: Array("RIFF".utf8)); put32(36 + byteCount)
		data.append(contentsOf: Array("WAVEfmt ".utf8)); put32(16)
		put16(1); put16(1) // PCM, mono
		put32(UInt32(sampleRate)); put32(UInt32(sampleRate * 2))
		put16(2); put16(16) // block align, bits per sample
		data.append(contentsOf: Array("data".utf8)); put32(byteCount)
		samples.forEach { put16(UInt16(bitPattern: $0)) }
		return data
	}
}
