//
//  SambungContactViews.swift
//  Sambung
//
//  Saving a contact, and the list of saved contacts under Perangkat.
//
import SwiftData
import SwiftUI

extension View {
	/// Asks for the real name of the person behind a radio. Assign a user to present it.
	func sambungContactAlert(user: Binding<UserEntity?>) -> some View {
		modifier(SambungContactAlert(user: user))
	}
}

private struct SambungContactAlert: ViewModifier {
	@EnvironmentObject private var accessoryManager: AccessoryManager
	@Binding var user: UserEntity?
	@State private var name = ""

	func body(content: Content) -> some View {
		content
			.alert(
				"Simpan kontak",
				isPresented: Binding(get: { user != nil }, set: { if !$0 { user = nil } }),
				presenting: user
			) { user in
				TextField("Nama orangnya", text: $name)
					.textInputAutocapitalization(.words)
					.autocorrectionDisabled()
				Button("Simpan") { SambungContacts.save(name, for: user, accessoryManager: accessoryManager) }
				if SambungContacts.isContact(user.num) {
					Button("Hapus kontak", role: .destructive) {
						SambungContacts.save("", for: user, accessoryManager: accessoryManager)
					}
				}
				Button("Batal", role: .cancel) {}
			} message: { user in
				Text(verbatim: sambungText("Radio: %@. Nama ini hanya tersimpan di HP ini.", user.longName ?? user.shortName ?? "?"))
			}
			.onChange(of: user?.num) { _, num in
				name = num.flatMap { NodeDisplayNameStore.displayName(for: $0) } ?? ""
			}
	}
}

/// One person: avatar, contact name, and the radio's own name underneath when they differ.
struct SambungPersonLabel: View {
	let user: UserEntity
	var size: CGFloat = 40
	var detail: String?

	var body: some View {
		HStack(spacing: 12) {
			SambungAvatar(kind: .user(shortName: user.shortName ?? "?", num: user.num), size: size)
			VStack(alignment: .leading, spacing: 2) {
				Text(verbatim: user.displayLongName)
					.font(.sambungName(.body))
					.foregroundStyle(.primary)
					.lineLimit(1)
				if let line = secondLine {
					Text(verbatim: line)
						.font(.footnote)
						.foregroundStyle(.secondary)
						.lineLimit(1)
				}
			}
		}
	}

	private var secondLine: String? {
		let radio = SambungContacts.isContact(user.num) ? user.longName : nil
		let parts = [radio, detail].compactMap { $0 }.filter { !$0.isEmpty }
		return parts.isEmpty ? nil : parts.joined(separator: ", ")
	}
}

/// Perangkat › Kontak: everyone saved, with rename and remove.
struct SambungContactList: View {
	@EnvironmentObject private var accessoryManager: AccessoryManager
	@Query(sort: [SortDescriptor(\UserEntity.longName)]) private var users: [UserEntity]
	@State private var userToEdit: UserEntity?
	@State private var revision = 0

	private var contacts: [UserEntity] {
		_ = revision
		return users.filter { SambungContacts.isContact($0.num) }
			.sorted { $0.displayLongName.localizedStandardCompare($1.displayLongName) == .orderedAscending }
	}

	var body: some View {
		List(contacts) { user in
			Button {
				userToEdit = user
			} label: {
				SambungPersonLabel(user: user)
			}
			.swipeActions {
				Button("Hapus", role: .destructive) {
					SambungContacts.save("", for: user, accessoryManager: accessoryManager)
				}
			}
		}
		.overlay {
			if contacts.isEmpty {
				ContentUnavailableView(
					"Belum ada kontak",
					systemImage: "person.crop.circle.badge.plus",
					description: Text("Tekan lama seseorang di Chat atau Jaringan, lalu pilih Simpan kontak, supaya namanya tampil sebagai nama asli.")
				)
			}
		}
		.navigationTitle("Kontak")
		.navigationBarTitleDisplayMode(.inline)
		.sambungContactAlert(user: $userToEdit)
		.onReceive(NotificationCenter.default.publisher(for: NodeDisplayNameStore.didChangeNotification)) { _ in
			revision += 1
		}
	}
}
