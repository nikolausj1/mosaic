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
        ZStack {
            Color(red: 0.043, green: 0.043, blue: 0.051) // #0B0B0D chrome background (PRD §7)
                .ignoresSafeArea()
            Text("Mosaic")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color(red: 0.443, green: 0.749, blue: 1.0)) // #71BFFF placeholder accent
        }
        .preferredColorScheme(.dark)
    }
}
