// CASSANDRA Terminal — Hello World
term.color("cyan");
print("=================================");
print("  Welcome to CASSANDRA OS v1.0");
print("=================================");
term.reset();
print("");
term.color("green");
print("QuickJS " + "is alive!");
term.reset();
print("");
print("Terminal size: " + term.cols + "x" + term.rows);
print("2 + 2 = " + (2 + 2));
print("Date: " + new Date().toISOString());
print("");

// Draw a little color bar
for (let i = 0; i < 8; i++) {
    term.write("\x1b[4" + i + "m   ");
}
term.reset();
print("");
for (let i = 0; i < 8; i++) {
    term.write("\x1b[10" + i + "m   ");
}
term.reset();
print("");
print("");
term.color("yellow");
print("Ready.");
term.reset();
