import Foundation
import SwiftData

/// Category membership is stored as a string on Feed. Keep both sides in one save.
@MainActor
struct CategoryService {
    enum ValidationError: LocalizedError {
        case emptyName, duplicateName, ambiguousName, missingCategory

        var errorDescription: String? {
            switch self {
            case .missingCategory: return "This category no longer exists. Close the editor and try again."
            case .emptyName: return "Enter a category name."
            case .duplicateName: return "A category with this name already exists."
            case .ambiguousName: return "Remove duplicate categories with this name before renaming it."
            }
        }
    }

    // Injectable persistence boundary lets tests exercise failure without mocking SwiftData.
    private let persist: (ModelContext) throws -> Void

    init(persist: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.persist = persist
    }

    @discardableResult
    func save(category: Category?, name: String, iconName: String, context: ModelContext) throws -> Category {
        if let category {
            guard category.modelContext === context, !category.isDeleted else {
                throw ValidationError.missingCategory
            }
        }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ValidationError.emptyName }
        let categories = try context.fetch(FetchDescriptor<Category>())
        let others = categories.filter { $0 !== category }
        guard !others.contains(where: { $0.name == name }) else { throw ValidationError.duplicateName }
        if let category, category.name != name,
           others.contains(where: { $0.name == category.name }) {
            throw ValidationError.ambiguousName
        }
        let oldName = category?.name
        let oldIcon = category?.iconName
        // Fetch before mutation so a fetch failure cannot leave a partial rename.
        let feeds: [Feed]
        if let oldName, oldName != name {
            feeds = try context.fetch(FetchDescriptor<Feed>(predicate: #Predicate { $0.category == oldName }))
        } else {
            feeds = []
        }
        let edited = category ?? Category(name: name, sortOrder: (categories.map(\.sortOrder).max() ?? -1) + 1, iconName: iconName)
        if category == nil { context.insert(edited) }
        edited.name = name
        edited.iconName = iconName
        for feed in feeds { feed.category = name }
        do {
            try persist(context)
        } catch {
            // Do not roll back unrelated pending read/save actions in this shared context.
            if let oldName, let oldIcon {
                edited.name = oldName
                edited.iconName = oldIcon
                for feed in feeds { feed.category = oldName }
            } else {
                context.delete(edited)
            }
            throw error
        }
        return edited
    }

    func delete(_ categories: [Category], context: ModelContext) throws {
        let all = try context.fetch(FetchDescriptor<Category>())
        let remaining = all.filter { candidate in !categories.contains(where: { $0 === candidate }) }
        let removedNames = Set(categories.map(\.name)).subtracting(remaining.map(\.name))
        let feeds = try context.fetch(FetchDescriptor<Feed>()).filter { removedNames.contains($0.category) }
        let previousNames = feeds.map(\.category)
        for feed in feeds { feed.category = "" } // The picker represents None as an empty string.
        for category in categories { context.delete(category) }
        do {
            try persist(context)
        } catch {
            for category in categories { context.insert(category) }
            for (feed, name) in zip(feeds, previousNames) { feed.category = name }
            throw error
        }
    }
}
