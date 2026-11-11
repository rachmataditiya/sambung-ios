//
//  SambungNodeRow.swift
//  Sambung
//
//  A node in the Jaringan list: who it is and whether a message would get there. The radio's
//  technical detail (role, logs, keys) lives on the node's own screen.
//
import SwiftData
import SwiftUI

struct SambungNodeRow: View {
	let node: NodeInfoEntity
	/// The radio this phone is connected to.
	let isOwnRadio: Bool

	var body: some View {
		let reach = SambungReach(lastHeard: node.lastHeard, hopsAway: Int(node.hopsAway), viaMqtt: node.viaMqtt)
		let name = node.user?.displayLongName ?? "?"
		HStack(spacing: 12) {
			SambungAvatar(kind: .user(shortName: node.user?.shortName ?? "?", num: node.num))
				.opacity(reach.isReachable || isOwnRadio ? 1 : 0.55)
			VStack(alignment: .leading, spacing: 3) {
				HStack(spacing: 6) {
					Text(verbatim: name)
						.font(.sambungName())
						.lineLimit(1)
					if node.favorite {
						Image(systemName: "star.fill")
							.font(.caption2)
							.foregroundStyle(SambungTheme.kunyit)
							.accessibilityLabel("Favorit")
					}
					Spacer(minLength: 8)
					if let battery = node.latestDeviceMetrics?.batteryLevel {
						// Above 100 is how the firmware reports "on external power".
						Label {
							Text(verbatim: battery > 100 ? sambungText("Daya luar") : "\(battery)%")
						} icon: {
							Image(systemName: battery > 100 ? "powerplug" : battery > 50 ? "battery.75percent" : "battery.25percent")
						}
						.labelStyle(.titleAndIcon)
						.font(.caption)
						.foregroundStyle(.secondary)
					}
				}
				if SambungContacts.isContact(node.num), let radioName = node.user?.longName {
					Text(verbatim: radioName)
						.font(.caption)
						.foregroundStyle(.secondary)
						.lineLimit(1)
				}
				HStack(spacing: 8) {
					if isOwnRadio {
						Text("Radio kamu")
					} else {
						SambungReachThread(reach: reach)
						Text(verbatim: reach.summary())
					}
				}
				.font(.footnote)
				.foregroundStyle(.secondary)
				.lineLimit(1)
			}
		}
		.padding(.vertical, 4)
		.accessibilityElement(children: .combine)
	}
}

/// The top of a node's screen: the person first, then what you can do, before the radio's detail.
struct SambungNodeHeader: View {
	@EnvironmentObject private var accessoryManager: AccessoryManager
	@Environment(\.openURL) private var openURL
	let node: NodeInfoEntity
	@State private var userToSave: UserEntity?
	@State private var contactsRevision = 0

	var body: some View {
		let reach = SambungReach(lastHeard: node.lastHeard, hopsAway: Int(node.hopsAway), viaMqtt: node.viaMqtt)
		let isOwnRadio = node.num == accessoryManager.activeDeviceNum
		let isContact = contactsRevision >= 0 && SambungContacts.isContact(node.num)
		Section {
			VStack(spacing: 10) {
				SambungAvatar(kind: .user(shortName: node.user?.shortName ?? "?", num: node.num), size: 76)
				VStack(spacing: 2) {
					Text(verbatim: node.user?.displayLongName ?? "?")
						.font(.sambungName(.title2))
						.multilineTextAlignment(.center)
					if isContact, let radioName = node.user?.longName {
						Text(verbatim: radioName).font(.subheadline).foregroundStyle(.secondary)
					}
				}
				HStack(spacing: 8) {
					if isOwnRadio {
						Text("Radio kamu")
					} else {
						SambungReachThread(reach: reach)
						Text(verbatim: reach.summary())
					}
				}
				.font(.footnote)
				.foregroundStyle(.secondary)

				if !isOwnRadio, let user = node.user {
					HStack(spacing: 10) {
						if user.showsDirectMessageAction {
							Button {
								if let url = URL(string: "meshtastic:///messages?userNum=\(node.num)") { openURL(url) }
							} label: {
								Label("Pesan", systemImage: "bubble.left.fill").frame(maxWidth: .infinity)
							}
							.buttonStyle(.borderedProminent)
						}
						Button {
							userToSave = user
						} label: {
							Label(isContact ? sambungText("Ubah kontak") : sambungText("Simpan kontak"), systemImage: "person.crop.circle.badge.plus").frame(maxWidth: .infinity)
						}
						.buttonStyle(.bordered)
					}
					.buttonBorderShape(.capsule)
					.controlSize(.large)
					.padding(.top, 4)
				}
			}
			.frame(maxWidth: .infinity)
			.listRowBackground(Color.clear)
			.listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
		}
		.sambungContactAlert(user: $userToSave)
		.onReceive(NotificationCenter.default.publisher(for: NodeDisplayNameStore.didChangeNotification)) { _ in
			contactsRevision += 1
		}
	}
}
