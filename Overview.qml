import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Mission Control-like overview: every workspace on the focused monitor as a
// card with live thumbnails of its windows.
//
// Motion works like macOS: nothing fades in. The whole grid is drawn scaled up
// so the current workspace's card exactly covers the screen, then zooms out to
// its resting layout. Closing zooms back into the chosen card, so the overlay
// hands off to the real desktop without a visible jump.
Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false
  property bool closing: false
  // 0 = zoomed into the anchor card (looks like the desktop), 1 = overview.
  property real progress: 0
  property int selectedIndex: 0
  property int anchorIndex: 0
  property var workspaceList: []
  property bool finishPending: false

  // Live 3-finger vertical swipe (see ~/.config/hypr/input.lua): the overview
  // follows the fingers and settles on release, like Mission Control.
  property bool tracking: false
  property real trackStart: 0
  property real trackDy: 0
  property real lastDy: 0
  property real fingerVelocity: 0
  property real lastUpdateAt: 0
  property real springTarget: 1
  property real springVelocity: 0
  property bool springClosing: false

  function springDone() {
    spring.running = false
    if (root.springClosing) {
      root.springClosing = false
      root.finishClose()
    }
  }

  // Critically damped spring: no overshoot, ~300ms to settle from rest.
  FrameAnimation {
    id: spring
    running: false
    onTriggered: {
      var dt = Math.min(frameTime, 1 / 30)
      var k = 220, c = 2 * Math.sqrt(k)
      var x = root.progress - root.springTarget
      root.springVelocity += (-k * x - c * root.springVelocity) * dt
      var next = root.progress + root.springVelocity * dt
      if (Math.abs(next - root.springTarget) < 0.001 && Math.abs(root.springVelocity) < 0.05) {
        root.progress = root.springTarget
        root.springDone()
      } else {
        root.progress = Math.max(0, Math.min(1, next))
      }
    }
  }

  // Where the fingers put the overview. Touchpad events arrive unevenly and
  // not in step with the display, so each displayed frame (120Hz here) eases
  // progress toward this instead of jumping on every event.
  property real gestureTarget: 0
  FrameAnimation {
    running: root.tracking && root.opened
    onTriggered: {
      var k = 1 - Math.exp(-frameTime / 0.025)
      var next = root.progress + (root.gestureTarget - root.progress) * k
      root.progress = Math.abs(root.gestureTarget - next) < 0.0005 ? root.gestureTarget : next
    }
  }

  // Touchpad units for a full open/close (Hyprland swipe units, ~px).
  readonly property real gestureDistance: 260

  readonly property string pluginId: (root.manifest && root.manifest.id) || "matheustimbo.overview"
  // The background symlink keeps its path when the wallpaper changes, so
  // resolve it on every open; a new target is a new URL, defeating the cache.
  readonly property string wallpaperLink: Quickshell.env("HOME") + "/.local/state/omarchy/current/background"
  property string wallpaper: "file://" + wallpaperLink

  Process {
    id: wallpaperResolve
    command: ["readlink", "-f", root.wallpaperLink]
    stdout: StdioCollector {
      onStreamFinished: {
        var target = String(text || "").trim()
        if (target.length > 0 && target.charAt(0) === "/") root.wallpaper = "file://" + target
      }
    }
  }
  Component.onCompleted: wallpaperResolve.running = true

  // A still of the real screen (bar, borders, wallpaper and all), taken as
  // the gesture starts. The current card shows it while the zoom begins so
  // the first frames match the desktop exactly, then hands over to the live
  // thumbnails.
  property var shotSource: null
  property int shotAnchor: -1
  readonly property bool shotReady: desktopShot.hasContent && shotSource !== null
  readonly property real shotOpacity: Math.max(0, Math.min(1, 1 - (progress - 0.05) / 0.35))

  property color foreground: Commons.Color.menu.text
  property color accent: Commons.Color.accent
  property color cardBackground: Commons.Color.menu.background
  property color barBackground: Commons.Color.bar.background
  property string fontFamily: Style.font.menuFamily

  readonly property int openMs: 380
  readonly property int closeMs: 320

  // Layout: cards keep the monitor's aspect ratio and wrap into centered rows.
  readonly property real screenW: Math.max(1, panel.width)
  readonly property real screenH: Math.max(1, panel.height)
  readonly property int count: Math.max(1, workspaceList.length)
  readonly property int columns: Math.min(count, count <= 3 ? count : Math.ceil(Math.sqrt(count * 1.6)))
  readonly property int rows: Math.ceil(count / columns)
  readonly property real gap: Style.space(28)
  readonly property real labelH: Style.font.title + Style.space(12)
  readonly property real cardW: Math.min(
    (screenW * 0.86 - gap * (columns - 1)) / columns,
    ((screenH * 0.78 - gap * (rows - 1)) / rows - labelH) * screenW / screenH,
    screenW * 0.34)
  readonly property real cardH: cardW * screenH / screenW
  readonly property real gridW: columns * cardW + (columns - 1) * gap
  readonly property real gridH: rows * (cardH + labelH) + (rows - 1) * gap
  readonly property real gridX: (screenW - gridW) / 2
  readonly property real gridY: (screenH - gridH) / 2

  // Space Hyprland reserves for the bar, so cards can draw it like the desktop.
  readonly property real barTop: {
    var mon = Hyprland.focusedMonitor
    var r = mon && mon.lastIpcObject ? mon.lastIpcObject.reserved : null
    return r && r.length > 1 ? r[1] : 0
  }

  function cardX(i) {
    var row = Math.floor(i / columns)
    var col = i % columns
    var inRow = Math.min(columns, workspaceList.length - row * columns)
    return (columns - inRow) * (cardW + gap) / 2 + col * (cardW + gap)
  }
  function cardY(i) { return Math.floor(i / columns) * (cardH + labelH + gap) }

  // Grid transform: at progress 0 the anchor card fills the screen exactly.
  readonly property real zoom: screenW / cardW
  readonly property real gridScale: zoom + (1 - zoom) * progress
  readonly property real gridTx: (-zoom * cardX(anchorIndex)) + (gridX + zoom * cardX(anchorIndex)) * progress
  readonly property real gridTy: (-zoom * cardY(anchorIndex)) + (gridY + zoom * cardY(anchorIndex)) * progress

  function refreshList() {
    var mon = Hyprland.focusedMonitor
    var out = []
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      var ws = values[i]
      if (!ws || ws.id <= 0) continue
      if (mon && ws.monitor && ws.monitor.name !== mon.name) continue
      out.push(ws)
    }
    out.sort(function(a, b) { return a.id - b.id })
    // Reassigning the model rebuilds every card and drops its thumbnails, so
    // only do it when the set of workspaces really changed.
    var same = out.length === root.workspaceList.length
    for (var k = 0; same && k < out.length; k++) same = out[k] === root.workspaceList[k]
    if (!same) root.workspaceList = out
  }

  function focusedIndex() {
    var focused = Hyprland.focusedWorkspace
    for (var j = 0; j < workspaceList.length; j++)
      if (focused && workspaceList[j].id === focused.id) return j
    return 0
  }

  // Window thumbnails take a few frames to arrive. Until the current
  // workspace's are in, the overlay stays hidden: the real desktop underneath
  // looks the same, so nothing flashes.
  property bool warm: false
  property bool revealTimedOut: false
  readonly property bool anchorReady: {
    var c = cardRepeater.count
    var it = c > anchorIndex ? cardRepeater.itemAt(anchorIndex) : null
    return it ? it.allReady : c === 0
  }
  // Copying every window at full resolution each frame halves the frame rate
  // of the zoom. Stream thumbnails only while the overview sits still, plus
  // once while warming up so the first frame is fresh; during motion they hold.
  readonly property bool settled: opened && !closing && !tracking && progress >= 0.999
    && !openAnim.running && !closeAnim.running && !spring.running
  readonly property bool thumbsLive: settled || (warm && !revealed)
  readonly property bool revealed: opened && ((anchorReady && shotReady) || revealTimedOut)

  onRevealedChanged: {
    // Keyboard/command opens animate from the first visible frame.
    if (revealed && !tracking && !closing && progress === 0) {
      openAnim.duration = Style.duration(root.openMs)
      openAnim.restart()
    }
  }

  Timer { id: revealFallback; interval: 250; onTriggered: root.revealTimedOut = true }
  Timer { id: coolDown; interval: 1500; onTriggered: if (!root.opened) root.warm = false }

  function open(payloadJson) {
    if (root.opened && !root.closing) return
    root.prepareOpen()
  }

  // Start capturing thumbnails without showing anything yet.
  function warmUp() {
    if (root.opened) return
    root.targetScreen = root.focusedScreen()
    Hyprland.refreshWorkspaces()
    Hyprland.refreshToplevels()
    root.refreshList()
    root.anchorIndex = root.focusedIndex()
    root.selectedIndex = root.anchorIndex
    root.warm = true
    wallpaperResolve.running = true
    // Re-take the still: drop the source, then set it on the next turn.
    root.shotSource = null
    root.shotAnchor = root.anchorIndex
    Qt.callLater(function() { if (root.warm && !root.revealed) root.shotSource = root.targetScreen })
    coolDown.restart()
  }

  function prepareOpen() {
    if (!root.warm) root.warmUp()
    closeAnim.stop()
    root.closing = false
    root.progress = 0
    root.revealTimedOut = false
    root.opened = true
    revealFallback.restart()
  }

  function gestureStart() {
    openAnim.stop()
    spring.running = false
    if (root.closing && !root.springClosing) return
    if (root.springClosing) { root.springClosing = false; root.closing = false }
    root.tracking = true
    root.trackDy = 0
    root.lastDy = 0
    root.trackStart = root.opened ? root.progress : 0
    root.gestureTarget = root.trackStart
    root.fingerVelocity = 0
    root.lastUpdateAt = 0
    if (!root.opened) root.warmUp()
  }

  function gestureUpdate(dy) {
    if (!root.tracking || !isFinite(dy)) return
    root.trackDy += dy
    root.lastDy = dy
    // Finger speed in progress units per second, smoothed over a few events.
    var now = Date.now()
    var dt = Math.max(4, now - root.lastUpdateAt) / 1000
    if (root.lastUpdateAt > 0 && now - root.lastUpdateAt < 60)
      root.fingerVelocity = 0.5 * root.fingerVelocity + 0.5 * (-dy / root.gestureDistance) / dt
    root.lastUpdateAt = now
    releaseTimer.restart()
    // Fingers up (negative dy) open; down close.
    var p = Math.max(0, Math.min(1, root.trackStart - root.trackDy / root.gestureDistance))
    if (!root.opened) {
      if (p <= 0) return
      root.prepareOpen()
    }
    root.gestureTarget = p
  }

  function gestureEnd(cancelled) {
    releaseTimer.stop()
    if (!root.tracking) return
    root.tracking = false
    // Settle from where the fingers were, not where the smoothing lagged to.
    if (root.opened) root.progress = root.gestureTarget
    if (!root.opened) return
    // A flick decides by its direction; a slow release by how far it got.
    var v = root.fingerVelocity
    var open
    if (cancelled) open = root.trackStart > 0.5
    else if (Math.abs(v) > 3) open = v > 0
    else open = root.progress > 0.5
    // Carry on from the fingers' speed and ease into place, like a spring.
    root.springTarget = open ? 1 : 0
    root.springVelocity = (v > 0) === open ? v : 0
    if (!open) {
      root.closing = true
      root.springClosing = true
      root.anchorIndex = root.focusedIndex()
    }
    if (Style.duration(100) === 0) { root.progress = root.springTarget; root.springDone(); return }
    spring.running = true
  }

  // Hyprland 0.56.2 never calls a Lua gesture's "end" callback, so a short pause in
  // updates is taken as the fingers lifting. While fingers move the touchpad
  // reports every ~8ms; the longest gap seen was 24ms.
  Timer {
    id: releaseTimer
    interval: 45
    onTriggered: root.gestureEnd(false)
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event || event.name !== "custom") return
      var data = String(event.data || "")
      if (data.indexOf("matheustimbo.overview:") !== 0) return
      var parts = data.split(":")
      if (parts[1] === "start") root.gestureStart()
      else if (parts[1] === "update") root.gestureUpdate(parseFloat(parts[2]))
      else if (parts[1] === "end") root.gestureEnd(parts[2] === "1")
    }
  }

  // Called by the shell (shell.hide, the swipe-down gesture) and by us.
  function close() {
    if (!root.opened || root.closing) return
    root.animateClose(root.focusedIndex())
  }

  function animateClose(targetIndex) {
    openAnim.stop()
    spring.running = false
    root.springClosing = false
    root.closing = true
    // Zoom back in on the target card, so it ends up covering the screen.
    root.anchorIndex = Math.max(0, Math.min(targetIndex, workspaceList.length - 1))
    root.tracking = false
    closeAnim.from = root.progress
    closeAnim.duration = Style.duration(Math.max(120, root.closeMs * root.progress))
    closeAnim.restart()
  }

  function finishClose() {
    // Keep covering the screen until Hyprland's own workspace slide underneath
    // is done, so the hand-off to the real desktop doesn't show it.
    if (switchHold.running) { root.finishPending = true; return }
    root.finishPending = false
    root.opened = false
    root.closing = false
    root.progress = 0
    root.warm = false
    root.revealTimedOut = false
    revealFallback.stop()
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
  }

  function dismiss() { root.close() }

  function toggle() {
    if (root.opened && !root.closing) root.close()
    else root.open("{}")
  }

  function indexOfWorkspace(ws) {
    for (var i = 0; i < workspaceList.length; i++) if (workspaceList[i] === ws) return i
    return -1
  }

  function goToWorkspace(ws) {
    if (!ws || root.closing) return
    // Switch underneath first; the overlay covers it and zooms into the card.
    if (!Hyprland.focusedWorkspace || Hyprland.focusedWorkspace.id !== ws.id) switchHold.restart()
    Hyprland.dispatch('hl.dsp.focus({ workspace = "' + ws.id + '" })')
    root.animateClose(root.indexOfWorkspace(ws))
  }

  function focusWindow(address, ws) {
    if (root.closing) return
    // Addresses come from Hyprland itself; still only accept hex so the
    // dispatched Lua expression stays well-formed.
    var a = String(address || "")
    if (!/^(0x)?[0-9a-fA-F]+$/.test(a)) return
    if (a.indexOf("0x") !== 0) a = "0x" + a
    if (!Hyprland.focusedWorkspace || !ws || Hyprland.focusedWorkspace.id !== ws.id) switchHold.restart()
    Hyprland.dispatch('hl.dsp.focus({ window = hl.get_window("address:' + a + '") })')
    root.animateClose(root.indexOfWorkspace(ws))
  }

  function move(delta) {
    if (workspaceList.length === 0) return
    selectedIndex = (selectedIndex + delta + workspaceList.length) % workspaceList.length
  }

  function moveRow(delta) {
    var next = selectedIndex + delta * columns
    if (next >= 0 && next < workspaceList.length) selectedIndex = next
  }

  // Hyprland's workspace animation is 400ms (looknfeel.lua); wait it out.
  Timer {
    id: switchHold
    interval: 430
    onTriggered: if (root.finishPending) root.finishClose()
  }

  NumberAnimation {
    id: openAnim
    target: root
    property: "progress"
    to: 1
    duration: Style.duration(root.openMs)
    easing.type: Easing.Bezier
    easing.bezierCurve: [0.2, 0.9, 0.25, 1.0, 1.0, 1.0]
  }

  NumberAnimation {
    id: closeAnim
    target: root
    property: "progress"
    to: 0
    duration: Style.duration(root.closeMs)
    easing.type: Easing.Bezier
    easing.bezierCurve: [0.3, 0.0, 0.2, 1.0, 1.0, 1.0]
    onFinished: if (root.closing) root.finishClose()
  }


  Connections {
    target: Hyprland.workspaces
    function onValuesChanged() { if (root.opened && !root.closing) root.refreshList() }
  }

  onOpenedChanged: if (opened) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  onTrackingChanged: if (!tracking && opened) Qt.callLater(function() { keyCatcher.forceActiveFocus() })

  property var targetScreen: Quickshell.screens.length > 0 ? Quickshell.screens[0] : null

  function focusedScreen() {
    var monitor = Hyprland.focusedMonitor
    var name = monitor ? String(monitor.name || "") : ""
    for (var i = 0; i < Quickshell.screens.length; i++)
      if (Quickshell.screens[i].name === name) return Quickshell.screens[i]
    return root.targetScreen
  }

  // Kept mapped all the time (transparent, ignoring input, no keyboard focus
  // while closed) so a swipe shows it on the very next frame instead of
  // waiting ~200ms for a fresh layer surface to be created and configured.
  Region { id: noInput }

  PanelWindow {
    id: panel
    visible: !!root.targetScreen
    screen: root.targetScreen
    anchors { top: true; left: true; bottom: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "matheustimbo-overview"
    WlrLayershell.layer: WlrLayer.Overlay
    // Take input only once a swipe is over: changing pointer or keyboard
    // focus mid-swipe makes Hyprland stop delivering the gesture's updates.
    readonly property bool takesInput: root.opened && !root.tracking
    WlrLayershell.keyboardFocus: takesInput ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    mask: takesInput ? null : noInput

    Binding { target: panel.contentItem; property: "visible"; value: root.revealed }
    Binding { target: panel.contentItem; property: "LayoutMirroring.enabled"; value: false }

    // Backdrop: the wallpaper, darkening as the desktop zooms out.
    Image {
      anchors.fill: parent
      source: root.wallpaper
      fillMode: Image.PreserveAspectCrop
      asynchronous: false
      cache: true
      sourceSize.width: 1280
    }
    Rectangle {
      anchors.fill: parent
      color: "#000000"
      opacity: 0.5 * root.progress
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: root.opened
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        var key = Util.readingKey(event)
        if (event.key === Qt.Key_Escape) root.close()
        else if (key === Qt.Key_Left || event.key === Qt.Key_H) root.move(-1)
        else if (key === Qt.Key_Right || event.key === Qt.Key_L) root.move(1)
        else if (event.key === Qt.Key_Up || event.key === Qt.Key_K) root.moveRow(-1)
        else if (event.key === Qt.Key_Down || event.key === Qt.Key_J) root.moveRow(1)
        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space)
          root.goToWorkspace(root.workspaceList[root.selectedIndex])
        else if (event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
          var n = event.key - Qt.Key_0
          for (var i = 0; i < root.workspaceList.length; i++)
            if (root.workspaceList[i].id === n) { root.goToWorkspace(root.workspaceList[i]); break }
        } else return
        event.accepted = true
      }
    }

    Item {
      id: grid
      x: 0
      y: 0
      width: root.gridW
      height: root.gridH
      transform: [
        Scale { xScale: root.gridScale; yScale: root.gridScale },
        Translate { x: root.gridTx; y: root.gridTy }
      ]

      Item {
        id: shotFrame
        z: 10
        x: root.cardX(root.anchorIndex)
        y: root.cardY(root.anchorIndex)
        width: root.cardW
        height: root.cardH
        // Also used when closing back onto the workspace it was taken on.
        visible: root.shotOpacity > 0 && root.anchorIndex === root.shotAnchor
        opacity: root.shotOpacity

        ScreencopyView {
          id: desktopShot
          anchors.fill: parent
          captureSource: root.shotSource
          live: false
          paintCursor: false
        }
      }

      Repeater {
        id: cardRepeater
        model: root.workspaceList

        delegate: Item {
          id: card
          required property var modelData
          required property int index

          readonly property var ws: modelData
          // Thumbnails with content; the card is ready when all have one.
          property int readyVersion: 0
          readonly property bool allReady: {
            readyVersion
            for (var i = 0; i < winRepeater.count; i++) {
              var w = winRepeater.itemAt(i)
              if (!w || !w.ready) return false
            }
            return true
          }
          readonly property bool isSelected: index === root.selectedIndex && root.progress > 0.99 && !root.closing
          readonly property real sx: root.cardW / root.screenW
          readonly property real sy: root.cardH / root.screenH

          x: root.cardX(index)
          y: root.cardY(index)
          width: root.cardW
          height: root.cardH + root.labelH

          Item {
            id: frame
            width: root.cardW
            height: root.cardH
            // Grow a little under the pointer, only once fully settled.
            scale: cardMouse.containsMouse && root.progress > 0.99 && !root.closing ? 1.025 : 1
            Behavior on scale {
              NumberAnimation { duration: Style.duration(160); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut }
            }

            // Rounded corners appear as the card shrinks; at full size the
            // card is square like the screen.
            // Omarchy's corner setting (Hyprland decoration:rounding); 0 = sharp.
            readonly property real radius: Style.cornerRadius * root.progress

            Rectangle {
              id: clipper
              anchors.fill: parent
              radius: frame.radius
              color: root.cardBackground
              clip: true

              Image {
                anchors.fill: parent
                source: root.wallpaper
                fillMode: Image.PreserveAspectCrop
                asynchronous: false
                cache: true
                sourceSize.width: 1280
              }

              // The bar, as it sits on the real desktop.
              Rectangle {
                width: parent.width
                height: root.barTop * card.sy
                color: root.barBackground
                visible: root.barTop > 0
              }

              // Windows, placed where they sit on screen.
              Repeater {
                id: winRepeater
                model: card.ws ? card.ws.toplevels : null

                delegate: Item {
                  id: win
                  readonly property bool ready: thumb.hasContent || !win.visible
                  onReadyChanged: card.readyVersion++
                  Component.onCompleted: card.readyVersion++
                  required property var modelData
                  readonly property var ipc: modelData.lastIpcObject || ({})
                  readonly property var at: ipc.at || [0, 0]
                  readonly property var size: ipc.size || [0, 0]
                  readonly property var mon: card.ws.monitor
                  readonly property real offX: mon && mon.lastIpcObject ? (mon.lastIpcObject.x || 0) : 0
                  readonly property real offY: mon && mon.lastIpcObject ? (mon.lastIpcObject.y || 0) : 0

                  visible: size[0] > 0 && size[1] > 0 && !ipc.hidden
                  x: (at[0] - offX) * card.sx
                  y: (at[1] - offY) * card.sy
                  width: size[0] * card.sx
                  height: size[1] * card.sy
                  z: ipc.floating ? 2 : 1

                  ScreencopyView {
                    id: thumb
                    anchors.fill: parent
                    // Keep the source bound so the last frame survives between
                    // opens (no blank thumbnails on the first frames); only
                    // stream new frames while warming up or open.
                    captureSource: win.modelData.wayland ? win.modelData.wayland : null
                    live: root.thumbsLive
                    paintCursor: false
                  }

                  Rectangle {
                    anchors.fill: parent
                    color: "transparent"
                    // A window's own rounding, scaled down with the card.
                    radius: Style.cornerRadius * card.sx
                    border.width: winMouse.containsMouse && root.progress > 0.99 ? Style.space(2) / root.gridScale : 0
                    border.color: root.accent
                  }

                  MouseArea {
                    id: winMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onContainsMouseChanged: if (containsMouse) root.selectedIndex = card.index
                    onClicked: root.focusWindow(win.modelData.address, card.ws)
                  }
                }
              }
            }

            // Selection ring, drawn outside the clipped content.
            Rectangle {
              anchors.fill: parent
              anchors.margins: -Style.space(3)
              radius: Style.cornerRadius > 0 ? frame.radius + Style.space(3) : 0
              color: "transparent"
              border.width: Style.space(3)
              border.color: root.accent
              visible: card.isSelected
            }

            MouseArea {
              id: cardMouse
              anchors.fill: parent
              z: -1
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onContainsMouseChanged: if (containsMouse) root.selectedIndex = card.index
              onClicked: root.goToWorkspace(card.ws)
            }
          }

          Text {
            textFormat: Text.PlainText
            anchors.top: frame.bottom
            anchors.topMargin: Style.space(8)
            anchors.horizontalCenter: frame.horizontalCenter
            text: card.ws ? String(card.ws.name || card.ws.id) : ""
            color: card.isSelected ? root.accent : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: Hyprland.focusedWorkspace && card.ws && Hyprland.focusedWorkspace.id === card.ws.id
            // Labels sit in the gaps, which only exist once zoomed out.
            visible: root.progress > 0.6
          }
        }
      }
    }
  }
}
