<div align="center">
  <img src="logo.png" alt="Autorino Logo" width="120"/>

  # Autorino

  *A writer's workbench — everything you need to shape a book, in one place.*
</div>

---

## What is Autorino?

Autorino helps writers structure their creative work before and during the writing process.


## Features

- **Characters** — Create character profiles with descriptions and tags
- **Relationships** — Draw connections between characters on an interactive canvas
- **Event Orders** — Plan scene sequences and timelines; filter by character tags
- **Locations** — Draw and document the places your story takes place
- **Notes & Questions** — Capture loose thoughts, open questions, and research links
- **Import** — Import characters or locations from one book into another
- **Multi-language** — Switch between English and German at any time
- **Local storage** — Books are saved as plain JSON files on your machine; nothing leaves your computer


## Prerequisites

- **Python 3** (version 3.8 or later)
- A modern web browser (Chrome, Firefox, Safari, Edge)

> **No additional installations needed.** Vue.js is loaded automatically from a CDN when you open the app in your browser — there is nothing to install via `npm`, `pip`, or any other package manager.


## Installation

### macOS / Linux

```bash
# 1. Clone the repository
git clone https://github.com/nwulkow/autorentool.git
cd autorentool

# 2. Make the start script executable (once)
chmod +x start.sh

# 3. Start Autorino
./start.sh
```

> **macOS note:** Python 3 is included since macOS Catalina.
> If you're on an older version, install it with `brew install python3` (requires [Homebrew](https://brew.sh)).

### Windows

```bash
# 1. Clone the repository
git clone https://github.com/nwulkow/autorentool.git
cd autorentool

# 2. Start the server directly with Python
python server.py 7001
```

> Download Python 3 from [python.org](https://www.python.org/downloads/) if not already installed.

### After starting

Open **http://localhost:7001** in your browser — that's it!

### Changing the port

```bash
PORT=9000 ./start.sh          # macOS / Linux
python server.py 9000         # Windows
```

### Stopping the server

Press **Ctrl+C** in the terminal. The start script cleans up automatically.


## How it works

| Layer | Technology |
|---|---|
| Frontend | Vue 3 (Options API, no build step) |
| Backend | Python 3 · `http.server` (standard library) |
| Storage | Plain JSON files in `./books/` |

There is **no build step** and **no dependency installation**.
The frontend loads Vue 3 from a CDN; the backend is a single-file Python HTTP server.
Your books are stored as JSON files in the `books/` folder and never leave your machine.


## Project structure

```
autorentool/
├── app.js          # Vue 3 application (single-file, no build)
├── index.html      # Entry point
├── styles.css      # All styling
├── server.py       # Python HTTP server with API endpoints
├── start.sh        # Start script (bash)
├── books/          # Your saved books (JSON files)
├── flag_images/    # Language flag icons
├── logo.png        # Autorino logo
└── favicon.ico     # Browser tab icon
```

---

<div align="center">
  <sub>More functionality to come.</sub>
</div>
