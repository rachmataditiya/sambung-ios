//
//  SambungVoice.swift
//  Sambung
//
//  Voice messages: record up to ten seconds, hear what the other side will hear, send; and
//  the player inside a message bubble.
//
import AVFoundation
import OSLog
import SwiftUI

/// Records from the microphone straight to 8 kHz mono, the format Codec2 takes.
@MainActor
final class SambungVoiceRecorder: NSObject, ObservableObject {
	enum State: Equatable { case idle, recording, recorded, denied, failed(String) }

	@Published private(set) var state = State.idle
	@Published private(set) var elapsed: TimeInterval = 0
	/// The clip after encoding and decoding again: exactly what the recipient will hear.
	private(set) var encoded = Data()

	private var recorder: AVAudioRecorder?
	private var player: AVAudioPlayer?
	private var timer: Timer?
	private let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("sambung-voice.wav")

	func start() {
		AVAudioApplication.requestRecordPermission { [weak self] granted in
			Task { @MainActor in
				guard let self else { return }
				guard granted else {
					self.state = .denied
					return
				}
				self.beginRecording()
			}
		}
	}

	private func beginRecording() {
		do {
			let session = AVAudioSession.sharedInstance()
			try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
			try session.setActive(true)
			let settings: [String: Any] = [
				AVFormatIDKey: kAudioFormatLinearPCM,
				AVSampleRateKey: SambungVoiceCodec.sampleRate,
				AVNumberOfChannelsKey: 1,
				AVLinearPCMBitDepthKey: 16,
				AVLinearPCMIsFloatKey: false,
				AVLinearPCMIsBigEndianKey: false
			]
			let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
			guard recorder.record(forDuration: TimeInterval(SambungVoiceCodec.maxSeconds)) else {
				state = .failed("Perekaman tidak bisa dimulai.")
				return
			}
			self.recorder = recorder
			elapsed = 0
			state = .recording
			timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
				Task { @MainActor in self?.tick() }
			}
		} catch {
			state = .failed(error.localizedDescription)
		}
	}

	private func tick() {
		guard let recorder else { return }
		if recorder.isRecording {
			elapsed = recorder.currentTime
		} else {
			stop() // reached the ten-second limit
		}
	}

	func stop() {
		timer?.invalidate()
		timer = nil
		guard let recorder else { return }
		recorder.stop()
		self.recorder = nil
		do {
			let samples = try Self.samples(from: fileURL)
			guard samples.count >= SambungVoiceCodec.sampleRate / 2 else {
				state = .failed("Rekaman terlalu pendek. Tahan sedikit lebih lama.")
				return
			}
			encoded = SambungVoiceCodec.encode(samples)
			elapsed = SambungVoiceCodec.seconds(forByteCount: encoded.count)
			state = .recorded
		} catch {
			state = .failed(error.localizedDescription)
		}
	}

	func playPreview() {
		player = try? AVAudioPlayer(data: SambungVoiceCodec.wav(SambungVoiceCodec.decode(encoded)))
		player?.play()
	}

	func reset() {
		player?.stop()
		encoded = Data()
		elapsed = 0
		state = .idle
	}

	private static func samples(from url: URL) throws -> [Int16] {
		let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
		guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
		try file.read(into: buffer)
		guard let channel = buffer.int16ChannelData else { return [] }
		return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
	}
}

/// The microphone button next to the photo button.
struct SambungVoiceButton: View {
	@EnvironmentObject private var accessoryManager: AccessoryManager
	let destination: MessageDestination
	@State private var isRecording = false
	@State private var isShowingNotAllowed = false

	var body: some View {
		Button {
			if SambungTransfer.isAllowed(destination) { isRecording = true } else { isShowingNotAllowed = true }
		} label: {
			Image(systemName: "mic")
				.font(.subheadline)
				.padding(8)
				.background(Color(.secondarySystemBackground), in: Circle())
		}
		.buttonStyle(.plain)
		.accessibilityLabel("Kirim pesan suara")
		.sheet(isPresented: $isRecording) {
			SambungVoiceSheet(destination: destination)
				.environmentObject(accessoryManager)
		}
		.alert("Pesan suara tidak bisa dikirim ke channel ini", isPresented: $isShowingNotAllowed) {
			Button("Mengerti", role: .cancel) {}
		} message: {
			Text("Satu pesan suara memakai radio puluhan detik dan semua orang di channel publik harus menunggu. Kirim lewat pesan langsung atau channel privat.")
		}
	}
}

private struct SambungVoiceSheet: View {
	@EnvironmentObject private var accessoryManager: AccessoryManager
	@Environment(\.dismiss) private var dismiss
	@StateObject private var recorder = SambungVoiceRecorder()
	let destination: MessageDestination
	@State private var errorText: String?

	var body: some View {
		NavigationStack {
			VStack(spacing: 24) {
				Spacer(minLength: 0)
				Text(verbatim: SambungVoiceCodec.durationText(recorder.elapsed))
					.font(.system(size: 56, weight: .semibold, design: .rounded))
					.monospacedDigit()
					.foregroundStyle(recorder.state == .recording ? SambungTheme.bata : Color.primary)

				ProgressView(value: min(recorder.elapsed, Double(SambungVoiceCodec.maxSeconds)), total: Double(SambungVoiceCodec.maxSeconds))
					.tint(SambungTheme.kunyit)
					.padding(.horizontal, 40)

				controls

				Text(verbatim: hint)
					.font(.footnote)
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
					.padding(.horizontal, 24)
				if let errorText {
					Text(verbatim: errorText).font(.footnote).foregroundStyle(SambungTheme.bata)
				}
				Spacer(minLength: 0)
			}
			.navigationTitle("Pesan suara")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button("Batal") { dismiss() } }
				ToolbarItem(placement: .confirmationAction) {
					Button("Kirim", action: send).disabled(recorder.state != .recorded)
				}
			}
		}
		.presentationDetents([.medium])
		.onDisappear { recorder.reset() }
	}

	@ViewBuilder
	private var controls: some View {
		switch recorder.state {
		case .idle, .denied, .failed:
			bigButton("Rekam", symbol: "mic.fill", tint: SambungTheme.bata) { recorder.start() }
		case .recording:
			bigButton("Selesai", symbol: "stop.fill", tint: SambungTheme.bata) { recorder.stop() }
		case .recorded:
			HStack(spacing: 28) {
				bigButton("Dengarkan", symbol: "play.fill", tint: .accentColor) { recorder.playPreview() }
				bigButton("Ulangi", symbol: "arrow.counterclockwise", tint: .secondary) { recorder.reset() }
			}
		}
	}

	private func bigButton(_ title: LocalizedStringKey, symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			VStack(spacing: 8) {
				Image(systemName: symbol)
					.font(.title)
					.foregroundStyle(.white)
					.frame(width: 72, height: 72)
					.background(tint, in: Circle())
				Text(title).font(.footnote).foregroundStyle(.primary)
			}
		}
		.buttonStyle(.plain)
	}

	private var hint: String {
		switch recorder.state {
		case .idle: return "Paling lama \(SambungVoiceCodec.maxSeconds) detik. Bicara dekat ke mikrofon."
		case .recording: return "Merekam…"
		case .recorded:
			let seconds = SambungTransfer.estimatedSeconds(forByteCount: recorder.encoded.count)
			return "Dengarkan dulu: begitulah suaranya di penerima. Terkirim dalam kira-kira \(seconds) detik."
		case .denied: return "Sambung belum diizinkan memakai mikrofon. Izinkan di Pengaturan iPhone."
		case let .failed(message): return message
		}
	}

	private func send() {
		guard accessoryManager.isConnected else {
			errorText = "Belum tersambung ke radio."
			return
		}
		let clip = recorder.encoded, destination = destination, manager = accessoryManager
		let placeholder = SambungVoiceCodec.placeholder(seconds: SambungVoiceCodec.seconds(forByteCount: clip.count))
		// The transfer runs on after the sheet closes; progress shows in the bubble.
		Task {
			do {
				try await SambungTransfer.shared.send(
					clip, kind: .voice, codec: SambungVoiceCodec.codec2Mode700C,
					placeholder: placeholder, to: destination, accessoryManager: manager
				)
			} catch {
				Logger.mesh.error("Sambung voice send failed: \(error.localizedDescription, privacy: .public)")
			}
		}
		dismiss()
	}
}

/// A received or sent voice clip: play button and length.
struct SambungVoicePlayer: View {
	let url: URL
	let tint: Color
	@State private var player: AVAudioPlayer?
	@State private var isPlaying = false

	private var seconds: Double {
		let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
		return SambungVoiceCodec.seconds(forByteCount: size)
	}

	var body: some View {
		Button(action: toggle) {
			HStack(spacing: 10) {
				Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
					.font(.system(size: 34))
				VStack(alignment: .leading, spacing: 1) {
					Text("Pesan suara").font(.subheadline.weight(.semibold))
					Text(verbatim: SambungVoiceCodec.durationText(seconds)).font(.footnote).monospacedDigit().opacity(0.8)
				}
			}
			.foregroundStyle(tint)
		}
		.buttonStyle(.plain)
		.accessibilityLabel(isPlaying ? "Hentikan pesan suara" : "Putar pesan suara")
	}

	private func toggle() {
		if isPlaying {
			player?.stop()
			isPlaying = false
			return
		}
		guard let clip = try? Data(contentsOf: url) else { return }
		let samples = SambungVoiceCodec.decode(clip)
		try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
		player = try? AVAudioPlayer(data: SambungVoiceCodec.wav(samples))
		guard let player, player.play() else { return }
		isPlaying = true
		Task {
			try? await Task.sleep(for: .seconds(player.duration + 0.1))
			isPlaying = false
		}
	}
}
