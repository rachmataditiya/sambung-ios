//
//  SambungOutbox.swift
//  Sambung
//
//  Sends a failed message again by itself once there is somebody to hear it, instead of
//  leaving the person to press "try again" on each one. Uses upstream's resendMessage, so the
//  message keeps its place and id in the conversation.
//
import Foundation
import OSLog
import SwiftData

@MainActor
final class SambungOutbox {
	static let shared = SambungOutbox()

	nonisolated static let maxAttempts = 3
	/// Radio time is shared by everyone in range, so retries are spaced out.
	nonisolated static let minimumGap: TimeInterval = 120
	/// Older than this, a late delivery is more confusing than useful.
	nonisolated static let window: TimeInterval = 24 * 3600
	static let enabledKey = "sambung.autoResend"

	struct Candidate: Equatable {
		let sentAt: Date
		/// When the recipient (direct message) or any other node (channel) was last heard.
		let audienceLastHeard: Date?
	}

	struct Attempts: Codable, Equatable {
		var count = 0
		var last: Date?
	}

	/// Retry only when someone was heard after the last try: resending into silence would just
	/// fail again and burn airtime.
	nonisolated static func shouldRetry(_ candidate: Candidate, attempts: Attempts, now: Date) -> Bool {
		guard attempts.count < maxAttempts, now.timeIntervalSince(candidate.sentAt) <= window else { return false }
		let lastTry = attempts.last ?? candidate.sentAt
		guard now.timeIntervalSince(lastTry) >= minimumGap, let heard = candidate.audienceLastHeard else { return false }
		return heard > lastTry
	}

	private let defaults: UserDefaults
	private var attempts: [String: Attempts]
	private var loop: Task<Void, Never>?
	private static let attemptsKey = "sambung.outbox.attempts"

	init(defaults: UserDefaults = .standard) {
		self.defaults = defaults
		let stored = defaults.data(forKey: Self.attemptsKey).flatMap { try? JSONDecoder().decode([String: Attempts].self, from: $0) }
		attempts = stored ?? [:]
	}

	var isEnabled: Bool { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }

	func start(accessoryManager: AccessoryManager) {
		guard loop == nil else { return }
		loop = Task { [weak self] in
			while !Task.isCancelled {
				try? await Task.sleep(for: .seconds(60))
				await self?.tick(accessoryManager: accessoryManager)
			}
		}
	}

	private func tick(accessoryManager: AccessoryManager, now: Date = Date()) async {
		guard isEnabled, accessoryManager.isConnected, let me = accessoryManager.activeDeviceNum else { return }
		let context = PersistenceController.shared.context
		let cutoff = Int32(clamping: Int(now.addingTimeInterval(-Self.window).timeIntervalSince1970))
		let descriptor = FetchDescriptor<MessageEntity>(
			predicate: #Predicate<MessageEntity> {
				$0.fromUser?.num == me && $0.isEmoji == false && $0.admin == false && $0.messageTimestamp >= cutoff
			},
			sortBy: [SortDescriptor(\MessageEntity.messageTimestamp, order: .forward)]
		)
		guard let messages = try? context.fetch(descriptor), !messages.isEmpty else { return }
		let anyNodeLastHeard = latestHeard(excluding: me, in: context)

		// Forget messages that left the window, so the table does not grow for ever.
		let liveIDs = Set(messages.map { String($0.messageId) })
		attempts = attempts.filter { liveIDs.contains($0.key) }

		// One resend per tick: the oldest message that qualifies.
		for message in messages where message.channel >= 0 || message.toUser != nil {
			let isDirect = message.toUser != nil
			guard message.deliveryStatus(isDirectMessage: isDirect).canRetry else { continue }
			let key = String(message.messageId)
			let candidate = Candidate(
				sentAt: Date(timeIntervalSince1970: TimeInterval(message.messageTimestamp)),
				audienceLastHeard: isDirect ? message.toUser?.userNode?.lastHeard : anyNodeLastHeard
			)
			let record = attempts[key] ?? Attempts()
			guard Self.shouldRetry(candidate, attempts: record, now: now) else { continue }

			attempts[key] = Attempts(count: record.count + 1, last: now)
			save()
			do {
				try await accessoryManager.resendMessage(message)
				Logger.mesh.info("📤 Sambung outbox resent \(message.messageId, privacy: .public), attempt \(record.count + 1)")
				NotificationCenter.default.post(name: .meshMessagesDidChange, object: nil)
			} catch {
				Logger.mesh.warning("📤 Sambung outbox resend failed: \(error.localizedDescription, privacy: .public)")
			}
			return
		}
		save()
	}

	private func latestHeard(excluding me: Int64, in context: ModelContext) -> Date? {
		var descriptor = FetchDescriptor<NodeInfoEntity>(
			predicate: #Predicate<NodeInfoEntity> { $0.num != me && $0.lastHeard != nil },
			sortBy: [SortDescriptor(\NodeInfoEntity.lastHeard, order: .reverse)]
		)
		descriptor.fetchLimit = 1
		return (try? context.fetch(descriptor))?.first?.lastHeard
	}

	private func save() {
		defaults.set(try? JSONEncoder().encode(attempts), forKey: Self.attemptsKey)
	}
}
