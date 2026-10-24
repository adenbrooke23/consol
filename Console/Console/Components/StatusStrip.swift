import SwiftUI

// 36pt bottom strip, Label type only: hub state · session count · profile ·
// live clock. Hub offline turns the dot and text alert; no modal. Clock
// updates each minute.
struct StatusStrip: View {
    var hubOnline: Bool = true
    var sessionCount: Int
    var profileName: String

    var body: some View {
        HStack(spacing: Theme.Space.s5) {
            HStack(spacing: 6) {
                Circle()
                    .fill(hubOnline ? Theme.online : Theme.alert)   // green when online; the only green
                    .frame(width: 6, height: 6)
                Text(hubOnline ? "Hub Online" : "Hub Offline")
                    .typo(.label)
                    .foregroundStyle(hubOnline ? Theme.ink2 : Theme.alert)
            }
            Text("\(sessionCount) \(sessionCount == 1 ? "Session" : "Sessions")")
                .typo(.label).foregroundStyle(Theme.ink2)
            Text(profileName).typo(.label).foregroundStyle(Theme.ink2)
            Spacer(minLength: 0)
            TimelineView(.everyMinute) { context in
                Text(context.date, format: .dateTime.hour().minute())
                    .typo(.label).foregroundStyle(Theme.ink2)
            }
        }
        .frame(height: 36)
        .padding(.horizontal, Theme.Space.s4)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.rule).frame(height: 1)
        }
    }
}
