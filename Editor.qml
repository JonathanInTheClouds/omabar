import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Omabar's layout editor: a centred overlay summoned from the bar popup
// ("Edit…") or with `omarchy-shell shell summon io.github.jonathanintheclouds.omabar
// '{"layout":"dev"}'`. It edits a copy of a layout (built-ins are saved as your
// own layout with the same id), can put the draft on the real Touch Bar for 20
// seconds, and edits the follow-the-app rules. All reads and writes go through
// bin/omabar (editor-data, save, delete, try, restore, save-rules).
Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool opened: false

  readonly property string pluginId: (manifest && manifest.id) || "io.github.jonathanintheclouds.omabar"
  readonly property string tool: decodeURIComponent(
    Qt.resolvedUrl("bin/omabar").toString().replace(/^file:\/\//, ""))
  readonly property real barRatio: 2008 / 60
  readonly property int chipGap: 6
  property real laneWidth: 1000
  // Buttons shrink so a whole row (and the + tile) always fits the lane.
  readonly property real chipUnit: {
    var units = 0, n = buttons.length
    for (var i = 0; i < n; i++) units += stretchOf(buttons[i])
    var room = laneWidth - 56 - chipGap * (n + 1)
    return Math.max(26, Math.min(56, units ? room / units : 56))
  }

  // ---------- state ----------
  property var ed: null                // omabar editor-data
  property var iconMap: ({})
  property string tab: "layout"        // "layout" | "rules"
  property string currentId: ""
  property var draft: null             // the layout being edited
  property bool dirty: false
  property string row: "buttons"       // "buttons" (main row) | "fnLayer"
  property int sel: -1                 // selected button index in `row`
  property bool trying: false
  property int tryLeft: 0
  property string status: ""
  property string error: ""
  property var rulesDraft: null
  property bool rulesDirty: false
  property string confirm: ""          // "" | "close" | "switch"
  property string pendingId: ""
  property bool iconPicker: false
  property string iconFilter: ""
  property bool namingNew: false
  property var pendingPayload: ({})

  onIconPickerChanged: if (iconPicker) Qt.callLater(function () { iconSearch.text = ""; iconSearch.forceActiveFocus() })

  readonly property var current: entryFor(currentId)
  readonly property var buttons: draft ? (draft[row] || []) : []
  readonly property var selected: sel >= 0 && sel < buttons.length ? buttons[sel] : null
  readonly property var pal: ed ? ed.palette : ({})

  // ---------- lifecycle ----------
  function open(payloadJson) {
    var p = {}
    try { p = payloadJson ? JSON.parse(payloadJson) : {} } catch (e) { p = {} }
    pendingPayload = p
    tab = p.tab === "rules" ? "rules" : "layout"
    confirm = ""
    error = ""
    status = ""
    opened = true
    load()
  }

  // Host-initiated close (`shell hide`): never prompts.
  function close() {
    if (trying) restore()
    opened = false
    confirm = ""
    iconPicker = false
    namingNew = false
  }

  function dismiss() {
    if (dirty || rulesDirty) { confirm = "close"; return }
    requestHide()
  }

  function requestHide() {
    if (shell && typeof shell.hide === "function") shell.hide(pluginId)
    else close()
  }

  function load() {
    if (!dataProc.running) dataProc.running = true
  }

  // ---------- helpers ----------
  function clone(o) { return JSON.parse(JSON.stringify(o)) }
  function same(a, b) { return JSON.stringify(a) === JSON.stringify(b) }

  function entryFor(id) {
    if (!ed) return null
    for (var i = 0; i < ed.layouts.length; i++) if (ed.layouts[i].id === id) return ed.layouts[i]
    return null
  }

  function layoutOptions() {
    if (!ed) return []
    return ed.layouts.map(function (e) {
      var name = e.layout && e.layout.name ? e.layout.name : e.id
      return { value: e.id, label: name + (e.source === "yours" ? "  (yours)" : "") }
    })
  }

  function selectLayout(id) {
    if (id === currentId) return
    if (dirty) { pendingId = id; confirm = "switch"; return }
    doSelect(id)
  }

  function doSelect(id) {
    var e = entryFor(id)
    currentId = id
    draft = e && e.layout ? clone(e.layout) : null
    dirty = false
    row = "buttons"
    sel = draft && (draft.buttons || []).length ? 0 : -1
    error = e && e.error ? e.error : ""
    iconPicker = false
  }

  function commit(d) { draft = d; dirty = true; status = "" }
  function mutate(fn) { var d = clone(draft); fn(d); commit(d) }

  function setField(key, value) {
    mutate(function (d) {
      if (value === "" || value === null || value === undefined) delete d[key]
      else d[key] = value
    })
  }

  function setProp(key, value) {
    if (!selected) return
    mutate(function (d) {
      var b = d[row][sel]
      if (value === "" || value === null || value === undefined) delete b[key]
      else b[key] = value
    })
  }

  function stretchOf(b) { return Math.max(1, (b && b.stretch) || 1) }

  function kindOf(b) {
    if (!b) return ""
    if (b.spacer) return "spacer"
    if (b.time) return /%[HIlMp]|hr$/.test(b.time) ? "clock" : "date"
    if (b.battery) return "battery"
    if (b.weather) return b.weather === "icon" ? "wxicon" : "wxtemp"
    if (b.icon) return "icon"
    return "text"
  }

  function hasAction(kind) { return kind === "icon" || kind === "text" }

  function setKind(k) {
    if (!selected || kindOf(selected) === k) return
    mutate(function (d) {
      var o = d[row][sel], n
      if (k === "icon") n = { icon: o.icon || "apps", tint: o.tint || "accent" }
      else if (k === "text") n = { text: o.text || "Label" }
      else if (k === "spacer") n = { spacer: true }
      else if (k === "clock") n = { time: "%-I:%M %p", stretch: 2 }
      else if (k === "date") n = { time: "%a %b %-d", stretch: 3 }
      else if (k === "battery") n = { battery: "both", stretch: 2 }
      else if (k === "wxicon") n = { weather: "icon" }
      else n = { weather: "temp" }
      if (hasAction(k)) {
        if (o.command) n.command = o.command
        else n.key = o.key || "Search"
      }
      if (o.stretch && !n.stretch) n.stretch = o.stretch
      d[row][sel] = n
    })
  }

  // ---------- actions (what a button does) ----------
  function presetFor(key) {
    if (!ed || key === undefined) return null
    for (var i = 0; i < ed.keys.length; i++) if (same(ed.keys[i].key, key)) return ed.keys[i]
    return null
  }

  function shortcutFor(key) {
    if (!ed || key === undefined) return null
    for (var i = 0; i < ed.shortcuts.length; i++) if (same(ed.shortcuts[i].key, key)) return ed.shortcuts[i]
    return null
  }

  function appFor(cmd) {
    var m = /^uwsm-app -- ([A-Za-z0-9._+-]+\.desktop)$/.exec(cmd || "")
    if (!m || !ed) return null
    for (var i = 0; i < ed.apps.length; i++) if (ed.apps[i].id === m[1]) return ed.apps[i]
    return { id: m[1], name: m[1].replace(/\.desktop$/, ""), command: cmd }
  }

  function actionKind(b) {
    if (!b) return "key"
    if (b.command) return appFor(b.command) ? "app" : "command"
    if (shortcutFor(b.key)) return "shortcut"
    return "key"
  }

  function keyText(key) {
    if (key === undefined || key === null) return "nothing yet"
    return Array.isArray(key) ? key.join(" + ") : String(key)
  }

  function actionSummary(b) {
    if (!b) return ""
    var k = actionKind(b)
    if (k === "app") return "Opens " + appFor(b.command).name
    if (k === "command") return "Runs: " + b.command
    if (k === "shortcut") { var s = shortcutFor(b.key); return "Sends " + s.combo + " (" + s.label + ")" }
    var p = presetFor(b.key)
    return p ? "Sends " + p.label : "Sends " + keyText(b.key)
  }

  function setKeyAction(key) {
    mutate(function (d) {
      var b = d[row][sel]
      b.key = key
      delete b.command
      delete b.hyprKey
    })
  }

  // The backend picks a free spare key and writes the Hyprland bind on save.
  function setCommand(cmd) {
    mutate(function (d) {
      var b = d[row][sel]
      b.command = cmd
      delete b.key
      delete b.hyprKey
    })
  }

  // ---------- button list ----------
  function addButton() {
    if (!draft) return
    mutate(function (d) {
      if (!d[row]) d[row] = []
      var at = sel >= 0 ? sel + 1 : d[row].length
      d[row].splice(at, 0, { icon: "apps", tint: "accent", key: "Search" })
      sel = at
    })
  }

  function removeButton() {
    if (!selected) return
    var at = sel
    mutate(function (d) { d[row].splice(at, 1) })
    sel = Math.min(at, buttons.length - 1)
  }

  function moveButton(from, to) {
    if (from === to || from < 0) return
    mutate(function (d) {
      var b = d[row].splice(from, 1)[0]
      d[row].splice(Math.max(0, Math.min(to, d[row].length)), 0, b)
    })
    sel = Math.max(0, Math.min(to, buttons.length - 1))
  }

  function matchingIcons() {
    if (!ed) return []
    var q = iconFilter.toLowerCase().replace(/ /g, "_")
    return ed.icons.filter(function (i) { return i.name.indexOf(q) !== -1 })
  }

  function chipWidth(i) { return chipUnit * stretchOf(buttons[i]) + chipGap * (stretchOf(buttons[i]) - 1) }

  function chipX(i) {
    var x = 0
    for (var j = 0; j < i; j++) x += chipWidth(j) + chipGap
    return x
  }

  function dropIndex(centerX, from) {
    for (var i = 0; i < buttons.length; i++) {
      if (centerX < chipX(i) + chipWidth(i) / 2) return i > from ? i - 1 : i
    }
    return buttons.length - 1
  }

  // ---------- backend calls ----------
  function runWithStdin(proc, command, payload) {
    if (proc.running) return
    error = ""
    proc.payload = payload
    proc.stdinEnabled = true
    proc.command = command
    proc.running = true
  }

  function slug(name) {
    var s = String(name || "").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 40)
    if (!s) s = "my-layout"
    var base = s, n = 2
    while (entryFor(s)) s = base + "-" + (n++)
    return s
  }

  function save(asNewName) {
    if (!draft) return
    var d = clone(draft), id = currentId
    if (asNewName !== undefined) { d.name = asNewName; id = slug(asNewName) }
    saveProc.targetId = id
    runWithStdin(saveProc, [tool, "save", id], JSON.stringify(d))
  }

  function tryOnBar() {
    if (!draft) return
    runWithStdin(tryProc, [tool, "try"], JSON.stringify(draft))
  }

  function restore() {
    trialTimer.stop()
    trying = false
    if (!restoreProc.running) restoreProc.running = true
  }

  function saveRules() {
    if (!rulesDraft) return
    runWithStdin(rulesProc, [tool, "save-rules"], JSON.stringify({
      rules: rulesDraft.rules, default: rulesDraft.default, shortcut: rulesDraft.shortcut
    }))
  }

  function runSimple(args) {
    if (flagProc.running) return
    flagProc.command = [tool].concat(args)
    flagProc.running = true
  }

  // ---------- processes ----------
  Process {
    id: dataProc
    command: [root.tool, "editor-data"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var d = JSON.parse(text)
          var map = {}
          for (var i = 0; i < d.icons.length; i++) map[d.icons[i].name] = d.icons[i]
          root.iconMap = map
          root.ed = d
          var r = d.rules || {}
          if (root.rulesDraft) {
            // Switches save immediately, so they always follow the file.
            var keep = root.clone(root.rulesDraft)
            keep.follow = r.follow === true
            keep.emptyDefault = r.emptyDefault !== false
            root.rulesDraft = keep
          }
          if (!root.rulesDirty) {
            root.rulesDraft = { rules: root.clone(r.rules || []), default: r.default || "",
                                shortcut: r.shortcut === undefined || r.shortcut === null ? d.shortcutDefault : r.shortcut,
                                follow: r.follow === true, emptyDefault: r.emptyDefault !== false }
          }
          var p = root.pendingPayload
          var want = p.layout || root.currentId
          root.pendingPayload = ({})
          if (!root.entryFor(want)) want = d.layouts.length ? d.layouts[0].id : ""
          if (!root.dirty || want !== root.currentId) root.doSelect(want)
          // Deep link: {"row": "fnLayer", "select": 3, "picker": "icon"}
          if (p.row === "fnLayer" || p.row === "buttons") root.row = p.row
          if (typeof p.select === "number" && p.select >= 0 && p.select < root.buttons.length) root.sel = p.select
          if (p.picker === "icon" && root.kindOf(root.selected) === "icon") { root.iconFilter = ""; root.iconPicker = true }
        } catch (e) {
          root.error = "Couldn't load the editor data: " + e
        }
      }
    }
    stderr: StdioCollector { id: dataErr; waitForEnd: true }
    onExited: function (code) { if (code !== 0) root.error = String(dataErr.text || "").trim() || "Couldn't load the editor data" }
  }

  component StdinProcess: Process {
    property string payload: ""
    stdinEnabled: true
    onStarted: { write(payload); stdinEnabled = false }
  }

  StdinProcess {
    id: saveProc
    property string targetId: ""
    stderr: StdioCollector { id: saveErr; waitForEnd: true }
    onExited: function (code) {
      if (code !== 0) { root.error = String(saveErr.text || "").trim() || "Saving failed"; return }
      root.dirty = false
      root.namingNew = false
      root.status = "Saved"
      root.pendingPayload = { layout: saveProc.targetId }
      root.currentId = ""
      root.load()
    }
  }

  StdinProcess {
    id: tryProc
    stderr: StdioCollector { id: tryErr; waitForEnd: true }
    onExited: function (code) {
      if (code !== 0) { root.error = String(tryErr.text || "").trim() || "Couldn't put the draft on the bar"; return }
      root.trying = true
      root.tryLeft = 20
      trialTimer.restart()
    }
  }

  Process {
    id: restoreProc
    command: [root.tool, "restore"]
  }

  StdinProcess {
    id: rulesProc
    stderr: StdioCollector { id: rulesErr; waitForEnd: true }
    onExited: function (code) {
      if (code !== 0) { root.error = String(rulesErr.text || "").trim() || "Saving the rules failed"; return }
      root.rulesDirty = false
      root.status = "Rules saved"
      root.load()
    }
  }

  Process {
    id: deleteProc
    stderr: StdioCollector { id: deleteErr; waitForEnd: true }
    onExited: function (code) {
      if (code !== 0) { root.error = String(deleteErr.text || "").trim() || "Deleting failed"; return }
      root.dirty = false
      root.status = "Deleted"
      root.currentId = ""
      root.load()
    }
  }

  Process {
    id: flagProc
    onExited: root.load()
  }

  Timer {
    id: trialTimer
    interval: 1000
    repeat: true
    onTriggered: {
      root.tryLeft -= 1
      if (root.tryLeft <= 0) root.restore()
    }
  }

  // ---------- window ----------
  PanelWindow {
    id: win
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "omabar-editor"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

    onVisibleChanged: if (visible) Qt.callLater(function () { keys.forceActiveFocus() })

    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(0, 0, 0, 0.6)
      MouseArea { anchors.fill: parent; onClicked: root.dismiss() }
    }

    Item {
      id: keys
      anchors.fill: parent
      focus: true
      Keys.onEscapePressed: {
        if (root.iconPicker) root.iconPicker = false
        else if (root.confirm !== "") root.confirm = ""
        else root.dismiss()
      }
      Keys.onDeletePressed: if (root.tab === "layout" && !root.iconPicker) root.removeButton()
      // Ctrl+S saves (layout or rules), Ctrl+T tries the draft on the Touch Bar.
      Keys.onPressed: function (event) {
        if (!(event.modifiers & Qt.ControlModifier)) return
        if (event.key === Qt.Key_S) {
          if (root.tab === "rules") { if (root.rulesDirty) root.saveRules() }
          else if (root.dirty) root.save()
          event.accepted = true
        } else if (event.key === Qt.Key_T && root.tab === "layout") {
          if (root.trying) root.restore(); else root.tryOnBar()
          event.accepted = true
        }
      }
      Keys.onLeftPressed: if (root.tab === "layout" && root.sel > 0) root.sel -= 1
      Keys.onRightPressed: if (root.tab === "layout" && root.sel < root.buttons.length - 1) root.sel += 1

      Rectangle {
        id: card
        width: Style.space(1180)
        height: Style.space(800)
        anchors.centerIn: parent
        scale: Math.min(1, (parent.width - Style.space(40)) / width, (parent.height - Style.space(40)) / height)
        color: Color.popups.background
        border.color: Color.popups.border
        border.width: Math.max(1, Style.space(2))
        radius: Style.cornerRadius

        MouseArea { anchors.fill: parent; onClicked: keys.forceActiveFocus() }

        ColumnLayout {
          anchors.fill: parent
          anchors.margins: Style.space(22)
          spacing: Style.space(14)

          // ---------- header ----------
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(14)

            Text {
              textFormat: Text.PlainText
              text: "󰌌"
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.display
            }
            Column {
              Layout.fillWidth: true
              Text {
                textFormat: Text.PlainText
                text: "Omabar editor"
                color: Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.title
                font.bold: true
              }
              Text {
                textFormat: Text.PlainText
                text: root.tab === "layout"
                      ? "Change a layout, try it on the Touch Bar, save it as yours."
                      : "Choose which layout each app gets when Omabar follows the focused app."
                color: Qt.darker(Color.popups.text, 1.4)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
            ButtonGroup {
              options: [{ value: "layout", label: "Layouts" }, { value: "rules", label: "Rules" }]
              value: root.tab
              fontFamily: Style.font.family
              onChanged: function (v) { root.tab = v; root.iconPicker = false }
            }
            Button {
              text: "Close"
              bordered: true
              fontFamily: Style.font.family
              fontSize: Style.font.bodySmall
              onClicked: root.dismiss()
            }
          }

          PanelSeparator { Layout.fillWidth: true; foreground: Color.popups.text }

          // ---------- confirm bar ----------
          Rectangle {
            visible: root.confirm !== ""
            Layout.fillWidth: true
            implicitHeight: confirmRow.implicitHeight + Style.space(16)
            radius: Style.cornerRadius
            color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.12)
            border.color: Color.accent
            border.width: 1

            RowLayout {
              id: confirmRow
              anchors.fill: parent
              anchors.margins: Style.space(8)
              spacing: Style.space(10)
              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: root.confirm === "close" ? "You have unsaved changes. Close without saving?"
                                               : "You have unsaved changes to this layout. Switch and discard them?"
                color: Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.Wrap
              }
              Button {
                text: "Discard"
                bordered: true
                fontFamily: Style.font.family
                fontSize: Style.font.bodySmall
                onClicked: {
                  var what = root.confirm
                  root.confirm = ""
                  if (what === "close") { root.dirty = false; root.rulesDirty = false; root.requestHide() }
                  else root.doSelect(root.pendingId)
                }
              }
              Button {
                text: "Keep editing"
                bordered: true
                fontFamily: Style.font.family
                fontSize: Style.font.bodySmall
                onClicked: root.confirm = ""
              }
            }
          }

          // ================= LAYOUT TAB =================
          ColumnLayout {
            visible: root.tab === "layout"
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Style.space(12)

            // layout picker + layout actions
            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(10)

              BoundDropdown {
                Layout.preferredWidth: Style.space(320)
                showLabel: false
                options: root.layoutOptions()
                current: root.currentId
                fontFamily: Style.font.family
                onPicked: function (v) { root.selectLayout(v) }
              }
              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: !root.current ? ""
                      : root.current.source === "yours"
                        ? (root.current.builtin ? "Your version of a built-in layout." : "One of your layouts.")
                        : "Built-in. Saving keeps a copy as yours; the original stays available."
                color: Qt.darker(Color.popups.text, 1.4)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
              Button {
                text: "New copy…"
                bordered: true
                fontFamily: Style.font.family
                fontSize: Style.font.bodySmall
                onClicked: { root.namingNew = true; newName.text = (root.draft && root.draft.name ? root.draft.name : "Layout") + " copy"; newName.forceActiveFocus(); newName.selectAll() }
              }
              Button {
                visible: !!root.current && root.current.source === "yours"
                text: root.current && root.current.builtin ? "Reset to built-in" : "Delete"
                bordered: true
                fontFamily: Style.font.family
                fontSize: Style.font.bodySmall
                onClicked: {
                  if (deleteProc.running) return
                  deleteProc.command = [root.tool, "delete", root.currentId]
                  root.pendingPayload = { layout: root.current.builtin ? root.currentId : "" }
                  deleteProc.running = true
                }
              }
            }

            // new-copy name row
            RowLayout {
              visible: root.namingNew
              Layout.fillWidth: true
              spacing: Style.space(10)
              Text {
                textFormat: Text.PlainText
                text: "Name for the copy:"
                color: Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
              TextField {
                id: newName
                Layout.preferredWidth: Style.space(320)
                font.family: Style.font.family
                onAccepted: if (text.trim() !== "") root.save(text.trim())
              }
              Button {
                text: "Save copy"
                bordered: true
                fontFamily: Style.font.family
                fontSize: Style.font.bodySmall
                onClicked: if (newName.text.trim() !== "") root.save(newName.text.trim())
              }
              Button {
                text: "Cancel"
                bordered: true
                fontFamily: Style.font.family
                fontSize: Style.font.bodySmall
                onClicked: root.namingNew = false
              }
              Item { Layout.fillWidth: true }
            }

            // name / description / outlines
            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(10)
              enabled: !!root.draft
              TextField {
                Layout.preferredWidth: Style.space(240)
                placeholderText: "Name"
                text: root.draft && root.draft.name ? root.draft.name : ""
                font.family: Style.font.family
                onTextEdited: root.setField("name", text)
                onTextChanged: if (!activeFocus) cursorPosition = 0
              }
              TextField {
                Layout.fillWidth: true
                placeholderText: "Description"
                text: root.draft && root.draft.description ? root.draft.description : ""
                font.family: Style.font.family
                onTextEdited: root.setField("description", text)
                onTextChanged: if (!activeFocus) cursorPosition = 0
              }
              Text {
                textFormat: Text.PlainText
                text: "Grey keys"
                color: Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
              ToggleSwitch {
                checked: !!root.draft && root.draft.showButtonOutlines === true
                onToggled: root.setField("showButtonOutlines", !(root.draft.showButtonOutlines === true))
              }
            }

            // to-scale preview of both rows
            Column {
              Layout.fillWidth: true
              spacing: Style.space(6)
              Strip {
                width: parent.width
                items: root.draft ? (root.draft.buttons || []) : []
                outlines: !!root.draft && root.draft.showButtonOutlines === true
                highlight: root.row === "buttons" ? root.sel : -1
              }
              Strip {
                width: parent.width
                opacity: 0.75
                items: root.draft ? (root.draft.fnLayer || []) : []
                outlines: !!root.draft && root.draft.showButtonOutlines === true
                highlight: root.row === "fnLayer" ? root.sel : -1
              }
            }

            // row switcher
            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(10)
              ButtonGroup {
                options: [{ value: "buttons", label: "Main row" }, { value: "fnLayer", label: "Fn row (hold Fn)" }]
                value: root.row
                fontFamily: Style.font.family
                onChanged: function (v) { root.row = v; root.sel = root.buttons.length ? 0 : -1; root.iconPicker = false }
              }
              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: root.buttons.length + " buttons. Drag to reorder, click to edit."
                      + (root.buttons.length > 24 ? "  Over 24 buttons may not draw properly." : "")
                color: root.buttons.length > 24 ? Color.urgent : Qt.darker(Color.popups.text, 1.4)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }

            // ---------- chip lane: the editable button list ----------
            Flickable {
              id: lane
              Layout.fillWidth: true
              onWidthChanged: root.laneWidth = width
              Layout.preferredHeight: 56 + Style.space(12)
              contentWidth: Math.max(width, laneContent.width + root.chipUnit + root.chipGap * 2)
              contentHeight: height
              clip: true
              interactive: !ghost.visible
              boundsBehavior: Flickable.StopAtBounds

              Item {
                id: laneContent
                y: Style.space(6) + (56 - root.chipUnit) / 2
                width: root.buttons.length ? root.chipX(root.buttons.length - 1) + root.chipWidth(root.buttons.length - 1) : 0
                height: root.chipUnit

                Repeater {
                  model: root.buttons.length

                  Rectangle {
                    id: chip
                    required property int index
                    readonly property var b: root.buttons[index]
                    x: root.chipX(index)
                    width: root.chipWidth(index)
                    height: root.chipUnit
                    radius: Style.space(6)
                    color: root.kindOf(b) === "spacer" ? "transparent" : "#111214"
                    border.width: index === root.sel ? 2 : 1
                    border.color: index === root.sel ? Color.accent : Qt.rgba(1, 1, 1, 0.18)
                    opacity: dragArea.drag.active ? 0.35 : 1

                    ButtonFace {
                      anchors.fill: parent
                      anchors.margins: Style.space(6)
                      b: chip.b
                      large: true
                    }

                    MouseArea {
                      id: dragArea
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      drag.target: ghost
                      drag.axis: Drag.XAxis
                      drag.threshold: 6
                      preventStealing: true
                      onPressed: {
                        root.sel = chip.index
                        ghost.from = chip.index
                        ghost.width = chip.width
                        ghost.x = chip.x
                        keys.forceActiveFocus()
                      }
                      onReleased: {
                        if (ghost.visible) root.moveButton(ghost.from, root.dropIndex(ghost.x + ghost.width / 2, ghost.from))
                        ghost.from = -1
                      }
                    }
                  }
                }

                // add button
                Rectangle {
                  x: laneContent.width + (root.buttons.length ? root.chipGap : 0)
                  width: Math.max(root.chipUnit, 40)
                  height: root.chipUnit
                  radius: Style.space(6)
                  color: "transparent"
                  border.width: 1
                  border.color: Qt.rgba(1, 1, 1, 0.3)
                  Text {
                    textFormat: Text.PlainText
                    anchors.centerIn: parent
                    text: "+"
                    color: Color.popups.text
                    font.pixelSize: Style.font.title
                  }
                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.addButton()
                  }
                }

                // drag ghost
                Rectangle {
                  id: ghost
                  property int from: -1
                  visible: from >= 0 && Math.abs(x - root.chipX(from)) > 2
                  height: root.chipUnit
                  radius: Style.space(6)
                  color: "#1b1c20"
                  border.width: 2
                  border.color: Color.accent
                  z: 10
                  ButtonFace {
                    anchors.fill: parent
                    anchors.margins: Style.space(6)
                    b: ghost.from >= 0 ? root.buttons[ghost.from] : null
                    large: true
                  }
                }
              }
            }

            // ---------- properties of the selected button ----------
            Rectangle {
              Layout.fillWidth: true
              Layout.fillHeight: true
              radius: Style.cornerRadius
              color: Qt.rgba(1, 1, 1, 0.03)
              border.width: 1
              border.color: Qt.rgba(1, 1, 1, 0.08)

              Text {
                textFormat: Text.PlainText
                visible: !root.selected && !!root.draft
                anchors.centerIn: parent
                text: root.buttons.length ? "Select a button to edit it." : "This row is empty. Press + to add a button."
                color: Qt.darker(Color.popups.text, 1.4)
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }

              GridLayout {
                visible: !!root.selected && !root.iconPicker
                anchors.fill: parent
                anchors.margins: Style.space(14)
                columns: 2
                columnSpacing: Style.space(14)
                rowSpacing: Style.space(10)

                Label { text: "Type" }
                RowLayout {
                  spacing: Style.space(10)
                  BoundDropdown {
                    Layout.preferredWidth: Style.space(220)
                    showLabel: false
                    fontFamily: Style.font.family
                    options: [
                      { value: "icon", label: "Icon" }, { value: "text", label: "Text" },
                      { value: "clock", label: "Clock" }, { value: "date", label: "Date" },
                      { value: "battery", label: "Battery" }, { value: "wxicon", label: "Weather icon" },
                      { value: "wxtemp", label: "Temperature" }, { value: "spacer", label: "Gap" }
                    ]
                    current: root.kindOf(root.selected)
                    onPicked: function (v) { root.setKind(v) }
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: "Width"
                    color: Color.popups.text
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                  }
                  NumberField {
                    from: 1
                    to: 6
                    value: root.stretchOf(root.selected)
                    fontFamily: Style.font.family
                    fieldWidth: Style.space(90)
                    onModified: function (v) { root.setProp("stretch", v > 1 ? v : null) }
                  }
                  Item { Layout.fillWidth: true }
                  Button {
                    text: "◀"
                    bordered: true
                    fontFamily: Style.font.family
                    enabled: root.sel > 0
                    onClicked: root.moveButton(root.sel, root.sel - 1)
                  }
                  Button {
                    text: "▶"
                    bordered: true
                    fontFamily: Style.font.family
                    enabled: root.sel < root.buttons.length - 1
                    onClicked: root.moveButton(root.sel, root.sel + 1)
                  }
                  Button {
                    text: "Remove"
                    bordered: true
                    fontFamily: Style.font.family
                    fontSize: Style.font.bodySmall
                    onClicked: root.removeButton()
                  }
                }

                // icon + tint
                Label { text: "Icon"; visible: root.kindOf(root.selected) === "icon" }
                RowLayout {
                  visible: root.kindOf(root.selected) === "icon"
                  spacing: Style.space(10)
                  Rectangle {
                    width: Style.space(44)
                    height: Style.space(44)
                    radius: Style.space(6)
                    color: "#000000"
                    border.width: 1
                    border.color: Qt.rgba(1, 1, 1, 0.2)
                    Glyph {
                      anchors.fill: parent
                      anchors.margins: Style.space(6)
                      icon: root.selected ? root.iconMap[root.selected.icon] : null
                      tint: root.selected ? (root.pal[root.selected.tint || "white"] || "white") : "white"
                    }
                  }
                  Button {
                    text: "Choose icon…"
                    bordered: true
                    fontFamily: Style.font.family
                    fontSize: Style.font.bodySmall
                    onClicked: { root.iconFilter = ""; root.iconPicker = true }
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: "Colour"
                    color: Color.popups.text
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                  }
                  Repeater {
                    model: root.ed ? root.ed.roles : []
                    Rectangle {
                      required property string modelData
                      width: Style.space(28)
                      height: Style.space(28)
                      radius: width / 2
                      color: root.pal[modelData] || "white"
                      border.width: root.selected && (root.selected.tint || "white") === modelData ? 3 : 1
                      border.color: root.selected && (root.selected.tint || "white") === modelData ? Color.accent : Qt.rgba(1, 1, 1, 0.3)
                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.setProp("tint", modelData)
                      }
                    }
                  }
                  Item { Layout.fillWidth: true }
                }

                // text
                Label { text: "Label"; visible: root.kindOf(root.selected) === "text" }
                RowLayout {
                  visible: root.kindOf(root.selected) === "text"
                  spacing: Style.space(10)
                  TextField {
                    Layout.preferredWidth: Style.space(260)
                    text: root.selected && root.selected.text ? root.selected.text : ""
                    font.family: Style.font.family
                    onTextEdited: root.setProp("text", text)
                    onTextChanged: if (!activeFocus) cursorPosition = 0
                  }
                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: "Always white on the Touch Bar. Nerd Font glyphs work."
                    color: Qt.darker(Color.popups.text, 1.4)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                }

                // clock/date format
                Label { text: "Format"; visible: root.kindOf(root.selected) === "clock" || root.kindOf(root.selected) === "date" }
                BoundDropdown {
                  visible: root.kindOf(root.selected) === "clock" || root.kindOf(root.selected) === "date"
                  Layout.preferredWidth: Style.space(320)
                  showLabel: false
                  fontFamily: Style.font.family
                  options: [
                    { value: "%-I:%M %p", label: "12-hour (3:28 PM)" }, { value: "%H:%M", label: "24-hour (15:28)" },
                    { value: "%a %b %-d", label: "Date (Sun Oct 4)" }, { value: "%-d %b", label: "Date (4 Oct)" },
                    { value: "%a %-I:%M %p", label: "Day and time (Sun 3:28 PM)" }
                  ]
                  current: root.selected && root.selected.time ? root.selected.time : ""
                  onPicked: function (v) { root.setProp("time", v) }
                }

                // battery mode
                Label { text: "Shows"; visible: root.kindOf(root.selected) === "battery" }
                BoundDropdown {
                  visible: root.kindOf(root.selected) === "battery"
                  Layout.preferredWidth: Style.space(320)
                  showLabel: false
                  fontFamily: Style.font.family
                  options: [{ value: "both", label: "Icon and percentage" }, { value: "icon", label: "Icon" },
                            { value: "percentage", label: "Percentage" }]
                  current: root.selected && root.selected.battery ? root.selected.battery : ""
                  onPicked: function (v) { root.setProp("battery", v) }
                }

                // action
                Label { text: "Does"; visible: root.hasAction(root.kindOf(root.selected)) }
                ColumnLayout {
                  visible: root.hasAction(root.kindOf(root.selected))
                  spacing: Style.space(8)
                  RowLayout {
                    spacing: Style.space(10)
                    ButtonGroup {
                      id: actionTabs
                      options: [{ value: "key", label: "Key" }, { value: "shortcut", label: "Omarchy shortcut" },
                                { value: "app", label: "Open app" }, { value: "command", label: "Run command" }]
                      value: actionTabs.chosen || root.actionKind(root.selected)
                      fontFamily: Style.font.family
                      onChanged: function (v) { actionTabs.chosen = v }
                      property string chosen: ""
                      Connections {
                        target: root
                        function onSelChanged() { actionTabs.chosen = "" }
                        function onRowChanged() { actionTabs.chosen = "" }
                      }
                    }
                    Text {
                      textFormat: Text.PlainText
                      Layout.fillWidth: true
                      text: root.actionSummary(root.selected)
                      color: Color.accent
                      font.family: Style.font.family
                      font.pixelSize: Style.font.bodySmall
                      elide: Text.ElideRight
                    }
                  }
                  readonly property string mode: actionTabs.chosen || root.actionKind(root.selected)

                  BoundSearch {
                    visible: parent.mode === "key"
                    Layout.preferredWidth: Style.space(420)
                    showLabel: false
                    fontFamily: Style.font.family
                    triggerLabel: "Choose a key…"
                    options: root.ed ? root.ed.keys.map(function (k, i) { return { value: String(i), label: k.group + ": " + k.label } }) : []
                    current: { var p = root.presetFor(root.selected ? root.selected.key : undefined); return p ? String(root.ed.keys.indexOf(p)) : "" }
                    onPicked: function (v) { root.setKeyAction(root.ed.keys[parseInt(v)].key) }
                  }
                  BoundSearch {
                    visible: parent.mode === "shortcut"
                    Layout.preferredWidth: Style.space(560)
                    showLabel: false
                    fontFamily: Style.font.family
                    triggerLabel: "Choose one of your shortcuts…"
                    placeholderText: "Search shortcuts…"
                    options: root.ed ? root.ed.shortcuts.map(function (s, i) { return { value: String(i), label: s.label + "   " + s.combo } }) : []
                    current: { var s = root.shortcutFor(root.selected ? root.selected.key : undefined); return s ? String(root.ed.shortcuts.indexOf(s)) : "" }
                    onPicked: function (v) { root.setKeyAction(root.ed.shortcuts[parseInt(v)].key) }
                  }
                  BoundSearch {
                    visible: parent.mode === "app"
                    Layout.preferredWidth: Style.space(420)
                    showLabel: false
                    fontFamily: Style.font.family
                    triggerLabel: "Choose an app…"
                    placeholderText: "Search apps…"
                    options: root.ed ? root.ed.apps.map(function (a) { return { value: a.id, label: a.name } }) : []
                    current: { var a = root.selected ? root.appFor(root.selected.command) : null; return a ? a.id : "" }
                    onPicked: function (v) { root.setCommand("uwsm-app -- " + v) }
                  }
                  RowLayout {
                    visible: parent.mode === "command"
                    spacing: Style.space(10)
                    TextField {
                      id: cmdField
                      Layout.preferredWidth: Style.space(460)
                      placeholderText: "e.g. omarchy-launch-editor"
                      text: root.selected && root.selected.command && !root.appFor(root.selected.command) ? root.selected.command : ""
                      font.family: Style.font.family
                      onAccepted: if (text.trim() !== "") root.setCommand(text.trim())
                    }
                    Button {
                      text: "Use"
                      bordered: true
                      fontFamily: Style.font.family
                      fontSize: Style.font.bodySmall
                      onClicked: if (cmdField.text.trim() !== "") root.setCommand(cmdField.text.trim())
                    }
                    Text {
                      textFormat: Text.PlainText
                      Layout.fillWidth: true
                      text: "Omabar gives it a spare key and adds the Hyprland bind when you save."
                      color: Qt.darker(Color.popups.text, 1.4)
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      wrapMode: Text.Wrap
                    }
                  }
                }

                Item { Layout.columnSpan: 2; Layout.fillHeight: true }
              }

              // ---------- icon picker ----------
              ColumnLayout {
                visible: root.iconPicker && !!root.selected
                anchors.fill: parent
                anchors.margins: Style.space(14)
                spacing: Style.space(10)
                RowLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(10)
                  TextField {
                    id: iconSearch
                    Layout.preferredWidth: Style.space(300)
                    placeholderText: "Search icons…"
                    font.family: Style.font.family
                    onTextChanged: root.iconFilter = text
                    // Enter takes the first match.
                    onAccepted: {
                      var hits = root.matchingIcons()
                      if (hits.length) { root.setProp("icon", hits[0].name); root.iconPicker = false }
                    }
                  }
                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: "Add your own SVGs to ~/.config/omarchy/omabar/icons/"
                    color: Qt.darker(Color.popups.text, 1.4)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                  Button {
                    text: "Done"
                    bordered: true
                    fontFamily: Style.font.family
                    fontSize: Style.font.bodySmall
                    onClicked: root.iconPicker = false
                  }
                }
                GridView {
                  Layout.fillWidth: true
                  Layout.fillHeight: true
                  clip: true
                  cellWidth: Style.space(92)
                  cellHeight: Style.space(78)
                  model: root.matchingIcons()
                  delegate: Item {
                    required property var modelData
                    width: Style.space(92)
                    height: Style.space(78)
                    Rectangle {
                      anchors.fill: parent
                      anchors.margins: Style.space(3)
                      radius: Style.space(6)
                      color: root.selected && root.selected.icon === modelData.name ? Qt.rgba(1, 1, 1, 0.12) : "transparent"
                      border.width: root.selected && root.selected.icon === modelData.name ? 2 : 0
                      border.color: Color.accent
                      Glyph {
                        width: Style.space(34)
                        height: Style.space(34)
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: Style.space(8)
                        icon: modelData
                        tint: root.selected ? (root.pal[root.selected.tint || "white"] || "white") : "white"
                      }
                      Text {
                        textFormat: Text.PlainText
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: Style.space(4)
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        text: modelData.name.replace(/_/g, " ")
                        color: Qt.darker(Color.popups.text, 1.3)
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }
                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { root.setProp("icon", modelData.name); root.iconPicker = false }
                      }
                    }
                  }
                }
              }
            }

            // ---------- footer ----------
            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(10)
              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: root.error !== "" ? root.error
                      : root.trying ? "On your Touch Bar now. It goes back in " + root.tryLeft + " s."
                      : root.status !== "" ? root.status
                      : root.dirty ? "Unsaved changes.  Ctrl+S saves, Ctrl+T tries it on the Touch Bar." : "Ctrl+T tries the layout on the Touch Bar."
                color: root.error !== "" ? Color.urgent : root.trying ? Color.accent : Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.Wrap
              }
              Button {
                text: root.trying ? "Stop trying" : "Try on Touch Bar (20 s)"
                bordered: true
                enabled: !!root.draft
                fontFamily: Style.font.family
                fontSize: Style.font.bodySmall
                onClicked: root.trying ? root.restore() : root.tryOnBar()
              }
              Button {
                text: "Revert"
                bordered: true
                enabled: root.dirty
                fontFamily: Style.font.family
                fontSize: Style.font.bodySmall
                onClicked: { root.dirty = false; var id = root.currentId; root.currentId = ""; root.doSelect(id) }
              }
              Button {
                text: root.current && root.current.source !== "yours" ? "Save as yours" : "Save"
                bordered: true
                active: root.dirty
                enabled: root.dirty && !saveProc.running
                fontFamily: Style.font.family
                fontSize: Style.font.bodySmall
                onClicked: root.save()
              }
            }
          }

          // ================= RULES TAB =================
          ColumnLayout {
            visible: root.tab === "rules"
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Style.space(12)

            GridLayout {
              Layout.fillWidth: true
              columns: 4
              columnSpacing: Style.space(14)
              rowSpacing: Style.space(10)

              Label { text: "Follow the focused app" }
              ToggleSwitch {
                checked: !!root.rulesDraft && root.rulesDraft.follow
                busy: flagProc.running
                onToggled: root.runSimple(["follow", root.rulesDraft.follow ? "off" : "on"])
              }
              Label { text: "Empty desktop returns to your pick" }
              ToggleSwitch {
                checked: !!root.rulesDraft && root.rulesDraft.emptyDefault
                busy: flagProc.running
                onToggled: root.runSimple(["empty-default", root.rulesDraft.emptyDefault ? "off" : "on"])
              }

              Label { text: "Default layout" }
              BoundDropdown {
                Layout.preferredWidth: Style.space(300)
                showLabel: false
                fontFamily: Style.font.family
                options: root.layoutOptions()
                current: root.rulesDraft ? root.rulesDraft.default : ""
                onPicked: function (v) { root.rulesDraft.default = v; root.rulesDraft = root.clone(root.rulesDraft); root.rulesDirty = true }
              }
              Label { text: "Shortcut to open Omabar" }
              TextField {
                Layout.preferredWidth: Style.space(220)
                placeholderText: "e.g. SUPER + ALT + T (empty: none)"
                text: root.rulesDraft ? root.rulesDraft.shortcut : ""
                font.family: Style.font.family
                onTextEdited: { root.rulesDraft.shortcut = text; root.rulesDirty = true }
                onTextChanged: if (!activeFocus) cursorPosition = 0
              }
            }

            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              text: "Rules run top to bottom; the first whose app pattern matches the focused window's class wins. Apps with no rule, and empty desktops, use your last pick, else the default."
              color: Qt.darker(Color.popups.text, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
            }

            PanelSeparator { Layout.fillWidth: true; foreground: Color.popups.text }

            Flickable {
              Layout.fillWidth: true
              Layout.fillHeight: true
              contentHeight: rulesCol.implicitHeight
              clip: true
              boundsBehavior: Flickable.StopAtBounds

              ColumnLayout {
                id: rulesCol
                width: parent.width
                spacing: Style.space(8)

                Repeater {
                  model: root.rulesDraft ? root.rulesDraft.rules.length : 0
                  RowLayout {
                    required property int index
                    readonly property var rule: root.rulesDraft.rules[index]
                    Layout.fillWidth: true
                    spacing: Style.space(10)
                    Text {
                      textFormat: Text.PlainText
                      text: (index + 1) + "."
                      color: Qt.darker(Color.popups.text, 1.4)
                      font.family: Style.font.family
                      font.pixelSize: Style.font.bodySmall
                      Layout.preferredWidth: Style.space(26)
                    }
                    TextField {
                      Layout.fillWidth: true
                      placeholderText: "App pattern, e.g. chromium|firefox"
                      text: rule ? rule.app : ""
                      font.family: Style.font.family
                      onTextEdited: { root.rulesDraft.rules[index].app = text; root.rulesDirty = true }
                      onTextChanged: if (!activeFocus) cursorPosition = 0
                    }
                    Text {
                      textFormat: Text.PlainText
                      text: "→"
                      color: Color.popups.text
                      font.pixelSize: Style.font.body
                    }
                    BoundDropdown {
                      Layout.preferredWidth: Style.space(280)
                      showLabel: false
                      fontFamily: Style.font.family
                      options: root.layoutOptions()
                      current: rule ? rule.layout : ""
                      onPicked: function (v) { var r = root.clone(root.rulesDraft); r.rules[index].layout = v; root.rulesDraft = r; root.rulesDirty = true }
                    }
                    Button {
                      text: "▲"
                      bordered: true
                      enabled: index > 0
                      fontFamily: Style.font.family
                      onClicked: { var r = root.clone(root.rulesDraft); var x = r.rules.splice(index, 1)[0]; r.rules.splice(index - 1, 0, x); root.rulesDraft = r; root.rulesDirty = true }
                    }
                    Button {
                      text: "▼"
                      bordered: true
                      enabled: index < root.rulesDraft.rules.length - 1
                      fontFamily: Style.font.family
                      onClicked: { var r = root.clone(root.rulesDraft); var x = r.rules.splice(index, 1)[0]; r.rules.splice(index + 1, 0, x); root.rulesDraft = r; root.rulesDirty = true }
                    }
                    Button {
                      text: "Remove"
                      bordered: true
                      fontFamily: Style.font.family
                      fontSize: Style.font.bodySmall
                      onClicked: { var r = root.clone(root.rulesDraft); r.rules.splice(index, 1); root.rulesDraft = r; root.rulesDirty = true }
                    }
                  }
                }

                RowLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(10)
                  BoundSearch {
                    id: addFrom
                    Layout.preferredWidth: Style.space(360)
                    showLabel: false
                    fontFamily: Style.font.family
                    triggerLabel: "Add a rule for a running app…"
                    placeholderText: "Search open apps…"
                    options: root.ed ? root.ed.runningApps : []
                    onPicked: function (v) {
                      var r = root.clone(root.rulesDraft)
                      r.rules.push({ app: v.replace(/[.^$*+?()[\]{}|\\]/g, "\\$&"), layout: root.currentId || r.default })
                      root.rulesDraft = r
                      root.rulesDirty = true
                    }
                  }
                  Button {
                    text: "Add empty rule"
                    bordered: true
                    fontFamily: Style.font.family
                    fontSize: Style.font.bodySmall
                    onClicked: { var r = root.clone(root.rulesDraft); r.rules.push({ app: "", layout: r.default }); root.rulesDraft = r; root.rulesDirty = true }
                  }
                  Item { Layout.fillWidth: true }
                }
              }
            }

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(10)
              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: root.error !== "" ? root.error : root.status !== "" ? root.status : root.rulesDirty ? "Unsaved changes." : ""
                color: root.error !== "" ? Color.urgent : Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.Wrap
              }
              Button {
                text: "Revert"
                bordered: true
                enabled: root.rulesDirty
                fontFamily: Style.font.family
                fontSize: Style.font.bodySmall
                onClicked: { root.rulesDirty = false; root.load() }
              }
              Button {
                text: "Save rules"
                bordered: true
                active: root.rulesDirty
                enabled: root.rulesDirty && !rulesProc.running
                fontFamily: Style.font.family
                fontSize: Style.font.bodySmall
                onClicked: root.saveRules()
              }
            }
          }
        }
      }
    }
  }

  // ---------- components ----------
  // Omarchy's dropdowns assign their own `value` when picked, which breaks a
  // binding to the editor's state. These re-bind to `current` after each pick.
  component BoundDropdown: Dropdown {
    id: bd
    property string current: ""
    signal picked(string v)
    value: current
    onChanged: function (v) { bd.value = Qt.binding(function () { return bd.current }); bd.picked(v) }
  }

  component BoundSearch: SearchableDropdown {
    id: bs
    property string current: ""
    signal picked(string v)
    value: current
    onChanged: function (v) { bs.value = Qt.binding(function () { return bs.current }); bs.picked(v) }
  }

  component Label: Text {
    textFormat: Text.PlainText
    color: Color.popups.text
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    font.bold: true
  }

  // An icon drawn from its SVG path data, in any colour.
  component Glyph: Item {
    id: glyph
    property var icon: null
    property color tint: "white"
    readonly property var vb: icon && icon.viewBox ? icon.viewBox : [0, -960, 960, 960]
    readonly property real s: Math.min(width / vb[2], height / vb[3])

    Repeater {
      model: glyph.icon ? glyph.icon.paths : []
      Shape {
        required property string modelData
        width: glyph.vb[2]
        height: glyph.vb[3]
        x: (glyph.width - glyph.vb[2] * glyph.s) / 2 - glyph.vb[0] * glyph.s
        y: (glyph.height - glyph.vb[3] * glyph.s) / 2 - glyph.vb[1] * glyph.s
        scale: glyph.s
        transformOrigin: Item.TopLeft
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
          fillColor: glyph.tint
          strokeColor: "transparent"
          strokeWidth: 0
          PathSvg { path: modelData }
        }
      }
    }
  }

  // What a button shows: icon, text, or a placeholder for widgets.
  component ButtonFace: Item {
    id: face
    property var b: null
    property bool large: false
    readonly property string kind: root.kindOf(b)
    readonly property real fs: large ? Style.font.bodySmall : Math.max(8, height * 0.5)

    Glyph {
      visible: face.kind === "icon" || face.kind === "wxicon"
      anchors.centerIn: parent
      width: Math.min(parent.width, parent.height)
      height: width
      icon: face.kind === "wxicon" ? root.iconMap["cloud"] : (face.b ? root.iconMap[face.b.icon] : null)
      tint: face.kind === "wxicon" ? (root.pal.foreground || "white")
            : face.b ? (root.pal[face.b.tint || "white"] || "white") : "white"
    }
    Text {
      textFormat: Text.PlainText
      visible: face.kind !== "icon" && face.kind !== "wxicon" && face.kind !== "spacer"
      anchors.centerIn: parent
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      elide: Text.ElideRight
      color: "white"
      font.family: "JetBrainsMono Nerd Font"
      font.bold: true
      font.pixelSize: face.fs
      text: !face.b ? ""
            : face.kind === "text" ? (face.b.text || "")
            : face.kind === "clock" ? Qt.formatTime(new Date(), face.b.time.indexOf("%H") !== -1 ? "HH:mm" : "h:mm AP")
            : face.kind === "date" ? Qt.formatDate(new Date(), "ddd MMM d")
            : face.kind === "battery" ? (face.b.battery === "icon" ? "▭" : "▭ 87%")
            : face.kind === "wxtemp" ? "78°" : ""
    }
    Text {
      textFormat: Text.PlainText
      visible: face.kind === "spacer" && face.large
      anchors.centerIn: parent
      text: "gap"
      color: Qt.rgba(1, 1, 1, 0.35)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }

  // To-scale Touch Bar strip of a row.
  component Strip: Rectangle {
    id: strip
    property var items: []
    property bool outlines: false
    property int highlight: -1
    readonly property real total: {
      var t = 0
      for (var i = 0; i < items.length; i++) t += root.stretchOf(items[i])
      return Math.max(1, t)
    }
    height: Math.round(width / root.barRatio)
    radius: height * 0.12
    color: "#000000"
    border.width: 1
    border.color: Qt.rgba(1, 1, 1, 0.12)

    Row {
      id: stripRow
      x: strip.height * 0.06
      y: strip.height * 0.06
      width: strip.width - x * 2
      height: strip.height - y * 2
      spacing: strip.width * 0.008
      readonly property real unit: (width - spacing * Math.max(0, strip.items.length - 1)) / strip.total

      Repeater {
        model: strip.items.length
        Rectangle {
          required property int index
          readonly property var b: strip.items[index]
          width: stripRow.unit * root.stretchOf(b)
          height: stripRow.height
          radius: height * 0.14
          color: strip.outlines && (root.kindOf(b) === "icon" || root.kindOf(b) === "text") ? "#333333" : "transparent"
          border.width: index === strip.highlight ? 2 : 0
          border.color: Color.accent
          ButtonFace {
            anchors.fill: parent
            anchors.margins: parent.height * 0.12
            b: parent.b
          }
        }
      }
    }
  }
}
