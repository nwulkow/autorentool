import SwiftUI

/// Entry point for the LLM assistant from any tab. Kept as its own view
/// so every screen that gets a chat surface (Editor now, Event orders /
/// others later) opens it the same way.
struct LLMAssistantButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Assistant", systemImage: "sparkles")
        }
    }
}
