//
//  SambungVoice.swift
//  Sambung
//
//  Voice messages, push to talk: hold the button to record up to ten seconds, let go to send.
//  A clip that arrives for the open conversation plays at once; the bubble can replay it.
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
	/// Cleared when the talk button is let go, so a late permission answer does not start recording.
	var isWanted = true

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
				// The microphone prompt can outlast the press that asked for it.
				guard self.isWanted else { return }
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
				state = .failed(sambungText("Perekaman tidak bisa dimulai."))
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
				state = .failed(sambungText("Rekaman terlalu pendek. Tahan sedikit lebih lama."))
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

/// What the bar above the message field shows while the talk button is held.
struct SambungTalkState: Equatable {
	var elapsed: TimeInterval
	/// The finger slid away: letting go now throws the recording away.
	var willCancel: Bool
}

/// Push to talk: hold to record, let go to send, slide left to cancel. There is no second step,
/// so a voice message is as quick as on a handheld radio.
struct SambungTalkButton: View {
	@EnvironmentObject private var accessoryManager: AccessoryManager
	let destination: MessageDestination
	@Binding var talk: SambungTalkState?
	@StateObject private var recorder = SambungVoiceRecorder()
	@State private var isPressed = false
	@State private var willCancel = false
	@State private var isShowingNotAllowed = false

	/// How far left the finger has to slide for letting go to mean cancel.
	static let cancelDistance: CGFloat = 70

	var body: some View {
		Image(systemName: isPressed ? "mic.fill" : "mic")
			.font(.title3)
			.foregroundStyle(isPressed ? Color.white : Color.accentColor)
			.frame(width: 48, height: 36)
			.background(isPressed ? SambungTheme.bata : Color(.secondarySystemBackground), in: Capsule())
			.scaleEffect(isPressed ? 1.2 : 1)
			.animation(.snappy, value: isPressed)
			.contentShape(Capsule())
			.gesture(
				DragGesture(minimumDistance: 0)
					.onChanged { value in
						if !isPressed { press() }
						willCancel = value.translation.width < -Self.cancelDistance
					}
					.onEnded { _ in release() }
			)
			.sensoryFeedback(.impact, trigger: isPressed)
			.onChange(of: recorder.state) { _, state in finished(state) }
			.onChange(of: recorder.elapsed) { publish() }
			.onChange(of: willCancel) { publish() }
			.accessibilityLabel("Tahan untuk bicara")
			.accessibilityHint("Lepas untuk kirim, geser ke kiri untuk batal")
			.accessibilityAddTraits(.isButton)
			.alert("Pesan suara tidak bisa dikirim ke channel ini", isPresented: $isShowingNotAllowed) {
				Button("Mengerti", role: .cancel) {}
			} message: {
				Text("Satu pesan suara memakai radio puluhan detik dan semua orang di channel publik harus menunggu. Kirim lewat pesan langsung atau channel privat.")
			}
	}

	private func press() {
		isPressed = true
		willCancel = false
		guard SambungTransfer.isAllowed(destination) else {
			isShowingNotAllowed = true
			return
		}
		recorder.isWanted = true
		recorder.start()
		publish()
	}

	private func release() {
		guard isPressed else { return }
		isPressed = false
		recorder.isWanted = false
		if recorder.state == .recording {
			recorder.stop() // ends in .recorded or .failed, handled in finished(_:)
		} else {
			// Let go before recording began (the microphone prompt), or after the ten seconds ran out.
			recorder.reset()
			talk = nil
		}
	}

	private func finished(_ state: SambungVoiceRecorder.State) {
		switch state {
		case .recorded:
			if !willCancel { send(recorder.encoded) }
			recorder.reset()
			talk = nil
		case .failed, .denied:
			// Too short to be a message, or no microphone: nothing to send.
			recorder.reset()
			talk = nil
		case .idle, .recording:
			break
		}
	}

	private func publish() {
		talk = isPressed ? SambungTalkState(elapsed: recorder.elapsed, willCancel: willCancel) : nil
	}

	private func send(_ clip: Data) {
		guard accessoryManager.isConnected, !clip.isEmpty else { return }
		let destination = destination, manager = accessoryManager
		let placeholder = SambungVoiceCodec.placeholder(seconds: SambungVoiceCodec.seconds(forByteCount: clip.count))
		// The transfer runs on; progress shows in the bubble.
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
	}
}

/// Covers the quick replies while talking: how long so far, and what letting go will do.
struct SambungTalkStrip: View {
	let state: SambungTalkState

	var body: some View {
		HStack(spacing: 10) {
			Circle()
				.fill(SambungTheme.bata)
				.frame(width: 10, height: 10)
				.symbolEffect(.pulse)
			Text(verbatim: SambungVoiceCodec.durationText(state.elapsed))
				.font(.headline)
				.monospacedDigit()
			Spacer(minLength: 8)
			Text(state.willCancel ? "Lepas untuk batal" : "Lepas untuk kirim, geser ke kiri untuk batal")
				.font(.footnote)
				.foregroundStyle(state.willCancel ? SambungTheme.bata : Color.secondary)
				.lineLimit(1)
				.minimumScaleFactor(0.8)
		}
		.padding(.horizontal, 12)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background(Color(.systemBackground))
		.accessibilityElement(children: .combine)
	}
}

/// Plays a voice clip the moment it arrives for the conversation on screen, like a handheld
/// radio; other clips wait for their play button.
@MainActor
final class SambungVoicePlayback {
	static let shared = SambungVoicePlayback()

	/// The conversation on screen.
	var open: SambungRoute?
	private var player: AVAudioPlayer?

	nonisolated static func shouldPlay(open: SambungRoute?, from: Int64, isDirect: Bool, channel: UInt32) -> Bool {
		switch open {
		case let .user(num): return isDirect && num == from
		case let .channel(index): return !isDirect && UInt32(max(0, index)) == channel
		case nil: return false
		}
	}

	func arrived(_ clip: Data, from: Int64, isDirect: Bool, channel: UInt32) {
		guard Self.shouldPlay(open: open, from: from, isDirect: isDirect, channel: channel) else { return }
		try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
		try? AVAudioSession.sharedInstance().setActive(true)
		player = try? AVAudioPlayer(data: SambungVoiceCodec.wav(SambungVoiceCodec.decode(clip)))
		player?.play()
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
		.accessibilityLabel(isPlaying ? sambungText("Hentikan pesan suara") : sambungText("Putar pesan suara"))
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
