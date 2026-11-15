#!/usr/bin/env python3
"""macOS fix for the character renderer of the Godot remake (植物大战僵尸杂交重制版).

usage: shader_intmask.py <in.gdshader> <out.gdshader>

On Apple GPUs (Metal, MoltenVK and Apple OpenGL alike) body parts that the animation data marks as visible are not
drawn (for example the normal zombie's tie and outer arm). The two functions read_gpu_graph_layer_mask() and
read_crowd_layer_mask() extract one visibility bit from a 16-bit word stored in a float channel with float
pow/floor/mod arithmetic, which Apple's shader compiler evaluates wrongly for set bits.

This script keeps each function's signature and its first early-return guard, and replaces the rest of the body with
an integer decode (shifts and AND), which is exact on every backend. Nothing else in the shader changes. The game's
shader itself is not part of this repository; it is read from the user's own copy of the game.
"""
import sys

# Mask-address expression per function (where the 4-component mask texel is read from).
FUNCS = {
    'read_gpu_graph_layer_mask': ('maskBase + float(maskTexel)',
                                  'decode the 16-bit visibility word with integer ops instead of pow/floor/mod.'),
    'read_crowd_layer_mask': ('stateBase + 5.0 + float(maskTexel)', 'integer decode, see read_gpu_graph_layer_mask.'),
}

BODY = """\t// macOS fix: {note}
\tint id = int(floor(layerId + 0.5));
\tint chunk = id >> 4;
\tint maskTexel = chunk >> 2;
\tint component = chunk & 3;
\tvec4 masks = read_crowd_state_texel({addr});
\tfloat mask = masks.x;
\tif (component == 3) {{
\t\tmask = masks.w;
\t}} else if (component == 2) {{
\t\tmask = masks.z;
\t}} else if (component == 1) {{
\t\tmask = masks.y;
\t}}
\tint bits = int(floor(mask + 0.5));
\treturn float((bits >> (id & 15)) & 1);
"""

GUARD = 'return 1.0;\n\t}\n'


def patch_function(src: str, name: str, addr: str, note: str) -> str:
    start = src.find('float ' + name + '(')
    if start < 0:
        raise SystemExit(f'error: function {name} not found')
    brace = src.index('{', start)
    depth, i = 0, brace
    while True:
        if src[i] == '{':
            depth += 1
        elif src[i] == '}':
            depth -= 1
            if depth == 0:
                break
        i += 1
    end = i                                     # index of the function's closing brace
    g = src.find(GUARD, brace, end)
    if g < 0:
        raise SystemExit(f'error: early-return guard not found in {name}')
    keep = g + len(GUARD)
    return src[:keep] + BODY.format(addr=addr, note=note) + src[end:]


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    src = open(sys.argv[1], encoding='utf-8', newline='').read()
    for name, (addr, note) in FUNCS.items():
        src = patch_function(src, name, addr, note)
    open(sys.argv[2], 'w', encoding='utf-8', newline='').write(src)


if __name__ == '__main__':
    main()
