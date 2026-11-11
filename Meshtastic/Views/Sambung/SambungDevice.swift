//
//  SambungDevice.swift
//  Sambung
//
//  The top of the Perangkat tab: the radio link as a card, then Sambung's own settings. The
//  rest of that screen is upstream's settings list, which this is placed into.
//
import SwiftUI

struct SambungDeviceSection: View {
	@EnvironmentObject private var accessoryManager: AccessoryManager
	@ObservedObject var router: Router
	@AppStorage(SambungOutbox.enabledKey) private var autoResend = true
	@State private var isShowingContacts = false
	@State private var isEditingQuickReplies = false

	var body: some View {
		Section {
			Button {
				router.selectedTab = .connect
			} label: {
				linkSummary
			}
			.accessibilityHint("Membuka sambungan radio")
		}

		Section("Sambung") {
			Button {
				isShowingContacts = true
			} label: {
				Label("Kontak", systemImage: "person.crop.circle")
			}
			.tint(Color(.label)) // reads as a row like the links below, not as an action
			.sheet(isPresented: $isShowingContacts) {
				NavigationStack { SambungContactList().sheetCloseButton() }
			}
			Button {
				isEditingQuickReplies = true
			} label: {
				Label("Balasan cepat", systemImage: "text.bubble")
			}
			.tint(Color(.label))
			.sheet(isPresented: $isEditingQuickReplies) { SambungQuickReplyEditor() }
			Toggle(isOn: $autoResend) {
				Label("Kirim ulang otomatis", systemImage: "arrow.clockwise")
					.labelStyle(SambungSettingsLabelStyle())
			}
		}
	}

	private var linkSummary: some View {
		let device = accessoryManager.isConnected || accessoryManager.isConnecting ? accessoryManager.activeConnection?.device : nil
		return HStack(spacing: 14) {
			if let device {
				SambungAvatar(kind: .user(shortName: device.shortName ?? "?", num: device.num ?? 0), size: 52)
			} else {
				Image(systemName: "antenna.radiowaves.left.and.right.slash")
					.font(.title2)
					.foregroundStyle(.secondary)
					.frame(width: 52, height: 52)
					.background(Color(.tertiarySystemFill), in: Circle())
			}
			VStack(alignment: .leading, spacing: 3) {
				Text(verbatim: device.map { $0.longName ?? $0.name } ?? String(localized: "Belum tersambung"))
					.font(.sambungName(.title3))
					.foregroundStyle(Color(.label))
					.lineLimit(1)
				Text(verbatim: device == nil ? String(localized: "Ketuk untuk memilih radio") : accessoryManager.sambungStateText)
					.font(.subheadline)
					.foregroundStyle(accessoryManager.isConnected ? SambungTheme.daun : Color.secondary)
			}
			Spacer(minLength: 8)
			Image(systemName: "chevron.right")
				.font(.footnote.weight(.semibold))
				.foregroundStyle(.tertiary)
		}
		.padding(.vertical, 6)
		.contentShape(Rectangle())
	}
}

/// Settings rows: a white symbol on a small accent square, the way iOS Settings draws them.
struct SambungSettingsLabelStyle: LabelStyle {
	func makeBody(configuration: Configuration) -> some View {
		HStack(spacing: 12) {
			configuration.icon
				.font(.system(size: 15, weight: .semibold))
				.foregroundStyle(.white)
				.frame(width: 30, height: 30)
				.background(Color.accentFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
			configuration.title
		}
	}
}

extension View {
	/// Pushes the connection screen on the settings stack while the router is on `.connect`.
	func sambungConnectDestination(router: Router) -> some View {
		modifier(SambungConnectDestination(router: router))
	}
}

private struct SambungConnectDestination: ViewModifier {
	@ObservedObject var router: Router

	func body(content: Content) -> some View {
		content.navigationDestination(
			isPresented: Binding(get: { router.selectedTab == .connect }, set: { router.selectedTab = $0 ? .connect : .settings })
		) {
			SambungConnect(router: router)
				.trackScreen(NavigationState.Tab.connect.screenName)
		}
	}
}
