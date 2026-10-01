import Foundation
import SwiftUI
import UIKit

/// Runs chapter-digest extraction as a background job.
///
/// It lives on `AppEnvironment`, **not** in a view, and that is the whole
/// point: a `Task` started from `.task`/`.onAppear` is cancelled the moment
/// its view disappears, so a rebuild launched from the chapter list would die
/// as soon as the user navigated anywhere. Owned here, the job outlives every
/// screen — the user can keep writing, switch tabs, open another book, and it
/// keeps going.
///
/// What *does* stop it is the system suspending the app a few seconds after
/// it is backgrounded. Two things make that harmless rather than
/// catastrophic:
///
/// 1. `beginBackgroundTask` buys roughly half a minute of grace, enough for
///    the in-flight chapter to land and be written.
/// 2. Every chapter is persisted the instant it returns, so an interrupted
///    run loses at most the one chapter that was mid-flight. Starting again
///    picks up exactly where it stopped, because "what still needs doing" is
///    derived from content hashes rather than from a position in a list.
///
/// The loop is serial on purpose: 25 parallel calls is the fastest route to
/// a 429, and serial keeps "resume" trivially correct.
@MainActor
final class DigestService: ObservableObject {
    struct Progress: Equatable {
        var bookTitle: String
        var completed: Int
        var total: Int
        var failed: Int
        var currentTitle: String

        var fraction: Double { total == 0 ? 0 : Double(completed) / Double(total) }
    }

    @Published private(set) var progress: Progress?
    @Published var lastError: String?

    private let llm: LLMService
    private var job: Task<Void, Never>?
    /// One store per book, cached so every screen and the running job all
    /// observe the same instance.
    private var stores: [String: ChapterDigestStore] = [:]

    init(llm: LLMService) {
        self.llm = llm
    }

    var isRunning: Bool { progress != nil }

    func store(for bookTitle: String) -> ChapterDigestStore {
        let key = Book.sanitizedFilename(for: bookTitle)
        if let existing = stores[key] { return existing }
        let created = ChapterDigestStore(bookTitle: bookTitle)
        stores[key] = created
        return created
    }

    /// Re-reads every cached store from disk — after a digest sync pulled
    /// changes from another device.
    func reloadStores() {
        stores.values.forEach { $0.reload() }
    }

    // MARK: - Starting work

    /// One chapter, on demand. Used by the per-chapter button, including to
    /// deliberately overwrite a hand-edited digest once the user has
    /// confirmed that is what they want.
    func generate(chapter: Chapter, index: Int, in book: Book) {
        run(chapters: [(index, chapter)], book: book)
    }

    /// Every chapter whose digest is missing or out of date. Hand-edited
    /// digests are skipped even when stale — `ChapterDigestStore` leaves them
    /// out of `needingGeneration`, so a bulk run can never quietly discard
    /// something the user wrote.
    func generateAll(in book: Book) {
        run(chapters: store(for: book.title).needingGeneration(in: book), book: book)
    }

    func cancel() {
        job?.cancel()
    }

    // MARK: - The loop

    private func run(chapters: [(index: Int, chapter: Chapter)], book: Book) {
        guard job == nil, !chapters.isEmpty else { return }
        let store = store(for: book.title)
        let cast = book.characters.map(\.name).filter { !$0.isEmpty }
        lastError = nil
        progress = Progress(bookTitle: book.title, completed: 0, total: chapters.count, failed: 0, currentTitle: "")

        // Grace period if the user backgrounds the app mid-run. Without it
        // the process is suspended within seconds and the in-flight request
        // dies with nothing written.
        var background = UIBackgroundTaskIdentifier.invalid
        background = UIApplication.shared.beginBackgroundTask(withName: "chapter-digests") { [weak self] in
            self?.job?.cancel()
        }

        job = Task { [weak self] in
            defer {
                if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
            }
            guard let self else { return }

            for (index, chapter) in chapters {
                if Task.isCancelled { break }
                self.progress?.currentTitle = Self.displayTitle(chapter, index: index)

                let text = PromptBuilder.chapterPlainText(chapter)
                // An empty chapter has nothing to extract, and asking anyway
                // returns a confidently invented digest.
                guard !text.isEmpty else {
                    self.progress?.completed += 1
                    continue
                }

                do {
                    let payload = try await self.llm.digest(
                        chapterTitle: Self.displayTitle(chapter, index: index),
                        chapterText: text,
                        castNames: cast,
                        model: GeminiModelCatalog.digestModel
                    )
                    // Hash the content we actually sent, not the chapter as
                    // it stands now — the user may have kept typing while
                    // this ran, and claiming that edit is covered would hide
                    // a stale digest behind a current-looking badge.
                    store.upsert(ChapterDigest(
                        chapterId: chapter.id,
                        contentHash: ChapterDigestStore.hash(chapter.content),
                        index: index,
                        title: Self.displayTitle(chapter, index: index),
                        generatedBy: GeminiModelCatalog.digestModel,
                        payload: payload
                    ))
                } catch {
                    if Task.isCancelled { break }
                    self.progress?.failed += 1
                    self.lastError = error.localizedDescription
                }
                self.progress?.completed += 1
            }

            self.progress = nil
            self.job = nil
        }
    }

    static func displayTitle(_ chapter: Chapter, index: Int) -> String {
        let label = chapter.name.isEmpty ? chapter.label : chapter.name
        return label.isEmpty ? "\(index + 1)" : "\(index + 1) – \(label)"
    }
}
