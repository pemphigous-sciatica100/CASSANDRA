// Search for pattern in input or file
// Usage: grep <pattern> [file]
//    or: cat file | grep <pattern>

const args = (globalThis.__args || "").trim();
if (!args) {
    term.color("red");
    print("Usage: grep <pattern> [file]");
    term.reset();
} else {
    const parts = args.split(" ");
    const pattern = parts[0];
    const file = parts.slice(1).join(" ");

    let input = "";
    if (__piped && __stdin) {
        input = __stdin;
    } else if (file && fs.exists(file)) {
        input = fs.readFile(file) || "";
    } else if (!__piped) {
        term.color("red");
        print("No input. Pipe something or specify a file.");
        term.reset();
        input = null;
    }

    if (input !== null) {
        const re = new RegExp(pattern, "gi");
        const lines = input.split("\n");
        for (const line of lines) {
            if (re.test(line)) {
                // Highlight matches
                const highlighted = line.replace(
                    new RegExp(pattern, "gi"),
                    "\x1b[1;31m$&\x1b[0m"
                );
                print(highlighted);
            }
        }
    }
}
