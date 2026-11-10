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
}
