//
//  SambungTransferWire.swift
//  Sambung
//
//  How Sambung carries a small file (a photo, a voice clip) over the mesh: the bytes are cut
//  into chunks that each fit one LoRa packet and sent on the private application port, which
//  other Meshtastic clients ignore. A normal text message goes out first ("🖼️ Foto"), so those
//  clients still show something, and the transfer names that message so Sambung can draw the
//  file in its place.
//
//  Every packet starts with the magic byte and a type:
//
//    manifest  'S' 1  id:u16 kind:u8 codec:u8 chunks:u8 size:u16 crc32:u32 message:u32 data…
//    chunk     'S' 2  id:u16 index:u8 data…
//    request   'S' 3  id:u16 count:u8 index:u8…        receiver asks for the chunks it lacks
//    complete  'S' 4  id:u16                           receiver has the whole file
//
//  Integers are big-endian. The manifest carries chunk 0, so a one-packet file is one packet.
//
import Foundation
import zlib

enum SambungTransferWire {
	static let magic: UInt8 = 0x53
	/// One packet stays about 1.2 seconds on air with LongFast. Longer ones arrive broken
	/// from boards without a temperature-steady oscillator: the frequency slides while the
	/// radio transmits, and a two-second packet outlasts what the receiver can follow (seen
	/// as CRC errors on the receiving radio, November 2026). A Meshtastic payload could hold
	/// 233 bytes; this is deliberately far below that.
	static let maxPacketSize = 90
	static let manifestHeaderSize = 17
	static let chunkHeaderSize = 5
	/// Policy, not format: about a minute of airtime on LongFast, and room for the largest photo.
	static let maxChunks = 56

	enum Kind: UInt8, Codable { case image = 1, voice = 2 }

	struct Manifest: Equatable {
		var id: UInt16
		var kind: Kind
		var codec: UInt8
		var chunkCount: UInt8
		var size: UInt16
		var crc32: UInt32
		/// Packet id of the text message this file belongs to.
		var messageID: UInt32
	}

	enum Packet: Equatable {
		case manifest(Manifest, data: Data)
		case chunk(id: UInt16, index: UInt8, data: Data)
		case request(id: UInt16, missing: [UInt8])
		case complete(id: UInt16)
	}

	enum WireError: Error { case tooLarge }

	static func crc32(_ data: Data) -> UInt32 {
		data.withUnsafeBytes { UInt32(zlib.crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))) }
	}

	/// Cuts a file into the packets to send, manifest first.
	static func packets(for file: Data, id: UInt16, kind: Kind, codec: UInt8, messageID: UInt32) throws -> [Packet] {
		let firstSize = maxPacketSize - manifestHeaderSize, restSize = maxPacketSize - chunkHeaderSize
		let chunkCount = file.count <= firstSize ? 1 : 1 + (file.count - firstSize + restSize - 1) / restSize
		guard !file.isEmpty, chunkCount <= maxChunks, file.count <= Int(UInt16.max) else { throw WireError.tooLarge }

		let manifest = Manifest(id: id, kind: kind, codec: codec, chunkCount: UInt8(chunkCount), size: UInt16(file.count), crc32: crc32(file), messageID: messageID)
		var packets: [Packet] = [.manifest(manifest, data: file.prefix(firstSize))]
		var offset = firstSize, index: UInt8 = 1
		while offset < file.count {
			packets.append(.chunk(id: id, index: index, data: file.subdata(in: offset..<min(offset + restSize, file.count))))
			offset += restSize
			index += 1
		}
		return packets
	}

	static func encode(_ packet: Packet) -> Data {
		var out = Data([magic])
		func put16(_ value: UInt16) { out.append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xFF)]) }
		func put32(_ value: UInt32) { put16(UInt16(value >> 16)); put16(UInt16(value & 0xFFFF)) }
		switch packet {
		case let .manifest(manifest, data):
			out.append(1)
			put16(manifest.id)
			out.append(contentsOf: [manifest.kind.rawValue, manifest.codec, manifest.chunkCount])
			put16(manifest.size)
			put32(manifest.crc32)
			put32(manifest.messageID)
			out.append(data)
		case let .chunk(id, index, data):
			out.append(2)
			put16(id)
			out.append(index)
			out.append(data)
		case let .request(id, missing):
			out.append(3)
			put16(id)
			out.append(UInt8(missing.count))
			out.append(contentsOf: missing)
		case let .complete(id):
			out.append(4)
			put16(id)
		}
		return out
	}

	/// Nil for anything that is not a well-formed Sambung transfer packet: the private port is
	/// shared with whatever else people run on the mesh.
	static func decode(_ payload: Data) -> Packet? {
		let bytes = [UInt8](payload)
		guard bytes.count >= 4, bytes[0] == magic else { return nil }
		func get16(_ at: Int) -> UInt16 { UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1]) }
		func get32(_ at: Int) -> UInt32 { UInt32(get16(at)) << 16 | UInt32(get16(at + 2)) }
		let id = get16(2)
		switch bytes[1] {
		case 1:
			guard bytes.count > manifestHeaderSize, let kind = Kind(rawValue: bytes[4]), bytes[6] >= 1 else { return nil }
			let manifest = Manifest(id: id, kind: kind, codec: bytes[5], chunkCount: bytes[6], size: get16(7), crc32: get32(9), messageID: get32(13))
			return .manifest(manifest, data: Data(bytes[manifestHeaderSize...]))
		case 2:
			guard bytes.count > chunkHeaderSize else { return nil }
			return .chunk(id: id, index: bytes[4], data: Data(bytes[chunkHeaderSize...]))
		case 3:
			guard bytes.count >= 5, bytes.count == 5 + Int(bytes[4]) else { return nil }
			return .request(id: id, missing: Array(bytes[5...]))
		case 4:
			return .complete(id: id)
		default:
			return nil
		}
	}

	/// Collects the chunks of one incoming file. Chunks may arrive in any order, more than
	/// once, and before the manifest.
	struct Assembler {
		private(set) var manifest: Manifest?
		private var chunks: [UInt8: Data] = [:]

		var receivedCount: Int { chunks.count }

		mutating func add(_ packet: Packet) {
			switch packet {
			case let .manifest(manifest, data):
				self.manifest = manifest
				chunks[0] = data
			case let .chunk(_, index, data):
				chunks[index] = data
			case .request, .complete:
				break
			}
		}

		/// Every index still needed. Before the manifest arrives the total is unknown, so only
		/// the manifest is asked for.
		var missing: [UInt8] {
			guard let manifest else { return [0] }
			return (0..<manifest.chunkCount).filter { chunks[$0] == nil }
		}

		/// The file once every chunk is here and the checksum matches, otherwise nil.
		func file() -> Data? {
			guard let manifest, missing.isEmpty else { return nil }
			var file = Data()
			for index in 0..<manifest.chunkCount { file.append(chunks[index] ?? Data()) }
			guard file.count == Int(manifest.size), SambungTransferWire.crc32(file) == manifest.crc32 else { return nil }
			return file
		}

		/// All chunks are here but they do not add up to the file that was announced.
		var isCorrupt: Bool { manifest != nil && missing.isEmpty && file() == nil }
	}
}
