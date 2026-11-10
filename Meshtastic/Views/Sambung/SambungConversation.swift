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

	var body: some View {
		switch route {
		case let .channel(index):
			let myInfo = connectedNode?.myInfo
			if let myInfo, let channel = myInfo.channels.first(where: { $0.index == index }) {
				ChannelMessageList(myInfo: myInfo, channel: channel)
					.id(channel.persistentModelID)
					.trackScreen(.channelMessages)
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
			text: heardCount > 0 ? "\(heardCount) node terdengar dalam 2 jam terakhir" : "Belum ada node lain yang terdengar"
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
