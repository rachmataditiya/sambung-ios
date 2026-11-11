//
//  SambungLocationMessage.swift
//  Sambung
//
//  A shared location is an ordinary text message ("📍 Lokasi saya: -6.20880, 106.84560"), so
//  every Meshtastic client can read it. Sambung recognises the pattern and draws a map bubble.
//
import CoreLocation
import Foundation

enum SambungLocationMessage {
	static func text(for coordinate: CLLocationCoordinate2D) -> String {
		// 5 decimals is about a metre; en_US_POSIX keeps the decimal point a point.
		String(format: "📍 Lokasi saya: %.5f, %.5f", locale: Locale(identifier: "en_US_POSIX"), coordinate.latitude, coordinate.longitude)
	}

	/// The coordinate in a message that starts its location with the pin, or nil for ordinary text.
	static func coordinate(in text: String) -> CLLocationCoordinate2D? {
		guard let match = text.firstMatch(of: #/📍[^\d\-]*(-?\d{1,2}\.\d{3,}),\s*(-?\d{1,3}\.\d{3,})/#),
			  let latitude = Double(match.1), let longitude = Double(match.2),
			  abs(latitude) <= 90, abs(longitude) <= 180 else { return nil }
		return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
	}

	/// What a message says besides its position (an SOS call, a note), or nil when the position
	/// is all there is.
	static func caption(in text: String) -> String? {
		guard let match = text.firstMatch(of: #/📍[^\d\-]*(-?\d{1,2}\.\d{3,}),\s*(-?\d{1,3}\.\d{3,})/#) else { return nil }
		var rest = text
		rest.removeSubrange(match.range)
		// The bell an SOS starts with is for radios to ring, not for reading.
		let caption = rest.replacingOccurrences(of: "\u{07}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
		return caption.isEmpty ? nil : caption
	}

	/// "1,2 km ke arah timur laut": readable with no map tiles at all.
	static func distanceText(from origin: CLLocationCoordinate2D, to target: CLLocationCoordinate2D) -> String {
		let meters = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
			.distance(from: CLLocation(latitude: target.latitude, longitude: target.longitude))
		if meters < 15 { return sambungText("Di tempat yang sama denganmu") }
		let distance = meters < 1000
			? "\(Int((meters / 10).rounded()) * 10) m"
			: String(format: "%.1f km", locale: .current, meters / 1000)
		return sambungText("%@ ke arah %@", distance, compassName(bearing(from: origin, to: target)))
	}

	static func bearing(from origin: CLLocationCoordinate2D, to target: CLLocationCoordinate2D) -> Double {
		let lat1 = origin.latitude * .pi / 180, lat2 = target.latitude * .pi / 180
		let deltaLon = (target.longitude - origin.longitude) * .pi / 180
		let y = sin(deltaLon) * cos(lat2)
		let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLon)
		return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
	}

	static func compassName(_ bearing: Double) -> String {
		let names = [sambungText("utara"), sambungText("timur laut"), sambungText("timur"), sambungText("tenggara"), sambungText("selatan"), sambungText("barat daya"), sambungText("barat"), sambungText("barat laut")]
		return names[Int((bearing + 22.5) / 45) % 8]
	}
}
