import SwiftUI

struct WombatGlyph: Shape {
    static let points: [CGPoint] = [
        .init(x: 0.08, y: 0.20), .init(x: 0.29, y: 0.80),
        .init(x: 0.50, y: 0.38), .init(x: 0.71, y: 0.80),
        .init(x: 0.92, y: 0.20)
    ]

    func path(in rect: CGRect) -> Path {
        Path { path in
            path.addLines(Self.points.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) })
        }
    }
}

struct WombatMark: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.25)
                .fill(Color(red: 0.14, green: 0.18, blue: 0.14))
            WombatGlyph()
                .stroke(Color(red: 0.98, green: 0.77, blue: 0.50),
                        style: StrokeStyle(lineWidth: size * 0.09, lineCap: .round, lineJoin: .round))
                .padding(size * 0.18)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
