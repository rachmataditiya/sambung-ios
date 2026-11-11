//
//  SambungShell.swift
//  Sambung
//
//  Three tabs instead of upstream's five: Chat, Jaringan (nodes + map) and Perangkat
//  (connection + settings). The router keeps its five-way `selectedTab`, so deep links,
//  notifications and upstream code that switches tabs keep working; this view maps it down.
//
import SwiftUI

struct SambungShell: View {
	@ObservedObject var appState: AppState
	@ObservedObject var router: Router
	@EnvironmentObject private var accessoryManager: AccessoryManager
	/// ContentView's side-effecting binding (tap the current tab again to pop to root).
	let tabSelection: Binding<NavigationState.Tab>

	enum Section: Hashable {
		case chat, network, device

		init(_ tab: NavigationState.Tab) {
			switch tab {
			case .messages: self = .chat
			case .nodes, .map: self = .network
			case .settings, .connect: self = .device
			}
		}
	}

	private var selection: Binding<Section> {
		Binding(
			get: { Section(router.selectedTab) },
			set: { section in
				let current = router.selectedTab
				switch section {
				case .chat: tabSelection.wrappedValue = .messages
				// Re-selecting keeps the sub-screen the person was on.
				case .network: tabSelection.wrappedValue = current == .map ? .map : .nodes
				case .device: tabSelection.wrappedValue = current == .settings ? .settings : .connect
				}
			}
		)
	}

	var body: some View {
		TabView(selection: selection) {
			SambungInbox(router: router)
				.trackScreen(NavigationState.Tab.messages.screenName)
				.tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
				.tag(Section.chat)
				.badge(appState.totalUnreadMessages)

			SambungLazyTab(isActive: Section(router.selectedTab) == .network) {
				SambungSwitcher(
					first: "Daftar", second: "Peta",
					showsSecond: Binding(get: { router.selectedTab == .map }, set: { router.selectedTab = $0 ? .map : .nodes })
				) {
					NodeList().trackScreen(NavigationState.Tab.nodes.screenName)
				} secondContent: {
					MeshMapMK(router: router).trackScreen(NavigationState.Tab.map.screenName)
				}
			}
			.tabItem { Label("Jaringan", systemImage: "point.3.connected.trianglepath.dotted") }
			.tag(Section.network)

			SambungLazyTab(isActive: Section(router.selectedTab) == .device) {
				SambungSwitcher(
					first: "Sambungan", second: "Setelan",
					showsSecond: Binding(get: { router.selectedTab == .settings }, set: { router.selectedTab = $0 ? .settings : .connect })
				) {
					SambungConnect(router: router).trackScreen(NavigationState.Tab.connect.screenName)
				} secondContent: {
					Settings().trackScreen(NavigationState.Tab.settings.screenName)
				}
			}
			.tabItem { Label("Perangkat", systemImage: "antenna.radiowaves.left.and.right") }
			.tag(Section.device)
		}
		.task {
			SambungOutbox.shared.start(accessoryManager: accessoryManager)
			#if DEBUG
			// Screenshot tooling: SAMBUNG_START=chat|device picks the tab a simulator launch opens on.
			// Waits a moment: the demo seed sets its own tab as the window appears.
			try? await Task.sleep(for: .seconds(1))
			switch ProcessInfo.processInfo.environment["SAMBUNG_START"] {
			case "chat": router.selectedTab = .messages
			case "device": router.selectedTab = .connect
			default: break
			}
			#endif
		}
	}
}

/// Two upstream screens behind one tab, with a segmented switch on top.
/// shortcut: the switch sits above each screen's own navigation bar; the Jaringan and
/// Perangkat screens get their own Sambung layout in stage 2 and this goes away.
private struct SambungSwitcher<First: View, Second: View>: View {
	let first: LocalizedStringKey
	let second: LocalizedStringKey
	@Binding var showsSecond: Bool
	@ViewBuilder let firstContent: () -> First
	@ViewBuilder let secondContent: () -> Second

	var body: some View {
		Group {
			if showsSecond { secondContent() } else { firstContent() }
		}
		.safeAreaInset(edge: .top, spacing: 0) {
			Picker("Tampilan", selection: $showsSecond) {
				Text(first).tag(false)
				Text(second).tag(true)
			}
			.pickerStyle(.segmented)
			.padding(.horizontal, 16)
			.padding(.vertical, 6)
			.background(.bar)
		}
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
