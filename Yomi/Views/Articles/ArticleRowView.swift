import SwiftUI

struct ArticleRowView: View {
    let article: Article
    var showFeedName: Bool = true
    var featured: Bool = false
    var additionalFeedCount: Int = 0
    @Environment(\.modelContext) private var context

    private var hasImage: Bool {
        guard let imageURL = article.imageURL, !imageURL.isEmpty else { return false }
        return URL(string: imageURL) != nil
    }

    var body: some View {
        Group {
            // A row may receive one last body update while its enclosing detail
            // screen or sheet animates away after a cascading unsubscribe.
            if article.modelContext === context && !article.isDeleted {
                liveContent
            }
        }
    }

    private var liveContent: some View {
        Group {
            if featured {
                featuredLayout
            } else {
                regularLayout
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .opacity(article.isRead ? 0.7 : 1.0)
        .task(id: article.url) {
            guard article.modelContext === context, !article.isDeleted,
                  article.imageURL == nil, !article.url.isEmpty else { return }
            if let url = await OGImageFetcher.shared.fetch(articleURL: article.url) {
                guard !Task.isCancelled, article.modelContext === context,
                      !article.isDeleted else { return }
                article.imageURL = url
                try? context.save()
            }
        }
    }

    // MARK: - Featured (image on top, text below)

    private var featuredLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasImage, let url = imageURL {
                GeometryReader { proxy in
                    CachedAsyncImage(url: url) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: proxy.size.width, height: 240)
                            .clipped()
                    } placeholder: {
                        Color(.systemGray5)
                            .frame(width: proxy.size.width, height: 240)
                    }
                }
                .frame(height: 240)
            }

            VStack(alignment: .leading, spacing: 8) {
                feedNameView
                titleView
                    .lineLimit(3)
                bottomRow
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Regular (text left, square thumbnail right)

    private var regularLayout: some View {
        VStack(alignment: .leading, spacing: 6) {
            feedNameView

            HStack(alignment: .top, spacing: 12) {
                titleView
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if hasImage, let url = imageURL {
                    CachedAsyncImage(url: url) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 80, height: 80)
                            .clipped()
                    } placeholder: {
                        Color(.systemGray5)
                            .frame(width: 80, height: 80)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }

            bottomRow
        }
        .padding(12)
    }

    // MARK: - Shared subviews

    private var imageURL: URL? {
        guard let urlString = article.imageURL else { return nil }
        return URL(string: urlString)
    }

    @ViewBuilder
    private var feedNameView: some View {
        if showFeedName, let feedTitle = article.feed?.title {
            Text(additionalFeedCount > 0 ? "\(feedTitle) +\(additionalFeedCount)" : feedTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var titleView: some View {
        Text(article.title)
            .font(.headline)
            .fontWeight(article.isRead ? .regular : .semibold)
            .foregroundStyle(article.isRead ? .secondary : .primary)
            .multilineTextAlignment(.leading)
    }

    private var bottomRow: some View {
        HStack(spacing: 8) {
            Text(article.publishedAt.publishedFormatted)
                .font(.caption)
                .foregroundStyle(.secondary)
            if !article.author.isEmpty {
                Text("·")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(article.author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if article.isSaved {
                Image(systemName: "bookmark.fill")
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Saved")
            }
            actionsMenu
        }
    }

    private var actionsMenu: some View {
        Menu {
            ArticleContextMenu(article: article)
        } label: {
            Image(systemName: "ellipsis")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .tint(.secondary)
    }
}

extension Date {
    var relativeFormatted: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: self, relativeTo: Date())
    }

    var publishedFormatted: String {
        Self.publishedFormatter.string(from: self)
    }

    private static let publishedFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd HH:mm"
        return f
    }()
}
