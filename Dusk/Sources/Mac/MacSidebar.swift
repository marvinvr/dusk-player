#if os(macOS)
import SwiftUI

/// The main window's source list: Home and Search, the content destinations in
/// the user's library order, then Downloads.
struct MacSidebar: View {
    let contentDestinations: [MainTabItem]
    let showsDownloads: Bool
    @Binding var selection: MainTabItem

    var body: some View {
        List(selection: optionalSelection) {
            Section {
                row(.home)
                row(.search)
            }

            if !contentDestinations.isEmpty {
                Section("Library") {
                    ForEach(contentDestinations) { destination in
                        row(destination)
                    }
                }
            }

            if showsDownloads {
                Section("On This Mac") {
                    row(.downloads)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 300)
    }

    private func row(_ destination: MainTabItem) -> some View {
        Label(destination.title, systemImage: destination.systemImage)
            .tag(destination)
    }

    /// `List` selection is optional; the shell always has a destination, so a
    /// deselect (a click on empty space) keeps the current one.
    private var optionalSelection: Binding<MainTabItem?> {
        Binding(
            get: { selection },
            set: { newValue in
                if let newValue {
                    selection = newValue
                }
            }
        )
    }
}
#endif
