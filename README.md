# Ultrawide Bar

The stock Omarchy bar, constrained to a percentage of the screen's long edge.

Built for ultrawide monitors, where a full-width bar strands the left and right
widget groups a metre apart and puts a constant head-turn between the workspace
indicator and the system tray.

![Ultrawide Bar at 50% on a 32:9 display](preview.png)

This is not a reimplementation. The plugin instantiates the packaged
`omarchy.bar` at runtime and only changes where its contents sit, so every
widget, theme, setting and future upstream fix works exactly as it does on the
stock bar.

## Install

Review the repository, then add the plugin:

```bash
omarchy plugin add https://github.com/ceffo/ultrawide-bar.git
```

Accept the prompt to enable the plugin during installation. Enabling a `bar`
plugin selects it as the active bar; it can also be selected later with:

```bash
omarchy bar use io.github.ceffo.ultrawide-bar
```

For an unattended install from a repository you already trust:

```bash
omarchy plugin add https://github.com/ceffo/ultrawide-bar.git --enable --yes
```

## Configuration

Everything lives in the `bar:` block of `~/.config/omarchy/shell.json`, which
the shell hands to the active bar verbatim. Changes hot-reload; no restart.

```json
"bar": {
  "id": "io.github.ceffo.ultrawide-bar",
  "widthPercent": 50,
  "widthAlign": "center"
}
```

| Key | Default | Meaning |
|-----|---------|---------|
| `widthPercent` | `100` | share of the screen's long edge to occupy, clamped to 10–100 |
| `widthAlign` | `center` | `center`, `start` (left/top edge) or `end` (right/bottom edge) |

Every other `bar:` key — `position`, `transparent`, `centerAnchor`, `layout` —
behaves exactly as on the stock bar. `widthPercent` applies to the long edge,
so it narrows a top or bottom bar and shortens a left or right one.

Multi-monitor setups get a proportional bar on each screen: the percentage is
computed per screen, so a 5120px ultrawide and a 1920px sidecar each get their
own inset.

To go back to the packaged bar, remove the `id` key.

### A note on centring

If widgets to the right of your centre group shift when a collapsed widget
expands, that is upstream's centre-section layout, not this plugin: with no
`centerAnchor` matching an id actually present in `layout.center`, the whole
centre section renders as one centred block and any width change re-centres it.
Set `centerAnchor` to a real id from your centre list and place hover-expanding
widgets before it — items before the anchor grow leftward, items after it stay
put.

## Update

Review and apply the next fast-forward update:

```bash
omarchy plugin update io.github.ceffo.ultrawide-bar
```

Or update all Git-managed plugins:

```bash
omarchy plugin update --all
```

## Validate from source

```bash
omarchy plugin validate .
```

## How it works

The obvious implementation — shrinking the bar's `PanelWindow` with margins —
works, and is wrong. The rest of the shell assumes the bar surface spans its
screen edge. `Ui/KeyboardPanel.qml` says so outright ("For a full-width top
bar, the content x maps directly to screen x") and positions every widget
popout from bar-window-local coordinates; `Bar.qml`'s own `windowScreenPoint()`
makes the same assumption for drag ghosts. Shrink the window and every panel
opens shifted by the inset.

So the surface stays full width and fully transparent, and the bar's content
item is moved and resized *inside* it, with an opaque backdrop painted behind
just that span and an input mask clipping clicks to it. Bar-window-local
coordinates still equal screen coordinates, upstream's math keeps working
untouched, and clicks beside the bar fall through to the window underneath
instead of dying on an invisible full-width surface.

`shell.bar` is pointed at the inner bar rather than at this wrapper, so every
consumer in the shell — notifications, plugins, IPC — talks to upstream
directly and there is no forwarding layer to keep in sync as upstream's API
moves.

### Known coupling

Three assumptions about upstream internals. All three fail soft: if the plugin
throws, the host logs it and falls back to `omarchy.bar`, so a break costs you
the inset, not the desktop.

1. The bar's panels are reachable as the `instances` of `Variants` objects
   directly under the bar root, and only the drag/move ghosts carry
   `ghostScreen`.
2. The bar's contents are a single `Loader` filling the panel window.
3. `createObject`'s initial-property map round-trips through `QVariantMap`,
   which turns the nested layout arrays into `QVariantList` and makes
   upstream's `Array.isArray()` checks fail, so `barConfig` is re-assigned
   after construction to hand over the real JS object.

The better long-term home for this is upstream: a `bar.widthPercent` key on the
stock bar, plus making `anchorScreenPos` and `windowScreenPoint` account for the
bar window's screen offset instead of assuming zero. That second half is a
genuine latent bug — any bar narrower than its screen edge hits it.

## Behavior

- **External commands:** none.
- **Files read or written:** none. Configuration is read from the `bar:` block
  the shell already passes to the active bar; the plugin never opens a file.
- **Network access:** none.
- **Background services:** none. A 50ms coalescing timer re-applies geometry
  after config, monitor or bar-position changes.
- **IPC or global shortcuts:** none of its own. The packaged bar's IPC surface
  is reached directly and is unchanged.
- **User configuration outside this repository:** the `bar:` keys documented
  above, in `~/.config/omarchy/shell.json`.

## Compatibility

Developed and tested against Omarchy 4.0.1 with Quickshell 0.3.1, on a single
5120x1440 display at scale 1.25.

## Security

This plugin runs unsandboxed inside `omarchy-shell` when enabled. Review its
source and the documented command, file, and network behavior before installing
it.

## License

MIT — see [LICENSE](LICENSE).
