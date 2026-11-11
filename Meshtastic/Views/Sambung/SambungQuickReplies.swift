//
//  SambungQuickReplies.swift
//  Sambung
//
//  One-tap replies above the message field, and the sheet to edit them.
//
import SwiftUI

struct SambungQuickReplyBar: View {
	@ObservedObject private var store = SambungStore.shared
	@State private var isEditing = false
	@State private var talk: SambungTalkState?
	let destination: MessageDestination
	let onPick: (String) -> Void

	var body: some View {
		HStack(spacing: 8) {
			// Push to talk sits outside the scrolling row, so holding and sliding it never scrolls.
			SambungTalkButton(destination: destination, talk: $talk)
				.padding(.leading, 15)
			replies
				.overlay {
					if let talk { SambungTalkStrip(state: talk) }
				}
		}
		.padding(.top, 8)
		.sheet(isPresented: $isEditing) {
			SambungQuickReplyEditor()
		}
	}

	private var replies: some View {
		ScrollView(.horizontal, showsIndicators: false) {
			HStack(spacing: 8) {
				SambungPhotoButton(destination: destination)
				ForEach(store.quickReplies, id: \.self) { reply in
					Button {
						onPick(reply)
					} label: {
						Text(verbatim: reply)
							.font(.subheadline)
							.padding(.horizontal, 14)
							.padding(.vertical, 7)
							.background(Color(.secondarySystemBackground), in: Capsule())
					}
					.buttonStyle(.plain)
					.accessibilityHint("Langsung terkirim")
				}
				Button {
					isEditing = true
				} label: {
					Image(systemName: "slider.horizontal.3")
						.font(.subheadline)
						.padding(8)
						.background(Color(.secondarySystemBackground), in: Circle())
				}
				.buttonStyle(.plain)
				.accessibilityLabel("Atur balasan cepat")
			}
			.padding(.trailing, 15)
		}
	}
}

struct SambungQuickReplyEditor: View {
	@ObservedObject private var store = SambungStore.shared
	@Environment(\.dismiss) private var dismiss
	@State private var newReply = ""

	var body: some View {
		NavigationStack {
			List {
				Section {
					ForEach(store.quickReplies, id: \.self) { reply in
						Text(verbatim: reply)
					}
					.onDelete { store.quickReplies.remove(atOffsets: $0) }
					.onMove { store.quickReplies.move(fromOffsets: $0, toOffset: $1) }
				} footer: {
					Text("Balasan cepat langsung terkirim saat diketuk. Buat yang pendek, supaya cepat sampai lewat radio.")
				}
				Section {
					HStack {
						TextField("Balasan baru", text: $newReply)
							.onSubmit(add)
						Button("Tambah", action: add)
							.disabled(trimmed.isEmpty)
					}
				}
			}
			.environment(\.editMode, .constant(.active))
			.navigationTitle("Balasan cepat")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .confirmationAction) {
					Button("Selesai") { dismiss() }
				}
				ToolbarItem(placement: .cancellationAction) {
					Button("Kembalikan bawaan") { store.quickReplies = SambungStore.defaultQuickReplies }
				}
			}
		}
		.presentationDetents([.medium, .large])
	}

	private var trimmed: String { newReply.trimmingCharacters(in: .whitespacesAndNewlines) }

	private func add() {
		guard !trimmed.isEmpty, !store.quickReplies.contains(trimmed) else { return }
		store.quickReplies.append(trimmed)
		newReply = ""
	}
}
