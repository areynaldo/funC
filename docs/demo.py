"""Renders docs/demo.gif: one program shown in every built-in syntax, highlighted the way the
editor highlights it, then compiled to C and run.

Everything comes from the real tools: `funC highlight` prints each view with its tokens,
`funC c89` compiles, and a C compiler builds the result. Needs Pillow and a C compiler
(`zig cc` or `cc`). From the repository root, after building bin/funC:

    python docs/demo.py
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FUNC = os.path.join(ROOT, "bin", "funC.exe" if os.name == "nt" else "funC")
PROGRAM = os.path.join(ROOT, "examples", "fib.func")
OUTPUT = os.path.join(ROOT, "docs", "demo.gif")
VIEWS = ["func", "odin", "python", "lua", "c", "haskell", "lisp"]

# VS Code's Dark+ colours, by semantic token kind
BACKGROUND = (30, 30, 30)
BAR = (37, 37, 38)
TEXT = (212, 212, 212)
DIM = (133, 133, 133)
ACCENT = (0, 122, 204)
COLOURS = {
    "Keyword": (86, 156, 214),
    "Operator": (212, 212, 212),
    "String": (206, 145, 120),
    "Number": (181, 206, 168),
    "Comment": (106, 153, 85),
    "Variable": (156, 220, 254),
    "Function": (220, 220, 170),
    "Parameter": (156, 220, 254),
    "Type": (78, 201, 176),
    "Namespace": (78, 201, 176),
    "Property": (156, 220, 254),
}

SIZE, PAD, BAR_HEIGHT = 18, 24, 44


def font(bold=False):
    candidates = ["CascadiaMono.ttf", "consola.ttf", "DejaVuSansMono.ttf"]
    for name in candidates:
        for directory in [r"C:\Windows\Fonts", "/usr/share/fonts/truetype/dejavu", "/Library/Fonts"]:
            path = os.path.join(directory, name)
            if os.path.exists(path):
                return ImageFont.truetype(path, SIZE + (1 if bold else 0))
    return ImageFont.load_default()


def highlight(syntax):
    output = subprocess.run([FUNC, "highlight", PROGRAM, syntax], capture_output=True, text=True, check=True)
    return json.loads(output.stdout)


def run_compiled():
    """The commands, the C they produce, and what the program prints when built and run."""
    with tempfile.TemporaryDirectory() as directory:
        source = os.path.join(directory, "fib.c")
        binary = os.path.join(directory, "fib.exe")
        subprocess.run([FUNC, "c89", PROGRAM, source], check=True)
        compiler = ["zig", "cc"] if shutil.which("zig") else ["cc"]
        flags = ["-std=c89", "-pedantic", "-Wall", "-Werror"]
        subprocess.run(compiler + flags + [source, "-o", binary], check=True)
        printed = subprocess.run([binary], capture_output=True, text=True, check=True).stdout.strip()
        commands = ["funC c89 fib.func fib.c", " ".join(compiler + flags) + " fib.c -o fib", "./fib"]
        with open(source) as c_file:
            c_source = c_file.read()
        return commands, c_source, printed


def lines_of(view):
    """[[(text, colour)]] per line: tokens coloured, everything between them plain."""
    text, tokens = view["text"], view["tokens"]
    spans, at = [], 0
    for token in tokens:
        start, end = token["start"], token["start"] + token["length"]
        if start > at:
            spans.append((text[at:start], TEXT))
        spans.append((text[start:end], COLOURS.get(token["kind"], TEXT)))
        at = end
    spans.append((text[at:], TEXT))
    lines = [[]]
    for piece, colour in spans:
        for index, part in enumerate(piece.split("\n")):
            if index > 0:
                lines.append([])
            if part:
                lines[-1].append((part, colour))
    return lines


def terminal(commands, c_source, printed):
    """The last frame: the real commands and output, and the C89 it compiled"""
    green = (78, 201, 176)
    lines = [[("$ ", DIM), (command, TEXT)] for command in commands]
    lines.append([(printed, green)])
    lines.append([])
    # the generated fib, as written to fib.c
    c_lines = c_source.splitlines()
    start = next(index for index, line in enumerate(c_lines) if line.startswith("static long fib(long n)") and not line.endswith(";"))
    end = next(index for index in range(start + 1, len(c_lines)) if c_lines[index] == "}")
    lines.append([("/* fib.c */", COLOURS["Comment"])])
    lines.extend([[(line, DIM)] for line in c_lines[start:end + 1]])
    return lines


def draw_frame(width, height, regular, bold, current, lines, numbered=True):
    image = Image.new("RGB", (width, height), BACKGROUND)
    draw = ImageDraw.Draw(image)
    advance = draw.textlength("m", font=regular)
    line_height = int(SIZE * 1.45)

    # a tab per syntax, the current one lit
    draw.rectangle([0, 0, width, BAR_HEIGHT], fill=BAR)
    x = PAD
    for name in VIEWS + ["c89"]:
        label = "C89 → run" if name == "c89" else ("fib.func" if name == "func" else name)
        label_width = draw.textlength(label, font=bold) + 24
        if name == current:
            draw.rectangle([x, 8, x + label_width, BAR_HEIGHT], fill=BACKGROUND)
            draw.rectangle([x, 8, x + label_width, 10], fill=ACCENT)
        draw.text((x + 12, 14), label, font=bold, fill=TEXT if name == current else DIM)
        x += label_width + 4

    y = BAR_HEIGHT + PAD // 2 + 4
    for number, line in enumerate(lines, 1):
        if numbered:
            draw.text((PAD, y), f"{number:>2}", font=regular, fill=(90, 90, 90))
        column = PAD + advance * (4 if numbered else 0)
        for piece, colour in line:
            draw.text((column, y), piece, font=regular, fill=colour)
            column += draw.textlength(piece, font=regular)
        y += line_height
    return image


def main():
    if not os.path.exists(FUNC):
        sys.exit(f"build the command line tool first: odin build cli -out:{FUNC}")
    regular, bold = font(), font(bold=True)
    views = {name: lines_of(highlight(name)) for name in VIEWS}
    last = terminal(*run_compiled())

    measure = ImageDraw.Draw(Image.new("RGB", (1, 1)))
    advance = measure.textlength("m", font=regular)
    longest = max(sum(len(piece) for piece, _ in line) for lines in views.values() for line in lines)
    tallest = max([len(lines) for lines in views.values()] + [len(last)])
    width = int(max(PAD * 2 + advance * (longest + 5), 900))
    height = BAR_HEIGHT + PAD + int(SIZE * 1.45) * (tallest + 2) + PAD

    frames, durations = [], []
    previous = None
    for name in VIEWS:
        frame = draw_frame(width, height, regular, bold, name, views[name])
        if previous is not None:
            for step in (0.33, 0.66):  # a short crossfade between views
                frames.append(Image.blend(previous, frame, step))
                durations.append(60)
        frames.append(frame)
        durations.append(1700)
        previous = frame
    frames.append(draw_frame(width, height, regular, bold, "c89", last, numbered=False))
    durations.append(2600)

    palette = [frame.convert("P", palette=Image.Palette.ADAPTIVE, colors=128) for frame in frames]
    palette[0].save(OUTPUT, save_all=True, append_images=palette[1:], duration=durations, loop=0, optimize=True)
    print(f"wrote {OUTPUT}: {len(frames)} frames, {width}x{height}, {os.path.getsize(OUTPUT) // 1024} KiB")


if __name__ == "__main__":
    main()
