import SwiftUI
import EffectView

@main
struct EffectViewExampleApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                Counter.ContentView()
                .tabItem {
                    Label("Counter", systemImage: "plus.forwardslash.minus")
                }
                
                Movies.ContentView()
                .tabItem {
                    Label("Movies", systemImage: "film")
                }

                // Requires the Observation framework
                if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
                    RemoteCounter.Views.ContentView()
                        .tabItem {
                            Label("Remote Counter", systemImage: "arrow.trianglehead.2.clockwise")
                        }
                } else {
                    // Fallback on earlier versions
                }
            }
        }
    }
}
