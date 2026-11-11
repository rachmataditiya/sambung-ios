//
//  SambungTransfer.swift
//  Sambung
//
//  Sends and receives files over the mesh using the packets in SambungTransferWire.
//
import Foundation
import MeshtasticProtobufs
import OSLog
import SwiftData

@MainActor
final class SambungTransfer {
	static let shared = SambungTransfer()

	/// Time between packets. One full packet is about two seconds on air with LongFast, and the
	/// radio's send queue is short, so packets are fed to it no faster than it can transmit.
	/// shortcut: fixed for LongFast; derive it from the modem preset when other presets matter.
	static let packetInterval: Duration = .seconds(4)
	/// Silence after which a receiver asks for what it still lacks.
	static let quietBeforeRequest: TimeInterval = 20
	static let maxRequestRounds = 3

	static let imagePlaceholder = "🖼️ Foto"

	enum TransferError: LocalizedError {
		case notAllowedHere, notConnected, messageNotFound

		var errorDescription: String? {
			switch self {
			case .notAllowedHere: return "Foto dan suara hanya bisa dikirim lewat pesan langsung atau channel privat."
			case .notConnected: return "Belum tersambung ke radio."
			case .messageNotFound: return "Pesan pengantar tidak tersimpan, kiriman dibatalkan."
			}
		}
	}

	/// A file takes tens of seconds of airtime that every node in range has to wait out, so it
	/// stays off channels that use the public default key.
	static func isAllowed(_ destination: MessageDestination) -> Bool {
		switch destination {
		case .user: return true
		case let .channel(channel): return (channel.psk?.count ?? 0) > 1
		}
	}

	static func estimatedSeconds(forByteCount count: Int) -> Int {
		let first = SambungTransferWire.maxPacketSize - SambungTransferWire.manifestHeaderSize
		let rest = SambungTransferWire.maxPacketSize - SambungTransferWire.chunkHeaderSize
		let packets = count <= first ? 1 : 1 + (count - first + rest - 1) / rest
		return packets * 4
	}

	private struct Incoming {
		var assembler = SambungTransferWire.Assembler()
		var lastActivity = Date()
		var requestRounds = 0
		var isDirect: Bool
		var channel: UInt32
		var finished = false
	}

	private struct Outgoing {
		var packets: [SambungTransferWire.Packet]
		var toUserNum: Int64
		var channel: Int32
		var recordKey: String
	}

	private var incoming: [String: Incoming] = [:]
	private var outgoing: [UInt16: Outgoing] = [:]
	private var watchdog: Task<Void, Never>?
	private let store = SambungMediaStore.shared

	// MARK: - Sending

	func send(_ file: Data, kind: SambungTransferWire.Kind, codec: UInt8, placeholder: String, to destination: MessageDestination, accessoryManager: AccessoryManager) async throws {
		guard Self.isAllowed(destination) else { throw TransferError.notAllowedHere }
		guard accessoryManager.isConnected, let me = accessoryManager.activeDeviceNum else { throw TransferError.notConnected }

		// The text message goes first: it is what other clients show, and its id is what the
		// file is attached to on both ends.
		try await accessoryManager.sendMessage(message: placeholder, toUserNum: destination.userNum, channel: destination.channelNum, isEmoji: false, replyID: 0)
		guard let messageID = latestOutgoingMessageID(from: me, payload: placeholder) else { throw TransferError.messageNotFound }

		let id = UInt16.random(in: 1...UInt16.max)
		let packets = try SambungTransferWire.packets(for: file, id: id, kind: kind, codec: codec, messageID: UInt32(truncatingIfNeeded: messageID))
		let key = SambungMediaStore.key(from: me, messageID: messageID)
		let record = SambungMediaRecord(kind: kind, codec: codec, fileName: nil, received: 0, total: packets.count, isOutgoing: true)
		// The sender keeps the file too, so its own bubble shows it; "received" then counts
		// packets sent.
		store.store(file, for: key, record: record)
		store.update(key) { $0.received = 0 }
		outgoing[id] = Outgoing(packets: packets, toUserNum: destination.userNum, channel: destination.channelNum, recordKey: key)

		do {
			for (index, packet) in packets.enumerated() {
				try await sendRaw(SambungTransferWire.encode(packet), toUserNum: destination.userNum, channel: destination.channelNum, accessoryManager: accessoryManager)
				store.update(key) { $0.received = index + 1 }
				if index < packets.count - 1 { try await Task.sleep(for: Self.packetInterval) }
			}
		} catch {
			// The bubble must not sit on "sending" for ever.
			store.update(key) { $0.failed = true }
			Logger.mesh.error("Sambung transfer \(id, privacy: .public) stopped: \(error.localizedDescription, privacy: .public)")
			throw error
		}
	}

	private func latestOutgoingMessageID(from me: Int64, payload: String) -> Int64? {
		var descriptor = FetchDescriptor<MessageEntity>(
			predicate: #Predicate<MessageEntity> { $0.fromUser?.num == me && $0.messagePayload == payload },
			sortBy: [SortDescriptor(\MessageEntity.messageTimestamp, order: .reverse), SortDescriptor(\MessageEntity.messageId, order: .reverse)]
		)
		descriptor.fetchLimit = 1
		return (try? PersistenceController.shared.context.fetch(descriptor))?.first?.messageId
	}

	private func sendRaw(_ payload: Data, toUserNum: Int64, channel: Int32, accessoryManager: AccessoryManager) async throws {
		guard let me = accessoryManager.activeDeviceNum else { throw TransferError.notConnected }
		var data = DataMessage()
		data.payload = payload
		data.portnum = .privateApp

		var packet = MeshPacket()
		packet.from = UInt32(truncatingIfNeeded: me)
		if toUserNum > 0 {
			packet.to = UInt32(truncatingIfNeeded: toUserNum)
			// Same as a direct text message: use the recipient's key when we hold it.
			let user = getUser(id: toUserNum, context: PersistenceController.shared.context)
			if user.pkiEncrypted, let key = user.publicKey {
				packet.pkiEncrypted = true
				packet.publicKey = key
			}
		} else {
			packet.to = Constants.maximumNodeNum
		}
		packet.channel = UInt32(max(0, channel))
		packet.decoded = data
		// Direct chunks ask for the radio-level ack, which makes the firmware retransmit them.
		packet.wantAck = toUserNum > 0

		var toRadio = ToRadio()
		toRadio.packet = packet
		try await accessoryManager.send(toRadio, debugDescription: "Sambung transfer packet, \(payload.count) bytes")
	}

	// MARK: - Receiving

	/// Called for every packet on the private application port.
	func handle(_ meshPacket: MeshPacket, accessoryManager: AccessoryManager) {
		guard case let .decoded(data) = meshPacket.payloadVariant,
			  let packet = SambungTransferWire.decode(data.payload),
			  let me = accessoryManager.activeDeviceNum else { return }
		let from = Int64(meshPacket.from)
		guard from != me else { return } // Our own packet echoed back by the mesh.

		switch packet {
		case let .manifest(manifest, _):
			receive(packet, id: manifest.id, from: from, meshPacket: meshPacket, me: me, accessoryManager: accessoryManager)
		case let .chunk(id, _, _):
			receive(packet, id: id, from: from, meshPacket: meshPacket, me: me, accessoryManager: accessoryManager)
		case let .request(id, missing):
			resend(id: id, missing: missing, requestedBy: from, accessoryManager: accessoryManager)
		case let .complete(id):
			if let sent = outgoing[id], sent.toUserNum == from {
				store.update(sent.recordKey) { $0.delivered = true }
				outgoing[id] = nil
			}
		}
	}

	private func receive(_ packet: SambungTransferWire.Packet, id: UInt16, from: Int64, meshPacket: MeshPacket, me: Int64, accessoryManager: AccessoryManager) {
		let transferKey = "\(from)-\(id)"
		var entry = incoming[transferKey] ?? Incoming(isDirect: Int64(meshPacket.to) == me, channel: meshPacket.channel)
		guard !entry.finished else { return }
		entry.assembler.add(packet)
		entry.lastActivity = Date()

		if let manifest = entry.assembler.manifest {
			let recordKey = SambungMediaStore.key(from: from, messageID: Int64(manifest.messageID))
			var record = SambungMediaRecord(kind: manifest.kind, codec: manifest.codec, fileName: nil, received: entry.assembler.receivedCount, total: Int(manifest.chunkCount), isOutgoing: false)
			if let file = entry.assembler.file() {
				store.store(file, for: recordKey, record: record)
				entry.finished = true
				if entry.isDirect { reply(.complete(id: id), to: from, accessoryManager: accessoryManager) }
				NotificationCenter.default.post(name: .meshMessagesDidChange, object: nil)
			} else {
				record.failed = entry.assembler.isCorrupt
				entry.finished = record.failed
				store.set(record, for: recordKey)
			}
		}
		incoming[transferKey] = entry
		startWatchdog(accessoryManager: accessoryManager)
	}

	private func resend(id: UInt16, missing: [UInt8], requestedBy from: Int64, accessoryManager: AccessoryManager) {
		guard let sent = outgoing[id], sent.toUserNum == from else { return }
		let wanted = sent.packets.enumerated().filter { missing.contains(UInt8($0.offset)) }.map(\.element)
		Task {
			for packet in wanted {
				try? await sendRaw(SambungTransferWire.encode(packet), toUserNum: sent.toUserNum, channel: sent.channel, accessoryManager: accessoryManager)
				try? await Task.sleep(for: Self.packetInterval)
			}
		}
	}

	private func reply(_ packet: SambungTransferWire.Packet, to nodeNum: Int64, accessoryManager: AccessoryManager) {
		Task { try? await sendRaw(SambungTransferWire.encode(packet), toUserNum: nodeNum, channel: 0, accessoryManager: accessoryManager) }
	}

	/// Asks the sender for missing chunks once a direct transfer has gone quiet, and gives up
	/// on transfers that never finish. Channel transfers cannot ask: there is no one sender to
	/// answer without everyone else answering too.
	private func startWatchdog(accessoryManager: AccessoryManager) {
		guard watchdog == nil else { return }
		watchdog = Task { [weak self] in
			while !Task.isCancelled {
				try? await Task.sleep(for: .seconds(5))
				guard let self else { return }
				if !self.checkStalled(accessoryManager: accessoryManager) {
					self.watchdog = nil
					return
				}
			}
		}
	}

	/// Returns false when nothing is in flight any more.
	private func checkStalled(accessoryManager: AccessoryManager, now: Date = Date()) -> Bool {
		var active = false
		for (key, entry) in incoming where !entry.finished {
			guard now.timeIntervalSince(entry.lastActivity) >= Self.quietBeforeRequest else {
				active = true
				continue
			}
			var entry = entry
			let parts = key.split(separator: "-")
			let from = Int64(parts.first ?? "") ?? 0, id = UInt16(parts.last ?? "") ?? 0
			if entry.isDirect, entry.requestRounds < Self.maxRequestRounds {
				entry.requestRounds += 1
				entry.lastActivity = now
				reply(.request(id: id, missing: Array(entry.assembler.missing.prefix(32))), to: from, accessoryManager: accessoryManager)
				active = true
			} else {
				entry.finished = true
				if let manifest = entry.assembler.manifest {
					store.update(SambungMediaStore.key(from: from, messageID: Int64(manifest.messageID))) { $0.failed = true }
				}
			}
			incoming[key] = entry
		}
		return active
	}
}
