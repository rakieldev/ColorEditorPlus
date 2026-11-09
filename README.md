# Color Editor Plus

An in-game character palette editor for **Ikemen GO 1.0 and nightly**.

The color locator requires a recent **nightly** build. Ikemen GO 1.0 uses the highlight in the main preview.

## Installation

1. Place the complete `colorEditor` folder in `external/mods/`, keeping its capitalization.
2. Add the following entry to your screenpack's `system.def`.

```ini
[Title Info]
menu.itemname.coloreditor = "COLOR EDITOR"
```

When upgrading, replace the previous module folder and update the menu entry. Extract ZIP characters before editing.

## Default controls

Buttons refer to Ikemen's logical inputs.

| Input | Action |
| --- | --- |
| Directions | Select a color. While editing, Up/Down selects a channel and Left/Right changes its value. |
| A | Edit a color or apply the current changes. |
| B | Open color actions or cancel the current edit. |
| Hold C + Directions | Move the preview. |
| Hold C + X or Y | Zoom out or in. |
| Hold C + A | Reset preview position and zoom. |
| Hold X + Left/Right | Browse preview animations. |
| Y | Mark or unmark a color for group editing. |
| Z | Restore the original backup, after confirmation. |
| Esc / Menu | Go back or cancel the current edit. |
| Start | Save the palette from the color grid. |

To adjust several colors with Hue, Saturation and Value, mark them with **Y**, then press **B** and choose **Adjust selected colors**.

**A applies changes. Start saves them.** Leaving with pending changes asks for confirmation. Leaving the editor returns to character selection.

## Palettes and backups

Edits affect the character's shared selectable palette. ACT and SFFv2.00 palettes use RGB. Internal SFFv2.01 palettes also support alpha.

The first save keeps a backup of the previous colors, preserved across later saves and restarts. **Z** restores and saves those colors immediately. By default, a successful restoration removes the backup.

## Configuration

Edit `colorEditor.def` for controls, layout, preview modes, sounds and backup settings. Optional screenpack overrides use `[ColorEditor Info]` and `[ColorEditorBGdef]` in `system.def`.

## Credits

By **Rakíel**, based on the original module by **jay_ts and m14**.
