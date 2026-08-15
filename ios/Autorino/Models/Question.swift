import Foundation

/// Mirrors `questions` (app.js:59).
struct Question: Codable, Identifiable, Hashable {
    var id: String
    var text: String
    var answer: String
    var answered: Bool

    init(id: String = IDGenerator.uid(), text: String = "", answer: String = "", answered: Bool = false) {
        self.id = id
        self.text = text
        self.answer = answer
        self.answered = answered
    }
}
