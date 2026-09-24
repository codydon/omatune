import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The YouTube Music popup: now playing with transport and a seek bar, a
// search box, and one list that shows either search results or the queue.
//
// Keyboard: / search · j/k move · enter play · a add to queue · q results or
// queue · p play/pause · n next · b back · h/l seek · x remove · esc close.
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

  // "results" or "queue". Searching flips to results; with nothing searched
  // the queue is the useful thing to show.
  property string view: "queue"
  property int cursor: -1

  readonly property var rows: !service ? [] : (view === "queue" ? service.queue : service.results)
  readonly property bool hasTrack: service ? service.hasTrack : false
  readonly property bool editing: searchField.activeFocus

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.4)
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property int rowHeight: Style.space(40)
  readonly property int visibleRows: 8

  function open() {
    root.controller.show()
    if (service && service.results.length > 0 && !hasTrack) view = "results"
    cursor = rows.length > 0 ? Math.max(0, currentQueueIndex()) : -1
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
      // Nothing to look at yet: the first thing anyone does is search.
      if (root.opened && !root.hasTrack && root.rows.length === 0) root.focusSearch()
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
    service.search(q)
    view = "results"
    cursor = 0
    leaveSearch()
  }

  function setView(next) {
    if (view === next) return
    view = next
    cursor = rows.length > 0 ? Math.max(0, currentQueueIndex()) : -1
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
    else service.playNow(rows[index])
  }

  function addSelected() {
    if (!service || view !== "results" || cursor < 0 || cursor >= rows.length) return
    service.enqueue(rows[cursor])
  }

  function removeSelected() {
    if (!service || view !== "queue" || cursor < 0 || cursor >= rows.length) return
    service.removeIndex(cursor)
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
        else if (t === "n") root.service.next()
        else if (t === "b") root.service.previous()
        else if (t === "a") root.addSelected()
        else if (t === "q") root.setView(root.view === "queue" ? "results" : "queue")
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
              text: root.hasTrack ? "󰝚" : "󰎈"
              color: root.service && root.service.playing ? root.fg : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
          title: !root.service ? "YouTube Music is loading"
            : root.hasTrack ? root.service.nowTitle
            : root.service.starting ? "Starting the player"
            : "Nothing is playing"
          meta: {
            if (!root.service || !root.hasTrack) return "SEARCH A SONG TO START A RADIO"
            var parts = []
            if (root.service.nowArtist) parts.push(root.service.nowArtist.toUpperCase())
            parts.push(root.service.buffering ? "LOADING" : (root.service.paused ? "PAUSED" : "PLAYING"))
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

          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              root.submitSearch(); event.accepted = true
            } else if (event.key === Qt.Key_Escape) {
              if (searchField.text !== "") searchField.text = ""
              else root.leaveSearch()
              event.accepted = true
            } else if (event.key === Qt.Key_Down) {
              root.leaveSearch()
              root.moveCursor(0)
              event.accepted = true
            }
          }
        }

        // ---- List header: which list, how long, and the way to the other.
        Item {
          width: parent.width
          height: header.implicitHeight

          PanelSectionHeader {
            id: header
            anchors.left: parent.left
            foreground: root.fg
            fontFamily: root.fontFamily
            text: {
              if (!root.service) return ""
              if (root.view === "queue") return "UP NEXT · " + root.service.queue.length + (root.service.queue.length === 1 ? " SONG" : " SONGS")
              if (root.service.searching) return "SEARCHING"
              return "RESULTS · " + root.service.results.length + " SONGS"
            }
          }

          PlainText {
            anchors.right: parent.right
            anchors.verticalCenter: header.verticalCenter
            text: root.view === "queue" ? "SHOW RESULTS (q)" : "SHOW QUEUE (q)"
            color: switchMouse.containsMouse ? Style.hoverStateColor(root.fg, Color.accent) : root.dim
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1

            MouseArea {
              id: switchMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.setView(root.view === "queue" ? "results" : "queue")
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
            if (!root.service) return ""
            if (root.view === "results") {
              if (root.service.searching) return "Asking YouTube Music…"
              if (root.service.searchError !== "") return root.service.searchError
              if (root.service.results.length === 0) return "Press / and type a song or an artist."
              return ""
            }
            if (root.service.queue.length === 0) return "The queue is empty. Search for a song and press enter to start a radio."
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
                  text: row.current ? (root.service && root.service.playing ? "󰝚" : "󰏤") : ""
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
                      ? row.modelData.artist + " · " + row.modelData.album
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
                  text: row.modelData.duration || ""
                  color: root.dim
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }
        }

        PlainText {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          color: root.dim
          font.pixelSize: Style.font.caption
          text: root.view === "results"
            ? "/ search · enter play + radio · a add to queue · q queue · esc close"
            : "enter play · x remove · p pause · n next · b back · h/l seek · q results"
        }
      }
    }
  }
}
