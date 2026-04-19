import SwiftUI
import CoreLocation

// MARK: - Visual Memories gallery

struct VisualMemoriesView: View {

    @StateObject private var store = VisualMemoryStore.shared
    @State private var searchText  = ""
    @State private var selected: VisualMemory?
    @State private var confirmDelete: VisualMemory?

    // 3-column grid matching iOS Photos Recents style
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    private var displayed: [VisualMemory] {
        store.search(searchText)
    }

    /// Group memories by "Month YYYY"
    private var grouped: [(header: String, items: [VisualMemory])] {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        var dict: [String: [VisualMemory]] = [:]
        var order: [String] = []
        for m in displayed {
            let key = formatter.string(from: m.timestamp)
            if dict[key] == nil { order.append(key); dict[key] = [] }
            dict[key]!.append(m)
        }
        return order.map { (header: $0, items: dict[$0]!) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.memories.isEmpty {
                    emptyState
                } else {
                    galleryContent
                }
            }
            .navigationTitle("Memories")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, prompt: "Search by place, tag, description…")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Text("\(store.memories.count) saved")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .sheet(item: $selected) { MemoryDetailView(memory: $0) }
            .confirmationDialog(
                "Delete this memory?",
                isPresented: Binding(get: { confirmDelete != nil },
                                     set: { if !$0 { confirmDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let m = confirmDelete { store.delete(m) }
                    confirmDelete = nil
                }
                Button("Cancel", role: .cancel) { confirmDelete = nil }
            } message: {
                Text("The image is removed from Max's memories. The copy in your Photos app stays.")
            }
        }
    }

    // MARK: - Gallery

    private var galleryContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                ForEach(grouped, id: \.header) { group in
                    Section {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(group.items) { memory in
                                PhotoTile(memory: memory)
                                    .onTapGesture { selected = memory }
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            confirmDelete = memory
                                        } label: {
                                            Label("Delete Memory", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                    } header: {
                        Text(group.header)
                            .font(.headline.weight(.semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.ultraThinMaterial)
                    }
                }
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 24) {
            Image(systemName: "memories")
                .font(.system(size: 64))
                .foregroundStyle(.quaternary)

            VStack(spacing: 8) {
                Text("No Visual Memories Yet")
                    .font(.title3.weight(.semibold))
                Text("Tap \u{201C}Remember This\u{201D} after capturing a snapshot\nand Max will save it with AI notes and your location.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Photo tile (3-column, full-bleed square)

private struct PhotoTile: View {

    let memory: VisualMemory
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                // Thumbnail
                if let img = image {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.width)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(Color(.tertiarySystemFill))
                        .frame(width: geo.size.width, height: geo.size.width)
                        .overlay(
                            Image(systemName: "photo")
                                .foregroundStyle(.tertiary)
                        )
                }

                // Subtle gradient + summary on hover/always
                if image != nil {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.55)],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                    .frame(width: geo.size.width, height: geo.size.width)

                    Text(memory.aiSummary)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .padding(.horizontal, 5)
                        .padding(.bottom, 5)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .task { image = VisualMemoryStore.shared.loadImage(for: memory) }
    }
}

// MARK: - Memory detail (full-screen card)

struct MemoryDetailView: View {

    let memory: VisualMemory
    @State private var image: UIImage?
    @State private var editingNote = false
    @State private var noteText   = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {

                    // Hero image
                    heroImage

                    // Metadata + content
                    VStack(alignment: .leading, spacing: 20) {

                        // Title + date/location
                        VStack(alignment: .leading, spacing: 6) {
                            Text(memory.aiSummary)
                                .font(.title2.weight(.bold))

                            HStack(spacing: 12) {
                                Label(
                                    memory.timestamp.formatted(date: .long, time: .shortened),
                                    systemImage: "clock"
                                )
                                if let loc = memory.locationName {
                                    Label(loc, systemImage: "location.fill")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }

                        Divider()

                        // AI description
                        if !memory.aiDescription.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("What Max saw", systemImage: "sparkles")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.secondary)

                                Text(memory.aiDescription)
                                    .font(.subheadline)
                                    .lineSpacing(3)
                            }
                        }

                        // Tags
                        if !memory.aiTags.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(memory.aiTags, id: \.self) { tag in
                                        Text("#\(tag)")
                                            .font(.caption.weight(.medium))
                                            .padding(.horizontal, 10).padding(.vertical, 5)
                                            .background(Color.blue.opacity(0.1))
                                            .foregroundStyle(.blue)
                                            .clipShape(Capsule())
                                    }
                                }
                                .padding(.horizontal, 1)
                            }
                        }

                        // Object inventory — lets user know what can be searched
                        if !memory.aiObjects.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Objects in scene", systemImage: "magnifyingglass")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.secondary)

                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(memory.aiObjects, id: \.self) { obj in
                                        HStack(alignment: .top, spacing: 6) {
                                            Image(systemName: "circle.fill")
                                                .font(.system(size: 4))
                                                .foregroundStyle(.secondary)
                                                .padding(.top, 5)
                                            Text(obj)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }

                        Divider()

                        // User note
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Your note", systemImage: "pencil")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)

                            if editingNote {
                                TextField("Add a note…", text: $noteText, axis: .vertical)
                                    .textFieldStyle(.roundedBorder)
                                    .lineLimit(3...6)
                                HStack {
                                    Button("Cancel") {
                                        editingNote = false
                                        noteText = memory.userNote ?? ""
                                    }
                                    .font(.subheadline)
                                    Spacer()
                                    Button("Save") { saveNote() }
                                        .font(.subheadline.weight(.semibold))
                                }
                            } else {
                                Button {
                                    noteText = memory.userNote ?? ""
                                    editingNote = true
                                } label: {
                                    Text(memory.userNote ?? "Tap to add a note…")
                                        .font(.subheadline)
                                        .foregroundStyle(memory.userNote == nil ? .secondary : .primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(12)
                                        .background(Color(.secondarySystemBackground))
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(20)
                }
            }
            .ignoresSafeArea(edges: .top)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                            .font(.title3)
                    }
                }
            }
            .task { image = VisualMemoryStore.shared.loadImage(for: memory) }
        }
    }

    private var heroImage: some View {
        ZStack {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: UIScreen.main.bounds.width)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Color(.secondarySystemBackground))
                    .frame(height: UIScreen.main.bounds.width)
                    .overlay(ProgressView())
            }
        }
    }

    private func saveNote() {
        VisualMemoryStore.shared.updateNote(
            id: memory.id,
            note: noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : noteText
        )
        editingNote = false
    }
}
