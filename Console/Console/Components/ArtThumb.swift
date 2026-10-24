import SwiftUI

// Flat placeholder art. Music is a square (or a circle for an artist); video is
// 16:10. Gradient is seeded so placeholder art has variety; it is the only
// gradient the design allows. Used by the bottom bar, the parked spines, and search results.

struct ArtThumb: View {
    var seed: Int
    var kind: SessionKind
    var side: CGFloat
    var circular: Bool = false
    var imageURL: String? = nil   // real cover art (Spotify); falls back to gradient

    private var width: CGFloat { (!circular && kind.isVideo) ? side * 1.6 : side }
    private var shape: some Shape {
        circular
            ? AnyShape(Circle())
            : AnyShape(RoundedRectangle(cornerRadius: Theme.Radius.key))
    }

    var body: some View {
        gradient
            .overlay { realArt }
            .frame(width: width, height: side)
            .clipShape(shape)
            .accessibilityHidden(true)
    }

    private var gradient: some View {
        Rectangle().fill(ArtPalette.gradient(seed: seed))
    }

    @ViewBuilder private var realArt: some View {
        if let imageURL, let url = URL(string: imageURL) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                }  // else: keep the gradient underneath while loading / on failure
            }
        }
    }
}
