// swift-tools-version:5.9
// Codec2 1.2.0 (https://github.com/drowe67/codec2), the speech codec only: the modem,
// FreeDV and LDPC parts are left out. LGPL-2.1, see COPYING. The C sources are unmodified;
// the codebook*.c files and codec2/version.h are the ones its CMake build generates.
import PackageDescription

let package = Package(
	name: "Codec2",
	platforms: [.iOS(.v15), .macOS(.v12), .macCatalyst(.v15)],
	products: [
		.library(name: "Codec2", targets: ["Codec2"])
	],
	targets: [
		.target(
			name: "Codec2",
			path: "Sources/Codec2",
			publicHeadersPath: "include",
			cSettings: [.unsafeFlags(["-w"])] // upstream C, not ours to tidy
		),
		.testTarget(name: "Codec2Tests", dependencies: ["Codec2"], path: "Tests/Codec2Tests")
	]
)
