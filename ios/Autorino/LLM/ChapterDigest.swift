import Foundation

/// One chapter reduced to the structure an idea prompt actually needs.
///
/// The point is that "how could X learn Z from Y?" is answerable from a
/// knowledge/opportunity index, not from prose: the whole book is ~100k
/// tokens, the digests for it are ~10k, and the prose contains almost none
/// of the who-knew-what-when that the question turns on. `learns` is the
/// load-bearing field — everything else is context for reading it.
///
/// Stored in a sidecar (`ChapterDigestStore`), never in `books/*.json`, so
/// the format shared with the web app (see CLAUDE.md) is untouched.
///
/// Decoded leniently, for the same reason the `Book` models are: a store
/// that throws on one unexpected record loses the whole file, and these are
/// expensive to rebuild.
struct ChapterDigest: Codable, Identifiable, Hashable {
    // — provenance —
    var chapterId: String
    /// SHA-256 of the chapter's *plain text*. Hashing the HTML would mark a
    /// digest stale after a reformat that changed no words.
    var contentHash: String
    var index: Int
    var title: String
    var generatedAt: Date
    var generatedBy: String
    /// Non-nil once the user has edited this digest by hand. From then on it
    /// is their writing, not a cache, and regeneration must ask first.
    var editedAt: Date?

    // — extracted —
    var pov: String
    var present: [String]
    var place: String
    var time: String
    var summary: String
    var learns: [Learn]
    var established: [String]
    var devices: [String]
    var openThreads: [String]
    /// Names that appear in the prose but not in `book.characters` — offered
    /// in the editor as "add as a character".
    var unknownNames: [String]

    var id: String { chapterId }

    var isUserEdited: Bool { editedAt != nil }

    struct Learn: Codable, Hashable, Identifiable {
        var who: String
        var what: String
        /// How it reached them: seen, overheard, a document, an admission,
        /// an inference. Free text — the taxonomy lives in the prompt.
        var how: String
        var certainty: Certainty

        var id: String { "\(who)|\(what)" }

        /// A suspicion and a fact are not interchangeable in a mystery: the
        /// whole plot is often the gap between them. Kept language-neutral
        /// and localised at display time.
        enum Certainty: String, Codable, Hashable, CaseIterable {
            case confirmed, suspected

            var label: String {
                switch self {
                case .confirmed: return String(localized: "Confirmed")
                case .suspected: return String(localized: "Suspected")
                }
            }
        }

        init(who: String = "", what: String = "", how: String = "", certainty: Certainty = .suspected) {
            self.who = who
            self.what = what
            self.how = how
            self.certainty = certainty
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            who = (try? c.decode(String.self, forKey: .who)) ?? ""
            what = (try? c.decode(String.self, forKey: .what)) ?? ""
            how = (try? c.decode(String.self, forKey: .how)) ?? ""
            // An unrecognised value means a newer writer or a hand edit — a
            // suspicion is the safer reading of an unknown certainty.
            let raw = (try? c.decode(String.self, forKey: .certainty)) ?? ""
            certainty = Certainty(rawValue: raw) ?? .suspected
        }
    }

    enum CodingKeys: String, CodingKey {
        case chapterId, contentHash, index, title, generatedAt, generatedBy, editedAt
        case pov, present, place, time, summary, learns, established, devices
        /// `open` is the field name in the JSON; `open` is awkward as a Swift
        /// property next to the access modifier, so the property is renamed.
        case openThreads = "open"
        case unknownNames
    }

    init(chapterId: String, contentHash: String, index: Int, title: String,
         generatedBy: String, payload: ChapterDigestPayload) {
        self.chapterId = chapterId
        self.contentHash = contentHash
        self.index = index
        self.title = title
        self.generatedAt = Date()
        self.generatedBy = generatedBy
        self.editedAt = nil
        self.pov = payload.pov
        self.present = payload.present
        self.place = payload.place
        self.time = payload.time
        self.summary = payload.summary
        self.learns = payload.learns
        self.established = payload.established
        self.devices = payload.devices
        self.openThreads = payload.open
        self.unknownNames = payload.unknownNames
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chapterId = (try? c.decode(String.self, forKey: .chapterId)) ?? ""
        contentHash = (try? c.decode(String.self, forKey: .contentHash)) ?? ""
        index = (try? c.decode(Int.self, forKey: .index)) ?? 0
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        generatedAt = (try? c.decode(Date.self, forKey: .generatedAt)) ?? Date()
        generatedBy = (try? c.decode(String.self, forKey: .generatedBy)) ?? ""
        editedAt = try? c.decode(Date.self, forKey: .editedAt)
        pov = (try? c.decode(String.self, forKey: .pov)) ?? ""
        present = (try? c.decode([String].self, forKey: .present)) ?? []
        place = (try? c.decode(String.self, forKey: .place)) ?? ""
        time = (try? c.decode(String.self, forKey: .time)) ?? ""
        summary = (try? c.decode(String.self, forKey: .summary)) ?? ""
        learns = (try? c.decode([Learn].self, forKey: .learns)) ?? []
        established = (try? c.decode([String].self, forKey: .established)) ?? []
        devices = (try? c.decode([String].self, forKey: .devices)) ?? []
        openThreads = (try? c.decode([String].self, forKey: .openThreads)) ?? []
        unknownNames = (try? c.decode([String].self, forKey: .unknownNames)) ?? []
    }
}

/// Exactly the fields the model produces — the provenance half of
/// `ChapterDigest` is ours to fill in. Kept separate so the response schema
/// and the decode target are the same shape, and the model is never asked
/// for a hash or a timestamp it would have to invent.
struct ChapterDigestPayload: Codable, Hashable {
    var pov: String = ""
    var present: [String] = []
    var place: String = ""
    var time: String = ""
    var summary: String = ""
    var learns: [ChapterDigest.Learn] = []
    var established: [String] = []
    var devices: [String] = []
    var open: [String] = []
    var unknownNames: [String] = []

    /// Gemini `responseSchema` (OpenAPI subset). Constraining the response
    /// this way is what makes the extraction parseable without a repair
    /// pass — and `propertyOrdering` keeps the model writing `summary`
    /// before `learns`, so the list is drawn from a narrative it has already
    /// committed to rather than assembled cold.
    static var geminiSchema: [String: Any] {
        [
            "type": "OBJECT",
            "properties": [
                "pov": ["type": "STRING"],
                "present": ["type": "ARRAY", "items": ["type": "STRING"]],
                "place": ["type": "STRING"],
                "time": ["type": "STRING"],
                "summary": ["type": "STRING"],
                "learns": [
                    "type": "ARRAY",
                    "items": [
                        "type": "OBJECT",
                        "properties": [
                            "who": ["type": "STRING"],
                            "what": ["type": "STRING"],
                            "how": ["type": "STRING"],
                            "certainty": ["type": "STRING", "enum": ["confirmed", "suspected"]],
                        ],
                        "required": ["who", "what", "how", "certainty"],
                        "propertyOrdering": ["who", "what", "how", "certainty"],
                    ],
                ],
                "established": ["type": "ARRAY", "items": ["type": "STRING"]],
                "devices": ["type": "ARRAY", "items": ["type": "STRING"]],
                "open": ["type": "ARRAY", "items": ["type": "STRING"]],
                "unknownNames": ["type": "ARRAY", "items": ["type": "STRING"]],
            ],
            "required": ["pov", "present", "place", "time", "summary", "learns", "established", "devices", "open", "unknownNames"],
            "propertyOrdering": ["pov", "present", "place", "time", "summary", "learns", "established", "devices", "open", "unknownNames"],
        ]
    }
}
