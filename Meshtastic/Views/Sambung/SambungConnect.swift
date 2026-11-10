//
//  SambungConnect.swift
//  Sambung
//
//  The connection screen: what is connected now, the radios in Bluetooth range, and Wi-Fi as
//  the second way in. Discovery, pairing and radio switching are upstream's AccessoryManager
//  and the helpers in Connect.swift; this is a new face on them.
//
import OSLog
import SwiftData
import SwiftUI

struct SambungConnect: View {
	@Environment(\.modelContext) private var context
	@Environment(\.openURL) private var openURL
	@EnvironmentObject private var accessoryManager: AccessoryManager
	@ObservedObject var router: Router

	@State private var isSwitchingRadio = false
	@State private var isAskingAddress = false
	@State private var address = ""
	@State private var isShowingFullScreen = false
	@State private var isConfirmingDisconnect = false

	private var isBusy: Bool { accessoryManager.isConnecting || isSwitchingRadio }
	private var activeDevice: Device? {
		guard accessoryManager.isConnected || accessoryManager.isConnecting else { return nil }
		return accessoryManager.activeConnection?.device
	}

	/// Last-used radio first, then strongest signal: the one you most likely want is on top.
	private var nearbyDevices: [Device] {
		let preferredId = UserDefaults.preferredPeripheralId
		let activeId = activeDevice?.id
		return accessoryManager.devices
			.filter { $0.id != activeId }
			.sorted { lhs, rhs in
				let lhsPreferred = lhs.id.uuidString == preferredId, rhsPreferred = rhs.id.uuidString == preferredId
				if lhsPreferred != rhsPreferred { return lhsPreferred }
				if (lhs.rssi ?? -200) != (rhs.rssi ?? -200) { return (lhs.rssi ?? -200) > (rhs.rssi ?? -200) }
				return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
			}
	}

	var body: some View {
		NavigationStack {
			List {
				Section {
					statusCard
						.listRowInsets(EdgeInsets())
						.listRowBackground(Color.clear)
				}

				Section {
					if accessoryManager.isBluetoothPoweredOff {
						bluetoothOffRow
					}
					ForEach(nearbyDevices) { device in
						SambungDeviceRow(device: device, isLastUsed: device.id.uuidString == UserDefaults.preferredPeripheralId) {
							connect(to: device)
						}
						.disabled(isBusy)
					}
					if nearbyDevices.isEmpty && !accessoryManager.isBluetoothPoweredOff {
						searchingRow
					}
				} header: {
					Text("Radio di sekitar")
				} footer: {
					Text("Saat iPhone meminta PIN, masukkan angka yang tampil di layar radio. Radio tanpa layar memakai 123456.")
				}

				Section {
					Button {
						address = ""
						isAskingAddress = true
					} label: {
						Label("Sambung lewat alamat IP", systemImage: "wifi")
					}
					.disabled(isBusy)
				} header: {
					Text("Lewat WiFi")
				} footer: {
					Text("Radio dan iPhone harus berada di jaringan WiFi yang sama. Pada radio berbasis ESP32, menyalakan WiFi mematikan Bluetooth-nya.")
				}

				Section {
					DisclosureGroup("Radio tidak muncul?") {
						SambungTip(symbol: "power", text: "Pastikan radio menyala dan antenanya terpasang.")
						SambungTip(symbol: "iphone.radiowaves.left.and.right", text: "Dekatkan radio ke iPhone, dalam jarak beberapa meter.")
						SambungTip(symbol: "personalhotspot", text: "Radio hanya melayani satu HP. Putuskan dulu dari HP atau app lain.")
						SambungTip(symbol: "arrow.clockwise", text: "Matikan lalu nyalakan lagi Bluetooth di iPhone.")
					}
					Button {
						isShowingFullScreen = true
					} label: {
						Label("Pilihan sambungan lanjutan", systemImage: "slider.horizontal.3")
					}
				}
			}
			.navigationTitle("Sambungan")
		}
		.alert("Sambung lewat WiFi", isPresented: $isAskingAddress) {
			TextField("192.168.1.20", text: $address)
				.keyboardType(.numbersAndPunctuation)
				.autocorrectionDisabled()
				.textInputAutocapitalization(.never)
			Button("Sambungkan") { connectManually(address) }
			Button("Batal", role: .cancel) {}
		} message: {
			Text("Ketik alamat IP atau nama host radio.")
		}
		.confirmationDialog("Putuskan sambungan ke radio?", isPresented: $isConfirmingDisconnect, titleVisibility: .visible) {
			Button("Putuskan", role: .destructive) {
				Task { try? await accessoryManager.disconnect() }
			}
		} message: {
			Text("Pesan baru tidak akan masuk sampai kamu menyambungkan lagi.")
		}
		.sheet(isPresented: $isShowingFullScreen) {
			Connect(router: router)
				.trackScreen(NavigationState.Tab.connect.screenName)
		}
		// Connect links (QR, NFC) hand a TCP address to whichever connection screen is up.
		.onReceive(router.$pendingTCPConnection) { connection in
			guard let connection else { return }
			router.pendingTCPConnection = nil
			connectManually(connection)
		}
	}

	// MARK: - Status

	@ViewBuilder
	private var statusCard: some View {
		VStack(alignment: .leading, spacing: 14) {
			if let device = activeDevice {
				HStack(spacing: 14) {
					SambungAvatar(kind: .user(shortName: device.shortName ?? "?", num: device.num ?? 0), size: 56)
					VStack(alignment: .leading, spacing: 3) {
						Text(verbatim: device.longName ?? device.name)
							.font(.sambungName(.title3))
							.lineLimit(2)
						Text(verbatim: stateText)
							.font(.subheadline)
							.foregroundStyle(accessoryManager.isConnected ? SambungTheme.daun : Color.secondary)
					}
					Spacer(minLength: 0)
					if !accessoryManager.isConnected { ProgressView() }
				}
				SambungDeviceFacts(device: device, batteryLevel: batteryLevel(of: device))
				if accessoryManager.allowDisconnect {
					Button(accessoryManager.isConnected ? "Putuskan sambungan" : "Batalkan") {
						if accessoryManager.isConnected {
							isConfirmingDisconnect = true
						} else {
							Task { try? await accessoryManager.disconnect() }
						}
					}
					.buttonStyle(.bordered)
					.tint(SambungTheme.bata)
				}
			} else {
				HStack(spacing: 14) {
					Image(systemName: "antenna.radiowaves.left.and.right.slash")
						.font(.system(size: 28))
						.foregroundStyle(.secondary)
						.frame(width: 56, height: 56)
						.background(Color(.tertiarySystemFill), in: Circle())
					VStack(alignment: .leading, spacing: 3) {
						Text("Belum tersambung")
							.font(.sambungName(.title3))
						Text("Pilih radio di bawah untuk mulai berkirim pesan.")
							.font(.subheadline)
							.foregroundStyle(.secondary)
					}
				}
				if let error = accessoryManager.lastConnectionError {
					Label {
						Text(verbatim: "Sambungan terakhir gagal: \(error.localizedDescription)")
					} icon: {
						Image(systemName: "exclamationmark.triangle.fill")
					}
					.font(.footnote)
					.foregroundStyle(SambungTheme.bata)
				}
			}
		}
		.padding(16)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
	}

	private var stateText: String {
		switch accessoryManager.state {
		case .subscribed: return "Tersambung"
		case .connecting: return "Menyambungkan…"
		case let .retrying(attempt, maxAttempts): return "Mencoba lagi (\(attempt) dari \(maxAttempts))…"
		case let .retrievingDatabase(nodeCount): return nodeCount > 0 ? "Mengambil daftar node (\(nodeCount))…" : "Mengambil data dari radio…"
		case .communicating: return "Menyiapkan radio…"
		case .uninitialized, .idle, .discovering: return accessoryManager.isConnected ? "Tersambung" : "Menyambungkan…"
		}
	}

	private func batteryLevel(of device: Device) -> Int? {
		guard let num = device.num, let node = getNodeInfo(id: num, context: context),
			  let level = node.latestDeviceMetrics?.batteryLevel else { return nil }
		return Int(level)
	}

	private var bluetoothOffRow: some View {
		Button {
			if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
		} label: {
			Label {
				VStack(alignment: .leading, spacing: 2) {
					Text("Bluetooth mati").font(.callout.weight(.semibold)).foregroundStyle(.primary)
					Text("Nyalakan Bluetooth di Pengaturan untuk melihat radio di sekitar.")
						.font(.footnote)
						.foregroundStyle(.secondary)
				}
			} icon: {
				Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(SambungTheme.kunyit)
			}
		}
		.accessibilityHint("Membuka Pengaturan")
	}

	private var searchingRow: some View {
		HStack(spacing: 12) {
			ProgressView()
			Text(activeDevice == nil ? "Mencari radio di sekitar…" : "Tidak ada radio lain di sekitar.")
				.font(.callout)
				.foregroundStyle(.secondary)
		}
	}

	// MARK: - Actions

	private func connect(to device: Device) {
		let preferredId = UserDefaults.preferredPeripheralId
		Task {
			// A different radio than last time has its own message store; upstream's switch
			// backs up the current one and restores the other before connecting.
			if !preferredId.isEmpty && device.id.uuidString != preferredId {
				await performRadioSwitch(device, isSwitchingRadio: $isSwitchingRadio, accessoryManager: accessoryManager, router: router)
			} else {
				if accessoryManager.activeConnection != nil { try? await accessoryManager.disconnect() }
				try? await accessoryManager.connect(to: device)
			}
		}
	}

	private func connectManually(_ address: String) {
		let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return }
		Task {
			await Meshtastic.connectManually(trimmed, transportType: .tcp, isSwitchingRadio: $isSwitchingRadio, accessoryManager: accessoryManager, router: router)
		}
	}
}

private struct SambungDeviceRow: View {
	let device: Device
	let isLastUsed: Bool
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			HStack(spacing: 12) {
				Image(systemName: device.transportType == .ble ? "dot.radiowaves.left.and.right" : "wifi")
					.font(.title3)
					.foregroundStyle(Color.accentColor)
					.frame(width: 36)
				VStack(alignment: .leading, spacing: 2) {
					Text(verbatim: device.longName ?? device.name)
						.font(.sambungName(.body))
						.foregroundStyle(.primary)
					Text(verbatim: subtitle)
						.font(.footnote)
						.foregroundStyle(.secondary)
				}
				Spacer(minLength: 8)
				if let strength = device.getSignalStrength() {
					SambungSignalBars(level: strength == .strong ? 3 : strength == .normal ? 2 : 1)
				}
			}
		}
		.accessibilityHint("Sambungkan ke radio ini")
	}

	private var subtitle: String {
		var parts = [device.transportType == .ble ? "Bluetooth" : device.transportType == .tcp ? "WiFi" : "USB"]
		if isLastUsed { parts.append("terakhir dipakai") }
		return parts.joined(separator: ", ")
	}
}

private struct SambungDeviceFacts: View {
	let device: Device
	let batteryLevel: Int?

	var body: some View {
		HStack(spacing: 18) {
			fact(symbol: device.transportType == .ble ? "dot.radiowaves.left.and.right" : "wifi",
				 text: device.transportType == .ble ? "Bluetooth" : device.transportType == .tcp ? "WiFi" : "USB")
			if let batteryLevel {
				// Above 100 is how the firmware reports "on external power".
				fact(symbol: batteryLevel > 100 ? "powerplug" : "battery.75percent",
					 text: batteryLevel > 100 ? "Daya luar" : "\(batteryLevel)%")
			}
			if let version = device.firmwareVersion, !version.isEmpty, version != "?.?.?" {
				fact(symbol: "cpu", text: version)
			}
		}
		.font(.footnote)
		.foregroundStyle(.secondary)
	}

	private func fact(symbol: String, text: String) -> some View {
		Label { Text(verbatim: text) } icon: { Image(systemName: symbol) }
			.labelStyle(.titleAndIcon)
	}
}

private struct SambungSignalBars: View {
	let level: Int

	var body: some View {
		HStack(alignment: .bottom, spacing: 2) {
			ForEach(1...3, id: \.self) { bar in
				RoundedRectangle(cornerRadius: 1.5)
					.fill(bar <= level ? SambungTheme.kunyit : Color(.tertiaryLabel))
					.frame(width: 4, height: CGFloat(4 + bar * 4))
			}
		}
		.accessibilityLabel(level == 3 ? "Sinyal kuat" : level == 2 ? "Sinyal sedang" : "Sinyal lemah")
	}
}

private struct SambungTip: View {
	let symbol: String
	let text: LocalizedStringKey

	var body: some View {
		Label { Text(text).font(.callout) } icon: { Image(systemName: symbol).foregroundStyle(.secondary) }
	}
}
