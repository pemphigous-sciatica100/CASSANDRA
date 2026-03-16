// Display file contents
// Usage: cat <filename>

const filename = globalThis.__args || "";
if (!filename) {
    term.color("red");
    print("Usage: cat <filename>");
    term.reset();
} else if (!fs.exists(filename)) {
    term.color("red");
    print("File not found: " + filename);
    term.reset();
} else {
    const content = fs.readFile(filename);
    if (content !== null) {
        term.write(content);
        // Ensure we end on a new line
        if (content.length > 0 && content[content.length - 1] !== "\n") {
            print("");
        }
    }
}
