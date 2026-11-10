//
//  MeshtasticLogo.swift
//  Meshtastic
//
//  Copyright(c) Garth Vander Houwen 10/6/22.
//  Modified for Sambung, November 2026: shows the Sambung wordmark instead of the Meshtastic mark.
//
import SwiftUI

/// The top-left nav mark. The type keeps its upstream name so the call sites stay untouched.
struct MeshtasticLogo: View {

	var body: some View {
		Link(destination: URL(string: "meshtastic:///settings/about")!) {
			Text(verbatim: "Sambung")
				.font(.system(.title3, design: .rounded, weight: .bold))
				.foregroundStyle(Color.accentColor)
				.lineLimit(1)
				.minimumScaleFactor(0.6)
		}
		.accessibilityLabel(Text(verbatim: "Sambung"))
	}
}

#Preview {
	MeshtasticLogo()
		.frame(width: 200, height: 44)
}
