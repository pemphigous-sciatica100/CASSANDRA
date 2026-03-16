// List files in a directory
// Usage: ls [path]  (defaults to current directory)

const path = globalThis.__args || ".";
const files = fs.listDir(path);

if (!files) {
    term.color("red");
    print("Cannot open: " + path);
    term.reset();
} else {
    const sorted = files.sort();
    for (const name of sorted) {
        // Color directories differently (heuristic: no extension = likely dir)
        const isDir = !name.includes(".") || name.startsWith(".");
        if (isDir) {
            term.color("cyan");
            print(name + "/");
        } else if (name.endsWith(".js")) {
            term.color("green");
            print(name);
        } else {
            term.reset();
            print(name);
        }
    }
    term.reset();
    print("");
    print(sorted.length + " item(s)");
}
