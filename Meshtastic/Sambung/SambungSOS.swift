//
//  SambungSOS.swift
//  Sambung
//
//  The emergency message: who is calling, what for, and where from, sent as ordinary text so
//  every Meshtastic client can read it, and again every few minutes with the latest position
//  until it is stopped. The bell character at the front makes radios with an alert set up
//  sound it.
//
import CoreLocation
import Foundation
import OSLog

@MainActor
final class SambungSOS: ObservableObject {
	static let shared = SambungSOS()

	/// An hour of repeats is enough to be heard; after that it is airtime and battery.
	nonisolated static let maxDuration: TimeInterval = 3600
	/// A public channel is shared airtime, so no faster than once a minute.
	nonisolated static let minInterval = 60
	nonisolated static let defaultInterval = 120

	private enum Keys {
		static let destination = "sambung.sos.destination"
		static let text = "sambung.sos.text"
		static let interval = "sambung.sos.interval"
	}

	@Published private(set) var startedAt: Date?
	@Published private(set) var sentCount = 0
	@Published private(set) var lastError: String?

	private var loop: Task<Void, Never>?
	private let defaults: UserDefaults

	init(defaults: UserDefaults = .standard) {
		self.defaults = defaults
	}

	var isActive: Bool { startedAt != nil }

	/// Where the call goes, as a conversation key ("channel:0", "user:123"). The primary channel
	/// until another is picked: in an emergency, anyone in range is who you want.
	var destinationKey: String {
		get { defaults.string(forKey: Keys.destination) ?? "channel:0" }
		set { defaults.set(newValue, forKey: Keys.destination); objectWillChange.send() }
	}

	var text: String {
		get { defaults.string(forKey: Keys.text) ?? sambungText("Butuh bantuan segera.") }
		set { defaults.set(newValue, forKey: Keys.text); objectWillChange.send() }
	}

	var interval: Int {
		get { Self.clampedInterval(defaults.object(forKey: Keys.interval) as? Int ?? Self.defaultInterval) }
		set { defaults.set(Self.clampedInterval(newValue), forKey: Keys.interval); objectWillChange.send() }
	}

	nonisolated static func clampedInterval(_ seconds: Int) -> Int { max(minInterval, seconds) }

	nonisolated static func isOver(startedAt: Date, now: Date) -> Bool {
		now.timeIntervalSince(startedAt) >= maxDuration
	}

	/// "🆘 SOS dari Budi: Butuh bantuan segera." and, when there is a position, the same
	/// location line a shared position uses, so Sambung draws it as a map.
	nonisolated static func message(name: String, text: String, coordinate: CLLocationCoordinate2D?) -> String {
		let call = "\u{07}🆘 SOS \(name): \(text.trimmingCharacters(in: .whitespacesAndNewlines))"
		guard let coordinate else { return call }
		return call + "\n" + SambungLocationMessage.text(for: coordinate)
	}

	/// The user number and channel a conversation key stands for, or nil for a key that is neither.
	nonisolated static func target(for key: String) -> (userNum: Int64, channel: Int32)? {
		let parts = key.split(separator: ":")
		guard parts.count == 2 else { return nil }
		switch parts[0] {
		case "user": return Int64(parts[1]).map { ($0, 0) }
		case "channel": return Int32(parts[1]).map { (0, $0) }
		default: return nil
		}
	}

	func start(accessoryManager: AccessoryManager, now: Date = Date()) {
		guard !isActive else { return }
		startedAt = now
		sentCount = 0
		lastError = nil
		loop = Task { [weak self] in
			while let self, let startedAt = self.startedAt, !Task.isCancelled {
				if Self.isOver(startedAt: startedAt, now: Date()) {
					self.stop()
					break
				}
				await self.sendOnce(accessoryManager: accessoryManager)
				try? await Task.sleep(for: .seconds(self.interval))
			}
		}
	}

	func stop() {
		loop?.cancel()
		loop = nil
		startedAt = nil
	}

	private func sendOnce(accessoryManager: AccessoryManager) async {
		guard accessoryManager.isConnected, let target = Self.target(for: destinationKey) else {
			lastError = sambungText("Belum tersambung ke radio.")
			return
		}
		let name = accessoryManager.activeConnection?.device.longName ?? "?"
		let message = Self.message(name: name, text: text, coordinate: LocationsHandler.currentLocation)
		do {
			try await accessoryManager.sendMessage(message: message, toUserNum: target.userNum, channel: target.channel, isEmoji: false, replyID: 0)
			sentCount += 1
			lastError = nil
		} catch {
			lastError = error.localizedDescription
			Logger.mesh.error("Sambung SOS was not sent: \(error.localizedDescription, privacy: .public)")
		}
	}
}
