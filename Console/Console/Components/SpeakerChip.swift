import SwiftUI

// A group-member chip (shared by the music card's Speakers section and the
// transport bar's routing strip). Indigo-500 fill when in-group; a small
// lemon dot marks live routing. Tap to add/remove the room.
struct SpeakerChip: View {
    let name: String
    let inGroup: Bool
    let live: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if live {
                    Circle().fill(Theme.signal).frame(width: 5, height: 5)   // live routing dot
                }
                Text(name).font(.custom(FontStack.ui.medium, size: 12.5))
                    .foregroundStyle(inGroup ? Theme.ink : Theme.ink2)
            }
            .padding(.vertical, 7).padding(.horizontal, Theme.Space.s3)
            .background(inGroup ? Theme.Indigo.i500 : .clear)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(inGroup ? .clear : Theme.rule, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name)\(inGroup ? ", in group" : "")")
        .accessibilityAddTraits(inGroup ? [.isButton, .isSelected] : .isButton)
    }
}
