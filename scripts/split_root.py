import re
import os

with open('src/root.zig', 'r') as f:
    lines = f.readlines()

def get_block(start_pattern):
    start = -1
    for i, l in enumerate(lines):
        if l.startswith(start_pattern):
            start = i
            break
    if start == -1: return []
    
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
            pass # one-liners? In zig they usually have braces or ;
        if ';' in l and braces == 0 and not in_struct:
            end = i
            break
    
    res = lines[start:end+1]
    # nullify in original
    for i in range(start, end+1):
        lines[i] = ""
    return res

# 1. RIB Provider
provider_decls = [
    "pub const RIB_DATA_TYPE = enum",
    "pub const RIB_ENTRY_TYPE = enum",
    "pub const RIB_INTERFACE_ENTRY = extern struct",
    "pub const RIB_alloc_provider_handle_ptr =",
    "pub const RIB_register_interface_ptr =",
    "pub const RIB_unregister_interface_ptr =",
    "pub const RIB_Main_ptr =",
    "pub const Provider = struct",
    "pub const Interface = struct",
    "pub const HPROVIDER ="
]
provider_lines = []
for d in provider_decls:
    provider_lines.extend(get_block(d))
    provider_lines.append("\n")

# 2. Timer
timer_lines = get_block("pub const Timer = struct")

# 3. Midi
midi_decls = [
    "pub const MidiDriver = struct",
    "pub const MidiStatus = enum",
    "pub const Sequence = struct"
]
midi_lines = []
for d in midi_decls:
    midi_lines.extend(get_block(d))
    midi_lines.append("\n")

# 4. Digital
digital_decls = [
    "pub const SampleStatus = enum",
    "pub const DigitalDriver = struct",
    "pub const SamplePcmFormat = struct",
    "pub fn buildWavFromPcm",
    "pub const Sample = struct",
    "pub const Sample3D = struct"
]
digital_lines = []
for d in digital_decls:
    digital_lines.extend(get_block(d))
    digital_lines.append("\n")

# 5. Filter
filter_lines = get_block("pub const Filter = struct")

header = """const std = @import("std");
const root = @import("../root.zig");
const ma = root.ma;
const tsf = root.tsf;
const log = root.log;

"""

with open('src/rib/provider.zig', 'w') as f:
    f.write(header)
    f.writelines(provider_lines)

with open('src/engine/timer.zig', 'w') as f:
    f.write(header)
    f.writelines(timer_lines)

with open('src/engine/midi.zig', 'w') as f:
    f.write(header)
    f.writelines(midi_lines)

with open('src/engine/digital.zig', 'w') as f:
    f.write(header)
    f.writelines(digital_lines)

with open('src/engine/filter.zig', 'w') as f:
    f.write(header)
    f.writelines(filter_lines)

# Write remaining root
with open('src/root.zig', 'w') as f:
    for l in lines:
        if l is not None:
            f.write(l)

print("Split completed.")
