//
//  SambungInbox.swift
//  Sambung
//
//  One list for every conversation, channels and direct messages together, newest first with
//  pinned ones on top. Replaces upstream's two-level Channels / Direct Messages split.
//
import OSLog
import SwiftData
import SwiftUI

enum SambungRoute: Hashable {
	case channel(index: Int32)
	case user(num: Int64)
}

/// A row in the inbox. Built from the upstream entities on every refresh.
struct SambungConversationItem: Identifiable {
	enum Target {
		case channel(ChannelEntity)
		case user(UserEntity)
	}

	let target: Target
	let key: String
	let title: String
	let preview: String
	let timestamp: Int32
	let unread: Int
	let isMuted: Bool

	var id: String { key }

	var route: SambungRoute {
		switch target {
		case let .channel(channel): return .channel(index: channel.index)
		case let .user(user): return .user(num: user.num)
		}
	}

	/// Pinned first, then newest. Conversations without messages keep their natural order last.
	static func sorted(_ items: [SambungConversationItem], pinned: Set<String>) -> [SambungConversationItem] {
		items.sorted { lhs, rhs in
			let lhsPinned = pinned.contains(lhs.key), rhsPinned = pinned.contains(rhs.key)
			if lhsPinned != rhsPinned { return lhsPinned }
			if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
			return lhs.key < rhs.key
		}
	}
}

struct SambungInbox: View {
	@Environment(\.modelContext) private var context
	@EnvironmentObject private var accessoryManager: AccessoryManager
	@EnvironmentObject private var appState: AppState
	@ObservedObject var router: Router
	@ObservedObject private var store = SambungStore.shared

	@Query(sort: [SortDescriptor(\UserEntity.lastMessage, order: .reverse)])
	private var allUsers: [UserEntity]

	@Environment(\.horizontalSizeClass) private var sizeClass
	/// The open conversation. A stack on a phone; on a Mac or iPad its last entry is the selection.
	@State private var path: [SambungRoute] = []
	@State private var summaries: [Int64: DirectMessageSummary] = [:]
	@State private var channelItems: [SambungConversationItem] = []
	@State private var searchText = ""
	@State private var isPickingContact = false
	@State private var itemToDelete: SambungConversationItem?
	#if DEBUG
	@State private var didDebugOpen = false
	#endif

	private var connectedNode: NodeInfoEntity? {
		let num = Int64(UserDefaults.preferredPeripheralNum)
		return num > 0 ? getNodeInfo(id: num, context: context) : nil
	}

	private var items: [SambungConversationItem] {
		let activeNum = Int64(accessoryManager.activeDeviceNum ?? 0)
		let userItems: [SambungConversationItem] = allUsers.compactMap { user in
			guard user.num != activeNum, user.lastMessage != nil, let summary = summaries[user.num] else { return nil }
			return SambungConversationItem(
				target: .user(user),
				key: MessageDestination.user(user).sambungKey,
				title: user.displayLongName,
				preview: summary.payload,
				timestamp: summary.timestamp,
				unread: summary.unreadCount,
				isMuted: user.mute
			)
		}
		let all = SambungConversationItem.sorted(channelItems + userItems, pinned: store.pinned)
		let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !query.isEmpty else { return all }
		return all.filter {
			$0.title.localizedStandardContains(query) || $0.preview.localizedStandardContains(query)
		}
	}

	var body: some View {
		Group {
			if sizeClass == .regular { splitLayout } else { stackLayout }
		}
		.sheet(isPresented: $isPickingContact) {
			SambungContactPicker { user in
				isPickingContact = false
				path = [.user(num: user.num)]
			}
		}
		.confirmationDialog(
			"Hapus percakapan ini?",
			isPresented: Binding(get: { itemToDelete != nil }, set: { if !$0 { itemToDelete = nil } }),
			titleVisibility: .visible
		) {
			Button("Hapus pesan", role: .destructive) {
				if let item = itemToDelete { delete(item) }
			}
		} message: {
			Text("Pesan dihapus dari HP ini saja. Orang lain tetap menyimpannya.")
		}
		.task(id: refreshID) { await refresh() }
		.onReceive(
			NotificationCenter.default.publisher(for: .meshMessagesDidChange)
				.debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
		) { _ in
			Task { await refresh() }
		}
		.onAppear { consumeDeepLink(router.messagesState) }
		.onChange(of: router.messagesState) { _, state in consumeDeepLink(state) }
	}

	/// iPhone: the inbox pushes the conversation.
	private var stackLayout: some View {
		NavigationStack(path: $path) {
			inbox(asSidebar: false)
				.navigationDestination(for: SambungRoute.self) { route in
					SambungConversation(route: route)
						// A conversation takes the whole screen; the tab bar comes back with the inbox.
						.toolbar(.hidden, for: .tabBar)
				}
				.navigationDestination(for: Int64.self) { nodeDetail($0) }
		}
	}

	/// Mac and iPad: the inbox stays on the left, the conversation opens beside it.
	private var splitLayout: some View {
		NavigationSplitView {
			inbox(asSidebar: true)
				.navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 420)
		} detail: {
			NavigationStack {
				Group {
					if let route = path.last {
						SambungConversation(route: route)
							.id(route)
					} else {
						ContentUnavailableView(
							"Pilih percakapan",
							systemImage: "bubble.left.and.bubble.right",
							description: Text("Pesan dari percakapan yang dipilih tampil di sini.")
						)
					}
				}
				.navigationDestination(for: Int64.self) { nodeDetail($0) }
			}
		}
		.navigationSplitViewStyle(.balanced)
	}

	private func inbox(asSidebar: Bool) -> some View {
		list(asSidebar: asSidebar)
			.navigationTitle("Chat")
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					Button {
						isPickingContact = true
					} label: {
						Label("Pesan baru", systemImage: "square.and.pencil")
					}
				}
			}
			.searchable(text: $searchText, prompt: "Cari percakapan")
	}

	@ViewBuilder
	private func nodeDetail(_ nodeNum: Int64) -> some View {
		if let node = getNodeInfo(id: nodeNum, context: context) {
			NodeDetail(node: node, nodeNum: nodeNum)
				.trackScreen(.nodeDetail)
		}
	}

	private var selectedRoute: Binding<SambungRoute?> {
		Binding(get: { path.last }, set: { path = $0.map { [$0] } ?? [] })
	}

	@ViewBuilder
	private func list(asSidebar: Bool) -> some View {
		let visible = items
		Group {
			if asSidebar {
				List(selection: selectedRoute) { rows(visible, asSidebar: true) }
			} else {
				List { rows(visible, asSidebar: false) }
			}
		}
		.listStyle(.plain)
		.overlay {
			if visible.isEmpty {
				if searchText.isEmpty {
					ContentUnavailableView(
						"Belum ada percakapan",
						systemImage: "bubble.left.and.bubble.right",
						description: Text("Sambungkan radio, lalu kirim pesan pertama ke channel atau ke satu orang.")
					)
				} else {
					ContentUnavailableView.search(text: searchText)
				}
			}
		}
	}

	@ViewBuilder
	private func rows(_ visible: [SambungConversationItem], asSidebar: Bool) -> some View {
		if !accessoryManager.isConnected {
			SambungLinkBanner(router: router)
				.listRowSeparator(.hidden)
				.listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
		}
		ForEach(visible) { item in
			let row = SambungInboxRow(item: item, isPinned: store.isPinned(item.key), draft: store.draft(for: item.key))
			Group {
				if asSidebar { row.tag(item.route) } else { NavigationLink(value: item.route) { row } }
			}
			.swipeActions(edge: .leading, allowsFullSwipe: true) {
				pinButton(item).tint(SambungTheme.kunyit)
			}
			.swipeActions(edge: .trailing) {
				deleteButton(item)
				muteButton(item)
			}
			// The same actions for a mouse (right-click) and for a long press.
			.contextMenu {
				pinButton(item)
				muteButton(item)
				deleteButton(item)
			}
		}
	}

	private func pinButton(_ item: SambungConversationItem) -> some View {
		Button {
			store.togglePin(item.key)
		} label: {
			Label(store.isPinned(item.key) ? "Lepas pin" : "Pin", systemImage: store.isPinned(item.key) ? "pin.slash" : "pin")
		}
	}

	private func muteButton(_ item: SambungConversationItem) -> some View {
		Button {
			toggleMute(item)
		} label: {
			Label(item.isMuted ? "Bunyikan" : "Senyapkan", systemImage: item.isMuted ? "bell" : "bell.slash")
		}
	}

	private func deleteButton(_ item: SambungConversationItem) -> some View {
		Button(role: .destructive) {
			itemToDelete = item
		} label: {
			Label("Hapus", systemImage: "trash")
		}
	}

	// MARK: - Data

	private var refreshID: String {
		"\(accessoryManager.activeDeviceNum ?? 0)-\(appState.totalUnreadMessages)-\(allUsers.count)-\(PersistenceController.shared.containerGeneration)"
	}

	@MainActor
	private func refresh() async {
		channelItems = buildChannelItems()
		#if DEBUG
		// Screenshot tooling: SAMBUNG_OPEN=channel opens the first channel on a simulator launch.
		if ProcessInfo.processInfo.environment["SAMBUNG_OPEN"] == "channel", path.isEmpty, !didDebugOpen, let first = channelItems.first {
			didDebugOpen = true
			path = [first.route]
		}
		#endif
		let activeNum = Int64(accessoryManager.activeDeviceNum ?? 0)
		let userNums = Set(allUsers.filter { $0.num != activeNum && $0.lastMessage != nil }.map(\.num))
		guard !userNums.isEmpty else {
			summaries = [:]
			return
		}
		do {
			let actor = DirectMessageSummaryActor(modelContainer: context.container)
			let result = try await actor.summaries(for: userNums)
			guard !Task.isCancelled else { return }
			summaries = result
		} catch is CancellationError {
			return
		} catch {
			Logger.data.error("Sambung inbox: failed to load summaries: \(error.localizedDescription, privacy: .public)")
		}
	}

	private func buildChannelItems() -> [SambungConversationItem] {
		guard let myInfo = connectedNode?.myInfo else { return [] }
		var byIndex: [Int32: ChannelEntity] = [:]
		for channel in myInfo.channels { byIndex[channel.index] = channel }
		return byIndex.values
			.filter { !ChannelEntity.isReservedModuleName($0.name ?? "") }
			.map { channel in
				let latest = channel.mostRecentPrivateMessage
				return SambungConversationItem(
					target: .channel(channel),
					key: MessageDestination.channel(channel).sambungKey,
					title: Self.title(for: channel),
					preview: latest?.messagePayload ?? "",
					timestamp: latest?.messageTimestamp ?? 0,
					unread: channel.unreadMessages(context: context),
					isMuted: channel.mute
				)
			}
	}

	static func title(for channel: ChannelEntity) -> String {
		if let name = channel.name, !name.isEmpty { return name }
		return channel.role == 1 ? "Channel utama" : "Channel \(channel.index)"
	}

	// MARK: - Actions

	private func toggleMute(_ item: SambungConversationItem) {
		switch item.target {
		case let .user(user):
			user.mute.toggle()
		case let .channel(channel):
			channel.mute.toggle()
			// The radio keeps the channel's mute flag too, same as upstream's channel list.
			if let user = connectedNode?.user {
				Task {
					_ = try? await accessoryManager.saveChannel(
						channel: channel.protoBuf, fromUser: user, toUser: user, refreshShareSnapshot: true
					)
				}
			}
		}
		try? context.save()
		Task { await refresh() }
	}

	private func delete(_ item: SambungConversationItem) {
		let key = item.key
		Task {
			switch item.target {
			case let .user(user):
				await MeshPackets.shared.deleteUserMessages(userNum: user.num)
			case let .channel(channel):
				await MeshPackets.shared.deleteChannelMessages(channel: channel)
			}
			await MainActor.run {
				store.forget(key)
				itemToDelete = nil
			}
			await refresh()
		}
	}

	/// Notifications, links and Siri all land here through the router's one-shot state.
	private func consumeDeepLink(_ state: MessagesNavigationState?) {
		guard let state else { return }
		switch state {
		case let .channels(channelId, _):
			if let channelId {
				guard let channel = connectedNode?.myInfo?.channels.first(where: { $0.id == channelId }) else {
					return // Not resolvable yet; keep the payload and retry on the next appear.
				}
				path = [.channel(index: channel.index)]
			} else {
				path = []
			}
		case let .directMessages(userNum, _):
			path = userNum.map { [.user(num: $0)] } ?? []
		}
		router.messagesState = nil
	}
}

private struct SambungInboxRow: View {
	let item: SambungConversationItem
	let isPinned: Bool
	let draft: String

	var body: some View {
		HStack(spacing: 12) {
			avatar
			VStack(alignment: .leading, spacing: 3) {
				HStack(alignment: .firstTextBaseline) {
					Text(item.title)
						.font(.sambungName())
						.lineLimit(1)
					if isPinned {
						Image(systemName: "pin.fill")
							.font(.caption2)
							.foregroundStyle(SambungTheme.kunyit)
							.accessibilityLabel("Dipin")
					}
					if item.isMuted {
						Image(systemName: "bell.slash.fill")
							.font(.caption2)
							.foregroundStyle(.secondary)
							.accessibilityLabel("Disenyapkan")
					}
					Spacer(minLength: 8)
					if item.timestamp > 0 {
						Text(Self.timeText(item.timestamp))
							.font(.footnote)
							.foregroundStyle(item.unread > 0 ? SambungTheme.kunyit : Color.secondary)
					}
				}
				HStack(alignment: .top) {
					previewText
						.font(.subheadline)
						.lineLimit(2)
					Spacer(minLength: 8)
					if item.unread > 0 {
						Text(verbatim: item.unread > 99 ? "99+" : "\(item.unread)")
							.font(.caption.weight(.bold))
							.monospacedDigit()
							.foregroundStyle(.black)
							.padding(.horizontal, 7)
							.padding(.vertical, 2)
							.background(SambungTheme.kunyit, in: Capsule())
							.accessibilityLabel("\(item.unread) belum dibaca")
					}
				}
			}
		}
		.padding(.vertical, 4)
	}

	@ViewBuilder
	private var avatar: some View {
		switch item.target {
		case let .user(user):
			SambungAvatar(kind: .user(shortName: user.shortName ?? "?", num: user.num))
		case .channel:
			SambungAvatar(kind: .channel(name: item.title))
		}
	}

	private var previewText: Text {
		if !draft.isEmpty {
			return Text("Draf: ").foregroundStyle(SambungTheme.bata) + Text(verbatim: draft).foregroundStyle(.secondary)
		}
		if item.preview.isEmpty {
			return Text("Belum ada pesan").foregroundStyle(.tertiary)
		}
		return Text(verbatim: item.preview).foregroundStyle(.secondary)
	}

	static func timeText(_ timestamp: Int32, now: Date = Date(), calendar: Calendar = .current) -> String {
		let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
		if calendar.isDate(date, inSameDayAs: now) {
			return date.formatted(date: .omitted, time: .shortened)
		}
		if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
			return "Kemarin"
		}
		return date.formatted(date: .numeric, time: .omitted)
	}
}

/// Shown at the top of the inbox while no radio is connected.
private struct SambungLinkBanner: View {
	@ObservedObject var router: Router

	var body: some View {
		Button {
			router.selectedTab = .connect
		} label: {
			HStack(spacing: 12) {
				Image(systemName: "antenna.radiowaves.left.and.right.slash")
					.font(.title3)
					.foregroundStyle(SambungTheme.bata)
				VStack(alignment: .leading, spacing: 2) {
					Text("Belum tersambung ke radio")
						.font(.subheadline.weight(.semibold))
						.foregroundStyle(.primary)
					Text("Pesan baru belum bisa dikirim atau diterima. Ketuk untuk menyambungkan.")
						.font(.footnote)
						.foregroundStyle(.secondary)
						.multilineTextAlignment(.leading)
				}
				Spacer(minLength: 0)
			}
			.padding(12)
			.background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
		}
		.buttonStyle(.plain)
	}
}

/// Pick someone on the mesh to start a direct message with.
private struct SambungContactPicker: View {
	@EnvironmentObject private var accessoryManager: AccessoryManager
	@Environment(\.dismiss) private var dismiss
	@Query(sort: [SortDescriptor(\UserEntity.longName)]) private var users: [UserEntity]
	@State private var searchText = ""
	let onPick: (UserEntity) -> Void

	private var visible: [UserEntity] {
		let activeNum = Int64(accessoryManager.activeDeviceNum ?? 0)
		let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
		return users.filter { user in
			user.num != activeNum && (query.isEmpty
				|| user.displayLongName.localizedStandardContains(query)
				|| (user.shortName ?? "").localizedStandardContains(query))
		}
	}

	var body: some View {
		NavigationStack {
			List(visible) { user in
				Button {
					onPick(user)
				} label: {
					HStack(spacing: 12) {
						SambungAvatar(kind: .user(shortName: user.shortName ?? "?", num: user.num), size: 40)
						VStack(alignment: .leading, spacing: 2) {
							Text(user.displayLongName).font(.sambungName(.body)).foregroundStyle(.primary)
							if let node = user.userNode {
								Text(SambungReach(lastHeard: node.lastHeard, hopsAway: Int(node.hopsAway), viaMqtt: node.viaMqtt).summary())
									.font(.footnote)
									.foregroundStyle(.secondary)
							}
						}
					}
				}
			}
			.listStyle(.plain)
			.overlay {
				if visible.isEmpty {
					ContentUnavailableView(
						"Belum ada orang di jaringan",
						systemImage: "person.2.slash",
						description: Text("Daftar ini terisi sendiri saat radio mendengar node lain.")
					)
				}
			}
			.searchable(text: $searchText, prompt: "Cari nama")
			.navigationTitle("Pesan baru")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Batal") { dismiss() }
				}
			}
		}
	}
}
