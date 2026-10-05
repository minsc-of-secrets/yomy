import SwiftUI
import SwiftData

struct CategoryEditView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let category: Category?

    @State private var name: String
    @State private var saveError: String?
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
                }
                .disabled(trimmedName.isEmpty)
            }
        }
        .alert("Could Not Save Category", isPresented: Binding(
            get: { saveError != nil }, set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .onAppear {
            if !isEditing {
                nameFocused = true
            }
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        do {
            try CategoryService().save(category: category, name: name, iconName: iconName, context: context)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
