import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The YouTube Music popup: now playing with transport and a seek bar, a
// search box, and one list that shows either search results or the queue.
//
// Keyboard: / search (↓↑ suggestions · tab complete) · j/k move · enter play
// · a add to queue · q next view
// (1 results · 2 queue · 3 local · 4 cached · 5 history) · p play/pause · m mute ·
// n next · b back · h/l seek · x remove · esc close.
//
// BarWidget.qml owns the bar button and injects bar, anchorItem, hostWidget
// and service. Every string shown here came through Model.plain() in the
// service, and every Text is PlainText.
Panel {
  id: root
  moduleName: "codydon.omatune"
  ipcTarget: "codydon.omatune"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var service: null
  readonly property var barIdentity: hostWidget || root

  // Which list is showing. Searching flips to results; with nothing
  // searched the queue is the useful thing to show.
  readonly property var views: ["results", "queue", "local", "cached", "history"]
  readonly property var viewNames: ({ results: "RESULTS", queue: "QUEUE", local: "LOCAL", cached: "CACHED", history: "HISTORY" })
  property string view: "queue"
  property int cursor: -1
  property int suggestCursor: -1
  // Clearing needs a second click within a few seconds.
  property string armedClear: ""

  readonly property var rows: {
    if (!service) return []
    if (view === "queue") return service.queue
    if (view === "local") return service.localTracks
    if (view === "cached") return service.cachedTracks
    if (view === "history") return service.history.map(function(q) { return { title: q, query: q } })
    return service.results
  }
  readonly property bool hasTrack: service ? service.hasTrack : false
  readonly property bool restoring: service ? service.restoring : false
  readonly property bool editing: searchField.activeFocus

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.4)
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property int rowHeight: Style.space(40)
  readonly property int visibleRows: 8

  function open() {
    root.controller.show()
    if (service) service.scanLocalMusic()
    if (restoring) view = "queue"
    else if (service && service.results.length > 0 && !hasTrack) view = "results"
    cursor = rows.length > 0 ? Math.max(0, currentQueueIndex()) : -1
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
      // Nothing to look at yet: the first thing anyone does is search.
      if (root.opened && !root.hasTrack && !root.restoring && root.rows.length === 0) root.focusSearch()
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function currentQueueIndex() {
    if (view !== "queue" || !service) return 0
    for (var i = 0; i < service.queue.length; i++) if (service.queue[i].current) return i
    return 0
  }

  function focusSearch() {
    searchField.forceActiveFocus()
    searchField.selectAll()
  }

  function leaveSearch() {
    keyCatcher.forceActiveFocus()
  }

  function submitSearch() {
    if (!service) return
    var q = searchField.text.trim()
    if (q === "") return
    suggestCursor = -1
    service.search(q)
    view = "results"
    cursor = 0
    leaveSearch()
  }

  function runSuggestion(index) {
    if (!service || index < 0 || index >= service.suggestions.length) return
    searchField.text = service.suggestions[index]
    suggestCursor = -1
    submitSearch()
  }

  function completeSuggestion() {
    if (!service || suggestCursor < 0 || suggestCursor >= service.suggestions.length) return
    searchField.text = service.suggestions[suggestCursor]
    searchField.cursorPosition = searchField.text.length
    suggestCursor = -1
  }

  readonly property bool suggestOpen: searchField.activeFocus && service !== null && service.suggestions.length > 0

  function setView(next) {
    if (view === next || views.indexOf(next) < 0) return
    view = next
    armedClear = ""
    listFlick.contentY = 0
    cursor = rows.length > 0 ? Math.max(0, currentQueueIndex()) : -1
  }

  function cycleView() {
    setView(views[(views.indexOf(view) + 1) % views.length])
  }

  function runHistory(q) {
    if (!service) return
    searchField.text = q
    service.search(q)
  }

  function armOrClear(which) {
    if (!service) return
    if (armedClear !== which) { armedClear = which; disarm.restart(); return }
    armedClear = ""
    if (which === "cache") service.clearCache()
    else service.clearHistory()
  }

  function moveCursor(delta) {
    if (rows.length === 0) { cursor = -1; return }
    cursor = Model.clampIndex(cursor < 0 ? 0 : cursor + delta, rows.length)
    ensureVisible(cursor)
  }

  function ensureVisible(index) {
    var top = index * rowHeight
    if (top < listFlick.contentY) listFlick.contentY = top
    else if (top + rowHeight > listFlick.contentY + listFlick.height)
      listFlick.contentY = top + rowHeight - listFlick.height
  }

  function activate(index) {
    if (!service || index < 0 || index >= rows.length) return
    if (view === "queue") service.playIndex(index)
    else if (view === "local") service.playLocal(rows[index])
    else if (view === "history") runHistory(rows[index].query)
    else if (view === "cached") service.playCached(index)
    else service.playNow(rows[index])
  }

  function addSelected() {
    if (!service || (view !== "results" && view !== "cached" && view !== "local") || cursor < 0 || cursor >= rows.length) return
    if (view === "local") service.enqueueLocal(rows[cursor])
    else service.enqueue(rows[cursor])
  }

  function removeSelected() {
    if (!service || cursor < 0 || cursor >= rows.length) return
    if (view === "queue") service.removeIndex(cursor)
    else if (view === "history") service.forgetSearch(rows[cursor].query)
    else return
    cursor = Model.clampIndex(cursor, rows.length - 1)
  }

  function seekBy(seconds) {
    if (service && hasTrack) service.seek(Math.max(0, service.position + seconds))
  }

  // Keep the cursor on a real row as the list under it changes.
  onRowsChanged: if (cursor >= rows.length) cursor = rows.length - 1

  // A search started anywhere (this panel, another monitor's, IPC) shows
  // its results here too.
  Connections {
    target: root.service
    ignoreUnknownSignals: true
    function onQueryChanged() {
      root.view = "results"
      root.cursor = 0
      listFlick.contentY = 0
    }
    function onSuggestionsChanged() { root.suggestCursor = -1 }
  }

  Timer {
    id: disarm
    interval: 4000
    onTriggered: root.armedClear = ""
  }

  // Autocomplete waits for a pause in typing before asking YouTube.
  Timer {
    id: suggestDebounce
    interval: 300
    onTriggered: {
      if (root.service && searchField.activeFocus) root.service.fetchSuggestions(searchField.text)
    }
  }

  component PlainText: Text {
    textFormat: Text.PlainText
    font.family: root.fontFamily
    color: root.fg
    elide: Text.ElideRight
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(520))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editing
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveCursor(dy)
        if (dx !== 0) root.seekBy(dx * 10)
      }
      onActivateRequested: root.activate(root.cursor)
      onCloseRequested: root.close()
      onDeleteRequested: root.removeSelected()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (!root.service) return
        if (t === "/" || t === "s") root.focusSearch()
        else if (t === "p") root.service.togglePause()
        else if (t === "m") root.service.toggleMute()
        else if (t === "n") root.service.next()
        else if (t === "b") root.service.previous()
        else if (t === "a") root.addSelected()
        else if (t === "q") root.cycleView()
        else if (t >= "1" && t <= "5") root.setView(root.views[Number(t) - 1])
      }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(10)

        // ---- Now playing
        PanelHero {
          width: parent.width
          foreground: root.fg
          fontFamily: root.fontFamily
          iconComponent: Component {
            Text {
              textFormat: Text.PlainText
              text: root.hasTrack || root.restoring ? "󰝚" : "󰎈"
              color: root.service && root.service.playing ? root.fg : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
          title: !root.service ? "YouTube Music is loading"
            : root.hasTrack ? root.service.nowTitle
            : root.service.starting ? "Starting the player"
            : root.restoring && root.service.resumeTrack ? root.service.resumeTrack.title
            : "Nothing is playing"
          meta: {
            if (root.service && root.restoring && root.service.resumeTrack) {
              var r = []
              if (root.service.resumeTrack.artist) r.push(root.service.resumeTrack.artist.toUpperCase())
              r.push(root.service.restored.position >= 1
                ? "PRESS PLAY TO RESUME AT " + Model.formatTime(root.service.restored.position)
                : "PRESS PLAY TO RESUME")
              return r.join(" · ")
            }
            if (!root.service || !root.hasTrack) return "SEARCH A SONG TO START A RADIO"
            var parts = []
            if (root.service.nowArtist) parts.push(root.service.nowArtist.toUpperCase())
            parts.push(root.service.buffering ? "LOADING" : (root.service.paused ? "PAUSED" : "PLAYING"))
            if (root.service.muted) parts.push("MUTED")
            if (root.service.radioLoading) parts.push("FINDING RADIO")
            return parts.join(" · ")
          }
          detail: root.hasTrack
            ? Model.formatTime(root.service.position) + " / " + Model.formatTime(root.service.duration)
            : ""
        }

        PanelSlider {
          width: parent.width
          visible: root.hasTrack
          bar: root.bar
          minimum: 0
          maximum: Math.max(1, root.service ? root.service.duration : 1)
          step: 1
          value: root.service ? root.service.position : 0
          onReleased: function(v) { if (root.service) root.service.seek(v) }
        }

        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(8)
          visible: root.hasTrack || (root.service && root.service.queue.length > 0)

          PanelActionButton {
            iconText: "󰒮"
            tooltipText: "Back (b)"
            foreground: root.fg
            fontFamily: root.fontFamily
            onClicked: if (root.service) root.service.previous()
          }
          PanelActionButton {
            iconText: root.service && root.service.playing ? "󰏤" : "󰐊"
            tooltipText: root.service && root.service.playing ? "Pause (p)" : "Play (p)"
            foreground: root.fg
            fontFamily: root.fontFamily
            onClicked: if (root.service) root.service.togglePause()
          }
          PanelActionButton {
            iconText: "󰒭"
            tooltipText: "Next (n)"
            foreground: root.fg
            fontFamily: root.fontFamily
            onClicked: if (root.service) root.service.next()
          }
          PanelActionButton {
            iconText: root.service && root.service.muted ? "󰖁" : "󰕾"
            tooltipText: root.service && root.service.muted ? "Unmute (m)" : "Mute (m)"
            foreground: root.fg
            fontFamily: root.fontFamily
            onClicked: if (root.service) root.service.toggleMute()
          }
          PanelActionButton {
            iconText: "󰓛"
            tooltipText: "Stop and close the player"
            foreground: root.fg
            fontFamily: root.fontFamily
            onClicked: if (root.service) root.service.stop()
          }
        }

        // ---- Error box: what went wrong, then what to do.
        Rectangle {
          width: parent.width
          visible: root.service !== null && root.service.lastError !== ""
          height: visible ? errorText.implicitHeight + Style.space(16) : 0
          color: "transparent"
          border.width: 1
          border.color: root.urgent
          radius: Style.cornerRadius

          PlainText {
            id: errorText
            x: Style.space(8)
            y: Style.space(8)
            width: parent.width - Style.space(16)
            text: root.service ? root.service.lastError : ""
            wrapMode: Text.Wrap
            elide: Text.ElideNone
            maximumLineCount: 4
            font.pixelSize: Style.font.bodySmall
          }
        }

        PanelSeparator {
          width: parent.width
          foreground: root.fg
        }

        // ---- Search
        TextField {
          id: searchField
          width: parent.width
          placeholderText: "Search songs  ( / )"
          foreground: root.fg
          font.family: root.fontFamily
          maximumLength: 200
          onTextChanged: if (activeFocus) suggestDebounce.restart()

          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              if (root.suggestOpen && root.suggestCursor >= 0) root.runSuggestion(root.suggestCursor)
              else root.submitSearch()
              event.accepted = true
            } else if (event.key === Qt.Key_Escape) {
              if (searchField.text !== "") searchField.text = ""
              else root.leaveSearch()
              event.accepted = true
            } else if (event.key === Qt.Key_Down) {
              if (root.suggestOpen) {
                if (root.suggestCursor < root.service.suggestions.length - 1) root.suggestCursor++
                else { root.suggestCursor = -1; root.leaveSearch(); root.moveCursor(0) }
              } else {
                root.leaveSearch()
                root.moveCursor(0)
              }
              event.accepted = true
            } else if (event.key === Qt.Key_Up) {
              if (root.suggestOpen && root.suggestCursor >= 0) root.suggestCursor--
              event.accepted = true
            } else if (event.key === Qt.Key_Tab) {
              if (root.suggestOpen && root.suggestCursor >= 0) {
                root.completeSuggestion()
                event.accepted = true
              }
            }
          }
        }

        // ---- Suggestions: YouTube completions for what is being typed.
        Column {
          width: parent.width
          visible: root.suggestOpen

          Repeater {
            model: root.service ? root.service.suggestions : []

            CursorSurface {
              id: suggestRow
              required property string modelData
              required property int index
              width: parent.width
              height: Style.space(30)
              foreground: root.fg
              hasCursor: index === root.suggestCursor

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: root.suggestCursor = suggestRow.index
                onClicked: root.runSuggestion(suggestRow.index)
              }

              PlainText {
                anchors.left: parent.left
                anchors.leftMargin: Style.spacing.rowPaddingX
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(18)
                text: "󰍉"
                font.pixelSize: Style.font.body
                color: root.dim
              }

              PlainText {
                anchors.left: parent.left
                anchors.leftMargin: Style.spacing.rowPaddingX + Style.space(24)
                anchors.right: parent.right
                anchors.rightMargin: Style.spacing.rowPaddingX
                anchors.verticalCenter: parent.verticalCenter
                text: suggestRow.modelData
                font.pixelSize: Style.font.bodySmall
              }
            }
          }
        }

        // ---- List header: what this list is, and tabs for the others.
        Item {
          width: parent.width
          height: header.implicitHeight

          PanelSectionHeader {
            id: header
            anchors.left: parent.left
            anchors.right: tabs.left
            anchors.rightMargin: Style.space(8)
            elide: Text.ElideRight
            foreground: root.fg
            fontFamily: root.fontFamily
            text: {
              var sv = root.service
              if (!sv) return ""
              var n
              if (root.view === "queue") {
                n = sv.queue.length
                return (root.restoring ? "SAVED QUEUE · " : "UP NEXT · ") + n + (n === 1 ? " SONG" : " SONGS")
              }
              if (root.view === "cached") {
                n = sv.cachedTracks.length
                var size = Model.formatBytes(sv.cacheBytes)
                return "OFFLINE · " + n + (n === 1 ? " SONG" : " SONGS") + (size ? " · " + size.toUpperCase() : "") + (sv.caching ? " · SAVING" : "")
              }
              if (root.view === "local") return (sv.localScanning ? "SCANNING · " : "LOCAL MUSIC · ") + sv.localTracks.length + " SONGS"
              if (root.view === "history") return "RECENT SEARCHES · " + sv.history.length
              if (sv.searching) return "SEARCHING"
              return "RESULTS · " + sv.results.length + " SONGS"
            }
          }

          Row {
            id: tabs
            anchors.right: parent.right
            anchors.verticalCenter: header.verticalCenter
            spacing: Style.space(10)

            Repeater {
              model: root.views

              PlainText {
                id: tab
                required property string modelData
                required property int index
                text: root.viewNames[modelData]
                color: modelData === root.view ? root.fg
                  : tabMouse.containsMouse ? Style.hoverStateColor(root.fg, Color.accent) : root.dim
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
                font.bold: modelData === root.view

                MouseArea {
                  id: tabMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.setView(tab.modelData)
                }
              }
            }
          }
        }

        PlainText {
          width: parent.width
          visible: text !== ""
          color: root.dim
          wrapMode: Text.Wrap
          elide: Text.ElideNone
          font.pixelSize: Style.font.bodySmall
          text: {
            var sv = root.service
            if (!sv) return ""
            if (root.view === "results") {
              if (sv.searching) return "Asking YouTube Music…"
              if (sv.searchError !== "") return sv.searchError
              if (sv.results.length === 0) return "Press / and type a song or an artist."
              return ""
            }
            if (root.view === "cached") {
              if (sv.cacheError !== "" && sv.cachedTracks.length === 0) return sv.cacheError
              if (sv.cachedTracks.length === 0)
                return sv.cacheSongs
                  ? "Songs you listen to for 20 seconds are saved here and play without a connection."
                  : "Offline saving is turned off in the widget settings. Songs saved earlier still show here."
              return ""
            }
            if (root.view === "local") {
              if (sv.localError !== "") return sv.localError
              if (sv.localScanning) return "Scanning ~/Music…"
              if (sv.localTracks.length === 0) return "No supported audio files found in ~/Music. Add music there and reopen this panel to rescan."
              return "Select a song to play it, or press a to add it to the queue."
            }
            if (root.view === "history") {
              if (sv.history.length === 0)
                return sv.saveHistory ? "Your searches will show up here." : "Search history is turned off in the widget settings."
              return ""
            }
            if (sv.queue.length === 0) return "The queue is empty. Search for a song and press enter to start a radio."
            return ""
          }
        }

        // ---- Rows
        Flickable {
          id: listFlick
          width: parent.width
          height: Math.min(root.rows.length, root.visibleRows) * root.rowHeight
          contentHeight: rowColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          Column {
            id: rowColumn
            width: listFlick.width

            Repeater {
              model: root.rows

              CursorSurface {
                id: row
                required property var modelData
                required property int index
                width: rowColumn.width
                height: root.rowHeight
                foreground: root.fg
                hasCursor: index === root.cursor
                current: root.view === "queue" && modelData.current === true

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                  cursorShape: Qt.PointingHandCursor
                  onEntered: root.cursor = row.index
                  onClicked: function(mouse) {
                    root.cursor = row.index
                    // Middle or right click: queue it (results) or drop it (queue).
                    if (mouse.button === Qt.LeftButton) root.activate(row.index)
                    else if (root.view === "results") root.addSelected()
                    else root.removeSelected()
                  }
                }

                PlainText {
                  id: rowGlyph
                  anchors.left: parent.left
                  anchors.leftMargin: Style.spacing.rowPaddingX
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(18)
                  text: root.view === "history" ? "󰋚"
                    : row.current ? (root.service && root.service.playing ? "󰝚" : "󰏤") : ""
                  font.pixelSize: Style.font.body
                }

                Column {
                  anchors.left: rowGlyph.right
                  anchors.leftMargin: Style.space(6)
                  anchors.right: rowDuration.left
                  anchors.rightMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(1)

                  PlainText {
                    width: parent.width
                    text: row.modelData.title
                    font.pixelSize: Style.font.body
                    font.bold: row.current
                  }
                  PlainText {
                    width: parent.width
                    visible: text !== ""
                    text: row.modelData.album && row.modelData.album !== row.modelData.title
                      ? (row.modelData.artist || "") + " · " + row.modelData.album
                      : (row.modelData.artist || "")
                    color: root.dim
                    font.pixelSize: Style.font.caption
                  }
                }

                PlainText {
                  id: rowDuration
                  anchors.right: parent.right
                  anchors.rightMargin: Style.spacing.rowPaddingX
                  anchors.verticalCenter: parent.verticalCenter
                  text: {
                    var d = row.modelData.duration || ""
                    if (root.view === "cached") return Model.formatBytes(row.modelData.size)
                    // A small marker for songs that will play from disk.
                    if (root.view !== "history" && root.service && root.service.cached[row.modelData.id]) return "󰇚 " + d
                    return d
                  }
                  color: root.dim
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }
        }

        // ---- Clearing: explicit, and it takes a second click.
        Item {
          width: parent.width
          height: clearText.implicitHeight
          visible: (root.view === "cached" && root.service && root.service.cachedTracks.length > 0)
            || (root.view === "history" && root.service && root.service.history.length > 0)

          PlainText {
            id: clearText
            readonly property string which: root.view === "cached" ? "cache" : "history"
            anchors.right: parent.right
            text: root.armedClear === which
              ? (which === "cache" ? "CLICK AGAIN TO DELETE ALL SAVED SONGS" : "CLICK AGAIN TO CLEAR HISTORY")
              : (which === "cache" ? "CLEAR OFFLINE SONGS" : "CLEAR HISTORY")
            color: root.armedClear === which ? root.urgent
              : clearMouse.containsMouse ? Style.hoverStateColor(root.fg, Color.accent) : root.dim
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1

            MouseArea {
              id: clearMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.armOrClear(clearText.which)
            }
          }
        }

        PlainText {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          color: root.dim
          font.pixelSize: Style.font.caption
          text: {
            if (root.view === "results") return "/ search (↓↑ pick · tab complete) · enter play + radio · a add to queue · q next list · esc close"
            if (root.view === "cached") return "enter play offline · a add to queue · q next list · esc close"
            if (root.view === "history") return "enter search again · x forget · q next list · esc close"
            return "enter play · x remove · p pause · m mute · n next · b back · h/l seek · q next list"
          }
        }
      }
    }
  }
}
