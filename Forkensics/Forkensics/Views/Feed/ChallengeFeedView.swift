import SwiftUI

struct ChallengeFeedView: View {
    @EnvironmentObject var dataService: MockDataService
    @State private var showCreate = false
    @State private var selectedId: UUID?

    private var sorted: [Challenge] {
        dataService.challenges.sorted {
            // Active first, then by posted date
            if $0.state == $1.state { return $0.postedAt > $1.postedAt }
            let order: [ChallengeState] = [.active, .locked, .revealed, .cancelled, .draft]
            let lhs = order.firstIndex(of: $0.state) ?? 99
            let rhs = order.firstIndex(of: $1.state) ?? 99
            return lhs < rhs
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(sorted) { challenge in
                    NavigationLink(value: challenge.id) {
                        ChallengeRowView(challenge: challenge)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Forkensics 🍴")
            .navigationDestination(for: UUID.self) { challengeId in
                if let challenge = dataService.challenge(for: challengeId) {
                    ChallengeDetailView(challenge: challenge)
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showCreate = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                }
            }
            .sheet(isPresented: $showCreate) {
                CreateChallengeView()
            }
        }
    }
}

#Preview {
    ChallengeFeedView()
        .environmentObject(MockDataService())
}
