import SwiftUI

/// 图标的一笔（由 tools/gen_design.py 从 doc/icons.json 生成数据）。
/// ops 编码：0 x y＝移到；1 x y＝直线；2 x1 y1 x2 y2 x y＝三次曲线；3＝闭合。坐标在 24×24 网格里。
struct IconElement: Sendable {
    let fill: Bool
    let evenOdd: Bool
    let width: CGFloat
    let ops: [CGFloat]

    func path(scale k: CGFloat) -> Path {
        var p = Path()
        var i = 0
        let o = ops
        while i < o.count {
            switch Int(o[i]) {
            case 0: p.move(to: CGPoint(x: o[i + 1] * k, y: o[i + 2] * k)); i += 3
            case 1: p.addLine(to: CGPoint(x: o[i + 1] * k, y: o[i + 2] * k)); i += 3
            case 2:
                p.addCurve(
                    to: CGPoint(x: o[i + 5] * k, y: o[i + 6] * k),
                    control1: CGPoint(x: o[i + 1] * k, y: o[i + 2] * k),
                    control2: CGPoint(x: o[i + 3] * k, y: o[i + 4] * k))
                i += 7
            default: p.closeSubpath(); i += 1
            }
        }
        return p
    }
}

enum Icons {
    static func exists(_ name: String) -> Bool { IconData.all[name] != nil }
}

/// 两端一样的矢量图标。name 用 Ionicons 的命名；没有的名字什么都不画。
struct ZIcon: View {
    let name: String
    var size: CGFloat = 24
    var color: Color = C.labelPrimary

    var body: some View {
        // 有对应的苹果系统图标（SF Symbols）就用系统的；没有的才用我们自己的矢量数据
        if let sym = SymbolName.all[name] {
            Image(systemName: sym)
                .resizable()
                .scaledToFit()
                .foregroundStyle(color)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            drawn
        }
    }

    private var drawn: some View {
        Canvas { ctx, sz in
            guard let els = IconData.all[name] else { return }
            let k = min(sz.width, sz.height) / 24
            for e in els {
                let path = e.path(scale: k)
                if e.fill {
                    ctx.fill(path, with: .color(color), style: FillStyle(eoFill: e.evenOdd))
                } else {
                    ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: e.width * k, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// 后退 15 / 前进 30 秒：用系统自带的图标（SF Symbols，和锁屏、控制中心同一套）。
struct SeekIcon: View {
    let forward: Bool
    var size: CGFloat
    var color: Color = C.labelPrimary

    var body: some View {
        Image(systemName: forward ? "goforward.\(Int(SEEK_FORWARD_SECONDS))" : "gobackward.\(Int(SEEK_BACK_SECONDS))")
            .resizable()
            .scaledToFit()
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
