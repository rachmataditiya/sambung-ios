//
//  SambungSOSViews.swift
//  Sambung
//
//  The SOS button, the screen that starts and stops the call, the bar shown while it runs, and
//  its settings.
//
import SwiftData
import SwiftUI

/// The red SOS button at the top of the Chat tab.
struct SambungSOSButton: View {
	@State private var isOpen = false

	var body: some View {
		Button {
			isOpen = true
		} label: {
			Text(verbatim: "SOS")
				.font(.subheadline.weight(.heavy))
				.foregroundStyle(.white)
				.padding(.horizontal, 10)
				.padding(.vertical, 4)
				.background(SambungTheme.bata, in: Capsule())
		}
		.accessibilityLabel("Panggilan darurat")
		.sheet(isPresented: $isOpen) { SambungSOSSheet() }
	}
}

/// Shown above every tab while the call is running.
struct SambungSOSBar: View {
	@ObservedObject private var sos = SambungSOS.shared

	var body: some View {
		if sos.isActive {
			HStack(spacing: 10) {
				Image(systemName: "sos")
					.font(.headline)
				Text(verbatim: sambungText("SOS aktif, terkirim %lld kali", sos.sentCount))
					.font(.subheadline.weight(.semibold))
					.lineLimit(1)
					.minimumScaleFactor(0.8)
				Spacer(minLength: 8)
				Button("Hentikan") { sos.stop() }
					.buttonStyle(.bordered)
					.tint(.white)
			}
			.foregroundStyle(.white)
			.padding(.horizontal, 16)
			.padding(.vertical, 8)
			.background(SambungTheme.bata)
		}
	}
}

private struct SambungSOSSheet: View {
	@EnvironmentObject private var accessoryManager: AccessoryManager
	@Environment(\.dismiss) private var dismiss
	@Environment(\.modelContext) private var context
	@ObservedObject private var sos = SambungSOS.shared
	@State private var isHolding = false

	var body: some View {
		NavigationStack {
			VStack(spacing: 22) {
				Spacer(minLength: 0)
				if sos.isActive {
					Image(systemName: "sos.circle.fill")
						.font(.system(size: 96))
						.foregroundStyle(SambungTheme.bata)
					Text(verbatim: sambungText("SOS aktif, terkirim %lld kali", sos.sentCount))
						.font(.sambungName(.title3))
					Button("Hentikan SOS") { sos.stop() }
						.buttonStyle(.borderedProminent)
						.controlSize(.large)
						.tint(SambungTheme.bata)
				} else {
					holdButton
					Text(verbatim: sambungText(
						"Mengirim pesan darurat berisi posisimu ke %@, diulang tiap %lld menit sampai kamu hentikan.",
						SambungSOSDestination.title(for: sos.destinationKey, context: context), sos.interval / 60
					))
					.font(.callout)
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
					.padding(.horizontal, 28)
				}
				if !accessoryManager.isConnected {
					Label("Belum tersambung ke radio", systemImage: "antenna.radiowaves.left.and.right.slash")
						.font(.footnote)
						.foregroundStyle(SambungTheme.bata)
				} else if let error = sos.lastError {
					Text(verbatim: error).font(.footnote).foregroundStyle(SambungTheme.bata)
				}
				Spacer(minLength: 0)
			}
			.navigationTitle("Panggilan darurat")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button("Tutup") { dismiss() } }
				ToolbarItem(placement: .primaryAction) {
					NavigationLink {
						SambungSOSSettings()
					} label: {
						Label("Setelan SOS", systemImage: "slider.horizontal.3")
					}
				}
			}
		}
	}

	/// Two seconds of holding, so a pocket cannot send it.
	private var holdButton: some View {
		ZStack {
			Circle()
				.fill(SambungTheme.bata)
				.frame(width: 170, height: 170)
			Circle()
				.trim(from: 0, to: isHolding ? 1 : 0)
				.stroke(.white, style: StrokeStyle(lineWidth: 8, lineCap: .round))
				.rotationEffect(.degrees(-90))
				.frame(width: 150, height: 150)
				.animation(isHolding ? .linear(duration: 2) : .easeOut(duration: 0.2), value: isHolding)
			VStack(spacing: 2) {
				Text(verbatim: "SOS").font(.system(size: 44, weight: .heavy, design: .rounded))
				Text("Tahan 2 detik").font(.footnote.weight(.semibold))
			}
			.foregroundStyle(.white)
		}
		.contentShape(Circle())
		.onLongPressGesture(minimumDuration: 2) {
			isHolding = false
			sos.start(accessoryManager: accessoryManager)
		} onPressingChanged: { pressing in
			isHolding = pressing
		}
		.accessibilityLabel("Kirim SOS")
		.accessibilityHint("Tahan dua detik untuk mengirim")
		.accessibilityAddTraits(.isButton)
	}
}

/// The conversations an SOS can go to: the radio's channels and the saved contacts.
enum SambungSOSDestination {
	@MainActor
	static func options(context: ModelContext) -> [(key: String, title: String)] {
		var options: [(key: String, title: String)] = []
		let num = Int64(UserDefaults.preferredPeripheralNum)
		if num > 0, let myInfo = getNodeInfo(id: num, context: context)?.myInfo {
			let channels = myInfo.channels
				.filter { !ChannelEntity.isReservedModuleName($0.name ?? "") }
				.sorted { $0.index < $1.index }
			options += channels.map { ("channel:\($0.index)", SambungInbox.title(for: $0)) }
		}
		let users = (try? context.fetch(FetchDescriptor<UserEntity>(sortBy: [SortDescriptor(\UserEntity.longName)]))) ?? []
		options += users.filter { SambungContacts.isContact($0.num) && $0.num != num }
			.map { ("user:\($0.num)", $0.displayLongName) }
		return options
	}

	@MainActor
	static func title(for key: String, context: ModelContext) -> String {
		options(context: context).first { $0.key == key }?.title ?? sambungText("Channel utama")
	}
}

struct SambungSOSSettings: View {
	@Environment(\.modelContext) private var context
	@ObservedObject private var sos = SambungSOS.shared

	var body: some View {
		Form {
			Section {
				Picker("Kirim ke", selection: Binding(get: { sos.destinationKey }, set: { sos.destinationKey = $0 })) {
					ForEach(SambungSOSDestination.options(context: context), id: \.key) { option in
						Text(verbatim: option.title).tag(option.key)
					}
				}
			} footer: {
				Text("Channel utama terdengar oleh semua orang dalam jangkauan. Kontak hanya menerima kalau radionya terjangkau.")
			}
			Section("Isi pesan") {
				TextField("Butuh bantuan segera.", text: Binding(get: { sos.text }, set: { sos.text = $0 }), axis: .vertical)
			}
			Section {
				Stepper(value: Binding(get: { sos.interval / 60 }, set: { sos.interval = $0 * 60 }), in: 1...30) {
					Text(verbatim: sambungText("Ulangi tiap %lld menit", sos.interval / 60))
				}
			} footer: {
				Text("Pesan diulang dengan posisi terbaru dan berhenti sendiri setelah satu jam.")
			}
		}
		.navigationTitle("Setelan SOS")
		.navigationBarTitleDisplayMode(.inline)
	}
}
