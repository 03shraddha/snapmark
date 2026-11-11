# SnapMark

A small Mac menu bar app. Take a screenshot, annotate it, and paste it anywhere.

![SnapMark demo](demo.gif)

Watch the [30 second demo with sound](demo.mp4). The [video](video) folder has the source of the demo.

## What it does

1. Press **Ctrl+Shift+A**.
2. Drag over an area of the screen.
3. Annotate the image in the editor.
4. Press **Enter**. The image goes to the clipboard.
5. Paste it in Slack, WhatsApp, or any other app.

## Tools

| Tool | Key | Use |
|------|-----|-----|
| Text | T | Click, type, press Enter |
| Arrow | A | Drag to point at something |
| Box | R | Drag to draw a rectangle |
| Oval | O | Drag to draw an oval |
| Pen | P | Draw freehand |
| Blur | B | Drag over private data to pixelate it |

The toolbar has six colors and three sizes. **Cmd+Z** removes the last annotation. **Esc** cancels.

## How it works

- The app is one Swift file, [main.swift](main.swift). It uses AppKit only and has no dependencies.
- A Carbon hot key starts the capture. This needs no Accessibility permission.
- The macOS `screencapture` tool draws the selection and returns the image.
- The editor keeps each annotation in a list and draws the list on top of the image.
- Blur uses a Core Image pixellate filter on the selected area.
- On Enter, the app draws the image at full resolution and writes a PNG to the clipboard.

## Privacy

- The app has no network code.
- The app writes no files. The image stays in memory and on the clipboard.

## Install

You need macOS 13 or later and the Xcode command line tools.

```bash
git clone https://github.com/03shraddha/snapmark.git
cd snapmark
./build.sh
open SnapMark.app
```

On the first capture, macOS asks for Screen Recording permission. Allow it, then quit SnapMark and open it again.

## Limits

- Text is one line for each click.
- You cannot move an annotation after you place it. Undo it and draw it again.
