// Markdown renderer — renders markdown as ANSI colored text
// Usage: cat file.md | md
//    or: md <file.md>

let input = __piped ? __stdin : "";

// If not piped, try to read file from args
if (!input && globalThis.__args) {
    const content = fs.readFile(globalThis.__args);
    if (content) input = content;
    else {
        term.color("red");
        print("Usage: md <file.md>  or  cat file.md | md");
        term.reset();
    }
}

if (input) {
    const lines = input.split("\n");
    let in_code_block = false;
    let in_list = false;

    for (const line of lines) {
        // Code blocks
        if (line.startsWith("```")) {
            in_code_block = !in_code_block;
            if (in_code_block) {
                term.write("\x1b[48;5;236m"); // dark bg
                const lang = line.substring(3).trim();
                if (lang) {
                    term.write("\x1b[0;33m " + lang + " \x1b[0m\x1b[48;5;236m");
                }
                print("");
            } else {
                term.reset();
                print("");
            }
            continue;
        }

        if (in_code_block) {
            term.write("\x1b[48;5;236m\x1b[0;32m " + line + " \x1b[K");
            term.reset();
            print("");
            continue;
        }

        // Headers
        if (line.startsWith("#### ")) {
            term.write("\x1b[1;37m  " + renderInline(line.substring(5)));
            term.reset();
            print("");
            continue;
        }
        if (line.startsWith("### ")) {
            print("");
            term.write("\x1b[1;33m  " + renderInline(line.substring(4)));
            term.reset();
            print("");
            continue;
        }
        if (line.startsWith("## ")) {
            print("");
            const text = renderInline(line.substring(3));
            term.write("\x1b[1;36m  " + text);
            term.reset();
            print("");
            term.write("\x1b[36m  " + "-".repeat(Math.min(text.length + 2, term.cols - 4)));
            term.reset();
            print("");
            continue;
        }
        if (line.startsWith("# ")) {
            print("");
            const text = renderInline(line.substring(2));
            term.write("\x1b[1;32m  " + text.toUpperCase());
            term.reset();
            print("");
            term.write("\x1b[32m  " + "=".repeat(Math.min(text.length + 2, term.cols - 4)));
            term.reset();
            print("");
            continue;
        }

        // Horizontal rule
        if (/^[-*_]{3,}\s*$/.test(line)) {
            term.color("cyan");
            print("-".repeat(Math.min(term.cols - 1, 60)));
            term.reset();
            continue;
        }

        // Blockquote
        if (line.startsWith("> ")) {
            term.write("\x1b[0;36m| \x1b[0;37m" + renderInline(line.substring(2)));
            term.reset();
            print("");
            continue;
        }

        // Unordered list
        if (/^\s*[-*+] /.test(line)) {
            const indent = line.match(/^(\s*)/)[1];
            const content = line.replace(/^\s*[-*+] /, "");
            term.write(indent + "\x1b[1;33m* \x1b[0m" + renderInline(content));
            print("");
            continue;
        }

        // Ordered list
        if (/^\s*\d+\. /.test(line)) {
            const match = line.match(/^(\s*)(\d+)\. (.*)/);
            if (match) {
                term.write(match[1] + "\x1b[1;33m" + match[2] + ". \x1b[0m" + renderInline(match[3]));
                print("");
                continue;
            }
        }

        // Table row
        if (line.includes("|") && line.trim().startsWith("|")) {
            const cells = line.split("|").filter(c => c.trim() !== "");
            if (cells.every(c => /^[\s-:]+$/.test(c))) {
                // Separator row
                term.color("cyan");
                print("-".repeat(Math.min(line.length, term.cols - 1)));
                term.reset();
            } else {
                term.write("\x1b[0;36m|\x1b[0m");
                for (const cell of cells) {
                    term.write(" " + renderInline(cell.trim()) + " \x1b[0;36m│\x1b[0m");
                }
                print("");
            }
            continue;
        }

        // Empty line
        if (line.trim() === "") {
            print("");
            continue;
        }

        // Regular paragraph
        term.write(renderInline(line));
        print("");
    }

    term.reset();
}

function renderInline(text) {
    return text
        // Bold + italic
        .replace(/\*\*\*(.*?)\*\*\*/g, "\x1b[1;3m$1\x1b[22;23m")
        // Bold
        .replace(/\*\*(.*?)\*\*/g, "\x1b[1m$1\x1b[22m")
        // Italic
        .replace(/\*(.*?)\*/g, "\x1b[3m$1\x1b[23m")
        // Inline code
        .replace(/`([^`]+)`/g, "\x1b[48;5;236m\x1b[32m $1 \x1b[0m")
        // Links [text](url)
        .replace(/\[([^\]]+)\]\([^)]+\)/g, "\x1b[4;34m$1\x1b[24;39m")
        // Strikethrough
        .replace(/~~(.*?)~~/g, "\x1b[9m$1\x1b[29m");
}
