import CoreLocation
import Foundation
import Testing
@testable import Meshtastic

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
		#expect(reach.summary(now: now) == "Terdengar langsung, 5 menit lalu")
	}

	@Test("Relays are counted, and capped for drawing")
	func relayed() {
		let reach = SambungReach(lastHeard: now.addingTimeInterval(-30), hopsAway: 6, viaMqtt: false, now: now)
		#expect(reach.state == .reachable(hops: 6))
		#expect(reach.relayCount == 4)
		#expect(reach.summary(now: now) == "Lewat 6 perantara, baru saja")
	}

	@Test("Past the online window it is stale, whatever the hop count")
	func stale() {
		let reach = SambungReach(lastHeard: now.addingTimeInterval(-3 * 3600), hopsAway: 1, viaMqtt: false, now: now)
		#expect(reach.state == .stale)
		#expect(!reach.isReachable)
		#expect(reach.summary(now: now) == "Terakhir terdengar 3 jam lalu")
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
		#expect(reach.summary(now: now) == "Belum pernah terdengar")
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

	@Test("Distance and direction read in plain Indonesian")
	func distance() {
		let monas = CLLocationCoordinate2D(latitude: -6.1754, longitude: 106.8272)
		// About 1.1 km due north of Monas.
		let north = CLLocationCoordinate2D(latitude: -6.1654, longitude: 106.8272)
		#expect(SambungLocationMessage.distanceText(from: monas, to: north) == "1,1 km ke arah utara")
		#expect(SambungLocationMessage.distanceText(from: monas, to: monas) == "Di tempat yang sama denganmu")
		#expect(SambungLocationMessage.compassName(225) == "barat daya")
		#expect(SambungLocationMessage.compassName(359) == "utara")
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
