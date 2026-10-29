"""Renders docs/rerender.gif: typing into one view while another view of the same tree
re-renders on every keystroke, then the other view switching syntax.

Every frame comes from the real tools: the typed text is written to a view file, `funC highlight`
shows it as it is (left) and parses it and prints it in another syntax (right). A half-typed line
doesn't parse, so the right side keeps it as typed until it does, as the editor would.
From the repository root, after building bin/funC:

    python docs/rerender.py
"""

import json
import os
import subprocess
import tempfile

from PIL import Image, ImageDraw

import demo

OUTPUT = os.path.join(demo.ROOT, "docs", "rerender.gif")
# the right-hand view: first while typing, then the ones it switches to
RIGHT = [("odin", "Odin", ".fodin"), ("lua", "Lua", ".flua"), ("haskell", "Haskell", ".fhs"), ("lisp", "Lisp", ".flisp"), ("c", "C", ".fc")]

# typed into the Python view: a new procedure before main, then an argument that calls it
NEW_PROCEDURE = "def double(x: int) -> int:\n    return x * 2"
NEW_ARGUMENT = ", double(21)"
GAP = "\n\n\n"  # the empty lines opened to type the procedure into

LINE_HEIGHT_FACTOR = 1.4


def highlight(path, syntax=None):
    command = [demo.FUNC, "highlight", path] + ([syntax] if syntax else [])
    output = subprocess.run(command, capture_output=True, text=True)
    if output.returncode != 0 or not output.stdout:
        return None
    return json.loads(output.stdout)


def render_pane(draw, box, regular, bold, title, view, caret=None):
    """One editor: a tab with its title, then the highlighted text, and the caret at (line, column)"""
    left, top, right, bottom = box
    draw.rectangle([left, top, right, top + demo.BAR_HEIGHT], fill=demo.BAR)
    tab_width = draw.textlength(title, font=bold) + 28
    draw.rectangle([left + 8, top + 8, left + 8 + tab_width, top + demo.BAR_HEIGHT], fill=demo.BACKGROUND)
    draw.rectangle([left + 8, top + 8, left + 8 + tab_width, top + 10], fill=demo.ACCENT)
    draw.text((left + 22, top + 14), title, font=bold, fill=demo.TEXT)

    advance = draw.textlength("m", font=regular)
    line_height = int(demo.SIZE * LINE_HEIGHT_FACTOR)
    y = top + demo.BAR_HEIGHT + 14
    for number, line in enumerate(demo.lines_of(view)):
        x = left + 20
        draw.text((x, y), f"{number + 1:>2}", font=regular, fill=(90, 90, 90))
        x += advance * 4
        for piece, colour in line:
            draw.text((x, y), piece, font=regular, fill=colour)
            x += draw.textlength(piece, font=regular)
        if caret and number == caret[0]:
            caret_x = left + 20 + advance * (4 + caret[1])
            draw.rectangle([caret_x, y + 1, caret_x + 2, y + line_height - 4], fill=(174, 175, 173))
        y += line_height


def line_column(text, offset):
    before = text[:offset]
    return before.count("\n"), len(before) - (before.rfind("\n") + 1)


def keystrokes(start):
    """(text, caret offset) after each keystroke, starting from the untouched view"""
    insert_at = start.index("def main")
    yield start, None
    opened = start[:insert_at] + GAP + start[insert_at:]
    yield opened, insert_at
    for count in range(1, len(NEW_PROCEDURE) + 1):
        yield start[:insert_at] + NEW_PROCEDURE[:count] + GAP + start[insert_at:], insert_at + count
    typed = start[:insert_at] + NEW_PROCEDURE + GAP + start[insert_at:]
    argument_at = typed.index("fib(20))") + len("fib(20)")
    for count in range(1, len(NEW_ARGUMENT) + 1):
        yield typed[:argument_at] + NEW_ARGUMENT[:count] + typed[argument_at:], argument_at + count


def main():
    demo.SIZE = 16
    regular, bold = demo.font(), demo.font(bold=True)
    start = highlight(demo.PROGRAM, "python")["text"]

    with tempfile.TemporaryDirectory() as directory:
        view_path = os.path.join(directory, "fib.func.fpy")
        rendered = []
        for text, caret in keystrokes(start):
            with open(view_path, "w", newline="\n") as view_file:
                view_file.write(text)
            rendered.append((highlight(view_path), highlight(view_path, RIGHT[0][0]), text, caret))
        last_text = rendered[-1][2]
        others = [highlight(view_path, syntax) for syntax, _, _ in RIGHT]

    line_height = int(demo.SIZE * LINE_HEIGHT_FACTOR)
    tallest = max(len(view["text"].split("\n")) for left, right, _, _ in rendered for view in (left, right))
    tallest = max([tallest] + [len(view["text"].split("\n")) for view in others])
    width = 1440
    height = demo.BAR_HEIGHT + 30 + line_height * tallest + 16
    half = width // 2

    def frame(left_view, right_index, right_view, caret, typing):
        image = Image.new("RGB", (width, height), demo.BACKGROUND)
        draw = ImageDraw.Draw(image)
        _, title, extension = RIGHT[right_index]
        render_pane(draw, (0, 0, half - 1, height), regular, bold, "fib.func.fpy  ·  Python" + ("  ·  typing" if typing else ""), left_view, caret)
        draw.rectangle([half - 1, 0, half, height], fill=(60, 60, 60))
        render_pane(draw, (half, 0, width, height), regular, bold, f"fib.func{extension}  ·  {title}  ·  " + ("re-rendered" if typing else "same tree"), right_view)
        return image

    frames, durations = [], []
    for index, (left_view, right_view, text, caret) in enumerate(rendered):
        frames.append(frame(left_view, 0, right_view, line_column(text, caret) if caret is not None else None, True))
        durations.append(1500 if index == 0 else 75)
    durations[-1] = 1800

    # the edit is done: the right side shows the same tree in other syntaxes
    previous = frames[-1]
    final_left = rendered[-1][0]
    for index in range(1, len(RIGHT)):
        image = frame(final_left, index, others[index], None, False)
        for step in (0.33, 0.66):
            frames.append(Image.blend(previous, image, step))
            durations.append(60)
        frames.append(image)
        durations.append(1500)
        previous = image

    palette = [image.convert("P", palette=Image.Palette.ADAPTIVE, colors=96) for image in frames]
    palette[0].save(OUTPUT, save_all=True, append_images=palette[1:], duration=durations, loop=0, optimize=True)
    print(f"wrote {OUTPUT}: {len(frames)} frames, {width}x{height}, {os.path.getsize(OUTPUT) // 1024} KiB")


if __name__ == "__main__":
    main()
