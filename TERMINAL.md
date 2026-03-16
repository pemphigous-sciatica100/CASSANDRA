# CASSANDRA Terminal

CASSANDRA includes a built-in terminal emulator and JavaScript-powered operating system. Press **backtick** (`` ` ``) to toggle.

![CASSANDRA Terminal](screenshot_cameras.png)

## Overview

The terminal is a full VT100/ANSI-compatible emulator with a programmable shell written entirely in JavaScript. It supports:

- ANSI escape sequences (colors, cursor movement, erase, scroll)
- 256-color and truecolor (24-bit) output
- Unicode text rendering (Cascadia Mono / DejaVu Sans Mono)
- Double-buffered cell grid with dirty-row tracking
- 5000-line scrollback buffer (mouse wheel to scroll)
- Alternate screen buffer (for TUI programs)
- Clipboard paste (Ctrl+V, Shift+Insert)

## The Shell

The shell (`scripts/shell.js`) is a JavaScript program. It handles command parsing, pipes, script discovery, and falls back to host system binaries. Everything is customisable.

### Built-in commands

| Command | Action |
|---------|--------|
| `help` | Show available commands and programs |
| `clear` | Clear the terminal |
| `js <code>` | Evaluate inline JavaScript |
| `quit` / `exit` | Close the terminal |

### Programs

Any `.js` file in the `scripts/` directory is automatically available as a command. Type the filename without the extension to run it.

| Program | Description |
|---------|-------------|
| `ls [path]` | List files in a directory |
| `cat <file>` | Display file contents |
| `edit <file>` | Nano-like text editor (Ctrl+S save, Ctrl+X quit) |
| `md <file>` | Render markdown with ANSI formatting |
| `grep <pattern> [file]` | Search with highlighted matches |
| `hello` | Welcome banner and color test |
| `status` | System status |
| `colors` | 256-color palette display |
| `matrix` | Matrix rain animation |
| `sysinfo` | System information panel |

### Pipes

Commands can be chained with pipes, just like Unix:

```
cat ../README.md | md
cat ../feeds.json | grep Economy
ls ../scripts | grep edit
```

Output from each stage flows into `__stdin` for the next. All output (including `term.write()`) is captured at the native level.

### Host System Binaries

If a command isn't a built-in or a `.js` script, it runs as a host system binary with a full PTY (pseudo-terminal). This means interactive programs work:

```
htop
vi somefile.txt
ssh user@host
curl wttr.in/London
python3 -c "print('hello')"
```

The host program's ANSI output is rendered by CASSANDRA's terminal emulator, so colors, cursor movement, and TUI layouts all work.

## Writing Programs

Drop a `.js` file in `scripts/` and it's immediately available. No compilation, no restart.

### JavaScript API

**Output:**
- `print(...)` — print to terminal with newline
- `clear()` — clear screen
- `term.write(s)` — raw write (supports ANSI escape sequences)
- `term.cursor(row, col)` — move cursor
- `term.color(name)` — set color by name (`red`, `green`, `cyan`, `yellow`, `blue`, `magenta`, `white`)
- `term.color("38;5;196")` — raw ANSI color code
- `term.reset()` — reset all attributes
- `term.cols` / `term.rows` — terminal dimensions

**Input:**
- `term.readLine()` — buffered line input with editing, history (up/down), and cursor movement (left/right, Ctrl+A/E, Ctrl+Left/Right word jump)
- `term.rawMode(1/0)` — enable/disable raw key input
- `term.getKey()` — blocking read of a single key (returns `"a"`, `"enter"`, `"up"`, `"ctrl-s"`, etc.)

**Filesystem:**
- `fs.readFile(path)` — read file contents as string (or null)
- `fs.writeFile(path, content)` — write string to file (returns true/false)
- `fs.listDir(path)` — list directory entries as array (or null)
- `fs.exists(path)` — check if file exists

**Execution:**
- `exec(path)` — run a `.js` file in its own scope
- `exec(path, true)` — run and capture all output, returns string
- `system(cmd)` — run a host binary with PTY (interactive)
- `sleep(ms)` — pause execution

**Piped input:**
- `__stdin` — string containing piped input from previous command
- `__piped` — boolean, true if receiving piped data
- `__args` — string containing command arguments

### Example: Hello World

```javascript
// scripts/hello.js
term.color("green");
print("Hello from CASSANDRA OS!");
term.reset();
print("Terminal: " + term.cols + "x" + term.rows);
print("Date: " + new Date().toISOString());
```

### Example: Interactive Program

```javascript
// scripts/ask.js
term.color("cyan");
term.write("What is your name? ");
term.reset();
const name = term.readLine();
print("Hello, " + name + "!");
```

### Example: Filter (for pipes)

```javascript
// scripts/upper.js — uppercases piped input
if (__piped && __stdin) {
    print(__stdin.toUpperCase());
} else {
    print("Usage: cat file | upper");
}
```

### Example: Raw Key Input

```javascript
// scripts/keytest.js
term.rawMode(1);
print("Press keys (ESC to quit):");
while (true) {
    const key = term.getKey();
    if (key === "escape") break;
    print("Key: " + key);
}
term.rawMode(0);
```

## Architecture

```
Keyboard ──> Terminal (Zig)
                │
                ├── Raw key queue ──> JS Worker Thread
                │                        │
                │                    QuickJS Engine
                │                        │
                │                    ┌────┴────┐
                │                    │ shell.js │
                │                    │ *.js     │
                │                    │ system() │──> PTY ──> Host Process
                │                    └────┬────┘
                │                         │
                └── Output queue <────────┘
                        │
                    Cell Grid (double-buffered)
                        │
                    RenderTexture ──> Screen
```

- **Terminal** (`viewer/src/terminal.zig`) — VT100 cell grid, ANSI parser, rendering, input handling
- **Parser** (`viewer/src/terminal_parser.zig`) — ANSI escape sequence state machine, SGR, CSI dispatch
- **JS Runtime** (`viewer/src/js.zig`) — QuickJS on worker thread, output queue, capture mode, PTY, readline
- **Shell** (`scripts/shell.js`) — command interpreter, pipes, script discovery
- **Programs** (`scripts/*.js`) — user-extensible JavaScript programs

## Engine

The terminal is powered by [QuickJS](https://bellard.org/quickjs/) (2025-09-13), Fabrice Bellard's lightweight ES2023 JavaScript engine. It is compiled from source as part of the build (vendored in `viewer/vendor/quickjs/`).
