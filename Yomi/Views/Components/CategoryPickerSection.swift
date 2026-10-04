import SwiftUI
import SwiftData

struct CategoryPickerSection: View {
    @Binding var selectedCategory: String
    @Environment(\.modelContext) private var context
    @Query(sort: \Category.sortOrder) private var categories: [Category]
    @State private var newCategoryName = ""
    @State private var showNewCategoryAlert = false
    @State private var saveError: String?

    var body: some View {
        Section("Category") {
            Menu {
                Button {
                    selectedCategory = ""
                } label: {
                    if selectedCategory.isEmpty {
                        Label("None", systemImage: "checkmark")
                    } else {
                        Text("None")
                    }
                }
                ForEach(categories) { cat in
                    Button {
                        selectedCategory = cat.name
                    } label: {
                        if selectedCategory == cat.name {
                            Label(cat.name, systemImage: "checkmark")
                        } else {
                            Text(cat.name)
                        }
                    }
                }
                Divider()
                Button {
                    showNewCategoryAlert = true
                } label: {
                    Label("New Category...", systemImage: "plus.circle")
                }
            } label: {
                HStack {
                    Text(selectedCategory.isEmpty ? "None" : selectedCategory)
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(.primary)
        }
        .onChange(of: categoryNames) { oldNames, newNames in
            guard !selectedCategory.isEmpty,
                  !newNames.values.contains(selectedCategory),
                  let selectedID = oldNames.first(where: { $0.value == selectedCategory })?.key else { return }
            selectedCategory = newNames[selectedID] ?? ""
        }
        .alert("New Category", isPresented: $showNewCategoryAlert) {
            TextField("Category name", text: $newCategoryName)
                .textInputAutocapitalization(.words)
            Button("Add") { addCategory() }
                .disabled(trimmedNewCategoryName.isEmpty)
            Button("Cancel", role: .cancel) {
                newCategoryName = ""
            }
        }
        .alert("Could Not Save Category", isPresented: Binding(
            get: { saveError != nil }, set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    private var categoryNames: [PersistentIdentifier: String] {
        Dictionary(uniqueKeysWithValues: categories.map { ($0.persistentModelID, $0.name) })
    }

    private var trimmedNewCategoryName: String {
        newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addCategory() {
        do {
            let category = try CategoryService().save(category: nil, name: newCategoryName, iconName: "tag", context: context)
            selectedCategory = category.name
            newCategoryName = ""
        } catch {
            saveError = error.localizedDescription
        }
    }
}
