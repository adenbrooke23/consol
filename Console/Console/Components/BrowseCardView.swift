import SwiftUI

// The companion browse card. Opens right beside the focused music card when an
// artist or album search result is tapped, so browsing gets its own card
// instead of a browser (or a modal) crammed into the session card. Same card grammar
// as everything else on the stage: true-black fill, 14pt radius, existing type
// and ink tokens only.
//
// Contract: anything tapped in here plays on the session card it was opened
// from. × closes; focusing another card closes it too (store-enforced).
// Artist mode → top tracks + albums; tapping an album drills into its track
// list with ← back to the artist.

struct BrowseCardView: View {
    let target: BrowseTarget
    let session: Session
    @Environment(SessionStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Content {
        case loading
        case artist(Hub.ArtistPage)
        case album(Hub.AlbumPage)
        case playlists([Hub.PlaylistItem])
        case playlistTracks(name: String, uri: String, tracks: [Hub.SearchHit])
        case recents([Hub.SearchHit])
        case show(Hub.ShowPage)
        case library(Hub.LibraryPage)
        case results([Hub.SearchHit])   // live search (query in target.spotifyID)
        case failed
    }
    @State private var content: Content = .loading
    @State private var parent: Content?   // one level of drill (album, playlist)

    private var motion: Animation? { reduceMotion ? nil : Theme.Motion.snappy }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s3) {
            header
            body_
        }
        .padding(Theme.Space.s4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bg)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .stroke(Theme.grab, lineWidth: 1)          // active surface = white edge
        )
        .task(id: target) { await load() }
    }

    // MARK: Header: [←] BROWSE · ×
    private var header: some View {
        HStack(spacing: Theme.Space.s2) {
            if parent != nil {
                IconButton(systemName: "chevron.left", a11y: "Back") {
                    withAnimation(motion) {
                        if let back = parent {
                            content = back
                            parent = nil
                        }
                    }
                }
                .padding(.leading, -14)
            }
            Text(target.kind == .search ? "Results" : "Browse")
                .typo(.label).foregroundStyle(Theme.ink2)
            Spacer(minLength: 0)
            Text("PLAYS ON \(session.whereLabel.uppercased())")
                .font(.custom(FontStack.mono.regular, size: 9.5))
                .tracking(0.1 * 9.5)
                .foregroundStyle(Theme.ink3)
            IconButton(systemName: "xmark", a11y: "Close browse") {
                withAnimation(motion) { store.browse = nil }
            }
            .padding(.trailing, -14)
        }
    }

    @ViewBuilder private var body_: some View {
        switch content {
        case .loading:
            VStack {
                Spacer()
                Text("Loading").typo(.label).foregroundStyle(Theme.ink3)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        case .failed:
            VStack {
                Spacer()
                Text("Couldn't reach hub").typo(.label).foregroundStyle(Theme.alert)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        case .artist(let page):
            artistView(page)
        case .album(let page):
            albumView(page)
        case .playlists(let items):
            playlistsView(items)
        case .playlistTracks(let name, let uri, let tracks):
            playlistTracksView(name: name, uri: uri, tracks: tracks)
        case .recents(let hits):
            recentsView(hits)
        case .show(let page):
            showView(page)
        case .library(let page):
            libraryView(page)
        case .results(let hits):
            resultsView(hits)
        }
    }

    // MARK: Search results (live, repainted as the query changes)
    // (no section label: the card header already reads RESULTS)
    private func resultsView(_ hits: [Hub.SearchHit]) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Theme.Space.s3) {
                if hits.isEmpty {
                    Text("No matches").typo(.label).foregroundStyle(Theme.ink3)
                }
                ForEach(hits) { hit in
                    hitRow(hit)
                }
            }
        }
    }

    // MARK: Show / audiobook: episodes (chapters) list
    private func showView(_ page: Hub.ShowPage) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Theme.Space.s3) {
                HStack(spacing: Theme.Space.s3) {
                    ArtThumb(seed: abs(page.id.hashValue), kind: .music, side: 56,
                             imageURL: page.image)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(page.name).typo(.cardTitle).foregroundStyle(Theme.ink).lineLimit(2)
                        if !page.publisher.isEmpty {
                            Text(page.publisher)
                                .font(.custom(FontStack.ui.regular, size: 12.5))
                                .foregroundStyle(Theme.ink2).lineLimit(1)
                        }
                    }
                }
                .padding(.bottom, Theme.Space.s1)

                sectionLabel("EPISODES")
                ForEach(page.episodes) { hit in
                    hitRow(hit)
                }
            }
        }
    }

    // MARK: Library: saved podcasts + audiobooks
    private func libraryView(_ page: Hub.LibraryPage) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Theme.Space.s3) {
                if !page.shows.isEmpty {
                    sectionLabel("PODCASTS")
                    ForEach(page.shows) { hit in
                        hitRow(hit)
                    }
                }
                if !page.audiobooks.isEmpty {
                    sectionLabel("AUDIOBOOKS").padding(.top, Theme.Space.s2)
                    ForEach(page.audiobooks) { hit in
                        hitRow(hit)
                    }
                }
                if page.shows.isEmpty && page.audiobooks.isEmpty {
                    Text("Nothing saved yet").typo(.label).foregroundStyle(Theme.ink3)
                }
            }
        }
    }

    // MARK: Playlists: index, drill into a playlist's tracks
    private func playlistsView(_ items: [Hub.PlaylistItem]) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Theme.Space.s3) {
                sectionLabel("PLAYLISTS")
                if items.isEmpty {
                    Text("No playlists").typo(.label).foregroundStyle(Theme.ink3)
                }
                ForEach(items) { playlist in
                    Button { openPlaylist(playlist) } label: {
                        HStack(spacing: Theme.Space.s3) {
                            ArtThumb(seed: abs(playlist.id.hashValue), kind: .music,
                                     side: 36, imageURL: playlist.image)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(playlist.name)
                                    .font(.custom(FontStack.ui.medium, size: 14))
                                    .foregroundStyle(Theme.ink).lineLimit(1)
                                Text(playlist.count.map { "Playlist · \($0)" } ?? "Playlist")
                                    .font(.custom(FontStack.ui.regular, size: 12))
                                    .foregroundStyle(Theme.ink2).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12)).foregroundStyle(Theme.ink3)
                        }
                        .padding(.vertical, Theme.Space.s1)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func openPlaylist(_ playlist: Hub.PlaylistItem) {
        if case .playlists = content { parent = content }
        Task {
            withAnimation(motion) { content = .loading }
            do {
                let tracks = try await Hub.playlistTracks(playlist.id)
                withAnimation(motion) {
                    content = .playlistTracks(name: playlist.name,
                                              uri: playlist.uri, tracks: tracks)
                }
            } catch {
                withAnimation(motion) { content = .failed }
            }
        }
    }

    private func playlistTracksView(name: String, uri: String, tracks: [Hub.SearchHit]) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Theme.Space.s3) {
                Text(name).typo(.cardTitle).foregroundStyle(Theme.ink).lineLimit(2)
                    .padding(.bottom, Theme.Space.s1)
                sectionLabel("TRACKS")
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, hit in
                    Button {
                        // Play the playlist from this track: the queue becomes
                        // the playlist, so next/prev walk it.
                        store.playContext(session.id, uri: uri, startIndex: index,
                                          title: hit.title, subtitle: hit.subtitle,
                                          image: hit.image)
                    } label: {
                        HStack(spacing: Theme.Space.s3) {
                            Text("\(index + 1)")
                                .typo(.readoutS).foregroundStyle(Theme.ink3)
                                .frame(width: 22, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(hit.title)
                                    .font(.custom(FontStack.ui.medium, size: 14))
                                    .foregroundStyle(Theme.ink).lineLimit(1)
                                if !hit.subtitle.isEmpty {
                                    Text(hit.subtitle)
                                        .font(.custom(FontStack.ui.regular, size: 12))
                                        .foregroundStyle(Theme.ink2).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, Theme.Space.s1)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Recently played: what the house heard, newest first
    private func recentsView(_ hits: [Hub.SearchHit]) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Theme.Space.s3) {
                sectionLabel("RECENTLY PLAYED")
                if hits.isEmpty {
                    Text("Nothing played yet").typo(.label).foregroundStyle(Theme.ink3)
                }
                ForEach(hits) { hit in
                    hitRow(hit)
                }
            }
        }
    }

    // MARK: Artist: top tracks + albums
    private func artistView(_ page: Hub.ArtistPage) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Theme.Space.s3) {
                HStack(spacing: Theme.Space.s3) {
                    ArtThumb(seed: target.hashValue, kind: .music, side: 56,
                             circular: true, imageURL: page.image)
                    Text(page.name).typo(.title).foregroundStyle(Theme.ink).lineLimit(1)
                }
                .padding(.bottom, Theme.Space.s1)

                sectionLabel("TOP TRACKS")
                ForEach(page.topTracks) { hit in
                    hitRow(hit)
                }

                sectionLabel("ALBUMS").padding(.top, Theme.Space.s2)
                ForEach(page.albums) { hit in
                    hitRow(hit)
                }
            }
        }
    }

    // MARK: Album: header + numbered track list
    private func albumView(_ page: Hub.AlbumPage) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Theme.Space.s3) {
                HStack(spacing: Theme.Space.s3) {
                    ArtThumb(seed: target.hashValue, kind: .music, side: 56,
                             imageURL: page.image)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(page.title).typo(.cardTitle).foregroundStyle(Theme.ink).lineLimit(2)
                        Text("\(page.artist) · \(page.year)")
                            .font(.custom(FontStack.ui.regular, size: 12.5))
                            .foregroundStyle(Theme.ink2).lineLimit(1)
                    }
                }
                .padding(.bottom, Theme.Space.s1)

                sectionLabel("TRACKS")
                ForEach(Array(page.tracks.enumerated()), id: \.element.id) { index, hit in
                    trackNumberRow(number: index + 1, hit: hit)
                }
            }
        }
    }

    // MARK: Rows
    private func hitRow(_ hit: Hub.SearchHit) -> some View {
        Button { tap(hit) } label: {
            HStack(spacing: Theme.Space.s3) {
                ArtThumb(seed: abs(hit.id.hashValue), kind: .music, side: 36,
                         circular: false, imageURL: hit.image)
                VStack(alignment: .leading, spacing: 1) {
                    Text(hit.title)
                        .font(.custom(FontStack.ui.medium, size: 14))
                        .foregroundStyle(Theme.ink).lineLimit(1)
                    if !hit.subtitle.isEmpty {
                        Text(hit.subtitle)
                            .font(.custom(FontStack.ui.regular, size: 12))
                            .foregroundStyle(Theme.ink2).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if ["album", "show", "audiobook", "artist"].contains(hit.kind) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12)).foregroundStyle(Theme.ink3)
                }
            }
            .padding(.vertical, Theme.Space.s1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func trackNumberRow(number: Int, hit: Hub.SearchHit) -> some View {
        Button { tap(hit) } label: {
            HStack(spacing: Theme.Space.s3) {
                Text("\(number)")
                    .typo(.readoutS).foregroundStyle(Theme.ink3)
                    .frame(width: 22, alignment: .trailing)
                Text(hit.title)
                    .font(.custom(FontStack.ui.medium, size: 14))
                    .foregroundStyle(Theme.ink).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, Theme.Space.s1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text).typo(.label).foregroundStyle(Theme.ink3)
    }

    // MARK: Actions
    private func tap(_ hit: Hub.SearchHit) {
        if hit.kind == "artist" {
            // drill to the artist page; remember the results for ← back
            parent = content
            Task {
                withAnimation(motion) { content = .loading }
                do {
                    let page = try await Hub.artist(hit.id)
                    withAnimation(motion) { content = .artist(page) }
                } catch {
                    withAnimation(motion) { content = .failed }
                }
            }
            return
        }
        if hit.kind == "show" || hit.kind == "audiobook" {
            // drill to the episodes/chapters page; remember where we came from
            parent = content
            Task {
                withAnimation(motion) { content = .loading }
                do {
                    let page = try await Hub.show(hit.id)
                    withAnimation(motion) { content = .show(page) }
                } catch {
                    withAnimation(motion) { content = .failed }
                }
            }
            return
        }
        if hit.kind == "album" {
            // drill in-place; remember the parent page for ← back
            if case .artist = content { parent = content }
            if case .results = content { parent = content }
            Task {
                withAnimation(motion) { content = .loading }
                do {
                    let album = try await Hub.album(hit.id)
                    withAnimation(motion) { content = .album(album) }
                } catch {
                    withAnimation(motion) { content = .failed }
                }
            }
        } else {
            store.playResult(session.id, SearchResult(hub: hit))
            // the store confirms (or errors) via the stage notice capsule
        }
    }

    private func load() async {
        // Live search repaints in place: keep the old results visible while
        // the next keystroke's batch loads instead of flashing "Loading".
        if target.kind == .search, case .results = content {
            parent = nil
        } else {
            content = .loading
            parent = nil
        }
        do {
            switch target.kind {
            case .artist:
                let page = try await Hub.artist(target.spotifyID)
                withAnimation(motion) { content = .artist(page) }
            case .album:
                let page = try await Hub.album(target.spotifyID)
                withAnimation(motion) { content = .album(page) }
            case .playlists:
                let items = try await Hub.playlists()
                withAnimation(motion) { content = .playlists(items) }
            case .recents:
                let hits = try await Hub.recents(limit: 20)
                withAnimation(motion) { content = .recents(hits) }
            case .show:
                let page = try await Hub.show(target.spotifyID)
                withAnimation(motion) { content = .show(page) }
            case .library:
                let page = try await Hub.library()
                withAnimation(motion) { content = .library(page) }
            case .search:
                let hits = try await Hub.search(target.spotifyID, scope: target.scope)
                if Task.isCancelled { return }   // a newer keystroke owns the card
                withAnimation(motion) { content = .results(hits) }
            }
        } catch {
            if target.kind == .search, error is CancellationError { return }
            withAnimation(motion) { content = .failed }
        }
    }
}
