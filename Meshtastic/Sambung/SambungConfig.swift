//
//  SambungConfig.swift
//  Sambung
//
//  Sambung is a modified version of Meshtastic-Apple (GPL-3.0), changed from November 2026.
//
import Foundation

enum SambungConfig {
	/// The Datadog keys in MeshtasticApp belong to the Meshtastic project. Sambung must not
	/// send its crash reports and usage data there, so the SDK is never initialized.
	static let upstreamTelemetryEnabled = false

	static let sourceURL = URL(string: "https://github.com/rachmataditiya/sambung-ios")!

	static let languageKey = "sambung.language"
	/// Indonesian first; English is the other language Sambung is written in.
	static let languages = [("id", "Indonesia"), ("en", "English")]

	/// The app's language is the one picked in Perangkat, Indonesian until one is picked. iOS
	/// reads this once per launch, so a change shows the next time the app opens.
	static func applyLanguage(_ defaults: UserDefaults = .standard) {
		let picked = defaults.string(forKey: languageKey) ?? "id"
		defaults.set([languages.contains { $0.0 == picked } ? picked : "id"], forKey: "AppleLanguages")
	}
}

/// Sambung's own strings are written in Indonesian in the code, and the string catalog carries
/// their English (scripts/sambung-en.json). A `Text("…")` literal goes through the catalog on
/// its own; this is for strings built in code. Arguments use format specifiers: %@, %lld.
func sambungText(_ key: String, _ arguments: CVarArg...) -> String {
	let format = NSLocalizedString(key, comment: "")
	return arguments.isEmpty ? format : String(format: format, locale: .current, arguments: arguments)
}
