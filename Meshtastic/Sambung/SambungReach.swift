//
//  SambungReach.swift
//  Sambung
//
//  Turns what the radio knows about a node (last heard, hops, MQTT) into a plain statement
//  about whether a message is likely to get there.
//
import Foundation

struct SambungReach: Equatable {
	enum State: Equatable {
		/// Heard over radio within the online window.
		case reachable(hops: Int)
		/// Only heard through an internet (MQTT) bridge.
		case viaInternet
		/// Heard before, but not recently.
		case stale
		case neverHeard
	}

	/// Same window upstream uses for "online" on the node list.
	static let onlineWindow: TimeInterval = 120 * 60

	let state: State
	let lastHeard: Date?

	init(lastHeard: Date?, hopsAway: Int, viaMqtt: Bool, now: Date = Date()) {
		self.lastHeard = lastHeard
		guard let lastHeard, lastHeard.timeIntervalSince1970 > 0 else {
			state = .neverHeard
			return
		}
		if now.timeIntervalSince(lastHeard) > Self.onlineWindow {
			state = .stale
		} else if viaMqtt {
			state = .viaInternet
		} else {
			state = .reachable(hops: max(0, hopsAway))
		}
	}

	var isReachable: Bool {
		switch state {
		case .reachable, .viaInternet: return true
		case .stale, .neverHeard: return false
		}
	}

	/// Number of relays to draw between "you" and "them".
	var relayCount: Int {
		if case let .reachable(hops) = state { return min(hops, 4) }
		return 0
	}

	func summary(now: Date = Date()) -> String {
		switch state {
		case .neverHeard:
			return sambungText("Belum pernah terdengar")
		case .stale:
			return sambungText("Terakhir terdengar %@", Self.ago(lastHeard, now: now))
		case .viaInternet:
			return sambungText("Terdengar lewat internet, %@", Self.ago(lastHeard, now: now))
		case let .reachable(hops):
			let path = hops == 0 ? sambungText("Terdengar langsung") : sambungText("Lewat %lld perantara", hops)
			return "\(path), \(Self.ago(lastHeard, now: now))"
		}
	}

	static func ago(_ date: Date?, now: Date = Date()) -> String {
		guard let date else { return "" }
		let seconds = max(0, now.timeIntervalSince(date))
		switch seconds {
		case ..<60: return sambungText("baru saja")
		case ..<3600: return sambungText("%lld menit lalu", Int(seconds / 60))
		case ..<86_400: return sambungText("%lld jam lalu", Int(seconds / 3600))
		default: return sambungText("%lld hari lalu", Int(seconds / 86_400))
		}
	}
}
