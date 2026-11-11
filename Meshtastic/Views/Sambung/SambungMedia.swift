//
//  SambungMedia.swift
//  Sambung
//
//  Photos in chat: the bubble that shows a transferred file in place of its text message,
//  and the sheet that picks, shrinks and sends one.
//
import OSLog
import PhotosUI
import SwiftUI

/// Shows the file attached to a message when there is one, otherwise the message's own content.
/// Observes the store, so a bubble turns into a photo as its packets arrive.
struct SambungMediaSlot<Content: View>: View {
	@ObservedObject private var store = SambungMediaStore.shared
	let fromNum: Int64?
	let messageID: Int64
	let isCurrentUser: Bool
	@ViewBuilder let content: () -> Content

	var body: some View {
		if let record = store.record(from: fromNum, messageID: messageID) {
			SambungMediaBubble(record: record, url: store.url(for: record), isCurrentUser: isCurrentUser)
		} else {
			content()
		}
	}
}

private struct SambungMediaBubble: View {
	let record: SambungMediaRecord
	let url: URL?
	let isCurrentUser: Bool

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			if record.kind == .voice, let url {
				SambungVoicePlayer(url: url, tint: isCurrentUser ? .white : .primary)
			} else if record.kind == .voice {
				Label("Pesan suara", systemImage: record.failed ? "mic.slash" : "mic")
					.font(.subheadline.weight(.semibold))
			} else if let url, let image = UIImage(contentsOfFile: url.path) {
				Image(uiImage: image)
					.resizable()
					.interpolation(.medium)
					.scaledToFit()
					.frame(maxWidth: 220, maxHeight: 220)
					.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
					.accessibilityLabel("Foto")
			} else {
				Label("Foto", systemImage: record.failed ? "photo.badge.exclamationmark" : "photo")
					.font(.subheadline.weight(.semibold))
			}
			if let status {
				Text(verbatim: status)
					.font(.footnote)
					.opacity(0.8)
			}
			if !record.isComplete && !record.failed {
				ProgressView(value: Double(record.received), total: Double(max(record.total, 1)))
					.frame(width: 160)
					.tint(isCurrentUser ? .white : SambungTheme.kunyit)
			}
		}
	}

	private var status: String? {
		if record.failed { return record.isOutgoing ? "Gagal terkirim" : "Tidak lengkap, sebagian paket tidak sampai" }
		if record.isOutgoing {
			if record.delivered { return "Sampai ke penerima" }
			return record.received < record.total ? "Mengirim paket \(record.received) dari \(record.total)" : nil
		}
		return record.isComplete ? nil : "Menerima paket \(record.received) dari \(record.total)"
	}
}

/// The photo button next to the quick replies.
struct SambungPhotoButton: View {
	@EnvironmentObject private var accessoryManager: AccessoryManager
	let destination: MessageDestination
	@State private var selection: PhotosPickerItem?
	@State private var picked: PickedPhoto?
	@State private var isShowingNotAllowed = false

	struct PickedPhoto: Identifiable {
		let id = UUID()
		let data: Data
	}

	var body: some View {
		Group {
			if SambungTransfer.isAllowed(destination) {
				PhotosPicker(selection: $selection, matching: .images) { icon }
			} else {
				Button { isShowingNotAllowed = true } label: { icon }
			}
		}
		.buttonStyle(.plain)
		.accessibilityLabel("Kirim foto")
		.onChange(of: selection) { _, item in
			guard let item else { return }
			Task {
				if let data = try? await item.loadTransferable(type: Data.self) { picked = PickedPhoto(data: data) }
				selection = nil
			}
		}
		.sheet(item: $picked) { photo in
			SambungPhotoSheet(source: photo.data, destination: destination)
				.environmentObject(accessoryManager)
		}
		.alert("Foto tidak bisa dikirim ke channel ini", isPresented: $isShowingNotAllowed) {
			Button("Mengerti", role: .cancel) {}
		} message: {
			Text("Satu foto memakai radio puluhan detik dan semua orang di channel publik harus menunggu. Kirim foto lewat pesan langsung atau channel privat.")
		}
	}

	private var icon: some View {
		Image(systemName: "photo")
			.font(.subheadline)
			.padding(8)
			.background(Color(.secondarySystemBackground), in: Circle())
	}
}

private struct SambungPhotoSheet: View {
	@EnvironmentObject private var accessoryManager: AccessoryManager
	@Environment(\.dismiss) private var dismiss
	let source: Data
	let destination: MessageDestination

	@State private var size = SambungImageCodec.Size.small
	@State private var encoded: SambungImageCodec.Encoded?
	@State private var errorText: String?

	var body: some View {
		NavigationStack {
			VStack(spacing: 20) {
				Group {
					if let encoded, let image = UIImage(data: encoded.data) {
						Image(uiImage: image)
							.resizable()
							.interpolation(.medium)
							.scaledToFit()
							.clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
					} else {
						ContentUnavailableView("Foto ini tidak bisa diperkecil secukupnya", systemImage: "photo.badge.exclamationmark", description: Text("Coba ukuran yang lebih besar atau foto lain."))
					}
				}
				.frame(maxWidth: .infinity, maxHeight: 280)

				Picker("Ukuran", selection: $size) {
					ForEach(SambungImageCodec.Size.allCases) { Text($0.label).tag($0) }
				}
				.pickerStyle(.segmented)

				if let encoded {
					let seconds = SambungTransfer.estimatedSeconds(forByteCount: encoded.data.count)
					Text("Yang terlihat di atas adalah yang akan diterima. Terkirim dalam kira-kira \(seconds) detik, dan selama itu radio dipakai untuk foto ini.")
						.font(.footnote)
						.foregroundStyle(.secondary)
						.multilineTextAlignment(.center)
				}
				if let errorText {
					Text(verbatim: errorText).font(.footnote).foregroundStyle(SambungTheme.bata)
				}
				Spacer(minLength: 0)
			}
			.padding(20)
			.navigationTitle("Kirim foto")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button("Batal") { dismiss() } }
				ToolbarItem(placement: .confirmationAction) {
					Button("Kirim", action: send).disabled(encoded == nil)
				}
			}
			.task(id: size) { encoded = SambungImageCodec.encode(source, size: size) }
		}
		.presentationDetents([.large])
	}

	private func send() {
		guard let encoded else { return }
		guard accessoryManager.isConnected else {
			errorText = "Belum tersambung ke radio."
			return
		}
		let destination = destination, manager = accessoryManager
		// The transfer runs on after the sheet closes; progress shows in the bubble.
		Task {
			do {
				try await SambungTransfer.shared.send(
					encoded.data, kind: .image, codec: encoded.codec,
					placeholder: SambungTransfer.imagePlaceholder, to: destination, accessoryManager: manager
				)
			} catch {
				// The sheet is gone by now; the bubble shows the failure.
				Logger.mesh.error("Sambung photo send failed: \(error.localizedDescription, privacy: .public)")
			}
		}
		dismiss()
	}
}
