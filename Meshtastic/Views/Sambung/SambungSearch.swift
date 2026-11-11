//
//  SambungSearch.swift
//  Sambung
//
//  The search tab: one field for people, channels and the text of every message.
//
import SwiftData
import SwiftUI

struct SambungSearch: View {
	@Environment(\.modelContext) private var context
	@EnvironmentObject private var accessoryManager: AccessoryManager
	@Query(sort: [SortDescriptor(\UserEntity.longName)]) private var users: [UserEntity]
	@State private var text = ""
	@State private var hits: [Hit] = []
	/// Opens a conversation in the Chat tab.
	let open: (SambungRoute) -> Void

	struct Hit: Identifiable {
		let id: Int64
		let route: SambungRoute
		let title: String
		let text: String
		let timestamp: Int32
	}

	static let maxHits = 50

	private var query: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
	private var me: Int64 { Int64(accessoryManager.activeDeviceNum ?? 0) }

	private var people: [UserEntity] {
		users.filter { user in
			user.num != me && (user.displayLongName.localizedStandardContains(query)
				|| (user.longName ?? "").localizedStandardContains(query)
				|| (user.shortName ?? "").localizedStandardContains(query))
		}
	}

	private var allChannels: [ChannelEntity] {
		let num = Int64(UserDefaults.preferredPeripheralNum)
		guard num > 0, let myInfo = getNodeInfo(id: num, context: context)?.myInfo else { return [] }
		return myInfo.channels.filter { !ChannelEntity.isReservedModuleName($0.name ?? "") }.sorted { $0.index < $1.index }
	}

	private var channels: [ChannelEntity] {
		allChannels.filter { SambungInbox.title(for: $0).localizedStandardContains(query) }
	}

	var body: some View {
		NavigationStack {
			List {
				if !query.isEmpty {
					let people = people, channels = channels
					if !people.isEmpty {
						Section("Orang") {
							ForEach(people) { user in
								Button { open(.user(num: user.num)) } label: { SambungPersonLabel(user: user) }
							}
						}
					}
					if !channels.isEmpty {
						Section("Channel") {
							ForEach(channels) { channel in
								Button { open(.channel(index: channel.index)) } label: {
									HStack(spacing: 12) {
										SambungAvatar(kind: .channel(name: SambungInbox.title(for: channel)), size: 40)
										Text(verbatim: SambungInbox.title(for: channel)).font(.sambungName(.body)).foregroundStyle(.primary)
									}
								}
							}
						}
					}
					if !hits.isEmpty {
						Section("Pesan") {
							ForEach(hits) { hit in
								Button { open(hit.route) } label: {
									VStack(alignment: .leading, spacing: 3) {
										HStack {
											Text(verbatim: hit.title).font(.sambungName(.subheadline)).foregroundStyle(.primary)
											Spacer(minLength: 8)
											Text(verbatim: SambungInboxRow.timeText(hit.timestamp)).font(.footnote).foregroundStyle(.secondary)
										}
										Text(verbatim: hit.text).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
									}
								}
							}
						}
					}
				}
			}
			.overlay {
				if query.isEmpty {
					ContentUnavailableView("Cari di Sambung", systemImage: "magnifyingglass", description: Text("Nama orang, nama channel, atau kata di dalam pesan."))
				} else if people.isEmpty && channels.isEmpty && hits.isEmpty {
					ContentUnavailableView.search(text: query)
				}
			}
			.navigationTitle("Cari")
			.searchable(text: $text, prompt: "Orang, channel, atau isi pesan")
			.task(id: query) {
				// Wait for a pause in typing before scanning the messages.
				try? await Task.sleep(for: .milliseconds(250))
				guard !Task.isCancelled else { return }
				hits = messageHits()
			}
		}
	}

	/// shortcut: reads every message on the main actor and matches in memory, newest first;
	/// move to a background actor if a store grows past a few tens of thousands of messages.
	private func messageHits() -> [Hit] {
		guard !query.isEmpty else { return [] }
		let descriptor = FetchDescriptor<MessageEntity>(
			predicate: #Predicate<MessageEntity> { $0.isEmoji == false && $0.admin == false },
			sortBy: [SortDescriptor(\MessageEntity.messageTimestamp, order: .reverse)]
		)
		let messages = (try? context.fetch(descriptor)) ?? []
		let channelTitles = Dictionary(allChannels.map { ($0.index, SambungInbox.title(for: $0)) }, uniquingKeysWith: { first, _ in first })
		var result: [Hit] = []
		for message in messages where MessageSearch.contentMatches(message, query: query) {
			guard let hit = hit(for: message, channelTitles: channelTitles) else { continue }
			result.append(hit)
			if result.count == Self.maxHits { break }
		}
		return result
	}

	private func hit(for message: MessageEntity, channelTitles: [Int32: String]) -> Hit? {
		let body = message.messagePayload ?? ""
		if let to = message.toUser {
			// A direct message belongs to the conversation with whoever is not me.
			guard let other = message.fromUser?.num == me ? to : message.fromUser else { return nil }
			return Hit(id: message.messageId, route: .user(num: other.num), title: other.displayLongName, text: body, timestamp: message.messageTimestamp)
		}
		let sender = message.fromUser?.num == me ? "Kamu" : (message.fromUser?.displayLongName ?? "?")
		return Hit(id: message.messageId, route: .channel(index: message.channel), title: channelTitles[message.channel] ?? "Channel \(message.channel)", text: "\(sender): \(body)", timestamp: message.messageTimestamp)
	}
}
