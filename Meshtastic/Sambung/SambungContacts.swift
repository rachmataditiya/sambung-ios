//
//  SambungContacts.swift
//  Sambung
//
//  A contact is a node you gave a real name. The name is upstream's local display name
//  (NodeDisplayNameStore), so every screen that already shows it picks the contact name up;
//  it stays on this phone and is never sent over the mesh.
//
import Foundation
import OSLog

enum SambungContacts {
	static func isContact(_ nodeNum: Int64) -> Bool {
		NodeDisplayNameStore.displayName(for: nodeNum) != nil
	}

	/// Contacts first, the rest after; each part keeps the order it came in.
	static func split<T>(_ items: [T], nodeNum: (T) -> Int64) -> (contacts: [T], others: [T]) {
		var contacts: [T] = [], others: [T] = []
		for item in items {
			if isContact(nodeNum(item)) { contacts.append(item) } else { others.append(item) }
		}
		return (contacts, others)
	}

	/// Saves or clears the name. A saved contact is also marked favourite on the radio, which
	/// keeps the radio from dropping the node when its node list fills up.
	@MainActor
	static func save(_ name: String, for user: UserEntity, accessoryManager: AccessoryManager) {
		let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
		NodeDisplayNameStore.setDisplayName(trimmed.isEmpty ? nil : trimmed, for: user.num)
		guard !trimmed.isEmpty, let node = user.userNode, !node.favorite,
			  accessoryManager.isConnected, let me = accessoryManager.activeDeviceNum else { return }
		node.favorite = true
		Task {
			do {
				try await accessoryManager.setFavoriteNode(node: node, connectedNodeNum: me)
			} catch {
				Logger.mesh.error("Sambung contact: could not favourite the node: \(error.localizedDescription, privacy: .public)")
			}
		}
	}
}
