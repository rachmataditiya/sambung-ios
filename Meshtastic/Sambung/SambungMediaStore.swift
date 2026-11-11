//
//  SambungMediaStore.swift
//  Sambung
//
//  Files that arrived (or were sent) as a Sambung transfer, kept next to the app's data and
//  looked up by the text message they belong to. Outside SwiftData on purpose: the schema
//  stays upstream's.
//
import Foundation
import OSLog

struct SambungMediaRecord: Codable, Equatable {
	var kind: SambungTransferWire.Kind
	var codec: UInt8
	/// Set once the file is complete and on disk.
	var fileName: String?
	var received: Int
	var total: Int
	var isOutgoing: Bool
	var failed = false
	/// Outgoing only: the recipient confirmed it has the whole file.
	var delivered = false

	var isComplete: Bool { fileName != nil }
}

@MainActor
final class SambungMediaStore: ObservableObject {
	static let shared = SambungMediaStore()

	@Published private(set) var records: [String: SambungMediaRecord] = [:]

	private let directory: URL
	private var indexURL: URL { directory.appendingPathComponent("index.json") }

	init(directory: URL? = nil) {
		let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
		self.directory = directory ?? base.appendingPathComponent("SambungMedia", isDirectory: true)
		try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
		if let data = try? Data(contentsOf: indexURL), let stored = try? JSONDecoder().decode([String: SambungMediaRecord].self, from: data) {
			records = stored
		}
	}

	/// A message is identified by who sent it and its packet id.
	static func key(from nodeNum: Int64, messageID: Int64) -> String { "\(nodeNum)-\(messageID)" }

	func record(from nodeNum: Int64?, messageID: Int64) -> SambungMediaRecord? {
		guard let nodeNum else { return nil }
		return records[Self.key(from: nodeNum, messageID: messageID)]
	}

	func url(for record: SambungMediaRecord) -> URL? {
		record.fileName.map { directory.appendingPathComponent($0) }
	}

	func set(_ record: SambungMediaRecord, for key: String) {
		guard records[key] != record else { return }
		records[key] = record
		persist()
	}

	func update(_ key: String, _ change: (inout SambungMediaRecord) -> Void) {
		guard var record = records[key] else { return }
		change(&record)
		set(record, for: key)
	}

	/// Writes a finished file and marks its record complete.
	func store(_ file: Data, for key: String, record: SambungMediaRecord) {
		var record = record
		let name = "\(key).\(record.kind == .image ? "img" : "voice")"
		do {
			try file.write(to: directory.appendingPathComponent(name), options: .atomic)
			record.fileName = name
			record.received = record.total
		} catch {
			Logger.data.error("Sambung media: could not write \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
			record.failed = true
		}
		set(record, for: key)
	}

	private func persist() {
		do {
			try JSONEncoder().encode(records).write(to: indexURL, options: .atomic)
		} catch {
			Logger.data.error("Sambung media: could not save the index: \(error.localizedDescription, privacy: .public)")
		}
	}
}
