import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            ChallengeFeedView()
                .tabItem {
                    Label("Feed", systemImage: "house.fill")
                }

            LeaderboardView()
                .tabItem {
                    Label("Standings", systemImage: "trophy.fill")
                }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(MockDataService())
}
