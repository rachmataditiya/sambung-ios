//
//  SambungLocationBubble.swift
//  Sambung
//
//  A shared location inside a message bubble: a small map, and the distance and direction
//  from where you are, which still helps when there is no internet for map tiles.
//
import CoreLocation
import MapKit
import SwiftUI

struct SambungLocationBubble: View {
	let coordinate: CLLocationCoordinate2D
	let isCurrentUser: Bool

	var body: some View {
		Button(action: openInMaps) {
			VStack(alignment: .leading, spacing: 6) {
				Map(
					initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 1200, longitudinalMeters: 1200)),
					interactionModes: []
				) {
					Marker("", coordinate: coordinate)
				}
				.frame(width: 220, height: 120)
				.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
				.allowsHitTesting(false)

				if !isCurrentUser, let here = LocationsHandler.currentLocation {
					Text(verbatim: SambungLocationMessage.distanceText(from: here, to: coordinate))
						.font(.subheadline.weight(.semibold))
				}
				Text(verbatim: String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude))
					.font(.footnote)
					.monospacedDigit()
					.opacity(0.75)
				Label("Buka di Peta", systemImage: "arrow.up.right.square")
					.font(.footnote.weight(.semibold))
			}
			.frame(width: 220, alignment: .leading)
		}
		.buttonStyle(.plain)
		.accessibilityLabel(isCurrentUser ? sambungText("Lokasi yang kamu bagikan") : sambungText("Lokasi yang dibagikan"))
		.accessibilityHint("Buka di Peta")
	}

	private func openInMaps() {
		let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
		item.name = sambungText("Lokasi dibagikan")
		// Apple's Maps may have been removed from the phone; the web address opens whichever
		// maps app is there, or the browser.
		guard !item.openInMaps(), let web = URL(string: "https://www.google.com/maps/search/?api=1&query=\(coordinate.latitude),\(coordinate.longitude)") else { return }
		UIApplication.shared.open(web)
	}
}
