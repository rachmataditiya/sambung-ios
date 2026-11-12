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

	/// Time between packets on a channel, where nobody acknowledges. One full packet is about
	/// two seconds on air with LongFast, and the radio's send queue is short.
	/// shortcut: fixed for LongFast; derive it from the modem preset when other presets matter.
	static let packetInterval: Duration = .seconds(4)
	/// A direct packet waits this long for the radio to say it was received or given up on.
	/// The radio tries three times, several seconds apart; sending the next packet meanwhile
	/// only collides with those tries and with the acknowledgements coming back.
	static let ackTimeout: Duration = .seconds(30)
	/// Silence after which a receiver asks for what it still lacks.
	static let quietBeforeRequest: TimeInterval = 20
	/// Requests in a row that brought nothing before a transfer is given up.
	static let maxRequestRounds = 4

	static var imagePlaceholder: String { sambungText("🖼️ Foto") }

	enum TransferError: LocalizedError {
		case notAllowedHere, notConnected, messageNotFound

		var errorDescription: String? {
			switch self {
			case .notAllowedHere: return sambungText("Foto dan suara hanya bisa dikirim lewat pesan langsung atau channel privat.")
			case .notConnected: return sambungText("Belum tersambung ke radio.")
			case .messageNotFound: return sambungText("Pesan pengantar tidak tersimpan, kiriman dibatalkan.")
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

	private var incoming: [String: Incoming] = [:]
	/// Transfers whose packets are going out right now, so a request does not start a second run.
	private var sending: Set<UInt16> = []
	private var ackWaiters: [UInt32: CheckedContinuation<Void, Never>] = [:]
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
		let wireMessageID = UInt32(truncatingIfNeeded: messageID)
		let packets = try SambungTransferWire.packets(for: file, id: id, kind: kind, codec: codec, messageID: wireMessageID)
		let key = SambungMediaStore.key(from: me, messageID: messageID)
		var record = SambungMediaRecord(kind: kind, codec: codec, fileName: nil, received: 0, total: packets.count, isOutgoing: true)
		record.sent = SambungSentTransfer(id: id, messageID: wireMessageID, toUserNum: destination.userNum, channel: destination.channelNum)
		// The sender keeps the file too, so its own bubble shows it; "received" then counts
		// packets sent.
		store.store(file, for: key, record: record)
		store.update(key) { $0.received = 0 }

		// The text message has to be through before the file starts, or the two collide.
		if destination.userNum > 0 { await waitForAck(of: wireMessageID) }
		do {
			try await deliver(packets, indexes: Array(packets.indices), id: id, toUserNum: destination.userNum, channel: destination.channelNum, accessoryManager: accessoryManager) { sentCount in
				self.store.update(key) { $0.received = sentCount }
			}
		} catch {
			// The bubble must not sit on "sending" for ever.
			store.update(key) { $0.failed = true }
			Logger.mesh.error("Sambung transfer \(id, privacy: .public) stopped: \(error.localizedDescription, privacy: .public)")
			throw error
		}
	}

	/// Sends the packets at [indexes] one at a time. A direct packet waits for the radio's word
	/// on the one before; that also keeps a transfer moving while the app is in the background,
	/// where each acknowledgement wakes it for a moment.
	private func deliver(_ packets: [SambungTransferWire.Packet], indexes: [Int], id: UInt16, toUserNum: Int64, channel: Int32, accessoryManager: AccessoryManager, progress: (Int) -> Void = { _ in }) async throws {
		sending.insert(id)
		defer { sending.remove(id) }
		for (position, index) in indexes.enumerated() where packets.indices.contains(index) {
			let packetID = try await sendRaw(SambungTransferWire.encode(packets[index]), toUserNum: toUserNum, channel: channel, accessoryManager: accessoryManager)
			progress(position + 1)
			guard position < indexes.count - 1 else { break }
			if toUserNum > 0 {
				await waitForAck(of: packetID)
			} else {
				try await Task.sleep(for: Self.packetInterval)
			}
		}
	}

	/// Returns once the radio reports on [packetID], acknowledged or given up, or after the timeout.
	private func waitForAck(of packetID: UInt32) async {
		await withCheckedContinuation { continuation in
			ackWaiters[packetID] = continuation
			Task {
				try? await Task.sleep(for: Self.ackTimeout)
				self.ackWaiters.removeValue(forKey: packetID)?.resume()
			}
		}
	}

	/// Called for every routing packet: an acknowledgement or a failure for something we sent.
	func acknowledged(_ meshPacket: MeshPacket) {
		ackWaiters.removeValue(forKey: meshPacket.decoded.requestID)?.resume()
	}

	private func latestOutgoingMessageID(from me: Int64, payload: String) -> Int64? {
		var descriptor = FetchDescriptor<MessageEntity>(
			predicate: #Predicate<MessageEntity> { $0.fromUser?.num == me && $0.messagePayload == payload },
			sortBy: [SortDescriptor(\MessageEntity.messageTimestamp, order: .reverse), SortDescriptor(\MessageEntity.messageId, order: .reverse)]
		)
		descriptor.fetchLimit = 1
		return (try? PersistenceController.shared.context.fetch(descriptor))?.first?.messageId
	}

	/// Returns the packet id, which is what the radio's acknowledgement will name.
	@discardableResult
	private func sendRaw(_ payload: Data, toUserNum: Int64, channel: Int32, accessoryManager: AccessoryManager) async throws -> UInt32 {
		guard let me = accessoryManager.activeDeviceNum else { throw TransferError.notConnected }
		var data = DataMessage()
		data.payload = payload
		data.portnum = .privateApp

		var packet = MeshPacket()
		packet.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
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
		return packet.id
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
			if let sent = store.sent(id: id, to: from) {
				store.update(sent.key) { $0.delivered = true }
			}
		}
	}

	private func receive(_ packet: SambungTransferWire.Packet, id: UInt16, from: Int64, meshPacket: MeshPacket, me: Int64, accessoryManager: AccessoryManager) {
		let transferKey = "\(from)-\(id)"
		var entry = incoming[transferKey] ?? Incoming(isDirect: Int64(meshPacket.to) == me, channel: meshPacket.channel)
		guard !entry.finished else { return }
		let before = entry.assembler.receivedCount
		entry.assembler.add(packet)
		entry.lastActivity = Date()
		// Only requests that bring nothing count towards giving up.
		if entry.assembler.receivedCount > before { entry.requestRounds = 0 }

		if let manifest = entry.assembler.manifest {
			let recordKey = SambungMediaStore.key(from: from, messageID: Int64(manifest.messageID))
			var record = SambungMediaRecord(kind: manifest.kind, codec: manifest.codec, fileName: nil, received: entry.assembler.receivedCount, total: Int(manifest.chunkCount), isOutgoing: false)
			if let file = entry.assembler.file() {
				store.store(file, for: recordKey, record: record)
				entry.finished = true
				// Push to talk: a clip for the conversation on screen is heard as it lands.
				if manifest.kind == .voice {
					SambungVoicePlayback.shared.arrived(file, name: "\(recordKey).voice", from: from, isDirect: entry.isDirect, channel: entry.channel)
				}
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

	/// Answers a request for missing packets. The packets are built again from the file on
	/// disk, so this works for a transfer started before the app was last closed.
	private func resend(id: UInt16, missing: [UInt8], requestedBy from: Int64, accessoryManager: AccessoryManager) {
		// While the first run is still going, what is missing is mostly what has not been sent yet.
		guard !sending.contains(id),
			  let sent = store.sent(id: id, to: from), let info = sent.record.sent,
			  let url = store.url(for: sent.record), let file = try? Data(contentsOf: url),
			  let packets = try? SambungTransferWire.packets(for: file, id: id, kind: sent.record.kind, codec: sent.record.codec, messageID: info.messageID) else { return }
		Task {
			try? await deliver(packets, indexes: missing.map(Int.init), id: id, toUserNum: info.toUserNum, channel: info.channel, accessoryManager: accessoryManager)
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
