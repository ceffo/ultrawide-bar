import QtQuick
import Quickshell

// A bar option that renders the *packaged* Omarchy bar and constrains it to a
// fraction of the screen's long edge.
//
// The point of the indirection is update resistance: this file never forks
// Bar.qml, it instantiates $OMARCHY_PATH/shell/plugins/bar/Bar.qml at runtime,
// so upstream widget work and bug fixes keep flowing in. The only thing owned
// here is where the bar's contents sit inside its surface.
//
// Config lives in the `bar:` block of ~/.config/omarchy/shell.json, which the
// host hands to any bar option verbatim as `barConfig`:
//
//   "bar": { "id": "io.github.ceffo.ultrawide-bar", "widthPercent": 50, "widthAlign": "center" }
//
// If anything below throws, the host logs it and falls back to omarchy.bar,
// so a broken customization costs you the inset, not the desktop.
//
// -- why the content moves and the window doesn't -----------------------------
// The obvious implementation is to shrink the bar's PanelWindow with margins.
// That works, and it is wrong: the rest of the shell assumes the bar surface
// spans its screen edge. Ui/KeyboardPanel.qml says so outright ("For a
// full-width top bar, the content x maps directly to screen x") and positions
// every widget popout from bar-window-local coordinates; Bar.qml's own
// windowScreenPoint() makes the same assumption for drag ghosts. Shrink the
// window and every panel opens shifted by the inset.
//
// So the surface stays full width and fully transparent, and the bar's content
// item is moved and resized inside it, with an opaque backdrop painted behind
// just that span and an input mask clipping clicks to it. Bar-window-local
// coordinates then still equal screen coordinates, and upstream's math keeps
// working untouched.
Item {
  id: root

  // Injected by omarchy-shell's configureBar(). Deliberately NOT `required`:
  // bar options are loaded through a Loader with `source:`, which has no way
  // to satisfy required properties, so declaring them required would make the
  // plugin fail to construct.
  property string omarchyPath: ""
  property var barWidgetRegistry: null
  property var barConfig: null
  property var shell: null
  property var pluginRegistry: null
  property var manifest: null

  // The packaged bar, created in ensureInner().
  property var innerBar: null

  // ------------------------------------------------------------- config

  // Fraction of the long edge the bar should occupy. Clamped to something
  // still usable so a typo can't reduce the bar to a sliver.
  readonly property real widthFraction: {
    var raw = barConfig && barConfig.widthPercent !== undefined ? Number(barConfig.widthPercent) : 100
    if (!isFinite(raw) || raw <= 0) raw = 100
    return Math.max(10, Math.min(100, raw)) / 100
  }

  // "center" (default), "start" (left/top edge) or "end" (right/bottom edge).
  readonly property string widthAlign: {
    var raw = String(barConfig && barConfig.widthAlign ? barConfig.widthAlign : "center").toLowerCase()
    return ["center", "start", "end"].indexOf(raw) === -1 ? "center" : raw
  }

  // ---------------------------------------------- pass-through bar API
  //
  // adopt() hands the inner bar straight to `shell.bar`, so every consumer in
  // the shell talks to upstream and this wrapper never has to track its API.
  // These proxies are the safety net for the window before adoption, and for
  // a future host that stops honouring that write.

  readonly property int barSize: innerBar ? innerBar.barSize : 0
  readonly property bool barHidden: innerBar ? innerBar.barHidden : false
  readonly property string position: innerBar ? String(innerBar.position) : "top"
  readonly property string fontFamily: innerBar ? String(innerBar.fontFamily) : ""

  function summonBarWidget(pluginId) { return innerBar ? innerBar.summonBarWidget(pluginId) : false }
  function hideBarWidget(pluginId) { return innerBar ? innerBar.hideBarWidget(pluginId) : false }
  function isBarWidgetOpen(pluginId) { return innerBar ? innerBar.isBarWidgetOpen(pluginId) : false }
  function panelWidgetIdAt(region, index) { return innerBar ? innerBar.panelWidgetIdAt(region, index) : "" }
  function debugBarGeometry() { return innerBar ? innerBar.debugBarGeometry() : [] }
  function toggleTransparency() { if (innerBar) innerBar.toggleTransparency() }

  // ------------------------------------------------------- construction

  onOmarchyPathChanged: ensureInner()
  onBarWidgetRegistryChanged: ensureInner()
  onShellChanged: {
    if (innerBar) innerBar.shell = shell
    ensureInner()
    adopt()
  }
  onBarConfigChanged: {
    if (innerBar) innerBar.barConfig = barConfig
    ensureInner()
    scheduleApply()
  }
  onWidthFractionChanged: scheduleApply()
  onWidthAlignChanged: scheduleApply()

  function ensureInner() {
    if (innerBar || !omarchyPath || !barWidgetRegistry || !barConfig) return

    var component = Qt.createComponent(omarchyPath + "/shell/plugins/bar/Bar.qml")
    if (component.status !== Component.Ready) {
      console.warn("ultrawide-bar: cannot load packaged bar:", component.errorString())
      return
    }

    var bar = component.createObject(root, {
      omarchyPath: root.omarchyPath,
      barWidgetRegistry: root.barWidgetRegistry,
      barConfig: root.barConfig,
      shell: root.shell,
      manifest: root.manifest
    })
    if (!bar) {
      console.warn("ultrawide-bar: packaged bar failed to instantiate")
      return
    }

    // createObject's initial-property map round-trips through QVariantMap,
    // which turns the nested layout arrays into QVariantList. Upstream gates
    // on Array.isArray(), so the bar would come up correctly sized but empty.
    // Re-assigning the property afterwards hands over the real JS object.
    bar.barConfig = root.barConfig

    root.innerBar = bar
    adopt()
    scheduleApply()
  }

  // Point shell.bar at the packaged bar rather than at this wrapper, so
  // summon/hide/geometry calls and every plugin reading `shell.bar` reach the
  // real implementation with no forwarding layer to keep in sync.
  //
  // Only swap when the host has pointed shell.bar at *this* wrapper: plugin
  // reloads leave the previous wrapper alive for a moment, and an
  // unconditional swap makes the two fight over shell.bar.
  function adopt() {
    if (!shell || !innerBar) return
    if (shell.bar === root) shell.bar = innerBar
  }

  Connections {
    target: root.shell
    ignoreUnknownSignals: true
    function onBarChanged() { root.adopt() }
  }

  Component.onDestruction: {
    if (shell && innerBar && shell.bar === innerBar) shell.bar = null
  }

  // --------------------------------------------------------- geometry

  Connections {
    target: root.innerBar
    ignoreUnknownSignals: true
    // adopt() makes shell.bar the *inner* bar, so the host pushes live
    // shell.json updates straight there and never touches this wrapper's copy.
    // Mirror them back, or width changes would only land on a restart.
    // Assigning the same object reference back in onBarConfigChanged is inert,
    // so this cannot loop.
    function onBarConfigChanged() {
      root.barConfig = root.innerBar.barConfig
      root.scheduleApply()
    }
    function onBarHiddenChanged() { root.scheduleApply() }
    function onPositionChanged() { root.scheduleApply() }
    function onBarSizeChanged() { root.scheduleApply() }
    function onTransparentChanged() { root.scheduleApply() }
  }

  Connections {
    target: Quickshell
    ignoreUnknownSignals: true
    function onScreensChanged() { root.scheduleApply() }
  }

  // Panels are created by Variants over Quickshell.screens; a monitor change
  // means new instances that don't exist yet on the signal. Coalesce and let
  // them settle first.
  Timer {
    id: applyTimer
    interval: 50
    onTriggered: root.applyInsets()
  }

  function scheduleApply() { applyTimer.restart() }

  // The opaque strip painted behind the inset content, replacing the window
  // colour we clear. Colour tracks the live bar so themes and the
  // transparency toggle keep working.
  Component {
    id: backdropComponent

    Rectangle {
      property bool ultrawideBackdrop: true
      z: -1
      color: root.innerBar && root.innerBar.transparent
        ? "transparent"
        : (root.innerBar ? root.innerBar.background : "transparent")
    }
  }

  // Input region, so clicks in the empty stretches beside the bar reach the
  // windows underneath instead of dying on an invisible full-width surface.
  Component {
    id: maskComponent

    Region { property bool ultrawideMask: true }
  }

  function isPanel(obj) {
    try {
      return !!obj && ("margins" in obj) && ("screen" in obj) && ("exclusionMode" in obj)
    } catch (e) {
      return false
    }
  }

  // Bar.qml holds three Variants: the bar panels, the widget-drag ghost, and
  // the bar-move ghost. Only the ghosts carry `ghostScreen`.
  function collectBarPanels() {
    var panels = []
    if (!innerBar) return panels

    var children = innerBar.data
    for (var i = 0; i < children.length; i++) {
      var instances = null
      try { instances = children[i] ? children[i].instances : null } catch (e) { instances = null }
      if (!instances) continue

      for (var j = 0; j < instances.length; j++) {
        var obj = instances[j]
        if (isPanel(obj) && !("ghostScreen" in obj)) panels.push(obj)
      }
    }
    return panels
  }

  // The bar's content is a single Loader filling the window (it picks the
  // horizontal or vertical layout). It is the thing we move.
  function contentLoaderOf(panel) {
    var kids = panel.contentItem ? panel.contentItem.children : null
    if (!kids) return null
    for (var i = 0; i < kids.length; i++) {
      if (kids[i] && ("sourceComponent" in kids[i])) return kids[i]
    }
    return null
  }

  function taggedChild(panel, tag) {
    var kids = panel.contentItem ? panel.contentItem.children : null
    if (!kids) return null
    for (var i = 0; i < kids.length; i++) {
      if (kids[i] && (tag in kids[i])) return kids[i]
    }
    return null
  }

  // Long-edge inset for one panel, as { lead, span } in logical pixels.
  function insetsFor(panel, vertical) {
    var full = vertical ? panel.height : panel.width
    if (!isFinite(full) || full <= 0) return { lead: 0, span: full }

    var span = Math.max(1, Math.round(full * widthFraction))
    var slack = Math.max(0, full - span)
    var lead = widthAlign === "start" ? 0
      : (widthAlign === "end" ? slack : Math.round(slack / 2))
    return { lead: lead, span: span }
  }

  // omarchy >= 4.5: the panel already spans its screen and draws the bar in a
  // `barStrip` item (background Rectangle + content Loader), with its input
  // Region bound to that item. Find it as the contentItem child that holds the
  // content Loader.
  function barStripOf(panel) {
    var kids = panel.contentItem ? panel.contentItem.children : null
    if (!kids) return null
    for (var i = 0; i < kids.length; i++) {
      var grand = kids[i] ? kids[i].children : null
      if (!grand) continue
      for (var j = 0; j < grand.length; j++) {
        if (grand[j] && ("sourceComponent" in grand[j])) return kids[i]
      }
    }
    return null
  }

  // Resizing the strip is all it takes: the backdrop and input mask upstream
  // attach to it follow along. Bindings (not one-shot values) so thickness,
  // position and screen-size changes keep tracking without a re-apply.
  function insetStrip(panel, strip) {
    strip.x = Qt.binding(function() {
      if (root.innerBar.vertical === true)
        return root.innerBar.position === "right" ? panel.width - panel.thickness : 0
      return root.insetsFor(panel, false).lead
    })
    strip.y = Qt.binding(function() {
      if (root.innerBar.vertical === true) return root.insetsFor(panel, true).lead
      return root.innerBar.position === "bottom" ? panel.height - panel.thickness : 0
    })
    strip.width = Qt.binding(function() {
      return root.innerBar.vertical === true ? panel.thickness : root.insetsFor(panel, false).span
    })
    strip.height = Qt.binding(function() {
      return root.innerBar.vertical === true ? root.insetsFor(panel, true).span : panel.thickness
    })
  }

  // insetsFor() measures the long edge of the full-screen surface.
  function applyInsets() {
    if (!innerBar) return

    var vertical = innerBar.vertical === true
    var panels = collectBarPanels()

    for (var i = 0; i < panels.length; i++) {
      var panel = panels[i]
      if (!panel || !panel.contentItem) continue

      var strip = barStripOf(panel)
      if (strip && ("thickness" in panel)) {
        insetStrip(panel, strip)
        continue
      }

      // Pre-4.5 layout: the Loader sat directly under contentItem.
      var loader = contentLoaderOf(panel)
      if (!loader) continue

      var geom = insetsFor(panel, vertical)

      // anchors.fill would keep dragging the content back to full size.
      loader.anchors.fill = undefined
      if (vertical) {
        loader.x = 0
        loader.y = geom.lead
        loader.width = panel.width
        loader.height = geom.span
      } else {
        loader.x = geom.lead
        loader.y = 0
        loader.width = geom.span
        loader.height = panel.height
      }

      // The window paints its own colour across the whole surface, so clear it
      // and paint only the inset span instead.
      panel.color = "transparent"

      var backdrop = taggedChild(panel, "ultrawideBackdrop")
      if (!backdrop) backdrop = backdropComponent.createObject(panel.contentItem)
      if (backdrop) {
        backdrop.x = loader.x
        backdrop.y = loader.y
        backdrop.width = loader.width
        backdrop.height = loader.height
      }

      var mask = panel.mask
      if (!mask || !("ultrawideMask" in mask)) mask = maskComponent.createObject(panel)
      if (mask) {
        mask.x = loader.x
        mask.y = loader.y
        mask.width = loader.width
        mask.height = loader.height
        panel.mask = mask
      }
    }
  }
}
