import SwiftUI

/// A stable color per host, used for snapshot placeholders.
enum HostTint {
    static func color(for host: String) -> Color {
        // djb2: stable across launches, unlike `hashValue`.
        let hash = host.unicodeScalars.reduce(UInt64(5381)) { ($0 << 5) &+ $0 &+ UInt64($1.value) }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.45, brightness: 0.75)
    }
}
