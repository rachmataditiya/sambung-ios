//
//  SambungStore.swift
//  Sambung
//
//  Per-conversation state that Sambung adds on top of the upstream data model: pins, drafts
//  and quick replies. Kept in UserDefaults so the SwiftData schema stays identical to upstream.
//
import Foundation
import Combine

@MainActor
final class SambungStore: ObservableObject {
	static let shared = SambungStore()

	static let defaultQuickReplies = ["Aman", "Butuh bantuan", "Di jalan", "Sudah sampai", "Oke", "Tunggu sebentar"]

	private enum Keys {
		static let pinned = "sambung.pinned"
		static let drafts = "sambung.drafts"
		static let quickReplies = "sambung.quickReplies"
	}

	private let defaults: UserDefaults

	@Published private(set) var pinned: Set<String>
	@Published private(set) var drafts: [String: String]
	@Published var quickReplies: [String] {
		didSet { defaults.set(quickReplies, forKey: Keys.quickReplies) }
	}

	init(defaults: UserDefaults = .standard) {
		self.defaults = defaults
		pinned = Set(defaults.stringArray(forKey: Keys.pinned) ?? [])
		drafts = defaults.dictionary(forKey: Keys.drafts) as? [String: String] ?? [:]
		quickReplies = defaults.stringArray(forKey: Keys.quickReplies) ?? Self.defaultQuickReplies
	}

	func isPinned(_ key: String) -> Bool { pinned.contains(key) }

	func togglePin(_ key: String) {
		if pinned.contains(key) { pinned.remove(key) } else { pinned.insert(key) }
		defaults.set(pinned.sorted(), forKey: Keys.pinned)
	}

	func draft(for key: String) -> String { drafts[key] ?? "" }

	/// A draft that is only whitespace is dropped, so it does not show up in the inbox.
	func setDraft(_ text: String, for key: String) {
		let isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		guard drafts[key] != (isEmpty ? nil : text) else { return }
		drafts[key] = isEmpty ? nil : text
		defaults.set(drafts, forKey: Keys.drafts)
	}

	/// Forget everything kept for a conversation that was deleted.
	func forget(_ key: String) {
		setDraft("", for: key)
		if pinned.contains(key) { togglePin(key) }
	}
}

extension MessageDestination {
	/// Stable key for Sambung's per-conversation state.
	/// shortcut: channel keys are the slot index only, so two radios share state for the same
	/// slot; scope by radio if people start switching between several radios.
	var sambungKey: String {
		switch self {
		case let .user(user): return "user:\(user.num)"
		case let .channel(channel): return "channel:\(channel.index)"
		}
	}
}
