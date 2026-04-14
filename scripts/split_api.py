import os
import re

with open('src/main.zig', 'r') as f:
    lines = f.readlines()

categories = {
    '3d': [],
    'dls': [],
    'midi': [],
    'rib': [],
    'timer': [],
    'quick': [],
    'digital': []
}

current_category = None
current_block = []

def get_category(func_name):
    if '3D' in func_name: return '3d'
    if 'DLS' in func_name: return 'dls'
    if 'sequence' in func_name.lower() or 'midi' in func_name.lower() or 'XMI' in func_name: return 'midi'
    if 'RIB' in func_name or 'ASI' in func_name or 'provider' in func_name.lower(): return 'rib'
    if 'timer' in func_name.lower(): return 'timer'
    if 'quick' in func_name.lower(): return 'quick'
    return 'digital'

header = []
i = 0
while i < len(lines):
    line = lines[i]
    if line.startswith('pub export fn ') or line.startswith('pub const '):
        break
    header.append(line)
    i += 1

# write main.zig header back
with open('src/main.zig', 'w') as f:
    for line in header:
        f.write(line)
    
    f.write('comptime {\n')
    for cat in categories.keys():
        f.write(f'    _ = @import("api/{cat}.zig");\n')
    f.write('}\n\n')

# Parse the rest
while i < len(lines):
    line = lines[i]
    if line.startswith('pub export fn '):
        m = re.match(r'pub export fn ([a-zA-Z0-9_]+)', line)
        if m:
            cat = get_category(m.group(1))
            categories[cat].append(line)
            # read body
            brace_count = line.count('{') - line.count('}')
            i += 1
            while i < len(lines) and brace_count > 0:
                categories[cat].append(lines[i])
                brace_count += lines[i].count('{') - lines[i].count('}')
                i += 1
            continue
    elif line.startswith('pub const '):
        m = re.match(r'pub const ([a-zA-Z0-9_]+)', line)
        if m:
            cat = get_category(m.group(1))
            categories[cat].append(line)
    elif line.strip() == '' or line.startswith('//'):
        # Ignore comments and empty lines at top level for simplicity
        pass
    else:
        # Some other top-level decl, just put it in digital
        categories['digital'].append(line)
    i += 1

header_imports = """const std = @import("std");
const builtin = @import("builtin");
const openmiles = @import("../root.zig");
const log = openmiles.log;
const DigitalDriver = openmiles.DigitalDriver;
const MidiDriver = openmiles.MidiDriver;
const Sample = openmiles.Sample;
const Sequence = openmiles.Sequence;
const Provider = openmiles.Provider;

"""

os.makedirs('src/api', exist_ok=True)
for cat, content in categories.items():
    if content:
        with open(f'src/api/{cat}.zig', 'w') as f:
            f.write(header_imports)
            for line in content:
                f.write(line)
