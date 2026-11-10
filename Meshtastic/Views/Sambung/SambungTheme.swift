//
//  SambungTheme.swift
//  Sambung
//
//  The few tokens Sambung adds. The accent (nila) comes from the asset catalog, so upstream
//  screens pick it up too; these are the signal colours used by the new screens.
//
import SwiftUI
import UIKit

enum SambungTheme {
	/// Turmeric: the "signal" colour — unread counts, pins, a live link.
	static let kunyit = dynamic(light: (0.86, 0.58, 0.00), dark: (0.98, 0.76, 0.18))
	/// Reached / delivered.
	static let daun = dynamic(light: (0.10, 0.56, 0.38), dark: (0.36, 0.84, 0.60))
	/// Failed, and SOS.
	static let bata = dynamic(light: (0.80, 0.20, 0.15), dark: (1.00, 0.45, 0.39))

	static let bubbleRadius: CGFloat = 20
	static let avatarSize: CGFloat = 48

	private static func dynamic(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
		Color(UIColor { traits in
			let c = traits.userInterfaceStyle == .dark ? dark : light
			return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
		})
	}
}

extension Font {
	/// Names and screen titles: rounded, so they read as friendly at a glance outdoors.
	static func sambungName(_ style: Font.TextStyle = .headline) -> Font {
		.system(style, design: .rounded, weight: .semibold)
	}
}

/// A person is a circle, a channel (many people) is a rounded square.
struct SambungAvatar: View {
	enum Kind {
		case user(shortName: String, num: Int64)
		case channel(name: String)
	}

	let kind: Kind
	var size: CGFloat = SambungTheme.avatarSize

	var body: some View {
		switch kind {
		case let .user(shortName, num):
			CircleText(text: shortName, color: Color(UIColor(hex: UInt32(truncatingIfNeeded: num))), circleSize: size)
				.accessibilityHidden(true)
		case let .channel(name):
			RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
				.fill(Color.accentFill)
				.frame(width: size, height: size)
				.overlay {
					Text(verbatim: String(name.first ?? "#").uppercased())
						.font(.system(size: size * 0.44, weight: .bold, design: .rounded))
						.foregroundStyle(.white)
				}
				.accessibilityHidden(true)
		}
	}
}

/// You, the relays in between, and them: the link drawn as a thread.
struct SambungReachThread: View {
	let reach: SambungReach

	var body: some View {
		HStack(spacing: 3) {
			dot(filled: true)
			ForEach(0..<reach.relayCount, id: \.self) { _ in
				line
				Circle().fill(tint).frame(width: 5, height: 5)
			}
			line
			dot(filled: reach.isReachable)
		}
		.accessibilityHidden(true)
	}

	private var tint: Color { reach.isReachable ? SambungTheme.kunyit : Color(.tertiaryLabel) }

	private var line: some View {
		Capsule().fill(tint).frame(width: 12, height: 2)
	}

	private func dot(filled: Bool) -> some View {
		Circle()
			.strokeBorder(tint, lineWidth: 2)
			.background(Circle().fill(filled ? tint : .clear))
			.frame(width: 9, height: 9)
	}
}
