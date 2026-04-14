import re

with open('src/root.zig', 'r') as f:
    lines = f.readlines()

decls = []
for i, line in enumerate(lines):
    if line.startswith('pub const ') or line.startswith('pub fn ') or line.startswith('pub var '):
        decls.append(f"{i+1}: {line.strip()}")

for d in decls:
    print(d)
