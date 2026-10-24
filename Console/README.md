# Console (iPad app)

The Consol remote: a native SwiftUI app for iPad, landscape only. It talks only to the hub, which it finds on the local network over Bonjour (`_consol-hub._tcp`). Everything on screen is a session card, something playing somewhere: music on Sonos rooms, or an app on an Apple TV.

Building, signing, installing and signing in are covered in the [main README](../README.md).

## Quick facts

- Open `Console.xcodeproj` and build the **Console** target. Deployment target: iPadOS 18.1.
- Set your own team and bundle identifier under Signing & Capabilities before building to a device.
- General Sans, the interface font, is not included because its license does not allow redistribution. Download it from [Fontshare](https://www.fontshare.com) and copy `GeneralSans-Regular.otf`, `GeneralSans-Medium.otf`, `GeneralSans-Semibold.otf` and `GeneralSans-Bold.otf` into `Console/Console/Fonts/` (path from the repository root). Without them the app uses the system font. They are listed in `.gitignore`.
- Use the Release configuration for everyday use. Debug builds mark their player polls as a heartbeat, and the hub pauses the room about 20 seconds after the polls stop.
- In the Simulator the app talks to a hub at `127.0.0.1:8000` and skips Bonjour unless `UITEST_DISCOVER=1` is set. Other `UITEST_*` variables, read in Debug builds only, are listed in `ConsoleApp.swift`. `UITEST_AUTOLOGIN=1` signs in as the mock admin "Alex" with PIN `1111`; against a real hub, a user with that name and PIN must exist.
- The project uses folder-synchronized groups, so new files under `Console/` compile without editing the project file.

## Layout

| Folder | Contents |
| --- | --- |
| `Services/` | `Hub.swift`, the only network client, and `HubDiscovery.swift` for Bonjour. |
| `Stores/` | `AuthStore` (PIN sign-in) and `SessionStore` (cards, outputs, playback state). |
| `Screens/` | Login, the stage and session chooser, Devices and Profile. |
| `Components/` | Session cards, transport bar, browse card, Apple TV remote card and smaller pieces. |
| `Models/` | Sessions, outputs, music types. |
| `Theme/` | Colors, spacing and typography. Fonts are registered at launch by `FontRegistrar`. |
| `Fonts/` | Martian Mono (SIL Open Font License 1.1, license file included). Add the four General Sans OTF files here yourself; see below. |
| `Mocks/` | Fixtures for previews and UI-test hooks only. |

The visual design follows [docs/design/style-guide.html](../docs/design/style-guide.html).
