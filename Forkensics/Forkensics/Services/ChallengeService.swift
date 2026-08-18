import Foundation
import Supabase

// MARK: - ChallengeService

/// Fetches the authenticated user's visible cases from Supabase and maps
/// them to WireframePostedCase for the Cases feed.
///
/// Schema baseline: V4 (20260807000003_v4_case_investigation_schema.sql)
///   • challenges → renamed to cases (group_id column dropped)
///   • Group membership path: cases → investigations → groups
///     (investigations.case_id → cases.id  /  investigations.group_id → groups.id)
///   • Poster display name: profiles embedded via cases.poster_id → profiles.id
///
/// RLS automatically restricts the result set to:
///   • The user's own cases (cases_poster_view: poster_id = auth_uid())
///   • Cases the user is an investigation member of (cases_member_view)
///
/// No backend change is needed — direct SDK read is fully authorised.
///
/// Error handling: on a fetch failure the existing feed is preserved unchanged.
/// An empty successful response (no cases yet) replaces the feed with an empty list,
/// which is correct — it means the database genuinely has no visible cases.

@MainActor
final class ChallengeService: ObservableObject {

    @Published private(set) var cases: [WireframePostedCase] = []
    @Published private(set) var isLoading = false
    @Published var error: String?

    // MARK: - Private decodable row

    private struct CaseRow: Decodable {
        let id: UUID
        let poster_id: UUID
        let state: String
        let public_city_display: String?
        let duration_seconds: Int
        let posted_at: Date?
        let deadline_at: Date?
        let created_at: Date

        // Embedded via cases.poster_id → profiles.id
        let profiles: PosterProfile?

        // Embedded via investigations.case_id → cases.id (one-to-many → array)
        // Each investigation links to one group via investigations.group_id → groups.id
        let investigations: [InvestigationRow]

        struct PosterProfile: Decodable {
            let display_name: String?
        }

        struct InvestigationRow: Decodable {
            let investigation_id: UUID
            let status: String
            let groups: GroupRow?

            struct GroupRow: Decodable {
                let name: String?
            }
        }
    }

    // MARK: - Fetch

    /// Fetches all cases visible to the authenticated user.
    /// On success, replaces `cases`. On failure, preserves the existing feed.
    func fetch(using client: SupabaseClient) async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let rows: [CaseRow] = try await client
                .from("cases")
                .select("""
                    id,
                    poster_id,
                    state,
                    public_city_display,
                    duration_seconds,
                    posted_at,
                    deadline_at,
                    created_at,
                    profiles ( display_name ),
                    investigations ( investigation_id, status, groups ( name ) )
                    """)
                .order("created_at", ascending: false)
                .execute()
                .value
            // Only update feed on success — empty array is a valid result.
            cases = rows.map(Self.map(_:))
        } catch {
            // Preserve existing feed data so the user's screen doesn't blank on
            // a transient network failure.
            self.error = error.localizedDescription
        }
    }

    // MARK: - Mapping

    /// Maps a raw Supabase row to the WireframePostedCase shape the feed expects.
    ///
    /// • tableNames: collected from all visible investigations → groups.
    ///   A case launched to multiple groups appears in multiple investigations.
    /// • posterPlayerID: the real Supabase UUID. WireframePlayerDirectory falls
    ///   back to "Unknown Detective" for IDs it doesn't recognise.
    /// • dish / restaurant / clue: empty — these are secrets stored in case_secrets,
    ///   not in the cases table, and are not displayed in feed rows.
    /// • photoData: empty Data() — R2 photo fetch is a future step.
    private static func map(_ row: CaseRow) -> WireframePostedCase {
        let postedAt = row.posted_at ?? row.created_at
        let durationHours = max(1, row.duration_seconds / 3600)

        let title: String = {
            if let city = row.public_city_display,
               !city.trimmingCharacters(in: .whitespaces).isEmpty {
                return "\(city) Case"
            }
            return "Case"
        }()

        // Collect group names from all visible investigations (RLS filters automatically).
        // Non-active investigations are included — the feed shows all states.
        let tableNames: [String] = {
            let names = row.investigations.compactMap { $0.groups?.name }
            return names.isEmpty ? ["Table"] : names
        }()

        return WireframePostedCase(
            id: row.id,
            postedAt: postedAt,
            photoData: Data(),                          // placeholder — R2/photo not yet wired
            title: title,
            dish: "",                                   // secret — lives in case_secrets, not here
            restaurant: "",                             // secret — lives in case_secrets, not here
            location: row.public_city_display ?? "",
            clue: "",                                   // from clues table — wired in a future step
            tableNames: tableNames,
            durationHours: durationHours,
            posterPlayerID: row.poster_id.uuidString   // real UUID; WireframePlayerDirectory falls
                                                        // back to "Unknown Detective" for unknown IDs
        )
        // Note: profiles(display_name) is fetched (row.profiles?.display_name) and
        // available for future use when WireframePostedCase gains a posterDisplayName field.
    }
}
