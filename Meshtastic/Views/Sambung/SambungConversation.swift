//
//  SambungConversation.swift
//  Sambung
//
//  Opens a conversation from the inbox. The message list itself is upstream's (paging, search,
//  reactions and read state are already right there); Sambung adds the reach bar on top.
//
import SwiftData
import SwiftUI

struct SambungConversation: View {
	@Environment(\.modelContext) private var context
	let route: SambungRoute
	@State private var isFinding = false

	var body: some View {
		content
			.environment(\.sambungIsFinding, $isFinding)
			.onAppear { SambungVoicePlayback.shared.open = route }
			.onDisappear {
				if SambungVoicePlayback.shared.open == route { SambungVoicePlayback.shared.open = nil }
			}
	}

	@ViewBuilder
	private var content: some View {
		switch route {
		case let .channel(index):
			let myInfo = connectedNode?.myInfo
			if let myInfo, let channel = myInfo.channels.first(where: { $0.index == index }) {
				ChannelMessageList(myInfo: myInfo, channel: channel)
					.id(channel.persistentModelID)
					.trackScreen(.channelMessages)
					// Not shown (the title item is), but it names the back button of the next screen.
					.navigationTitle(SambungInbox.title(for: channel))
					.safeAreaInset(edge: .top, spacing: 0) { SambungChannelReachBar() }
			} else {
				ContentUnavailableView(
					"Channel tidak ada di radio ini",
					systemImage: "antenna.radiowaves.left.and.right.slash",
					description: Text("Sambungkan radio yang memakai channel ini untuk membukanya.")
				)
			}
		case let .user(num):
			let user = getUser(id: num, context: context)
			UserMessageList(user: user)
				.id(user.persistentModelID)
				.trackScreen(.directMessages)
				.navigationTitle(user.displayLongName)
				.safeAreaInset(edge: .top, spacing: 0) { SambungUserReachBar(user: user) }
		}
	}

	private var connectedNode: NodeInfoEntity? {
		let num = Int64(UserDefaults.preferredPeripheralNum)
		return num > 0 ? getNodeInfo(id: num, context: context) : nil
	}
}

/// "Can this person hear me right now?" in one line under the title.
private struct SambungUserReachBar: View {
	@Bindable var user: UserEntity

	var body: some View {
		let node = user.userNode
		let reach = SambungReach(lastHeard: node?.lastHeard, hopsAway: Int(node?.hopsAway ?? 0), viaMqtt: node?.viaMqtt ?? false)
		TimelineView(.periodic(from: .now, by: 60)) { timeline in
			SambungReachBarLayout(reach: reach, text: reach.summary(now: timeline.date))
		}
	}
}

/// For a channel there is no single recipient, so say how many nodes are in earshot.
private struct SambungChannelReachBar: View {
	@Environment(\.modelContext) private var context
	@EnvironmentObject private var accessoryManager: AccessoryManager
	@State private var heardCount = 0

	var body: some View {
		let reach = SambungReach(lastHeard: heardCount > 0 ? Date() : nil, hopsAway: 0, viaMqtt: false)
		SambungReachBarLayout(
			reach: reach,
			text: heardCount > 0 ? sambungText("%lld node terdengar dalam 2 jam terakhir", heardCount) : sambungText("Belum ada node lain yang terdengar")
		)
		.task(id: accessoryManager.activeDeviceNum) {
			while !Task.isCancelled {
				heardCount = countHeardNodes()
				try? await Task.sleep(for: .seconds(60))
			}
		}
	}

	private func countHeardNodes() -> Int {
		let activeNum = accessoryManager.activeDeviceNum ?? 0
		let nodes = (try? context.fetch(FetchDescriptor<NodeInfoEntity>())) ?? []
		return nodes.filter { $0.num != activeNum && $0.isOnline }.count
	}
}

private struct SambungReachBarLayout: View {
	let reach: SambungReach
	let text: String

	var body: some View {
		HStack(spacing: 10) {
			SambungReachThread(reach: reach)
			Text(verbatim: text)
				.font(.footnote)
				.foregroundStyle(.secondary)
				.lineLimit(1)
				.minimumScaleFactor(0.8)
			Spacer(minLength: 0)
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 7)
		.background(.bar)
		.accessibilityElement(children: .ignore)
		.accessibilityLabel(Text(verbatim: text))
	}
}

// MARK: - Title and find

private struct SambungIsFindingKey: EnvironmentKey {
	static let defaultValue: Binding<Bool> = .constant(false)
}

extension EnvironmentValues {
	/// Whether the find field of the conversation on screen is open.
	var sambungIsFinding: Binding<Bool> {
		get { self[SambungIsFindingKey.self] }
		set { self[SambungIsFindingKey.self] = newValue }
	}
}

/// The conversation's name in the navigation bar. Tap it for what you can do with the conversation.
struct SambungConversationTitle: View {
	enum Kind {
		case user(UserEntity)
		case channel(name: String)
	}

	let kind: Kind
	@Environment(\.sambungIsFinding) private var isFinding
	@State private var userToSave: UserEntity?
	@State private var contactsRevision = 0

	var body: some View {
		Menu {
			Button {
				isFinding.wrappedValue = true
			} label: {
				Label("Cari di percakapan", systemImage: "magnifyingglass")
			}
			if case let .user(user) = kind {
				Button {
					userToSave = user
				} label: {
					Label(SambungContacts.isContact(user.num) ? sambungText("Ubah kontak") : sambungText("Simpan kontak"), systemImage: "person.crop.circle.badge.plus")
				}
			}
		} label: {
			HStack(spacing: 8) {
				switch kind {
				case let .user(user):
					SambungAvatar(kind: .user(shortName: user.shortName ?? "?", num: user.num), size: 34)
				case let .channel(name):
					SambungAvatar(kind: .channel(name: name), size: 34)
				}
				VStack(alignment: .leading, spacing: 0) {
					Text(verbatim: name).font(.sambungName(.headline)).lineLimit(1)
					if let radioName {
						Text(verbatim: radioName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
					}
				}
				Image(systemName: "chevron.down")
					.font(.caption2.weight(.bold))
					.foregroundStyle(.secondary)
			}
			.foregroundStyle(Color(.label))
		}
		.accessibilityLabel(Text(verbatim: name))
		.accessibilityHint("Membuka pilihan percakapan")
		.sambungContactAlert(user: $userToSave)
		.onReceive(NotificationCenter.default.publisher(for: NodeDisplayNameStore.didChangeNotification)) { _ in
			contactsRevision += 1
		}
	}

	private var name: String {
		_ = contactsRevision
		switch kind {
		case let .user(user): return user.displayLongName
		case let .channel(name): return name
		}
	}

	/// For a saved contact, the radio's own name goes underneath.
	private var radioName: String? {
		_ = contactsRevision
		guard case let .user(user) = kind, SambungContacts.isContact(user.num) else { return nil }
		return user.longName
	}
}

extension View {
	/// The find field of a conversation: a bar under the navigation bar, shown only while finding.
	func sambungFind(text: Binding<String>) -> some View {
		modifier(SambungFind(text: text))
	}
}

private struct SambungFind: ViewModifier {
	@Environment(\.sambungIsFinding) private var isFinding
	@Binding var text: String
	@FocusState private var isFocused: Bool

	func body(content: Content) -> some View {
		content.safeAreaInset(edge: .top, spacing: 0) {
			if isFinding.wrappedValue {
				HStack(spacing: 8) {
					Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
					TextField("Cari di percakapan", text: $text)
						.focused($isFocused)
						.submitLabel(.search)
						.autocorrectionDisabled()
						.textInputAutocapitalization(.never)
					Button("Tutup") {
						text = ""
						isFinding.wrappedValue = false
					}
				}
				.padding(.horizontal, 16)
				.padding(.vertical, 9)
				.background(.bar)
				.onAppear { isFocused = true }
			}
		}
	}
}
