import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar entry for YouTube Music: a note glyph, plus the playing song when
// there is one. Left click opens the panel, middle click plays or pauses,
// right click skips, and the wheel steps through the queue.
//
// All state lives in Service.qml (one per shell); every bar on every monitor
// is a thin view over it.
BarWidget {
  id: root
  moduleName: "codydon.omatune"

  readonly property var service: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor("codydon.omatune") : null

  readonly property bool showTitle: setting("showTitle", true) !== false && String(setting("showTitle", true)) !== "false"
  readonly property int maxTitleChars: Math.max(8, Math.min(80, parseInt(setting("maxTitleChars", 28), 10) || 28))
  readonly property bool autoRadio: setting("autoRadio", true) !== false && String(setting("autoRadio", true)) !== "false"
  readonly property bool saveHistory: setting("saveHistory", true) !== false && String(setting("saveHistory", true)) !== "false"
  readonly property bool cacheSongs: setting("cacheSongs", true) !== false && String(setting("cacheSongs", true)) !== "false"
  // `omarchy bar set` stores strings; clamp again because the schema's
  // min/max only limit the settings UI.
  readonly property int cacheLimitMB: Math.max(100, Math.min(20000, parseInt(setting("cacheLimitMB", 1024), 10) || 1024))

  readonly property bool hasTrack: service ? service.hasTrack : false
  readonly property bool playing: service ? service.playing : false
  readonly property string glyph: playing ? "󰝚" : (hasTrack ? "󰏤" : "󰎈")

  // WidgetButton renders its text with the host's format, so the title is
  // already stripped of markup by the service and capped again here.
  readonly property string titleText: {
    if (!service || !hasTrack || !showTitle || vertical) return ""
    var t = Model.plain(service.nowTitle, 200)
    return t.length > maxTitleChars ? t.slice(0, maxTitleChars - 1) + "…" : t
  }

  function pushSettings() {
    if (!service) return
    service.autoRadio = root.autoRadio
    service.saveHistory = root.saveHistory
    service.cacheSongs = root.cacheSongs
    service.cacheLimitMB = root.cacheLimitMB
  }

  onServiceChanged: pushSettings()
  onAutoRadioChanged: pushSettings()
  onSaveHistoryChanged: pushSettings()
  onCacheSongsChanged: pushSettings()
  onCacheLimitMBChanged: pushSettings()

  // ---- Panel contract (same shape as the first-party clock).
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("service" in target) target.service = root.service
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: { injectPanel(); pushSettings() }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // Every bar instance registers this target; the shell warns about the
  // duplicates and routes to one, which is fine because they all share the
  // service. Media keys go through MPRIS (mpv-mpris) instead.
  IpcHandler {
    target: "codydon.omatune"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function playPause(): void { if (root.service) root.service.togglePause() }
    function toggleMute(): void { if (root.service) root.service.toggleMute() }
    function next(): void { if (root.service) root.service.next() }
    function previous(): void { if (root.service) root.service.previous() }
    function stop(): void { if (root.service) root.service.stop() }
    // The three methods that take a value only trigger the widget's normal,
    // non-destructive actions, and are bounded the same way as the UI:
    // the query is capped and cleaned in Service.search, the filter must be
    // one of all / songs / videos (Model.searchFilter), and the index must
    // be an integer inside the current results.
    function search(query: string): void { if (root.service) root.service.search(String(query).slice(0, 200)) }
    function searchFilter(filter: string): void { if (root.service) root.service.setSearchFilter(String(filter)) }
    function clearSearch(): void { if (root.service) root.service.clearSearch() }
    function playResult(index: int): void {
      var i = Number(index)
      if (!root.service || !Number.isInteger(i) || i < 0 || i >= root.service.results.length) return
      root.service.playNow(root.service.results[i])
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.titleText !== "" ? root.glyph + "  " + root.titleText : root.glyph
    dimmed: !root.hasTrack
    tooltipText: root.hasTrack ? "" : "OmaTune"

    onPressed: function(b) {
      if (!root.service) return
      if (b === Qt.MiddleButton) root.service.togglePause()
      else if (b === Qt.RightButton) root.service.next()
      else root.togglePanel()
    }

    onWheelMoved: function(delta) {
      if (!root.service || !root.hasTrack) return
      if (delta > 0) root.service.previous()
      else root.service.next()
    }
  }
}
