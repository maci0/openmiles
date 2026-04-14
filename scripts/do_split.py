import re

with open('src/root.zig', 'r') as f:
    lines = f.readlines()

def find_block(start_line_pattern):
    start = -1
    for i, l in enumerate(lines):
        if l.startswith(start_line_pattern):
            start = i
            break
    if start == -1: return -1, -1
    
    braces = 0
    in_struct = False
    end = start
    for i in range(start, len(lines)):
        l = lines[i]
        braces += l.count('{')
        braces -= l.count('}')
        if '{' in l: in_struct = True
        
        if in_struct and braces == 0:
            end = i
            break
        elif not in_struct and l.strip() == '' and braces == 0:
            # function might be one line? No, all our fns have braces.
            pass
    return start, end

# Let's extract xmidi first
x_start1, x_end1 = find_block("pub fn xmidiToSmf")
x_start2, x_end2 = find_block("pub fn xmidiBareToSmf")
xmidi_lines = lines[x_start1:x_end1+1] + ["\n"] + lines[x_start2:x_end2+1]

with open('src/engine/xmidi.zig', 'w') as f:
    f.write('const std = @import("std");\n\n')
    f.writelines(xmidi_lines)

print(f"Extracted xmidi: {len(xmidi_lines)} lines")
