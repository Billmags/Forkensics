import Foundation
import Supabase

// MARK: - ChallengeService

/// Fetches the authenticated user's visible challenges from Supabase and maps
/// them to WireframePostedCase for the Cases feed.
///
/// RLS on challenges automatically restricts rows to:
///   • The user's own challenges (any state, including draft)
///   • Posted challenges for groups the user belongs to
///
/// No backend changes required — direct SDK read is fully authorized.
///
/// Usage (in ForkensicsMainShell):
///   await challengeService.fetch(using: authService.client)
///   challengeStore.loadFromSupabase(challengeService.cases)

@MainActor
final class ChallengeService: ObservableObject {

    @Published private(set) var cases: [WireframePostedCase] = []
    @Published private(set) var isLoading = false
    @Published var error: String?

    // MARK: - Private decodable row

    private struct ChallengeRow: Decodable {
        let id: UUID
        let poster_id: UUID
        let group_id: UUID
        let state: String
        let public_city_display: String?
        let duration_seconds: Int
        let posted_at: Date?
        let deadline_at: Date?
        let created_at: Date

        // Joined relations (PostgREST embedded resources)
        let profiles: PosterProfile?
        let groups: GroupInfo?

        struct PosterProfile: Decodable {
            let display_name: String?
        }
        struct GroupInfo: Decodable {
            let name: String?
        }
    }

    // MARK: - Fetch

    /// Fetches all challenges visible to the authenticated user and populates `cases`.
    /// Safe to call multiple times; replaces previous results on each call.
    func fetch(using client: SupabaseClient) async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let rows: [ChallengeRow] = try await client
                .from("challenges")
                .select("""
                    id,
                    poster_id,
                    group_id,
                    state,
                    public_city_display,
                    duration_seconds,
                    posted_at,
                    deadline_at,
                    created_at,
                    profiles ( display_name ),
                    groups ( name )
                    """)
                .order("created_at", ascending: false)
                .execute()
                .value
            cases = rows.map(Self.map(_:))
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Mapping

    /// Maps a raw Supabase row to the WireframePostedCase shape the feed expects.
    ///
    /// Fields not yet available from Supabase (dish, restaurant, clue, photo)
    /// are left as empty/placeholder — they are not displayed in feed rows.
    private static func map(_ row: ChallengeRow) -> WireframePostedCase {
        let postedAt = row.posted_at ?? row.created_at
        let durationHours = max(1, row.duration_seconds / 3600)

        // Build a readable title from the optional city hint
        let title: String = {
            if let city = row.public_city_display, !city.trimmingCharacters(in: .whitespaces).isEmpty {
                return "\(city) Case"
            }
            return "Case"
        }()

        return WireframePostedCase(
            id: row.id,
            postedAt: postedAt,
            photoData: Data(),                          // placeholder — R2/photo not yet wired
            title: title,
            dish: "",                                   // secret — lives in challenge_secrets, not here
            restaurant: "",                             // secret — lives in challenge_secrets, not here
            location: row.public_city_display ?? "",
            clue: "",                                   // from hints table — wired in a future step
            tableNames: [row.groups?.name ?? "Table"],
            durationHours: durationHours,
            posterPlayerID: row.poster_id.uuidString   // real UUID; WireframePlayerDirectory falls
                                                        // back to "Unknown Detective" for unknown IDs
        )
        // Note: profiles(display_name) is fetched in the join and available as
        // row.profiles?.display_name. Wiring it to the feed row label requires
        // extending WireframePostedCase with a posterDisplayName field — deferred
        // to a future step alongside the full profile data path.
    }
}
