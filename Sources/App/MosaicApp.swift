import SwiftUI

@main
struct MosaicApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        EditorView()
            .preferredColorScheme(.dark)
    }
}
