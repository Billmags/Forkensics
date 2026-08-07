import SwiftUI

struct ConversationView: View {
    @EnvironmentObject var dataService: MockDataService
    let challenge: Challenge

    @State private var newComment = ""
    @FocusState private var commentFocused: Bool

    private let quickEmojis = ["🔥", "😭", "👏", "😂", "😤", "🤯", "👌", "🍴"]

    private var comments: [Comment] { dataService.comments(for: challenge.id) }
    private var reactions: [Reaction] { dataService.reactions(for: challenge.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Conversation")
                .font(.headline)

            reactionRow

            if comments.filter({ !$0.isDeleted }).isEmpty && reactions.isEmpty {
                Text("Be first to react!")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            }

            ForEach(comments.filter { !$0.isDeleted }) { comment in
                commentRow(comment: comment)
            }

            // New comment input
            HStack(spacing: 10) {
                AvatarView(player: dataService.currentPlayer, size: 32)
                TextField("Add a comment…", text: $newComment)
                    .textFieldStyle(.roundedBorder)
                    .focused($commentFocused)
                    .submitLabel(.send)
                    .onSubmit { postComment() }
                Button { postComment() } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundColor(
                            newComment.trimmingCharacters(in: .whitespaces).isEmpty
                                ? Color.gray : Color.accentColor
                        )
                }
                .disabled(newComment.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: - Reactions

    private var reactionRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !reactions.isEmpty {
                let grouped = Dictionary(grouping: reactions, by: \.emoji)
                    .sorted { $0.value.count > $1.value.count }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(grouped, id: \.key) { emoji, list in
                            let iMine = list.contains { $0.playerId == dataService.currentPlayer.id }
                            Button {
                                dataService.addReaction(to: challenge.id, emoji: emoji)
                            } label: {
                                reactionPill(emoji: emoji, count: list.count, isMine: iMine)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            // Quick emoji picker
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(quickEmojis, id: \.self) { emoji in
                        Button {
                            dataService.addReaction(to: challenge.id, emoji: emoji)
                        } label: {
                            Text(emoji)
                                .font(.title3)
                                .padding(6)
                                .background {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.gray.opacity(0.15))
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func reactionPill(emoji: String, count: Int, isMine: Bool) -> some View {
        HStack(spacing: 4) {
            Text(emoji)
            Text("\(count)")
                .font(.caption.bold())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            if isMine {
                Capsule().fill(Color.accentColor.opacity(0.15))
            } else {
                Capsule().fill(Color.gray.opacity(0.12))
            }
        }
        .overlay {
            if isMine {
                Capsule().strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1)
            }
        }
    }

    // MARK: - Comment Row

    private func commentRow(comment: Comment) -> some View {
        let author = dataService.player(for: comment.authorId)
        let isMe = comment.authorId == dataService.currentPlayer.id
        return HStack(alignment: .top, spacing: 10) {
            if let author {
                AvatarView(player: author, size: 32)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(author?.displayName ?? "Unknown")
                        .font(.caption.weight(.semibold))
                    Text(comment.postedAt.formatted(.relative(presentation: .named)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if isMe {
                        Button {
                            dataService.deleteComment(comment.id, from: challenge.id)
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text(comment.text)
                    .font(.subheadline)
            }
            .padding(10)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(isMe ? Color.accentColor : Color.gray)
                    .opacity(isMe ? 0.08 : 0.1)
            }
        }
    }

    private func postComment() {
        let text = newComment.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        dataService.addComment(to: challenge.id, text: text)
        newComment = ""
        commentFocused = false
    }
}
