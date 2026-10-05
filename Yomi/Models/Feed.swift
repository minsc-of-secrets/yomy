import SwiftData
import Foundation

@Model
final class Feed {
    var id: UUID
    var url: String
    var title: String
    var siteURL: String
    var category: String
    // An archived source owns retained saved articles but is no longer a subscription.
    // The inline default lets existing stores migrate without removing any data.
    var isSubscribed: Bool = true
    var fetchedAt: Date?
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Article.feed)
    var articles: [Article]

    init(url: String, title: String, siteURL: String = "", category: String = "General") {
        self.id = UUID()
        self.url = url
        self.title = title
        self.siteURL = siteURL
        self.category = category
        self.createdAt = Date()
        self.articles = []
    }

    var unreadCount: Int {
        articles.filter { !$0.isRead }.count
    }
}
