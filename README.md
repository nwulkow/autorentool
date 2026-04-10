<div align="center">
  <img src="logo.png" alt="Autorino Logo" width="120"/>

  # Autorino

  *A writer's workbench — everything you need to shape a book, in one place.*
</div>

---

## What is Autorino?

Autorino is a lightweight, browser-based authoring tool that helps writers structure their creative work before and during the writing process.


## Features

- **Characters** — Create character profiles with descriptions and tags
- **Relationships** — Draw and explore connections between characters on an interactive canvas
- **Event Orders** — Plan scene sequences and timelines; filter by character tags
- **Locations** — Document the places your story takes place
- **Notes & Questions** — Capture loose thoughts, open questions, and research links
- **Local storage** — Books are saved as plain JSON files on your machine; nothing leaves your computer

## Getting Started

```bash
# Start the local server
./start.sh
```

Then open **http://localhost:7001** in your browser.

## Tech Stack

| Layer | Technology |
|---|---|
| Frontend | Vue 3 (Options API, no build step) |
| Backend | Python 3 · `http.server` |
| Storage | Plain JSON files in `./books/` |

---

<div align="center">
  <sub>More functionality to come.</sub>
</div>
