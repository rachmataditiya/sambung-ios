import CoreLocation
import UIKit
import Foundation
import Testing
@testable import Meshtastic

// Like upstream's tests, these compare English text: run with -testLanguage en -testRegion US.
@Suite("Sambung store")
@MainActor
struct SambungStoreTests {
	private func makeDefaults() -> UserDefaults {
		let name = "sambung-tests-\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: name)!
		defaults.removePersistentDomain(forName: name)
		return defaults
	}

	@Test("Pins and drafts survive a relaunch")
	func persists() {
		let defaults = makeDefaults()
		let store = SambungStore(defaults: defaults)
		store.togglePin("user:42")
		store.setDraft("halo", for: "channel:0")

		let reloaded = SambungStore(defaults: defaults)
		#expect(reloaded.isPinned("user:42"))
		#expect(reloaded.draft(for: "channel:0") == "halo")
		#expect(reloaded.quickReplies == SambungStore.defaultQuickReplies)
	}

	@Test("A whitespace-only draft is not kept")
	func emptyDraftIsDropped() {
		let store = SambungStore(defaults: makeDefaults())
		store.setDraft("halo", for: "user:1")
		store.setDraft("  \n", for: "user:1")
		#expect(store.draft(for: "user:1").isEmpty)
		#expect(store.drafts.isEmpty)
	}

	@Test("Deleting a conversation forgets its pin and draft")
	func forget() {
		let store = SambungStore(defaults: makeDefaults())
		store.togglePin("user:1")
		store.setDraft("halo", for: "user:1")
		store.forget("user:1")
		#expect(!store.isPinned("user:1"))
		#expect(store.draft(for: "user:1").isEmpty)
	}
}

@Suite("Sambung reach")
struct SambungReachTests {
	private let now = Date(timeIntervalSince1970: 1_800_000_000)

	@Test("Heard directly a few minutes ago")
	func direct() {
		let reach = SambungReach(lastHeard: now.addingTimeInterval(-300), hopsAway: 0, viaMqtt: false, now: now)
		#expect(reach.state == .reachable(hops: 0))
		#expect(reach.relayCount == 0)
		#expect(reach.summary(now: now) == "Heard directly, 5 min ago")
	}

	@Test("Relays are counted, and capped for drawing")
	func relayed() {
		let reach = SambungReach(lastHeard: now.addingTimeInterval(-30), hopsAway: 6, viaMqtt: false, now: now)
		#expect(reach.state == .reachable(hops: 6))
		#expect(reach.relayCount == 4)
		#expect(reach.summary(now: now) == "Relay hops: 6, just now")
	}

	@Test("Past the online window it is stale, whatever the hop count")
	func stale() {
		let reach = SambungReach(lastHeard: now.addingTimeInterval(-3 * 3600), hopsAway: 1, viaMqtt: false, now: now)
		#expect(reach.state == .stale)
		#expect(!reach.isReachable)
		#expect(reach.summary(now: now) == "Last heard 3 h ago")
	}

	@Test("MQTT-only nodes are reachable, but not by radio")
	func mqtt() {
		let reach = SambungReach(lastHeard: now.addingTimeInterval(-60), hopsAway: 0, viaMqtt: true, now: now)
		#expect(reach.state == .viaInternet)
		#expect(reach.isReachable)
	}

	@Test("No last-heard time means never heard", arguments: [nil, Date(timeIntervalSince1970: 0)] as [Date?])
	func neverHeard(lastHeard: Date?) {
		let reach = SambungReach(lastHeard: lastHeard, hopsAway: 0, viaMqtt: false, now: now)
		#expect(reach.state == .neverHeard)
		#expect(reach.summary(now: now) == "Never heard")
	}
}

@Suite("Sambung location message")
struct SambungLocationMessageTests {
	@Test("A shared location round-trips through its text")
	func roundTrip() throws {
		let text = SambungLocationMessage.text(for: .init(latitude: -6.2088, longitude: 106.8456))
		#expect(text == "📍 Lokasi saya: -6.20880, 106.84560")
		let coordinate = try #require(SambungLocationMessage.coordinate(in: text))
		#expect(abs(coordinate.latitude - -6.2088) < 0.00001)
		#expect(abs(coordinate.longitude - 106.8456) < 0.00001)
	}

	@Test("Ordinary text, upstream's position note and out-of-range numbers are not locations", arguments: [
		"Sampai jumpa di 6.2, 106.8",
		"📍 arkana has shared their position with you.",
		"📍 Lokasi saya: 96.00000, 106.84560",
		"Harga 12.500, 13.750"
	])
	func notALocation(text: String) {
		#expect(SambungLocationMessage.coordinate(in: text) == nil)
	}

	@Test("Distance and direction read in plain words")
	func distance() {
		let monas = CLLocationCoordinate2D(latitude: -6.1754, longitude: 106.8272)
		// About 1.1 km due north of Monas.
		let north = CLLocationCoordinate2D(latitude: -6.1654, longitude: 106.8272)
		#expect(SambungLocationMessage.distanceText(from: monas, to: north) == "1.1 km to the north")
		#expect(SambungLocationMessage.distanceText(from: monas, to: monas) == "Right where you are")
		#expect(SambungLocationMessage.compassName(225) == "southwest")
		#expect(SambungLocationMessage.compassName(359) == "north")
	}
}

@Suite("Sambung outbox")
struct SambungOutboxTests {
	private let sent = Date(timeIntervalSince1970: 1_800_000_000)

	private func candidate(heardAfter seconds: TimeInterval?) -> SambungOutbox.Candidate {
		.init(sentAt: sent, audienceLastHeard: seconds.map { sent.addingTimeInterval($0) })
	}

	@Test("Retries once someone is heard after the send, and not before the gap has passed")
	func retriesWhenHeard() {
		let heard = candidate(heardAfter: 30)
		#expect(!SambungOutbox.shouldRetry(heard, attempts: .init(), now: sent.addingTimeInterval(60)))
		#expect(SambungOutbox.shouldRetry(heard, attempts: .init(), now: sent.addingTimeInterval(180)))
	}

	@Test("Stays quiet when nobody was heard since the last try")
	func silentMesh() {
		let now = sent.addingTimeInterval(600)
		#expect(!SambungOutbox.shouldRetry(candidate(heardAfter: nil), attempts: .init(), now: now))
		#expect(!SambungOutbox.shouldRetry(candidate(heardAfter: -60), attempts: .init(), now: now))
		// Heard after the send, but before the previous retry: that retry already had its chance.
		let afterRetry = SambungOutbox.Attempts(count: 1, last: sent.addingTimeInterval(300))
		#expect(!SambungOutbox.shouldRetry(candidate(heardAfter: 200), attempts: afterRetry, now: now))
		#expect(SambungOutbox.shouldRetry(candidate(heardAfter: 400), attempts: afterRetry, now: now))
	}

	@Test("Gives up after the attempt limit and after a day")
	func limits() {
		let heard = candidate(heardAfter: 3000)
		let spent = SambungOutbox.Attempts(count: SambungOutbox.maxAttempts, last: sent.addingTimeInterval(60))
		#expect(!SambungOutbox.shouldRetry(heard, attempts: spent, now: sent.addingTimeInterval(3600)))
		let nextDay = SambungOutbox.Candidate(sentAt: sent, audienceLastHeard: sent.addingTimeInterval(90_000))
		#expect(!SambungOutbox.shouldRetry(nextDay, attempts: .init(), now: sent.addingTimeInterval(90_100)))
	}
}

@Suite("Sambung transfer wire")
struct SambungTransferWireTests {
	private func file(_ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }) }

	private func packets(_ count: Int) throws -> [SambungTransferWire.Packet] {
		try SambungTransferWire.packets(for: file(count), id: 0xBEEF, kind: .image, codec: 1, messageID: 0xDEADBEEF)
	}

	@Test("A file survives being cut, encoded, shuffled, duplicated and reassembled", arguments: [1, 73, 74, 1000, 4748])
	func roundTrip(count: Int) throws {
		let sent = try packets(count)
		var assembler = SambungTransferWire.Assembler()
		for packet in (sent + sent.prefix(2)).shuffled() {
			let wire = SambungTransferWire.encode(packet)
			#expect(wire.count <= SambungTransferWire.maxPacketSize)
			assembler.add(try #require(SambungTransferWire.decode(wire)))
		}
		#expect(assembler.missing.isEmpty)
		#expect(assembler.file() == file(count))
		#expect(assembler.manifest?.messageID == 0xDEADBEEF)
	}

	@Test("Packet counts at the size boundaries")
	func chunking() throws {
		#expect(try packets(73).count == 1)
		#expect(try packets(74).count == 2)
		#expect(try packets(4748).count == SambungTransferWire.maxChunks)
		#expect(throws: SambungTransferWire.WireError.self) { try packets(4749) }
		#expect(throws: SambungTransferWire.WireError.self) { try packets(0) }
	}

	@Test("Lost chunks are named, and the file is withheld until they arrive")
	func missingChunks() throws {
		let sent = try packets(498) // six packets
		var assembler = SambungTransferWire.Assembler()
		assembler.add(sent[2])
		#expect(assembler.missing == [0]) // no manifest yet: only it can be asked for
		assembler.add(sent[0])
		assembler.add(sent[4])
		#expect(assembler.missing == [1, 3, 5])
		#expect(assembler.file() == nil)
		#expect(!assembler.isCorrupt)
		for index in [1, 3, 5] { assembler.add(sent[index]) }
		#expect(assembler.file() == file(498))
	}

	@Test("A damaged chunk fails the checksum instead of producing a broken file")
	func corruption() throws {
		let sent = try packets(600)
		var assembler = SambungTransferWire.Assembler()
		for packet in sent { assembler.add(packet) }
		assembler.add(.chunk(id: 0xBEEF, index: 1, data: Data(repeating: 0, count: 195)))
		#expect(assembler.file() == nil)
		#expect(assembler.isCorrupt)
	}

	@Test("Requests and completions round-trip, and foreign packets are ignored")
	func control() {
		let request = SambungTransferWire.Packet.request(id: 7, missing: [1, 3, 5])
		#expect(SambungTransferWire.decode(SambungTransferWire.encode(request)) == request)
		#expect(SambungTransferWire.decode(SambungTransferWire.encode(.complete(id: 7))) == .complete(id: 7))
		#expect(SambungTransferWire.decode(Data("hello mesh".utf8)) == nil)
		#expect(SambungTransferWire.decode(Data([0x53, 9, 0, 1])) == nil)
		#expect(SambungTransferWire.decode(Data([0x53, 3, 0, 1, 4, 1])) == nil) // count says 4, one given
		#expect(SambungTransferWire.decode(Data()) == nil)
	}
}

@Suite("Sambung sent transfers")
@MainActor
struct SambungSentTransferTests {
	private func folder() -> URL {
		FileManager.default.temporaryDirectory.appendingPathComponent("sambung-sent-\(UUID().uuidString)", isDirectory: true)
	}

	@Test("A request for missing packets can be answered after the app was closed")
	func sentTransferSurvivesReopening() {
		let directory = folder()
		let store = SambungMediaStore(directory: directory)
		var record = SambungMediaRecord(kind: .image, codec: 2, fileName: nil, received: 0, total: 3, isOutgoing: true)
		record.sent = SambungSentTransfer(id: 77, messageID: 5, toUserNum: 4_186_346_496, channel: 0)
		store.store(Data([1, 2, 3]), for: "1-5", record: record)

		let reopened = SambungMediaStore(directory: directory)
		let found = reopened.sent(id: 77, to: 4_186_346_496)
		#expect(found?.key == "1-5")
		#expect(found.flatMap { reopened.url(for: $0.record) }.flatMap { try? Data(contentsOf: $0) } == Data([1, 2, 3]))
		// Someone else asking for the same number gets nothing.
		#expect(reopened.sent(id: 77, to: 1) == nil)
		#expect(reopened.sent(id: 78, to: 4_186_346_496) == nil)
	}

	@Test("An index saved before sent transfers were kept still loads")
	func olderIndexLoads() throws {
		let old = #"{"1-5":{"kind":1,"codec":2,"fileName":"1-5.img","received":3,"total":3,"isOutgoing":true,"failed":false,"delivered":true}}"#
		let records = try JSONDecoder().decode([String: SambungMediaRecord].self, from: Data(old.utf8))
		#expect(records["1-5"]?.delivered == true)
		#expect(records["1-5"]?.sent == nil)
	}
}

@Suite("Sambung image codec")
struct SambungImageCodecTests {
	/// A 1200×900 photo-like image: gradients plus noise, which compresses like a real picture.
	private func photo() throws -> Data {
		let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 900))
		let image = renderer.image { context in
			var generator = SystemRandomNumberGenerator()
			for row in 0..<45 {
				for column in 0..<60 {
					UIColor(hue: CGFloat(column) / 60, saturation: 0.6, brightness: CGFloat.random(in: 0.3...1, using: &generator), alpha: 1).setFill()
					context.fill(CGRect(x: column * 20, y: row * 20, width: 20, height: 20))
				}
			}
		}
		return try #require(image.jpegData(compressionQuality: 0.9))
	}

	@Test("Every size fits its byte budget and decodes at its pixel size", arguments: SambungImageCodec.Size.allCases)
	func fitsBudget(size: SambungImageCodec.Size) throws {
		let encoded = try #require(SambungImageCodec.encode(try photo(), size: size))
		#expect(encoded.data.count <= size.maxBytes)
		let image = try #require(UIImage(data: encoded.data))
		#expect(Int(max(image.size.width, image.size.height) * image.scale) == size.maxPixel)
		// And what the codec makes, the transfer format can carry.
		#expect(throws: Never.self) {
			try SambungTransferWire.packets(for: encoded.data, id: 1, kind: .image, codec: encoded.codec, messageID: 1)
		}
	}

	@Test("Something that is not an image is refused")
	func notAnImage() {
		#expect(SambungImageCodec.encode(Data("not a picture".utf8), size: .small) == nil)
	}
}

@Suite("Sambung voice codec")
struct SambungVoiceCodecTests {
	private func tone(seconds: Double) -> [Int16] {
		(0..<Int(seconds * 8000)).map { Int16(9000 * sin(2 * Double.pi * 280 * Double($0) / 8000)) }
	}

	@Test("Ten seconds is 1000 bytes and fits one transfer")
	func tenSeconds() throws {
		let clip = SambungVoiceCodec.encode(tone(seconds: 10))
		#expect(clip.count == 1000)
		#expect(SambungVoiceCodec.seconds(forByteCount: clip.count) == 10)
		let packets = try SambungTransferWire.packets(for: clip, id: 9, kind: .voice, codec: SambungVoiceCodec.codec2Mode700C, messageID: 1)
		#expect(packets.count == 12)
	}

	@Test("A partial last frame is padded, and decoding returns whole frames of sound")
	func roundTrip() {
		let clip = SambungVoiceCodec.encode(tone(seconds: 1.01))
		#expect(clip.count == 26 * SambungVoiceCodec.bytesPerFrame) // 25.25 frames round up
		let decoded = SambungVoiceCodec.decode(clip)
		#expect(decoded.count == 26 * SambungVoiceCodec.samplesPerFrame)
		let loudness = (decoded.suffix(4000).reduce(0.0) { $0 + Double($1) * Double($1) } / 4000).squareRoot()
		#expect(loudness > 500)
		#expect(SambungVoiceCodec.encode([]).isEmpty)
		#expect(SambungVoiceCodec.decode(Data([1, 2, 3])).isEmpty)
	}

	@Test("Duration text and the WAV header")
	func formatting() {
		#expect(SambungVoiceCodec.durationText(7.2) == "0:07")
		#expect(SambungVoiceCodec.placeholder(seconds: 10) == "🎤 Voice message 0:10")
		let wav = SambungVoiceCodec.wav([0, 1, -1])
		#expect(wav.count == 44 + 6)
		#expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
		#expect(wav[40] == 6) // data chunk length, little-endian
	}
}

@Suite("Sambung contacts", .serialized)
struct SambungContactsTests {
	// Node numbers no real node uses, cleared again after each test.
	private let saved: Int64 = 0x7FFF_0001
	private let unsaved: Int64 = 0x7FFF_0002

	@Test func aNodeWithALocalNameIsAContact() {
		NodeDisplayNameStore.setDisplayName("Bu Sari", for: saved)
		defer { NodeDisplayNameStore.setDisplayName(nil, for: saved) }
		#expect(SambungContacts.isContact(saved))
		#expect(!SambungContacts.isContact(unsaved))
	}

	@Test func clearingTheNameRemovesTheContact() {
		NodeDisplayNameStore.setDisplayName("Bu Sari", for: saved)
		NodeDisplayNameStore.setDisplayName("  ", for: saved)
		#expect(!SambungContacts.isContact(saved))
	}

	@Test func contactsComeFirstAndKeepTheirOrder() {
		NodeDisplayNameStore.setDisplayName("Bu Sari", for: saved)
		defer { NodeDisplayNameStore.setDisplayName(nil, for: saved) }
		let (contacts, others) = SambungContacts.split([unsaved, saved, 3, 4]) { $0 }
		#expect(contacts == [saved])
		#expect(others == [unsaved, 3, 4])
	}
}

@Suite("Sambung shell")
struct SambungShellTests {
	@Test func everyRouterTabHasAHome() {
		#expect(SambungShell.Section(.messages) == .chat)
		#expect(SambungShell.Section(.nodes) == .network)
		#expect(SambungShell.Section(.map) == .map)
		// Settings and the connection screen share the Perangkat tab.
		#expect(SambungShell.Section(.settings) == .device)
		#expect(SambungShell.Section(.connect) == .device)
	}
}

@Suite("Sambung SOS")
struct SambungSOSTests {
	@Test func theCallNamesTheSenderAndCarriesThePositionAsALocationLine() {
		let message = SambungSOS.message(name: "Budi", text: " Butuh bantuan segera. ", coordinate: CLLocationCoordinate2D(latitude: -6.2088, longitude: 106.8456))
		#expect(message == "\u{07}🆘 SOS Budi: Butuh bantuan segera.\n📍 Lokasi saya: -6.20880, 106.84560")
		// Sambung draws the position as a map and keeps the call readable above it.
		#expect(SambungLocationMessage.coordinate(in: message)?.latitude == -6.2088)
		#expect(SambungLocationMessage.caption(in: message) == "🆘 SOS Budi: Butuh bantuan segera.")
	}

	@Test func withoutAPositionTheCallStillGoesOut() {
		#expect(SambungSOS.message(name: "Budi", text: "Tolong", coordinate: nil) == "\u{07}🆘 SOS Budi: Tolong")
	}

	@Test func aPlainSharedPositionHasNoCaption() {
		#expect(SambungLocationMessage.caption(in: "📍 Lokasi saya: -6.20880, 106.84560") == nil)
		#expect(SambungLocationMessage.caption(in: "no position here") == nil)
	}

	@Test func aConversationKeyBecomesAUserOrAChannel() {
		#expect(SambungSOS.target(for: "channel:2")?.channel == 2)
		#expect(SambungSOS.target(for: "channel:2")?.userNum == 0)
		#expect(SambungSOS.target(for: "user:305419896")?.userNum == 305_419_896)
		#expect(SambungSOS.target(for: "nonsense") == nil)
	}

	@Test func repeatsAreNeverFasterThanOnceAMinuteAndStopAfterAnHour() {
		#expect(SambungSOS.clampedInterval(5) == 60)
		#expect(SambungSOS.clampedInterval(300) == 300)
		let start = Date(timeIntervalSince1970: 1_000_000)
		#expect(!SambungSOS.isOver(startedAt: start, now: start.addingTimeInterval(3599)))
		#expect(SambungSOS.isOver(startedAt: start, now: start.addingTimeInterval(3600)))
	}

	@Test @MainActor func settingsAreKeptAndTheIntervalIsClamped() throws {
		let defaults = try #require(UserDefaults(suiteName: "sambung-sos-tests"))
		defaults.removePersistentDomain(forName: "sambung-sos-tests")
		let sos = SambungSOS(defaults: defaults)
		#expect(sos.destinationKey == "channel:0")
		#expect(sos.interval == 120)
		sos.destinationKey = "user:7"
		sos.interval = 10
		#expect(SambungSOS(defaults: defaults).destinationKey == "user:7")
		#expect(SambungSOS(defaults: defaults).interval == 60)
	}
}

@Suite("Sambung push to talk")
struct SambungPushToTalkTests {
	@Test func aClipPlaysAtOnceOnlyForTheConversationOnScreen() {
		// A direct clip from the person whose conversation is open.
		#expect(SambungVoicePlayback.shouldPlay(open: .user(num: 7), from: 7, isDirect: true, channel: 0))
		// From someone else, or sent to a channel while a direct conversation is open.
		#expect(!SambungVoicePlayback.shouldPlay(open: .user(num: 7), from: 8, isDirect: true, channel: 0))
		#expect(!SambungVoicePlayback.shouldPlay(open: .user(num: 7), from: 7, isDirect: false, channel: 0))
		// A channel clip on the open channel, from anyone.
		#expect(SambungVoicePlayback.shouldPlay(open: .channel(index: 2), from: 9, isDirect: false, channel: 2))
		#expect(!SambungVoicePlayback.shouldPlay(open: .channel(index: 2), from: 9, isDirect: false, channel: 1))
		// Nothing open: it waits for its play button.
		#expect(!SambungVoicePlayback.shouldPlay(open: nil, from: 7, isDirect: true, channel: 0))
	}
}
