# Wax

A turntable for the Mac desktop. It sits behind your windows and shows whatever Apple Music
is playing: the cover on the sleeve and the record label, and the label turning while the
song plays.

There are three scenes, all rendered photographs:

- **Listening Room** — a room in afternoon sun, light falling through blinds.
- **After Hours** — the same room at night, lit by its lamp.
- **Turntable** — the turntable seen from straight above on a sunlit desk, with the tonearm
  tracking across the record as the song goes on.

Every song you play through lays its record on a pile beside the turntable, so the desk
fills up over a listening session. Medals mark 10, 30, 50 and 100 records.

Show Desktop (spreading thumb and three fingers, or F11) brings your files and widgets
forward over the scene. The scene stays where it is, in place of your wallpaper.

Requires macOS 14 or later and the Xcode command-line tools.

## Build and run

```bash
./build.sh run
```

This builds `build/Wax.app` and launches it. Its window opens, and a record icon appears in
the menu bar.

```bash
./build.sh install
```

Does the same, but puts the app in `/Applications` first. Do this before turning on
**Launch at Login**, so the login item points somewhere permanent.

## The window

Opening Wax — from the Dock, Finder, Spotlight, or **Open Wax** in the menu bar menu —
shows its window. The top half is the song: cover, title, and controls that drive Music —
previous, play/pause and next buttons (the space bar also plays and pauses), and a
progress bar you can drag, or click anywhere along, to move through the song. The bottom half is the desktop turntable's
settings beside a live miniature of your desktop, so each change shows before you look
behind your windows.

Between the two is the desk: how many records are on the pile, how far the next medal is,
the medals earned so far, and **Clear the desk**, which empties the pile and keeps the
medals. A song counts once half of it, or half a minute, has played; a skip doesn't.

**Reset to factory settings**, at the top of the settings, puts everything back the way a
fresh install has it and turns off opening at login. It asks first.

Closing the window doesn't quit. Wax leaves the Dock and carries on in the menu bar; open
it again to get the window back. Started at login, it skips the window.

## The menu

The menu bar menu repeats the settings for quick changes.

| Item | What it does |
|---|---|
| Open Wax | Shows the window |
| Scene | Listening Room, After Hours or Turntable |
| Show on Desktop | Hides or shows the scene without quitting |
| Show Song Title | The title, artist and album under the sleeve |
| Cover Widgets and Desktop Icons | On: the scene sits in front of them. Off: they sit in front of the scene |
| Match the Mac's Wallpaper | Makes the scene your Mac's real wallpaper too, so the menu bar shows it |
| Launch at Login | Starts Wax when you log in |
| Clear the Desk… | Empties the pile of played records |
| Reset to Factory Settings… | Puts every setting back to how a fresh install has it |

## How it works

- **Knowing what's playing.** Music announces every play, pause and track change to the
  rest of the system. Wax listens for that announcement, which needs no permission.
- **Position and startup.** The announcement doesn't say how far into the song you are, and
  nothing is announced until something changes. So Wax also asks Music directly. macOS
  will ask you once to let Wax control Music. If you decline, everything still works,
  except that the needle starts each song from the outer groove and a song already playing
  when Wax launches appears at the next track change.
- **Artwork.** The announcement includes the song's catalogue id, and Apple's public iTunes
  lookup returns the exact cover for it. Songs with no id (your own files) fall back to
  the artwork stored in your library, then to a search by name.
- **The scenes.** Each is a 3D scene rendered once in Blender, shipped as a photograph. The
  sleeve and the record label are blank white card in the render, so those pixels hold
  nothing but the room's light. Wax bends the cover into each
  shape and multiplies it by them, which lights your artwork the way the room is lit — the
  blind shadows fall across it, the lamp warms it.
- **The pile.** It isn't in the photograph, because it grows. The render also exports its
  camera and a picture of a white card lying where the pile stands. Wax uses the camera to
  put each sleeve where it would have been seen, the card to light it, and draws the
  shadow each sleeve throws on the one below and the pile throws on the table. The pile
  stops growing at 36 records; the count carries on. It is kept in
  `~/Library/Application Support/com.tigercho.wax/Desk`.
- **The tonearm.** Seen at an angle, as in the rooms, a swinging arm changes shape, so
  those scenes hold two photographs of the turntable: arm parked, and arm on the record.
  Seen from straight above, swinging the arm is just turning its picture. So the Turntable
  scene's arm is rendered alone on a clear background, with its shadow beside it, and Wax
  turns both about the pivot — which lets the needle follow the song across the whole side.
- **Drawing.** The scene is one click-through window per display, in the desktop layers
  beneath every app window: either just above the wallpaper, or just above the desktop
  widgets and icons so they can't overlap it. Covered widgets and icons are still there
  and still respond to clicks.
- **The menu bar.** Wax covers the Mac's wallpaper; it doesn't replace it. macOS draws the
  menu bar's background from the wallpaper itself, so with the scene in front the menu bar
  still shows the old one — most visibly when the menu bar is set to hide and slides back
  in. **Match the Mac's wallpaper** fixes that by making the real wallpaper the same
  picture: the scene with a stand-in cover painted in, saved to
  `~/Library/Application Support/com.tigercho.wax/Wallpapers`. It is on by default, it
  remembers your own wallpaper, and turning it off puts that back. macOS keeps a
  wallpaper per Space and lets an app change only the one in view, so each Space is brought
  into line, or put back, when you next visit it.
- **Show Desktop.** macOS tells no app when the desktop is shown. But the Dock sweeps
  windows aside to show it, so Wax keeps a small invisible window of its own for the Dock
  to sweep and checks four times a second whether it has moved. While it has, the scene
  drops behind the files and widgets; when it comes back, the scene covers them again.
  This only runs while **Cover widgets and desktop icons** is on. The label is turned by Core Animation, so a spinning record
  costs about 0.2% of one CPU core.

## Re-rendering the scenes

The scenes come from `Art/room_scene.py`, which builds the furniture, materials and lighting
from scratch and renders them. To change one, edit it and run the matching command — the
first for the two rooms, the second for the view from above:

```bash
/Applications/Blender.app/Contents/MacOS/Blender -b -P Art/room_scene.py -- --out Resources/Scenes
```

```bash
/Applications/Blender.app/Contents/MacOS/Blender -b -P Art/room_scene.py -- --out Resources/Scenes --scene desk
```

Each takes several minutes. Add `--preview` for a quarter-size render in seconds while
adjusting. Then rebuild the app, which copies `Resources/Scenes` into it.

## Development

The build compiles and signs in `~/Library/Caches/Wax` rather than in this folder, because
iCloud-synced folders add Finder metadata that code signing rejects.

The binary takes a few switches for testing without Music:

| Switch | Effect |
|---|---|
| `--snapshot out.png` | Render the desktop to a PNG and exit — the photograph and words only; the records are live layers |
| `--snapshot-window out.png` | Render the app window to a PNG and exit |
| `--wallpaper out.jpg` | Write a scene's wallpaper picture to a file and exit; changes no setting |
| `--background` | Start without opening the window |
| `--payload song.json` | Feed in a fake announcement (same keys Music uses) |
| `--progress 0.4` | With `--payload`: how far through the song |
| `--scene turntable` | With a snapshot: which scene |
| `--desk 12` | Start with that many test records on the desk, kept in memory only |
| `--celebrate 30` | Show that medal's celebration at launch |
| `--verbose` | Log announcements and artwork decisions to stderr |
| `--no-scripting` | Never ask Music anything directly |
| `--selftest` | Check the label turns clockwise and a factory reset restores every setting |
