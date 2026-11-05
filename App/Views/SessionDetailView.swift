import SwiftUI
import TranscriptCore
import UIKit

/// A finished recording: the formatted transcript with photos, plus ways to
/// rename, copy, share, send to Notes, import photos and delete.
struct SessionDetailView: View {
    let sessionID: UUID

    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var showRename = false
    @State private var draftTitle = ""
    @State private var showDeleteConfirmation = false
    @State private var shareItem: ShareItem?
    @State private var viewerPhoto: PhotoAttachment?
    @State private var toastMessage: String?
    @State private var isExporting = false
    // Editing
    @State private var editingParagraph: Paragraph?
    @State private var pendingParagraphDelete: Paragraph?
    @State private var editingBookmark: Bookmark?
    @State private var editingSpeaker: SpeakerChange?
    @State private var labelDraft = ""

    private var isImporting: Bool { model.importingSessionIDs.contains(sessionID) }

    var body: some View {
        if let session = model.session(id: sessionID) {
            content(for: session)
        } else {
            ContentUnavailableView("Recording not found", systemImage: "questionmark.folder")
        }
    }

    // Split into parts so the compiler can type-check each one quickly.
    private func content(for session: TranscriptSession) -> some View {
        let screen = transcriptScroll(for: session)
        .navigationTitle(TranscriptExporter.displayTitle(for: session))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                actionsMenu(for: session)
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    copyAll(session)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                Button {
                    shareText(session)
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                Spacer()
                Button {
                    sendToNotes(session)
                } label: {
                    Label("Send to Notes", systemImage: "note.text")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .alert("Rename recording", isPresented: $showRename) {
            TextField("Title", text: $draftTitle)
            Button("Save") { rename(session) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this recording?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                dismiss()
                model.delete(id: session.id)
            }
        } message: {
            Text("The transcript and its photos will be removed from this iPhone.")
        }
        .sheet(item: $shareItem) { item in
            ActivityView(items: [item.url])
        }
        .fullScreenCover(item: $viewerPhoto) { photo in
            PhotoViewer(url: model.photoURL(photo, in: session), takenAt: photo.takenAt)
        }
            .toast($toastMessage)
        return withEditingDialogs(screen)
    }

    private func transcriptScroll(for session: TranscriptSession) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    header(for: session)
                    if !session.speechSegments.isEmpty {
                        InsightsSection(sessionID: session.id)
                    }
                    if let chapters = session.insights?.chapters, !chapters.isEmpty {
                        ChaptersCard(chapters: chapters, session: session, style: settings.timestampStyle) { index in
                            withAnimation { proxy.scrollTo(TranscriptBlocksList.chapterAnchor(index), anchor: .top) }
                        }
                    }
                    TranscriptHint(isEmpty: session.items.isEmpty)
                    TranscriptBlocksList(
                        session: session,
                        options: settings.formatOptions,
                        style: settings.timestampStyle,
                        photoURL: { model.photoURL($0, in: session) },
                        onPhotoTap: { viewerPhoto = $0 },
                        onEdit: { handle($0) }
                    )
                    .equatable()
                }
                .padding()
            }
        }
    }

    private func withEditingDialogs<Content: View>(_ content: Content) -> some View {
        content
        .sheet(item: $editingParagraph) { paragraph in
            ParagraphEditor(text: paragraph.text) { newText in
                model.editSession(sessionID) { $0.replaceParagraph(segmentIDs: paragraph.segmentIDs, with: newText) }
            }
        }
        .confirmationDialog(
            "Delete this paragraph?",
            isPresented: Binding(get: { pendingParagraphDelete != nil }, set: { if !$0 { pendingParagraphDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingParagraphDelete
        ) { paragraph in
            Button("Delete", role: .destructive) {
                model.editSession(sessionID) { $0.replaceParagraph(segmentIDs: paragraph.segmentIDs, with: "") }
                toastMessage = "Paragraph deleted"
            }
        }
        .alert(
            "Bookmark note",
            isPresented: Binding(get: { editingBookmark != nil }, set: { if !$0 { editingBookmark = nil } }),
            presenting: editingBookmark
        ) { bookmark in
            TextField("Note (optional)", text: $labelDraft)
            Button("Save") {
                model.editSession(sessionID) { $0.setBookmarkNote(labelDraft, id: bookmark.id) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Speaker name",
            isPresented: Binding(get: { editingSpeaker != nil }, set: { if !$0 { editingSpeaker = nil } }),
            presenting: editingSpeaker
        ) { change in
            TextField("Name (optional)", text: $labelDraft)
            Button("Save") {
                model.editSession(sessionID) { $0.setSpeakerLabel(labelDraft, id: change.id) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Editing

    private func handle(_ edit: TranscriptEdit) {
        switch edit {
        case .editParagraph(let paragraph):
            editingParagraph = paragraph
        case .deleteParagraph(let paragraph):
            pendingParagraphDelete = paragraph
        case .addBookmark(let date):
            model.editSession(sessionID) { session in
                session.addBookmark(before: date)
                return true
            }
            toastMessage = "Bookmark added"
        case .addSpeaker(let date):
            var added: SpeakerChange?
            model.editSession(sessionID) { session in
                added = session.addSpeakerChange(before: date)
                return true
            }
            // Offer to name the new speaker right away.
            if let added {
                labelDraft = ""
                editingSpeaker = added
            }
        case .editBookmark(let bookmark):
            labelDraft = bookmark.note ?? ""
            editingBookmark = bookmark
        case .deleteBookmark(let bookmark):
            model.editSession(sessionID) { $0.removeItem(id: bookmark.id) }
            toastMessage = "Bookmark deleted"
        case .editSpeaker(let change):
            labelDraft = change.label ?? ""
            editingSpeaker = change
        case .deleteSpeaker(let change):
            model.editSession(sessionID) { $0.removeItem(id: change.id) }
            toastMessage = "Speaker marker deleted"
        }
    }

    // MARK: - Header

    private func header(for session: TranscriptSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                draftTitle = session.title ?? ""
                showRename = true
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(TranscriptExporter.displayTitle(for: session))
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.leading)
                    Image(systemName: "pencil")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Renames the recording")

            Text(TranscriptExporter.subtitle(for: session))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            let photoCount = session.photos.count
            if photoCount > 0 || !session.audioRecordings.isEmpty {
                HStack(spacing: 12) {
                    if photoCount > 0 {
                        Label("\(photoCount) photo\(photoCount == 1 ? "" : "s")", systemImage: "photo")
                    }
                    if !session.audioRecordings.isEmpty {
                        Label("Audio saved", systemImage: "waveform")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            if session.wasRecovered {
                Label(
                    "The app closed unexpectedly during this recording. Everything up to the last few seconds was saved.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
                .padding(.top, 4)
            }
        }
        .padding(.bottom, 8)
    }

    // MARK: - Actions

    private func actionsMenu(for session: TranscriptSession) -> some View {
        Menu {
            Button {
                exportFolder(session)
            } label: {
                Label("Export Markdown + photos", systemImage: "folder")
            }
            .disabled(isExporting)

            Divider()

            Button {
                importPhotos(session)
            } label: {
                Label("Import photos from Photos", systemImage: "photo.on.rectangle.angled")
            }
            .disabled(isImporting)

            Button {
                draftTitle = session.title ?? ""
                showRename = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            Divider()

            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        } label: {
            Label("Actions", systemImage: "ellipsis.circle")
        }
    }

    private func rename(_ session: TranscriptSession) {
        var updated = session
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.title = title.isEmpty ? nil : title
        model.update(updated)
    }

    private func copyAll(_ session: TranscriptSession) {
        UIPasteboard.general.string = TranscriptSharing.plainText(for: session, settings: settings)
        toastMessage = "Transcript copied"
    }

    private func shareText(_ session: TranscriptSession) {
        do {
            shareItem = ShareItem(url: try TranscriptSharing.plainTextFile(for: session, settings: settings))
        } catch {
            model.log.log("Text export failed: \(error)", category: "ui")
            toastMessage = "Couldn't share: \(error.localizedDescription)"
        }
    }

    private func exportFolder(_ session: TranscriptSession) {
        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                let url = try await TranscriptSharing.exportFolder(for: session, store: model.store, settings: settings)
                shareItem = ShareItem(url: url)
            } catch {
                model.log.log("Export failed: \(error)", category: "ui")
                toastMessage = "Couldn't export: \(error.localizedDescription)"
            }
        }
    }

    private func sendToNotes(_ session: TranscriptSession) {
        Task {
            let opened = await TranscriptSharing.sendToNotes(session, settings: settings)
            if !opened {
                toastMessage = "Couldn't run the Shortcut “\(settings.notesShortcutName)”. See Settings → Apple Notes."
            }
        }
    }

    private func importPhotos(_ session: TranscriptSession) {
        Task {
            do {
                let added = try await model.importLibraryPhotos(for: session.id)
                if added > 0 {
                    toastMessage = "Added \(added) photo\(added == 1 ? "" : "s")"
                } else {
                    toastMessage = "No new photos from the time of this recording"
                }
            } catch {
                model.log.log("Photo import failed: \(error)", category: "ui")
                toastMessage = error.localizedDescription
            }
        }
    }
}

/// Full-screen photo with pinch-to-zoom and sharing.
struct PhotoViewer: View {
    let url: URL
    let takenAt: Date

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    ZoomableImage(image: image)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    ProgressView()
                        .tint(.white)
                }
            }
            .navigationTitle("Photo · \(TimestampFormatter().clock(takenAt, includeSeconds: true))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: url) {
                        Label("Share photo", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .task {
            image = await ThumbnailCache.shared.image(for: url, maxPixelSize: 3000)
        }
    }
}

/// A `UIScrollView`-backed image view: pinch to zoom, drag to pan, double-tap
/// to toggle zoom.
private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 6
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .black
        scrollView.delegate = context.coordinator

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = "Photo"
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])
        context.coordinator.imageView = imageView

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        @objc func doubleTapped(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView = recognizer.view as? UIScrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                let point = recognizer.location(in: imageView)
                let scale: CGFloat = 2.5
                let size = CGSize(width: scrollView.bounds.width / scale, height: scrollView.bounds.height / scale)
                let rect = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
                scrollView.zoom(to: rect, animated: true)
            }
        }
    }
}

/// Compact list of the AI chapters; tapping one jumps to it in the transcript.
private struct ChaptersCard: View {
    let chapters: [Chapter]
    let session: TranscriptSession
    let style: TimestampStyle
    let onSelect: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Chapters", systemImage: "list.bullet")
                .font(.headline)
            ForEach(Array(chapters.enumerated()), id: \.offset) { index, chapter in
                Button {
                    onSelect(index)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(timestampLabel(chapter.start, in: session, style: style))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 44, alignment: .leading)
                        Text(chapter.title)
                            .font(.subheadline)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Jumps to this chapter")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// Full-screen-ish editor for one paragraph's text.
private struct ParagraphEditor: View {
    let onSave: (String) -> Void
    @State private var draft: String
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    init(text: String, onSave: @escaping (String) -> Void) {
        self.onSave = onSave
        _draft = State(initialValue: text)
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $draft)
                .font(.body)
                .focused($focused)
                .padding(.horizontal)
                .navigationTitle("Edit text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            onSave(draft)
                            dismiss()
                        }
                    }
                }
                .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }
}

/// "Nothing transcribed" or the editing tip above the transcript.
private struct TranscriptHint: View {
    let isEmpty: Bool

    var body: some View {
        if isEmpty {
            Text("Nothing was transcribed in this recording.")
                .foregroundStyle(.secondary)
                .padding(.top, 24)
        } else {
            Label("Long-press a paragraph, bookmark or speaker to edit.", systemImage: "hand.tap")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
