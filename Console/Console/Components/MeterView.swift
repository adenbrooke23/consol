import SwiftUI

// 5-bar VU meter. Lemon and animating only when live; parked at 12% in ink3
// otherwise. Static under Reduce Motion. Ambient meters appear only where audio is.
struct MeterView: View {
    var live: Bool
    var bars: Int = 5
    var height: CGFloat = 20

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let animate = live && !reduceMotion
        TimelineView(.animation(paused: !animate)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<bars, id: \.self) { i in
                    Capsule()
                        .fill(live ? Theme.signal : Theme.ink3)
                        .frame(width: 4, height: barHeight(i, t, animate))
                }
            }
            .frame(height: height, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }

    private func barHeight(_ i: Int, _ t: TimeInterval, _ animate: Bool) -> CGFloat {
        guard animate else { return height * (live ? 0.6 : 0.12) }
        let phase = Double(i) * 0.7
        let v = 0.5 + 0.5 * sin(t * 5.5 + phase)
        return height * CGFloat(max(0.12, v))
    }
}
