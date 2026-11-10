import SwiftUI

/// Batch 458: pick a mixtape (or start a new one) to add a clip to. Presented from `ClipEditorSheet`.
struct AddToMixtapeSheet: View {
    let clip: MixtapeClip
    /// Called after the clip was added, with the mixtape's title.
    var onAdded: (String) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var store = MixtapeStore.shared
    @State private var newTitle = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("New mixtape title", text: $newTitle)
                        .frame(minHeight: 44)
                    Button {
                        let made = store.create(title: newTitle, clips: [clip])
                        Haptics.success()
                        onAdded(made.title)
                        dismiss()
                    } label: {
                        Label("Create and Add", systemImage: "plus")
                            .frame(minHeight: 44)
                    }
                }
                if !store.mixtapes.isEmpty {
                    Section("Mixtapes") {
                        ForEach(store.mixtapes) { tape in
                            Button {
                                if store.add(clip, to: tape.id) {
                                    Haptics.success()
                                    onAdded(tape.title)
                                    dismiss()
                                } else {
                                    errorMessage = String(localized: "This mixtape is full (25 clips).", comment: "Add to mixtape: the mixtape already has the maximum number of clips")
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: tape.title).foregroundStyle(Color.shelfCream)
                                    Typo.supporting(Text("\(tape.clips.count) clips"))
                                        .foregroundStyle(Color.shelfMuted)
                                }
                                .frame(minHeight: 44, alignment: .leading)
                            }
                        }
                    }
                }
                if let errorMessage {
                    Section {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Color.shelfOrange)
                                .accessibilityHidden(true)
                            Typo.supporting(Text(verbatim: errorMessage)).foregroundStyle(Color.shelfCream)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.shelfBackground)
            .navigationTitle("Add to Mixtape")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.monochromeToolbarItem()
                }
            }
        }
        .systemChromeTint()
        .presentationDetents([.medium, .large])
    }
}
