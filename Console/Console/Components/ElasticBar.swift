import SwiftUI

// The elastic rail used for volume and the film scrubber. At rest it's a 4pt
// hairline; under the finger it swells to 12pt and its fill turns solid white
// ("what you grab"). No thumb: the fill edge is the value. On release it
// exhales back. The parent turns its readout lemon while `active` (live under
// the finger). Static under Reduce Motion.

struct ElasticBar: View {
    @Binding var value: Double            // 0…1
    var onActiveChange: ((Bool) -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var active = false

    private var restHeight: CGFloat = 4
    private var liveHeight: CGFloat = 12

    init(value: Binding<Double>, onActiveChange: ((Bool) -> Void)? = nil) {
        self._value = value
        self.onActiveChange = onActiveChange
    }

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let h = active ? liveHeight : restHeight
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.well).frame(height: h)
                Capsule()
                    .fill(active ? Theme.grab : Theme.ink2)   // white only while grabbed
                    .frame(width: min(w, max(h, w * value)), height: h)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !active { setActive(true) }
                        value = min(1, max(0, g.location.x / w))
                    }
                    .onEnded { _ in setActive(false) }
            )
            .animation(reduceMotion ? nil : Theme.Motion.elastic, value: active)
        }
        .frame(height: 24)                                     // stable touch target
        .accessibilityElement()
        .accessibilityValue("\(Int(value * 100)) percent")
        .accessibilityAdjustableAction { direction in
            let step = 0.05
            value = min(1, max(0, value + (direction == .increment ? step : -step)))
        }
    }

    private func setActive(_ v: Bool) {
        active = v
        onActiveChange?(v)
    }
}
