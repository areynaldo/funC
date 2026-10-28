# funC for VS Code

A `.func` file stores a funC program as its syntax tree, written as s-expressions. You don't have to edit it directly. Open a **view** instead: the same tree shown in the syntax you prefer (Odin, Lua or Python style), as an editable virtual document next to the file.

- Opening a `.func` file opens your default view beside it (settings `funC.autoOpenView` and `funC.defaultView`).
- **funC: Open View…** (also the preview button in the editor title bar) picks another syntax.
- Saving a view converts it back and writes the `.func` file. Other open views of the same file refresh.
- Lines that don't parse are kept in the tree as `(unparsed "…")`, so saving a view with errors loses nothing. The one exception is a broken file header: there's no tree then, and the save is refused.
- Diagnostics appear live in both views and `.func` files.
