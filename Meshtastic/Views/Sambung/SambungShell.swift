//
//  SambungShell.swift
//  Sambung
//
//  Four tabs and a search button: Chat, Jaringan (nodes), Peta (map), Perangkat (connection +
//  settings). The router keeps its five-way `selectedTab`, so deep links, notifications and
//  upstream code that switches tabs keep working; `.settings` and `.connect` both land on
//  Perangkat.
//
import SwiftData
import SwiftUI

struct SambungShell: View {
	@ObservedObject var appState: AppState
	@ObservedObject var router: Router
	@EnvironmentObject private var accessoryManager: AccessoryManager
	/// ContentView's side-effecting binding (tap the current tab again to pop to root).
	let tabSelection: Binding<NavigationState.Tab>

	enum Section: Hashable {
		case chat, network, map, device, search

		init(_ tab: NavigationState.Tab) {
			switch tab {
			case .messages: self = .chat
			case .nodes: self = .network
			case .map: self = .map
			case .settings, .connect: self = .device
			}
		}
	}

	/// The open conversation; lives here so tapping Chat again can close it.
	@State private var chat = SambungChatNavigation()
	/// Search is not one of the router's tabs, so the shell remembers it.
	@State private var isSearching = false

	private var selection: Binding<Section> {
		Binding(
			get: { isSearching ? .search : Section(router.selectedTab) },
			set: { section in
				let wasShowing = isSearching ? Section.search : Section(router.selectedTab)
				isSearching = section == .search
				switch section {
				case .chat:
					if wasShowing == .chat { chat.popToRoot() }
					tabSelection.wrappedValue = .messages
				case .network: tabSelection.wrappedValue = .nodes
				case .map: tabSelection.wrappedValue = .map
				case .device:
					// Tapping Perangkat again goes back to its first screen.
					if wasShowing == .device { router.popToRoot(tab: .settings) }
					router.selectedTab = .settings
				case .search: break
				}
			}
		)
	}

	var body: some View {
		TabView(selection: selection) {
			Tab("Chat", systemImage: "bubble.left.and.bubble.right", value: Section.chat) {
				SambungInbox(router: router, navigation: chat)
					.trackScreen(NavigationState.Tab.messages.screenName)
			}
			.badge(appState.totalUnreadMessages)

			Tab("Jaringan", systemImage: "point.3.connected.trianglepath.dotted", value: Section.network) {
				SambungLazyTab(isActive: selection.wrappedValue == .network) {
					NodeList().trackScreen(NavigationState.Tab.nodes.screenName)
				}
			}

			Tab("Peta", systemImage: "map", value: Section.map) {
				SambungLazyTab(isActive: selection.wrappedValue == .map) {
					MeshMapMK(router: router).trackScreen(NavigationState.Tab.map.screenName)
				}
			}

			Tab("Perangkat", systemImage: "antenna.radiowaves.left.and.right", value: Section.device) {
				SambungLazyTab(isActive: selection.wrappedValue == .device) {
					Settings().trackScreen(NavigationState.Tab.settings.screenName)
				}
			}

			Tab(value: Section.search, role: .search) {
				SambungSearch { route in
					chat.open(route)
					isSearching = false
					router.selectedTab = .messages
				}
			}
		}
		.tabBarMinimizeBehavior(.onScrollDown)
		// While an SOS is running it shows on every tab, with the way to stop it.
		.safeAreaInset(edge: .top, spacing: 0) { SambungSOSBar() }
		// Only while there is no radio, and not under a conversation's message field.
		.tabViewBottomAccessory(isEnabled: !accessoryManager.isConnected && chat.path.isEmpty) {
			SambungLinkAccessory {
				isSearching = false
				router.selectedTab = .connect
			}
		}
		// A deep link or a notification picks a router tab; that wins over the search tab.
		.onChange(of: router.selectedTab) { isSearching = false }
		.task {
			SambungOutbox.shared.start(accessoryManager: accessoryManager)
			#if DEBUG
			await applyDebugLaunchOptions()
			#endif
		}
	}

	#if DEBUG
	/// Screenshot tooling for simulator launches.
	/// SAMBUNG_START=chat|network|map|device|connect|search picks the tab.
	/// SAMBUNG_OPEN=setting:<SettingsNavigationState raw value> | node | channel (see SambungInbox).
	private func applyDebugLaunchOptions() async {
		let environment = ProcessInfo.processInfo.environment
		// Waits a moment: the demo seed sets its own tab as the window appears.
		try? await Task.sleep(for: .seconds(1))
		switch environment["SAMBUNG_START"] {
		case "chat": router.selectedTab = .messages
		case "network": router.selectedTab = .nodes
		case "map": router.selectedTab = .map
		case "device": router.selectedTab = .settings
		case "connect": router.selectedTab = .connect
		case "search": isSearching = true
		default: break
		}
		guard let open = environment["SAMBUNG_OPEN"] else { return }
		if open.hasPrefix("setting:"), let setting = SettingsNavigationState(rawValue: String(open.dropFirst(8))) {
			router.selectedTab = .settings
			try? await Task.sleep(for: .milliseconds(500))
			router.settingsPath = [setting]
		} else if open == "node" {
			let me = Int64(UserDefaults.preferredPeripheralNum)
			let nodes = (try? PersistenceController.shared.context.fetch(FetchDescriptor<NodeInfoEntity>())) ?? []
			if let node = nodes.first(where: { $0.num != me }) { router.navigateToNodeDetail(nodeNum: node.num) }
		}
	}
	#endif
}

/// Shown above the tab bar while no radio is connected. Tap it to connect one.
private struct SambungLinkAccessory: View {
	@EnvironmentObject private var accessoryManager: AccessoryManager
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			HStack(spacing: 8) {
				Circle()
					.fill(accessoryManager.isConnected ? SambungTheme.daun : accessoryManager.isConnecting ? SambungTheme.kunyit : SambungTheme.bata)
					.frame(width: 9, height: 9)
				Text(verbatim: title)
					.font(.subheadline.weight(.semibold))
					.lineLimit(1)
				Spacer(minLength: 8)
				Text(detail)
					.font(.footnote)
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}
			.padding(.horizontal, 16)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.accessibilityHint("Membuka sambungan radio")
	}

	private var title: String {
		guard accessoryManager.isConnected || accessoryManager.isConnecting, let device = accessoryManager.activeConnection?.device else {
			return String(localized: "Belum tersambung ke radio")
		}
		return device.longName ?? device.name
	}

	private var detail: LocalizedStringKey {
		if accessoryManager.isConnected { return "Tersambung" }
		return accessoryManager.isConnecting ? "Menyambungkan…" : "Sambungkan"
	}
}

/// Builds a tab's content the first time it is shown, so launch only pays for Chat.
private struct SambungLazyTab<Content: View>: View {
	let isActive: Bool
	@ViewBuilder let content: () -> Content
	@State private var hasActivated = false

	var body: some View {
		Group {
			if hasActivated { content() } else { Color(.systemBackground) }
		}
		.onAppear { if isActive { hasActivated = true } }
		.onChange(of: isActive) { _, active in
			if active { hasActivated = true }
		}
	}
}
