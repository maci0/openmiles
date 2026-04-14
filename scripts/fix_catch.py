import re
import glob

def fix_file(filepath):
    with open(filepath, 'r') as f:
        content = f.read()

    # Regex to find: catch return <value>;
    # and replace with: catch |err| { log("Error in " + func_name + ": {any}\n", .{err}); return <value>; };
    # Wait, getting func_name via regex is hard. Let's just log the error generically.
    new_content = re.sub(
        r'catch return ([^;]+);',
        r'catch |err| { log("Error: {any}\\n", .{err}); return \1; };',
        content
    )
    
    if new_content != content:
        with open(filepath, 'w') as f:
            f.write(new_content)

for filepath in glob.glob('src/api/*.zig'):
    fix_file(filepath)

print("Done catching errors.")
