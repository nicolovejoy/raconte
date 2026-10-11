import SwiftUI

/// The Search place (#194). A stub so the route compiles; the screen itself is built on
/// `SearchScreenModel` next.
struct SearchView: View {
    let model: SearchScreenModel
    let library: LibraryScreenModel

    var body: some View {
        List { }
            .navigationTitle("Search")
    }
}
