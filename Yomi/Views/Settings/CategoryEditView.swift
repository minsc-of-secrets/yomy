import SwiftUI
import SwiftData

struct CategoryEditView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Category.sortOrder) private var categories: [Category]

    let category: Category?

    @State private var name: String
    @State private var iconName: String
    @FocusState private var nameFocused: Bool

    init(category: Category? = nil) {
        self.category = category
        _name = State(initialValue: category?.name ?? "")
        _iconName = State(initialValue: category?.iconName ?? "tag")
    }

    private var isEditing: Bool { category != nil }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(Color(uiColor: .tertiarySystemFill))
                            .frame(width: 88, height: 88)
                        Image(systemName: iconName)
                            .font(.title)
                            .foregroundStyle(.primary)
                    }
                    .padding(.top, 8)

                    Divider()

                    TextField("Category name", text: $name)
                        .textInputAutocapitalization(.words)
                        .focused($nameFocused)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 4)
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                )

                NavigationLink {
                    IconPickerView(selection: $iconName)
                } label: {
                    HStack {
                        Text("Edit Icon...")
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    )
                }
                .buttonStyle(.plain)
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(isEditing ? "Edit Category" : "New Category")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", systemImage: "checkmark") {
                    save()
                    dismiss()
                }
                .disabled(trimmedName.isEmpty)
            }
        }
        .onAppear {
            if !isEditing {
                nameFocused = true
            }
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    private func save() {
        let newName = trimmedName
        guard !newName.isEmpty else { return }
        if let category {
            category.name = newName
            category.iconName = iconName
        } else {
            let cat = Category(name: newName, sortOrder: categories.count, iconName: iconName)
            context.insert(cat)
        }
        try? context.save()
    }
}
