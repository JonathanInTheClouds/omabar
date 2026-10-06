import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Services.UPower
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Omabar: Touch Bar layouts for Omarchy on Intel T2 MacBook Pros.
// The bar button opens a popup that previews each layout (built-in ones from
// the plugin's layouts/, yours from ~/.config/omarchy/omabar/layouts/) as a
// to-scale strip drawn from the real icons and font, and applies one with
// bin/omabar. It also follows the focused app and refreshes the weather.
// See AGENTS.md.
Panel {
  id: root
  moduleName: "io.github.jonathanintheclouds.omabar"
  ipcTarget: "io.github.jonathanintheclouds.omabar"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property string tool: decodeURIComponent(
    Qt.resolvedUrl("bin/omabar").toString().replace(/^file:\/\//, ""))
  // The bar's real size: 2008x60 on 16-inch models, 2170x60 on 13/15-inch.
  property real barWidth: 2008
  readonly property real stripRatio: barWidth / 60

  property var layouts: []
  property bool passwordless: true
  property string layoutsDir: ""
  property string applyingId: ""
  property string error: ""
  property string selectedId: ""
  property bool follow: false
  property bool emptyDefault: true
  property var ruleWarnings: []
  property string manualPick: ""
  property string defaultLayout: ""
  property string rulesFile: ""
  property string colors: "default"
  property bool supported: true
  property string model: ""
  property string helperPath: ""
  property string installScript: ""
  readonly property string helperState: passwordless ? "live" : "missing"
  property bool autoPending: false
  property bool autoPrimed: false
  // Window class of the focused app; "" on an empty workspace.
  property string focusedApp: ""
  property date now: new Date()

  readonly property var activeLayout: {
    for (var i = 0; i < layouts.length; i++) if (layouts[i].active) return layouts[i]
    return null
  }

  readonly property var selectedLayout: {
    for (var i = 0; i < layouts.length; i++) if (layouts[i].id === selectedId) return layouts[i]
    return null
  }

  function selectBy(step) {
    var n = layouts.length
    if (n === 0) return
    var i = 0
    for (var j = 0; j < n; j++) if (layouts[j].id === selectedId) i = j
    selectedId = layouts[(i + step + n) % n].id
    error = ""
  }

  function pickName() {
    return root.manualPick ? root.layoutName(root.manualPick) + " (your last pick)"
                           : root.layoutName(root.defaultLayout) + " (the default)"
  }

  function layoutName(id) {
    for (var i = 0; i < layouts.length; i++) if (layouts[i].id === id) return layouts[i].name
    return id
  }

  function canActivate(l) {
    return !!l && !l.active && !l.error
  }

  function refresh() {
    if (!listProc.running) listProc.running = true
  }

  function apply(id) {
    if (applyProc.running) return
    error = ""
    applyingId = id
    applyProc.command = [root.tool, "apply", id]
    applyProc.running = true
  }

  onOpenedChanged: if (opened) { now = new Date(); refresh() }

  // tiny-dfr's Time button takes strftime; cover the parts layouts use.
  function strftime(fmt, d) {
    if (fmt === "24hr") fmt = "%H:%M"
    if (fmt === "12hr") fmt = "%-I:%M %p"
    var pad = function (n) { return n < 10 ? "0" + n : String(n) }
    var h12 = d.getHours() % 12 || 12
    var days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    var map = {
      "H": pad(d.getHours()), "-H": String(d.getHours()),
      "I": pad(h12), "-I": String(h12),
      "M": pad(d.getMinutes()), "S": pad(d.getSeconds()),
      "p": d.getHours() < 12 ? "AM" : "PM",
      "d": pad(d.getDate()), "-d": String(d.getDate()), "e": String(d.getDate()), "-e": String(d.getDate()),
      "m": pad(d.getMonth() + 1), "-m": String(d.getMonth() + 1),
      "Y": String(d.getFullYear()), "a": days[d.getDay()], "b": months[d.getMonth()], "%": "%"
    }
    return fmt.replace(/%(-?[A-Za-z%])/g, function (m, k) { return map[k] !== undefined ? map[k] : m })
  }

  function batteryText() {
    var dev = UPower.displayDevice
    if (!dev || !dev.isPresent) return "—"
    return Math.round(Math.max(0, Math.min(1, dev.percentage)) * 100) + "%"
  }

  function batteryFraction() {
    var dev = UPower.displayDevice
    return dev && dev.isPresent ? Math.max(0, Math.min(1, dev.percentage)) : 0
  }

  // tiny-dfr colours the battery button green while charging, red under 10%.
  function batteryColor() {
    var dev = UPower.displayDevice
    if (dev && dev.isPresent && !UPower.onBattery && batteryFraction() < 0.99) return "#4caf50"
    if (dev && dev.isPresent && UPower.onBattery && batteryFraction() < 0.1) return "#e53935"
    return "#ffffff"
  }

  Process {
    id: listProc
    command: [root.tool, "list"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var data = JSON.parse(text)
          root.layouts = data.layouts || []
          root.passwordless = data.passwordless === true
          root.layoutsDir = data.layoutsDir || ""
          root.follow = data.follow === true
          root.emptyDefault = data.emptyDefault !== false
          root.ruleWarnings = data.ruleWarnings || []
          root.manualPick = data.manualPick || ""
          root.defaultLayout = data.defaultLayout || ""
          // The first list can land after focus already settled; catch up once.
          if (root.follow && !root.autoPrimed) { root.autoPrimed = true; root.runAuto() }
          root.rulesFile = data.rulesFile || ""
          root.colors = data.colors || "default"
          var hw = data.hardware || {}
          root.barWidth = hw.width || 2008
          root.supported = hw.supported !== false
          root.model = hw.model || ""
          root.helperPath = data.helperPath || ""
          root.installScript = data.installScript || ""
          if (data.rulesError) root.error = data.rulesError
          // Keep the current pick; otherwise start on the live layout.
          if (!root.selectedLayout) {
            var pick = root.activeLayout || root.layouts[0]
            root.selectedId = pick ? pick.id : ""
          }
        } catch (e) {
          root.error = "Could not read the layouts list"
        }
      }
    }
  }

  Process {
    id: applyProc
    stderr: StdioCollector { id: applyErr; waitForEnd: true }
    onExited: function (exitCode) {
      if (exitCode !== 0)
        root.error = String(applyErr.text || "").trim() || ("Applying the layout failed (exit " + exitCode + ")")
      root.applyingId = ""
      root.refresh()
      if (root.autoPending) { root.autoPending = false; root.runAuto() }
    }
  }

  // ---------- Follow the focused app ----------
  // Focus has to settle for a moment first, so Alt-Tabbing past windows
  // doesn't swap the bar for each one.
  Component.onCompleted: {
    focusedApp = ToplevelManager.activeToplevel ? (ToplevelManager.activeToplevel.appId || "") : ""
    refresh()
  }
  // The backend checks the rules file's "follow" flag itself, so turning it on
  // by editing the file works without reopening the panel.
  onFocusedAppChanged: autoTimer.restart()

  // Hyprland's activewindow event is "class,title", and ",": an empty
  // workspace, which sends the bar back to the default layout.
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event || String(event.name) !== "activewindow") return
      var data = String(event.data || "")
      var cls = data.split(",")[0]
      // A window with no class still counts as an app, not an empty desktop.
      root.focusedApp = cls !== "" ? cls : (data.length > 1 ? "?" : "")
      // Same app again (e.g. after a popup closed): the backend re-checks.
      autoTimer.restart()
    }
  }

  Timer {
    id: autoTimer
    interval: 350
    onTriggered: root.runAuto()
  }

  function runAuto() {
    if (autoProc.running || applyProc.running) { root.autoPending = true; return }
    autoProc.command = [root.tool, "auto", root.focusedApp]
    autoProc.running = true
  }

  Process {
    id: autoProc
    stderr: StdioCollector { id: autoErr; waitForEnd: true }
    onExited: function (exitCode) {
      if (exitCode !== 0) root.error = String(autoErr.text || "").trim() || "Switching layouts failed"
      if (root.opened) root.refresh()
      if (root.autoPending) { root.autoPending = false; root.runAuto() }
    }
  }

  // Installs the helper and polkit rule through the normal password dialog.
  function runSetup() {
    if (setupProc.running || root.installScript === "") return
    root.error = ""
    setupProc.command = ["/usr/bin/pkexec", "/usr/bin/bash", root.installScript]
    setupProc.running = true
  }

  Process {
    id: setupProc
    stderr: StdioCollector { id: setupErr; waitForEnd: true }
    onExited: function (exitCode) {
      // 126: the password dialog was dismissed; nothing to report.
      if (exitCode !== 0 && exitCode !== 126)
        root.error = String(setupErr.text || "").trim() || ("Setting up the helper failed (exit " + exitCode + ")")
      root.refresh()
      if (exitCode === 0) {
        firstApplyProc.command = [root.tool, "apply", root.manualPick || root.defaultLayout || "duotone-weather"]
        firstApplyProc.running = true
      }
    }
  }

  Process {
    id: firstApplyProc
    onExited: root.refresh()
  }

  function setColors(theme) {
    if (colorsProc.running) return
    root.colors = theme ? "theme" : "default"
    colorsProc.command = [root.tool, "colors", theme ? "theme" : "default"]
    colorsProc.running = true
  }

  Process {
    id: colorsProc
    stderr: StdioCollector { id: colorsErr; waitForEnd: true }
    onExited: function (exitCode) {
      if (exitCode !== 0) root.error = String(colorsErr.text || "").trim() || "Changing colours failed"
      root.refresh()
    }
  }

  // The editor is this plugin's panel entry point (Editor.qml); summoning the
  // plugin id opens it. The popup closes so the editor has the screen.
  function openEditor(payload) {
    root.close()
    Quickshell.execDetached(["omarchy-shell", "shell", "summon", "io.github.jonathanintheclouds.omabar",
                             JSON.stringify(payload || {})])
  }

  function setFollow(on) {
    if (followProc.running) return
    root.follow = on
    followProc.command = [root.tool, "follow", on ? "on" : "off"]
    followProc.running = true
  }

  Process {
    id: followProc
    onExited: { root.refresh(); if (root.follow) root.runAuto() }
  }

  function setEmptyDefault(on) {
    if (emptyProc.running) return
    root.emptyDefault = on
    emptyProc.command = [root.tool, "empty-default", on ? "on" : "off"]
    emptyProc.running = true
  }

  Process {
    id: emptyProc
    onExited: { root.refresh(); if (root.follow && root.focusedApp === "") root.runAuto() }
  }

  Timer {
    interval: 10000; repeat: true; running: root.opened
    onTriggered: root.now = new Date()
  }

  // Weather layouts refresh from inside the shell: it runs in the desktop
  // session, which is what the passwordless polkit rule requires.
  Process {
    id: weatherProc
    command: [root.tool, "refresh-weather"]
    onExited: if (root.opened) root.refresh()
  }

  Timer {
    interval: 15 * 60 * 1000; repeat: true; running: true; triggeredOnStart: true
    onTriggered: if (!weatherProc.running && !applyProc.running) weatherProc.running = true
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰌌"  // nf-md-keyboard
    tooltipText: root.activeLayout ? "Touch Bar: " + root.activeLayout.name : "Touch Bar layouts"
    onPressed: function (b) { if (b === Qt.LeftButton) root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(860))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: picker.popupOpen
      onMoveRequested: function (dx, dy) { root.selectBy(dy !== 0 ? dy : dx) }
      onActivateRequested: if (root.canActivate(root.selectedLayout)) root.apply(root.selectedId)
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }

      Flickable {
        anchors.fill: parent
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: column
          width: parent.width
          spacing: Style.space(16)

          // ---------- Hero ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

            Text {
              id: heroIcon
              text: "󰌌"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: "Omabar"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }
              Text {
                text: (root.applyingId !== "" ? "Applying " + root.applyingId
                      : root.activeLayout ? root.activeLayout.name + " is on the bar" + (root.follow ? " · following apps" : "")
                      : root.layouts.length + " saved layouts").toUpperCase()
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                width: parent.width
                elide: Text.ElideRight
              }
            }
          }

          // ---------- Follow toggle ----------
          PanelSeparator { foreground: root.bar.foreground }

          Item {
            width: parent.width
            implicitHeight: Math.max(followLabels.implicitHeight, followSwitch.implicitHeight)

            Column {
              id: followLabels
              anchors.left: parent.left
              anchors.right: followSwitch.left
              anchors.rightMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: "Follow the focused app"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }
              Text {
                text: root.follow && !root.passwordless
                      ? "Paused until Omabar is set up (see below)."
                      : root.follow
                      ? "Switches layouts as you change apps" + " (now: " + (root.focusedApp || "empty desktop") + ")"
                        + ". Rules live in " + root.rulesFile.replace(/^\/home\/[^/]+/, "~") + "."
                      : "Off: the layout you pick stays until you pick another."
                color: root.bar.foreground
                opacity: 0.6
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                width: parent.width
                wrapMode: Text.Wrap
              }
              Text {
                text: "Edit rules…"
                color: Color.accent
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.underline: rulesLink.containsMouse
                MouseArea {
                  id: rulesLink
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.openEditor({ tab: "rules" })
                }
              }
              Text {
                visible: root.ruleWarnings.length > 0
                text: "Rules file: " + root.ruleWarnings.join("; ")
                color: Color.urgent
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                width: parent.width
                wrapMode: Text.Wrap
              }
            }

            ToggleSwitch {
              id: followSwitch
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              checked: root.follow
              busy: followProc.running
              onToggled: root.setFollow(!root.follow)
            }
          }

          Item {
            visible: root.follow
            width: parent.width
            implicitHeight: Math.max(emptyLabels.implicitHeight, emptySwitch.implicitHeight)

            Column {
              id: emptyLabels
              anchors.left: parent.left
              anchors.right: emptySwitch.left
              anchors.rightMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: "Return to your pick on an empty desktop"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
              }
              Text {
                text: (root.emptyDefault
                      ? "With no window focused, the bar goes back to " + root.pickName() + "."
                      : "With no window focused, the bar keeps the last app's layout.")
                      + " Apps without a rule always use " + root.pickName() + "."
                color: root.bar.foreground
                opacity: 0.6
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                width: parent.width
                wrapMode: Text.Wrap
              }
            }

            ToggleSwitch {
              id: emptySwitch
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              checked: root.emptyDefault
              busy: emptyProc.running
              onToggled: root.setEmptyDefault(!root.emptyDefault)
            }
          }

          // ---------- Colours ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(colorLabels.implicitHeight, colorSwitch.implicitHeight)

            Column {
              id: colorLabels
              anchors.left: parent.left
              anchors.right: colorSwitch.left
              anchors.rightMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: "Match the Omarchy theme"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }
              Text {
                text: root.colors === "theme"
                      ? "Icon colours follow the current theme and change when you switch themes, kept readable on the Touch Bar's black."
                      : "Off: Omabar's own colours, green launchers and pale system keys, whatever the theme."
                color: root.bar.foreground
                opacity: 0.6
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                width: parent.width
                wrapMode: Text.Wrap
              }
            }

            ToggleSwitch {
              id: colorSwitch
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              checked: root.colors === "theme"
              busy: colorsProc.running
              onToggled: root.setColors(root.colors !== "theme")
            }
          }

          Text {
            visible: !root.supported
            text: "This Mac (" + (root.model || "unknown model") + ") isn't an Intel T2 MacBook Pro with a Touch Bar. Omabar is built for MacBookPro15,x and 16,x."
            color: Color.urgent
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            width: parent.width
            wrapMode: Text.Wrap
          }

          // ---------- Picker ----------
          PanelSeparator { foreground: root.bar.foreground }

          Item {
            width: parent.width
            implicitHeight: Math.max(picker.implicitHeight, actionBox.implicitHeight)

            Dropdown {
              id: picker
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(300)
              showLabel: false
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              value: root.selectedId
              options: root.layouts.map(function (l) {
                return { value: l.id, label: l.name + (l.source === "yours" ? "  (yours)" : "") + (l.active ? "  (active)" : "") }
              })
              onChanged: function (v) { root.selectedId = v; root.error = "" }
            }

            Button {
              id: editButton
              anchors.left: picker.right
              anchors.leftMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              text: "Edit…"
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              onClicked: root.openEditor({ layout: root.selectedId })
            }

            Item {
              id: actionBox
              readonly property bool isActive: !!root.selectedLayout && root.selectedLayout.active === true
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              implicitWidth: isActive ? activeTag.implicitWidth : activateButton.implicitWidth
              implicitHeight: isActive ? activeTag.implicitHeight : activateButton.implicitHeight

              Text {
                id: activeTag
                visible: actionBox.isActive
                text: "● ACTIVE"
                color: Color.accent
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
              }

              Button {
                id: activateButton
                visible: !actionBox.isActive && !!root.selectedLayout
                enabled: root.canActivate(root.selectedLayout) && root.applyingId === ""
                opacity: enabled ? 1 : 0.4
                text: root.applyingId !== "" ? "Activating…" : "Activate"
                fontSize: Style.font.bodySmall
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                bordered: true
                onClicked: if (root.canActivate(root.selectedLayout)) root.apply(root.selectedId)
              }
            }
          }

          // ---------- Preview of the selected layout ----------
          Column {
            id: preview
            readonly property var l: root.selectedLayout
            readonly property bool broken: !!l && !!l.error
            visible: !!l
            width: parent.width
            spacing: Style.space(10)

            Text {
              text: !preview.l ? "" : preview.broken ? preview.l.error : (preview.l.description || "")
              visible: text !== ""
              color: preview.broken ? Color.urgent : root.bar.foreground
              opacity: preview.broken ? 1 : 0.6
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              width: parent.width
              wrapMode: Text.Wrap
            }

            Strip {
              visible: !preview.broken
              width: parent.width
              buttons: preview.l ? (preview.l.main || []) : []
              outlines: !!preview.l && preview.l.outlines === true
              fontFamily: preview.l ? (preview.l.font || "") : ""
            }

            Row {
              visible: !preview.broken && !!preview.l && (preview.l.fn || []).length > 0
              width: parent.width
              spacing: Style.space(8)

              Text {
                id: fnLabel
                text: "FN"
                anchors.verticalCenter: parent.verticalCenter
                color: root.bar.foreground
                opacity: 0.5
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
              }
              Strip {
                width: parent.width - fnLabel.width - parent.spacing
                opacity: 0.75
                buttons: preview.l ? (preview.l.fn || []) : []
                outlines: !!preview.l && preview.l.outlines === true
                fontFamily: preview.l ? (preview.l.font || "") : ""
              }
            }

          }

          Text {
            visible: root.layouts.length === 0 && !listProc.running
            text: "No layouts found. Add layout files to " + (root.layoutsDir || "~/.config/omarchy/omabar/layouts")
            color: root.bar.foreground
            opacity: 0.6
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            width: parent.width
            wrapMode: Text.Wrap
          }

          // ---------- Status ----------
          Text {
            visible: root.error !== ""
            text: root.error
            color: Color.urgent
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            width: parent.width
            wrapMode: Text.Wrap
          }

          // ---------- Passwordless switching ----------
          PanelSeparator { foreground: root.bar.foreground }

          Item {
            width: parent.width
            implicitHeight: Math.max(helperLabels.implicitHeight, helperAction.implicitHeight)

            Column {
              id: helperLabels
              anchors.left: parent.left
              anchors.right: helperAction.visible ? helperAction.left : parent.right
              anchors.rightMargin: helperAction.visible ? Style.space(12) : 0
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: (root.helperState === "live" ? "● " : "○ ")
                      + (root.helperState === "missing" ? "Setup needed" : "Passwordless switching is on")
                // Only "on" takes the accent; some themes' urgent colour is green too.
                color: root.helperState === "live" ? Color.accent : root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
              }
              Text {
                text: root.helperState === "live"
                      ? "A small helper at " + root.helperPath + " lets this panel, app following, weather and theme updates change the Touch Bar without asking for your password, and the bar updates in place without a blink. It only accepts configs and icons made by Omabar."
                      : "Omabar needs a one-time setup before it can change the Touch Bar: it installs tiny-dfr if needed, a small helper so switching needs no password, and a fix that brings the Touch Bar back after sleep. Set up asks for your password once. (Or in a terminal: sudo " + root.installScript.replace(/^\/home\/[^/]+/, "~") + ")"
                color: root.bar.foreground
                opacity: 0.6
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                width: parent.width
                wrapMode: Text.Wrap
              }
            }

            Button {
              id: helperAction
              visible: root.helperState !== "live"
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: setupProc.running ? "Setting up…" : "Set up"
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              onClicked: root.runSetup()
            }
          }
        }
      }
    }
  }

  // A to-scale tiny-dfr strip: black glass, buttons sized by stretch, icons
  // drawn from their real SVG files, text in the layout's font. tiny-dfr
  // always draws text white and outlines as dark grey rounded keys.
  component Strip: Rectangle {
    id: strip
    property var buttons: []
    property bool outlines: true
    property string fontFamily: ""
    readonly property real totalStretch: {
      var t = 0
      for (var i = 0; i < buttons.length; i++) t += buttons[i].stretch || 1
      return Math.max(1, t)
    }
    readonly property real pad: height * 0.06
    readonly property real gap: width * 0.008

    height: Math.round(width / root.stripRatio)
    radius: height * 0.12
    color: "#000000"
    border.width: 1
    border.color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.12)

    Row {
      id: keys
      x: strip.pad
      y: strip.pad
      width: strip.width - strip.pad * 2
      height: strip.height - strip.pad * 2
      spacing: strip.gap
      readonly property real unit: (width - spacing * Math.max(0, strip.buttons.length - 1)) / strip.totalStretch

      Repeater {
        model: strip.buttons

        Rectangle {
          id: key
          required property var modelData
          width: keys.unit * (modelData.stretch || 1)
          height: keys.height
          radius: height * 0.14
          color: strip.outlines && (modelData.kind === "icon" || modelData.kind === "text") ? "#333333" : "transparent"

          Image {
            visible: key.modelData.kind === "icon" && key.modelData.path !== ""
            anchors.centerIn: parent
            width: Math.min(parent.width, parent.height * 0.8)
            height: width
            source: visible ? "file://" + key.modelData.path : ""
            sourceSize.width: Math.ceil(width * 2)
            sourceSize.height: Math.ceil(height * 2)
            fillMode: Image.PreserveAspectFit
            smooth: true
          }

          Text {
            visible: key.modelData.kind === "icon" && key.modelData.path === ""
            anchors.centerIn: parent
            text: "?"
            color: Color.urgent
            font.pixelSize: parent.height * 0.5
            font.bold: true
          }

          Row {
            anchors.centerIn: parent
            spacing: parent.height * 0.08
            readonly property bool isBattery: key.modelData.kind === "battery"
            visible: key.modelData.kind === "text" || key.modelData.kind === "time" || isBattery

            // Horizontal battery glyph, drawn rather than loaded: Qt's SVG
            // renderer drops the root-level fill on tiny-dfr's battery icons.
            Item {
              visible: parent.isBattery && key.modelData.mode !== "percentage"
              anchors.verticalCenter: parent.verticalCenter
              width: key.height * 0.75
              height: width * 0.45

              Rectangle {
                id: shell
                width: parent.width - nub.width
                height: parent.height
                radius: height * 0.2
                color: "transparent"
                border.width: Math.max(1, height * 0.12)
                border.color: root.batteryColor()

                Rectangle {
                  x: shell.border.width * 2
                  y: shell.border.width * 2
                  height: parent.height - y * 2
                  width: Math.max(0, (parent.width - x * 2) * root.batteryFraction())
                  radius: height * 0.15
                  color: root.batteryColor()
                }
              }
              Rectangle {
                id: nub
                anchors.left: shell.right
                anchors.verticalCenter: shell.verticalCenter
                width: parent.width * 0.07
                height: parent.height * 0.4
                color: root.batteryColor()
              }
            }

            Text {
              visible: !parent.isBattery || key.modelData.mode !== "icon"
              anchors.verticalCenter: parent.verticalCenter
              width: Math.min(implicitWidth, key.width)
              elide: Text.ElideRight
              text: key.modelData.kind === "time" ? root.strftime(key.modelData.format, root.now)
                  : parent.isBattery ? root.batteryText()
                  : (key.modelData.text || "")
              color: parent.isBattery ? root.batteryColor() : "#ffffff"
              font.family: strip.fontFamily
              font.bold: true
              font.pixelSize: key.height * 0.5
            }
          }
        }
      }
    }
  }
}
