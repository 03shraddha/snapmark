# SnapMark

A small Mac menu bar app. Take a screenshot, annotate it, and paste it anywhere.

[![SnapMark demo](demo.gif)](demo.mp4)

Click the image to watch the [30 second demo with sound](demo.mp4). The [video](video) folder has the source of the demo.

## What it does

1. Press **Ctrl+Shift+A**.
2. Drag over an area of the screen.
3. Annotate the image in the editor. The pen is the default tool.
4. Paste it in Slack, WhatsApp, or any other app. Each edit goes to the clipboard at once.
5. Press **Enter** to close the editor.

## Tools

| Tool | Key | Use |
|------|-----|-----|
| Text | T | Click, type, press Enter |
| Arrow | A | Drag to point at something |
| Box | R | Drag to draw a rectangle |
| Oval | O | Drag to draw an oval |
| Pen | P | Draw freehand |
| Marker | M | Draw a wide stroke that you can see through |
| Blur | B | Drag over private data to pixelate it |
| Step | N | Click to add the next number: 1, 2, 3. Each color has its own count. Option-click starts at 1 again |
| Spot | S | Drag over an area. The remainder goes dark |

The toolbar has six colors and a Size slider. The slider sets the size of the pen, the marker, the lines, the text, and the step numbers. **Cmd+Z** removes the last annotation. **Esc** closes the editor.

## Why not the Mac tool

macOS has Markup. You open it from the thumbnail that shows after a screenshot. SnapMark adds these items:

- A blur tool.
- Step numbers.
- No copy step. Each edit goes to the clipboard at once. Markup saves a file first.
- No file on the Desktop.
- One key for each tool.

## How it works

- The app is one Swift file, [main.swift](main.swift). It uses AppKit only and has no dependencies.
- A Carbon hot key starts the capture. This needs no Accessibility permission.
- The macOS `screencapture` tool draws the selection and returns the image.
- The editor keeps each annotation in a list and draws the list on top of the image.
- Blur uses a Core Image pixellate filter on the selected area.
- After each edit, the app draws the image at full resolution and writes a PNG to the clipboard.

## Privacy

- The app has no network code.
- The app writes no files. The image stays in memory and on the clipboard.

## Install

You need macOS 13 or later.

### Download the app

1. Download [SnapMark.zip](https://github.com/03shraddha/snapmark/releases/latest/download/SnapMark.zip).
2. Open the zip file. Move SnapMark to the Applications folder.
3. Open SnapMark. macOS blocks it because the app has no Apple developer signature.
4. Open System Settings, then Privacy & Security. Click **Open Anyway** next to SnapMark.
5. Press **Ctrl+Shift+A**. Allow Screen Recording permission, then quit SnapMark and open it again.

The icon shows in the menu bar. The app works on Apple and Intel Macs.

### Build from source

You need the Xcode command line tools.

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
