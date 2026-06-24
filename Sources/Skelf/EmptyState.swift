// The grid's empty states — shown (as an overlay over the AppKit collection view) whenever a
// screen has nothing to list: a search with no matches, an empty Favorites or folder, or a fresh
// install with no skills yet. Built on SwiftUI's ContentUnavailableView for the native look.

import SwiftUI

/// What the grid is empty *of* — picks the icon, title, and guidance copy.
enum EmptyKind: Equatable {
    case searchNoResults(String)   // a global search matched nothing
    case searching(String)         // on-device AI is still ranking — don't flash "no results"
    case noFavorites               // the Favorites screen, with nothing favorited
    case emptyFolder               // a folder with no skills or sub-folders
    case noSkills                  // no skills installed anywhere (first run)
}

/// Renders the empty state for `kind`, or nothing when `kind` is nil (the grid has content).
struct GridEmptyState: View {
    let kind: EmptyKind?

    var body: some View {
        switch kind {
        case .none:
            EmptyView()
        case .searchNoResults(let query):
            ContentUnavailableView.search(text: query)
        case .searching(let query):
            ContentUnavailableView {
                Label("Searching…", systemImage: "sparkles")
            } description: {
                Text("Looking for skills that match “\(query)”.")
            }
        case .noFavorites:
            ContentUnavailableView {
                Label("No Favorites Yet", systemImage: "star")
            } description: {
                Text("Open any skill and tap the star to pin it here for quick access.")
            }
        case .emptyFolder:
            ContentUnavailableView {
                Label("Empty Folder", systemImage: "folder")
            } description: {
                Text("Drag skills or folders in, or press ⌘N to add a sub-folder.")
            }
        case .noSkills:
            ContentUnavailableView {
                Label("No Skills Installed", systemImage: "square.stack.3d.up")
            } description: {
                Text("Install Claude Code skills and they’ll show up here automatically.")
            }
        }
    }
}
