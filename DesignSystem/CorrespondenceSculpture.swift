import SwiftUI
import simd

/// A static, orthographically projected sculpture, authored as two open toroidal forms.
/// Geometry and lighting are calculated once. No display link, network, or bitmap assets.
struct CorrespondenceSculpture: View {
    var exportQuality = false
    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            Canvas { context, size in
                let scale = min(size.width, size.height) * 0.53
                for face in (exportQuality ? SculptureGeometry.exportFaces : SculptureGeometry.faces) {
                    var path = Path()
                    for (index, point) in face.points.enumerated() {
                        let projected = CGPoint(x: size.width / 2 + point.x * scale,
                                                y: size.height / 2 - point.y * scale)
                        if index == 0 { path.move(to: projected) } else { path.addLine(to: projected) }
                    }
                    path.closeSubpath()
                    context.fill(path, with: .color(face.color))
                    // A subpixel seam seal avoids cracks between adjacent projected facets.
                    context.stroke(path, with: .color(face.color), lineWidth: 0.25)
                }
            }
            .shadow(color: .black.opacity(0.35), radius: side * 0.035, x: side * 0.018, y: side * 0.07)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

private enum SculptureGeometry {
    struct Face {
        let points: [SIMD3<Double>]
        let depth: Double
        let color: Color
    }

    static let faces = makeFaces(steps: 240, sides: 96)
    static let exportFaces = makeFaces(steps: 540, sides: 288)

    private static func makeFaces(steps: Int, sides: Int) -> [Face] {
        var result: [Face] = []
        for ring in 0..<2 {
            let radius = ring == 0 ? 0.68 : 0.37
            let tube = ring == 0 ? 0.135 : 0.105
            let start = ring == 0 ? 0.45 : 3.55
            let extent = 4.9
            let base = ring == 0 ? SIMD3<Double>(0.84, 0.73, 0.53) : SIMD3<Double>(0.66, 0.79, 0.85)
            func point(_ u: Double, _ v: Double) -> SIMD3<Double> {
                rotate(SIMD3((radius + tube * cos(v)) * cos(u),
                             (radius + tube * cos(v)) * sin(u), tube * sin(v)))
            }
            for i in 0..<steps {
                let u = start + Double(i) / Double(steps) * extent
                let nextU = start + Double(i + 1) / Double(steps) * extent
                for j in 0..<sides {
                    let v = Double(j) / Double(sides) * 2 * Double.pi
                    let nextV = Double(j + 1) / Double(sides) * 2 * Double.pi
                    let midU = (u + nextU) / 2
                    let midV = (v + nextV) / 2
                    let normal = rotate(SIMD3(cos(midV) * cos(midU), cos(midV) * sin(midU), sin(midV)))
                    guard normal.z > -0.08 else { continue }
                    let points = [point(u, v), point(nextU, v), point(nextU, nextV), point(u, nextV)]
                    result.append(Face(points: points, depth: points.map(\.z).reduce(0, +) / 4,
                                       color: shade(normal, base: base)))
                }
            }
            // Flat polished end caps make the opening feel machined, rather than painted.
            for (u, direction) in [(start, -1.0), (start + extent, 1.0)] {
                let normal = rotate(SIMD3(-sin(u) * direction, cos(u) * direction, 0))
                if normal.z > 0 {
                    let center = rotate(SIMD3(radius * cos(u), radius * sin(u), 0))
                    for j in 0..<sides {
                        let points = [center, point(u, Double(j) / Double(sides) * 2 * .pi),
                                      point(u, Double(j + 1) / Double(sides) * 2 * .pi)]
                        result.append(Face(points: points, depth: points.map(\.z).reduce(0, +) / 3,
                                           color: shade(normal, base: base)))
                    }
                }
            }
        }
        return result.sorted { $0.depth < $1.depth }
    }

    private static func rotate(_ p: SIMD3<Double>) -> SIMD3<Double> {
        let x = 0.42, y = -0.33, z = -0.23
        let a = SIMD3(p.x, p.y * cos(x) - p.z * sin(x), p.y * sin(x) + p.z * cos(x))
        let b = SIMD3(a.x * cos(y) + a.z * sin(y), a.y, -a.x * sin(y) + a.z * cos(y))
        return SIMD3(b.x * cos(z) - b.y * sin(z), b.x * sin(z) + b.y * cos(z), b.z)
    }

    private static func shade(_ normal: SIMD3<Double>, base: SIMD3<Double>) -> Color {
        let light = simd_normalize(SIMD3<Double>(-0.6, 0.8, 1.1))
        let halfway = simd_normalize(light + SIMD3<Double>(0, 0, 1))
        let diffuse = max(0, simd_dot(normal, light))
        let highlight = pow(max(0, simd_dot(normal, halfway)), 42) * 0.8
        let rim = pow(1 - max(0, normal.z), 3) * 0.28
        let reflectedBand = pow(max(0, 1 - abs(normal.y - 0.32) * 3), 8) * 0.28
        let rgb = base * (0.28 + diffuse * 0.67 + reflectedBand) + SIMD3(repeating: highlight + rim)
        return Color(.sRGB, red: min(1, rgb.x), green: min(1, rgb.y), blue: min(1, rgb.z))
    }
}
