import SwiftUI

/// Corner brackets + thirds.
struct ViewfinderBrackets: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let color: Color = .white.opacity(0.85)
            ZStack {
                ForEach(0..<4, id: \.self) { i in
                    Corner()
                        .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: 22, height: 22)
                        .rotationEffect(.degrees(Double(i) * 90))
                        .position(x: i == 0 || i == 3 ? 11 : w - 11, y: i < 2 ? 11 : h - 11)
                }
                ForEach([1.0 / 3, 2.0 / 3], id: \.self) { f in
                    Rectangle().fill(.white.opacity(0.14))
                        .frame(width: 1, height: h * 0.84)
                        .position(x: w * f, y: h / 2)
                }
            }
        }
    }

    private struct Corner: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.minX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            return p
        }
    }
}
