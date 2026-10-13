import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Networking
import Quickshell.Bluetooth
import Quickshell.Services.Pipewire
import Quickshell.Services.UPower
import qs.Commons
import qs.Ui
import "NetworkModel.js" as NetModel

// oma.controlpanel — a control center for the Omarchy bar.
//
// A popup anchored to the bar button: a hero, a grid of quick toggles
// (network, Bluetooth, night light, do-not-disturb), the audio and brightness
// sliders, and a power section (battery + power profile).
//
// Live system state comes straight from Quickshell's own services
// (Networking, Bluetooth, Pipewire, UPower) so nothing here depends on
// Omarchy's first-party panels being loaded. The handful of things Quickshell
// does not model (brightness, night light, DND, power profile, connection
// name) are read back from the omarchy-* helpers in short-lived Processes and
// written through the same helpers, so behaviour matches the rest of the
// desktop.
Panel {
  id: root
  moduleName: "oma.controlpanel"
  ipcTarget: "oma.controlpanel"

  // Injected by BarWidget.qml's injectPanel(), which owns the actual bar
  // button. KeyboardPanel anchors to the bar item rather than to this panel,
  // and `owner` has to be the bar widget so popout routing finds it.
  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property color foreground: bar ? bar.foreground : ShellColor.foreground
  readonly property color accent: ShellColor.accent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(foreground, 1.4)

  // ----------------------------------------------------------------- glyphs
  // Each written as a literal so the surrogate pairs survive tooling that
  // mangles \u escapes above the BMP.
  readonly property string glyphPanel: "󰕮"
  readonly property string glyphWifiOn: "󰖩"
  readonly property string glyphWifiOff: "󰖪"
  readonly property string glyphWired: "󰈀"
  readonly property string glyphBtOn: "󰂯"
  readonly property string glyphBtConnected: "󰂱"
  readonly property string glyphBtOff: "󰂲"
  readonly property string glyphMoon: "󰖔"
  readonly property string glyphDisplay: "󰍹"
  readonly property string glyphForward: "󰅂"
  readonly property string glyphBell: "󰂚"
  readonly property string glyphBellOff: "󰂛"
  readonly property string glyphVolume: "󰕾"
  readonly property string glyphMute: "󰝟"
  readonly property string glyphBrightness: "󰃠"
  readonly property string glyphBattery: "󰁹"
  readonly property string glyphBack: "󰅁"
  readonly property string glyphGlobe: "󰖟"
  readonly property string glyphSpeedometer: "󰓅"
  readonly property string glyphTimer: "󰔟"
  readonly property string glyphDownload: "󰇚"
  readonly property string glyphUpload: "󰕒"
  readonly property string glyphTheme: "󰏘"
  readonly property string glyphWifiLock: "󰌾"
  readonly property string glyphWifiCheck: "󰄬"

  // ------------------------------------------------------------ live state
  readonly property var netDevices: Networking.devices ? Networking.devices.values : []
  readonly property bool hasWifi: {
    for (var i = 0; i < netDevices.length; i++)
      if (netDevices[i] && netDevices[i].type === DeviceType.Wifi) return true
    return false
  }
  readonly property bool wifiOn: Networking.wifiEnabled
  // Connected-first Wi-Fi device for the network list. A machine can expose
  // several NICs of the same type, and the first-enumerated one may be
  // carrierless, so prefer whichever is up.
  readonly property var wifiDevice: {
    var fallback = null
    for (var i = 0; i < netDevices.length; i++) {
      var d = netDevices[i]
      if (!d || d.type !== DeviceType.Wifi) continue
      if (d.connected) return d
      if (!fallback) fallback = d
    }
    return fallback
  }
  readonly property var wifiNetworkObjects: wifiDevice && wifiDevice.networks ? wifiDevice.networks.values : []
  // { type, name } from `omarchy-network-status`; empty until the first poll.
  property var netInfo: ({})
  // System DNS provider from `omarchy-dns`; the Network page's pills write it.
  property string dnsProvider: "DHCP"
  property string dnsPending: ""
  readonly property var dnsProviders: ["DHCP", "Cloudflare", "Google", "Custom"]

  readonly property var btAdapter: Bluetooth.defaultAdapter
  readonly property bool btOn: btAdapter !== null && btAdapter.enabled
  readonly property var btDevices: Bluetooth.devices ? Bluetooth.devices.values : []
  readonly property int btConnectedCount: {
    var n = 0
    for (var i = 0; i < btDevices.length; i++)
      if (btDevices[i] && btDevices[i].connected) n++
    return n
  }

  readonly property var sink: Pipewire.defaultAudioSink
  readonly property real volume: sink && sink.audio ? sink.audio.volume : 0
  readonly property bool muted: sink && sink.audio ? sink.audio.muted : false
  readonly property string sinkName: sink ? String(sink.nickname || sink.description || sink.name || "") : ""

  readonly property var battery: UPower.displayDevice
  readonly property bool hasBattery: battery !== null && battery.isPresent === true
  readonly property int batteryPercent: {
    if (!battery || battery.percentage === undefined) return -1
    var p = Number(battery.percentage)
    if (!isFinite(p)) return -1
    return Math.round(p <= 1 ? p * 100 : p)
  }
  readonly property string batteryText: {
    if (!hasBattery) return ""
    if (batteryPercent < 0) return ""
    return batteryPercent + "%"
  }

  // Polled external state.
  property int brightness: -1          // percent, -1 when unknown
  property bool nightlight: false
  property bool dnd: false
  property string powerProfile: ""
  property bool profileAvailable: false
  property string hostname: ""
  property string themeName: ""

  // Themes page state: installed themes (slug + preview image path) read from
  // the theme directories, the slug currently highlighted for preview, and
  // whether a switch is in flight.
  property var themeRows: []
  property string themeSelected: ""
  property bool themeSetting: false

  // ------------------------------------------------- network detail sub-page
  // "home" | "network" | "bluetooth" | "display". A tile body (or the Display
  // entry row) opens its detail page; the back button (or Esc) returns home.
  property string page: "home"
  // Parsed `omarchy-network-status --verbose` key/value lines, e.g. ip,
  // gateway, iface, type, speed, internet_ping_ms.
  property var netDetail: ({})
  property bool netDetailLoaded: false

  // Wi-Fi list on the Network page. Rows are primitive snapshots (ssid +
  // flags) so NetworkManager churn never leaves a live wrapper in a delegate;
  // actions resolve the WifiNetwork by SSID at click time.
  property var wifiNetworks: []
  property bool wifiScanning: false
  property string wifiActionSsid: ""
  property string wifiActionKind: ""   // "connect" | "disconnect" | "forget"
  property string wifiFailureSsid: ""
  property string wifiFailureReason: ""
  // The row currently expanded into password-entry mode ("" = none). Kept open
  // across the poll so a slow scan doesn't collapse the input being typed.
  property string passwordSsid: ""
  property string passwordText: ""
  property string identityText: ""
  // The device this panel turned scanning on for. WifiDevice has no reference
  // counting, so remember whose scanner we own and release only that one.
  property var wifiScannerDevice: null

  // Speed test, modelled on the built-in omarchy.speedtest panel: measure
  // download for a few seconds, then upload, streaming Mbps from
  // `omarchy-network-speedtest down|up`.
  property bool speedRunning: false
  property string speedPhase: ""       // "down" | "up" | ""
  property string speedDown: ""
  property string speedUp: ""
  property string speedError: ""
  property string speedStderr: ""
  property bool speedExpectedStop: false
  property bool speedPendingRun: false

  // Bluetooth page state: address -> "connecting" | "disconnecting" |
  // "forgetting", kept only to keep the UI responsive while BlueZ catches up.
  // Discovery is owned by this instance while the page is open so it can be
  // stopped again on leave (BlueZ discovery holds the radio busy).
  property var btPending: ({})
  property bool btOwnsDiscovery: false

  // Display page state, mirroring the built-in omarchy.monitor panel: monitors
  // (and the focused one), its scale, and the text-size stop being previewed.
  // Brightness is already polled for the home slider and reused here.
  property string focusedMonitor: ""
  property string monitorScale: ""
  property var displays: []
  property int enabledDisplayCount: 0
  property int textSizePreviewIndex: -1
  readonly property var scalePresets: ["1", "1.25", "1.6", "2", "3", "4"]
  readonly property var textSizeStops: [9, 10, 11, 12, 14, 16, 20]

  // ----------------------------------------------------------- derived text
  readonly property string netSubtitle: {
    var t = String(netInfo.type || "")
    var n = String(netInfo.name || "")
    if (t === "wifi") return n !== "" ? n : "Wi-Fi"
    if (t === "ethernet") return n !== "" ? n : "Ethernet"
    // No helper answer yet: fall back to whatever the live devices report.
    for (var i = 0; i < netDevices.length; i++) {
      var d = netDevices[i]
      if (d && d.connected) return String(d.name || "Connected")
    }
    return "Disconnected"
  }
  readonly property string netIcon: {
    var t = String(netInfo.type || "")
    if (t === "ethernet") return glyphWired
    if (t === "wifi") return wifiOn ? glyphWifiOn : glyphWifiOff
    for (var i = 0; i < netDevices.length; i++) {
      var d = netDevices[i]
      if (d && d.connected && d.type === DeviceType.Wired) return glyphWired
    }
    return hasWifi ? (wifiOn ? glyphWifiOn : glyphWifiOff) : glyphWired
  }
  readonly property string btIcon: !btOn ? glyphBtOff : (btConnectedCount > 0 ? glyphBtConnected : glyphBtOn)
  readonly property string btSubtitle: {
    if (btAdapter === null) return "No adapter"
    if (!btOn) return "Off"
    if (btConnectedCount === 0) return "On"
    return btConnectedCount === 1 ? "1 device" : btConnectedCount + " devices"
  }

  // ------------------------------------------------------------ theme derived
  // The current theme's slug (e.g. "Tokyo Night" -> "tokyo-night") is how the
  // theme directories and the list rows are keyed.
  readonly property string currentThemeSlug: themeName !== "" ? themeName.toLowerCase().replace(/ /g, "-") : ""
  // The row to preview: the explicit pick, else the active theme, else the
  // first installed theme once the list has loaded.
  readonly property string themeEffectiveSlug: {
    if (themeSelected !== "") return themeSelected
    if (currentThemeSlug !== "") return currentThemeSlug
    return themeRows.length > 0 ? themeRows[0].slug : ""
  }
  readonly property string themeSelectedName: {
    var row = themeSelectedRow()
    return row ? row.name : ""
  }
  readonly property string themePreviewSource: {
    var row = themeSelectedRow()
    return row && row.preview !== "" ? "file://" + row.preview : ""
  }
  readonly property bool themeIsCurrent: themeEffectiveSlug !== "" && themeEffectiveSlug === currentThemeSlug

  // ------------------------------------------------- network page derived
  readonly property string netLocalIp: String(netDetail.ip || "")
  readonly property string netGateway: String(netDetail.gateway || "")
  readonly property string netIface: String(netDetail.iface || netInfo.name || "")
  readonly property string netLinkSpeed: netDetail.speed ? String(netDetail.speed) + " Mbps" : ""
  readonly property string netPing: {
    var p = Number(String(netDetail.internet_ping_ms || ""))
    if (!isFinite(p) || p <= 0) return ""
    return (p < 10 ? p.toFixed(1) : String(Math.round(p))) + " ms"
  }
  readonly property string speedDownText: formatMbps(speedDown)
  readonly property bool wifiBusy: wifiActionKind !== ""
  // ConnectionFailReason values as a plain object, so NetworkModel.js helpers
  // stay pure JS.
  readonly property var connectionFailReasons: ({
    NoSecrets: ConnectionFailReason.NoSecrets,
    WifiAuthTimeout: ConnectionFailReason.WifiAuthTimeout,
    WifiNetworkLost: ConnectionFailReason.WifiNetworkLost,
    WifiClientDisconnected: ConnectionFailReason.WifiClientDisconnected,
    WifiClientFailed: ConnectionFailReason.WifiClientFailed
  })
  readonly property string speedUpText: formatMbps(speedUp)
  readonly property bool speedHasResult: speedDownText !== "" || speedUpText !== ""

  // ------------------------------------------------- bluetooth page derived
  // Device rows are turned into plain objects: a Repeater model that holds the
  // live Device wrappers would race BlueZ teardown, so each row carries only
  // primitives and actions resolve the live device by address at click time.
  readonly property var btLists: {
    var out = { connected: [], known: [], available: [] }
    var devs = btDevices
    for (var i = 0; i < devs.length; i++) {
      var d = devs[i]
      if (!d || !btHasHumanName(d)) continue
      var row = {
        address: btAddr(d),
        label: btLabel(d),
        connected: d.connected === true,
        batteryAvailable: d.batteryAvailable === true,
        battery: d.battery !== undefined ? Number(d.battery) : 0,
        pairing: d.pairing === true
      }
      if (row.connected) out.connected.push(row)
      else if (d.paired || d.bonded || d.trusted) out.known.push(row)
      else out.available.push(row)
    }
    btSortRows(out.connected)
    btSortRows(out.known)
    btSortRows(out.available)
    return out
  }
  readonly property var btConnectedRows: btLists.connected
  readonly property var btKnownRows: btLists.known
  readonly property var btAvailableRows: btLists.available
  readonly property bool btScanning: btAdapter !== null && btAdapter.enabled && btAdapter.discovering === true
  readonly property int btRowCount: btConnectedRows.length + btKnownRows.length + btAvailableRows.length

  // ------------------------------------------------- display page derived
  readonly property var focusedDisplay: {
    for (var i = 0; i < displays.length; i++)
      if (displays[i] && displays[i].focused) return displays[i]
    return null
  }
  readonly property var scaleValues: focusedDisplay
    ? availableScales(scalePresets, focusedDisplay.width, focusedDisplay.height)
    : scalePresets
  readonly property var scaleOptions: {
    var opts = []
    for (var i = 0; i < scaleValues.length; i++)
      opts.push({ value: String(scaleValues[i]), label: effectiveScale(scaleValues[i]) + "x" })
    return opts
  }
  // The preset whose effective scale matches the monitor's current one, if any.
  readonly property string currentScaleValue: {
    if (!focusedDisplay) return ""
    var idx = matchingScaleIndex(scaleValues, monitorScale, focusedDisplay.width, focusedDisplay.height)
    return idx >= 0 ? String(scaleValues[idx]) : ""
  }
  readonly property string displaySubtitle: focusedMonitor !== ""
    ? focusedMonitor + (monitorScale !== "" ? " · " + monitorScale + "x" : "")
    : ""
  readonly property int textSizeIndex: textSizePreviewIndex >= 0 ? textSizePreviewIndex : nearestTextStop(Style.font.baseSize)
  readonly property int textSizePx: textSizePreviewIndex >= 0 ? textSizeStops[textSizePreviewIndex] : Style.font.baseSize

  function btLabel(d) {
    if (!d) return ""
    return String(d.deviceName || d.name || "").trim()
  }
  function btAddr(d) {
    return d ? String(d.address || "") : ""
  }
  function btIsUuidLike(v) {
    var t = String(v || "").trim()
    return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(t)
        || /^[0-9a-f]{32}$/i.test(t)
  }
  function btIsAddressLike(v) {
    return /^([0-9a-f]{2}[:-]){5}[0-9a-f]{2}$/i.test(String(v || "").trim())
  }
  // BlueZ exposes many devices with only a UUID or raw address as their name;
  // hide those so the list only shows things a person can recognise.
  function btHasHumanName(d) {
    var l = btLabel(d)
    return l !== "" && !btIsUuidLike(l) && !btIsAddressLike(l)
  }
  function btSortRows(rows) {
    rows.sort(function(a, b) { return a.label.localeCompare(b.label) })
  }

  function formatMbps(raw) {
    if (raw === undefined || raw === null || String(raw).trim() === "") return ""
    var v = Number(raw)
    if (!isFinite(v) || v < 0) return ""
    return v < 10 ? v.toFixed(1) : String(Math.round(v))
  }

  // -------------------------------------------------------------- actions
  function refresh() {
    netProc.running = true
    nightlightGetProc.running = true
    dndGetProc.running = true
    profileGetProc.running = true
    hostProc.running = true
    themeProc.running = true
    // monitorStateProc also carries the brightness read. Skip it while a set is
    // in flight: two DDC/CI calls at once make the write fail on external
    // monitors.
    if (!brightnessSetProc.running && !brightnessDebounce.running) monitorStateProc.running = true
    if (page === "network") {
      netDetailProc.running = true
      dnsGetProc.running = true
      syncWifiNetworks()
    }
    if (page === "themes") {
      themeListProc.running = true
      themeProc.running = true
    }
  }

  function openFromHotkey() {
    open()
    refresh()
  }

  onOpenedChanged: {
    if (opened) {
      refresh()
    } else {
      // Dismissing the panel must not leave the speed-test traffic running nor
      // the Bluetooth radio scanning.
      stopSpeedTest()
      stopBtDiscovery()
      cancelPasswordPrompt()
      setWifiScanner(false)
      page = "home"
    }
  }

  function toggleWifi() {
    if (!hasWifi) return
    Networking.wifiEnabled = !Networking.wifiEnabled
  }

  function toggleBluetooth() {
    if (btAdapter === null) return
    Quickshell.execDetached(["omarchy-bluetooth-power", btOn ? "off" : "on"])
  }

  function toggleNightlight() {
    Quickshell.execDetached(["omarchy-toggle-nightlight"])
    // The helper retries for up to ~2s while hyprsunset settles, so poll twice.
    nightlightTimer.restart()
  }

  function setDnd(on) {
    Quickshell.execDetached(["omarchy-shell", "notifications", "setDnd", on ? "on" : "off"])
    dndTimer.restart()
  }

  function setVolume(v) {
    if (sink && sink.audio) sink.audio.volume = Math.max(0, Math.min(1, Number(v)))
  }

  function toggleMute() {
    if (sink && sink.audio) sink.audio.muted = !sink.audio.muted
  }

  function clampBrightnessPercent(v) {
    var n = Math.round(Number(v) * 100)
    if (!isFinite(n)) n = 50
    return Math.max(1, Math.min(100, n))
  }

  function stageBrightness(v) {
    brightnessPending = clampBrightnessPercent(v)
    brightnessDebounce.restart()
  }

  function commitBrightness(v) {
    brightnessPending = clampBrightnessPercent(v)
    brightnessDebounce.stop()
    applyBrightness()
  }

  function applyBrightness() {
    // Optimistic: the slider should not snap back while the helper runs.
    brightness = brightnessPending
    if (brightnessSetProc.running) {
      brightnessSetQueued = true
      return
    }
    brightnessSetQueued = false
    brightnessSetProc.running = true
  }

  function setPowerProfile(p) {
    if (String(p) === "" || String(p) === powerProfile) return
    powerProfile = String(p) // optimistic
    Quickshell.execDetached(["powerprofilesctl", "set", String(p)])
    profileTimer.restart()
  }

  // --------------------------------------------------------- network actions
  function openNetworkPage() {
    stopBtDiscovery()
    page = "network"
    netDetailProc.running = true
    dnsGetProc.running = true
    wifiScanning = true
    setWifiScanner(true)
    wifiScanSettle.restart()
  }

  function updateDns(raw) {
    var v = String(raw || "").trim()
    dnsProvider = v !== "" ? v : "DHCP"
  }

  function setDns(provider) {
    if (!provider || dnsSetProc.running) return
    if (provider === "Custom") {
      // Custom prompts for the servers, so it needs a terminal.
      Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", "omarchy-dns Custom"])
      return
    }
    dnsPending = provider
    dnsProvider = provider // optimistic; the re-read on exit reverts on failure
    dnsSetProc.command = ["omarchy-dns", provider]
    dnsSetProc.running = true
  }

  function backToHome() {
    stopSpeedTest()
    stopBtDiscovery()
    cancelPasswordPrompt()
    setWifiScanner(false)
    page = "home"
  }

  // ----------------------------------------------------------- wifi actions
  function wifiIconFor(strength) {
    return NetModel.wifiIconFor(strength)
  }

  function requiresWifiCredentials(security) {
    return NetModel.requiresCredentials(security, WifiSecurityType.Open, WifiSecurityType.Owe)
  }

  function canForgetWifi(row) {
    return !!(row && row.known && !row.connected)
  }

  // Resolve the live WifiNetwork behind a primitive row/SSID.
  function networkForSsid(ssid) {
    var nets = wifiNetworkObjects || []
    for (var i = 0; i < nets.length; i++)
      if (nets[i] && nets[i].name === ssid) return nets[i]
    return null
  }

  function syncWifiNetworks() {
    var nets = []
    var objs = wifiNetworkObjects || []
    for (var i = 0; i < objs.length; i++) {
      var n = objs[i]
      if (!n) continue
      checkWifiActionCompletion(n)
      var row = NetModel.wifiRow(n)
      if (row) nets.push(row)
    }
    // Reassign only when the list actually changed: a plain reassign would
    // rebuild every delegate on the 4s poll and tear down an open passphrase
    // prompt (and its focus) underneath the user.
    var sorted = NetModel.sortWifiRows(nets)
    if (JSON.stringify(sorted) !== JSON.stringify(wifiNetworks)) wifiNetworks = sorted
    // Stop showing the scanning state once results start landing; the settle
    // timer ends it for an empty scan.
    if (sorted.length > 0) wifiScanning = false
  }

  // WifiDevice's scanner flag has no reference counting, so only ever release
  // the device this instance turned on.
  function setWifiScanner(enabled) {
    var next = (opened && page === "network") ? wifiDevice : null
    if (wifiScannerDevice && wifiScannerDevice !== next)
      wifiScannerDevice.scannerEnabled = false
    wifiScannerDevice = next
    if (wifiScannerDevice) wifiScannerDevice.scannerEnabled = enabled
  }

  function openPasswordPrompt(ssid) {
    if (passwordSsid !== ssid) {
      passwordText = ""
      identityText = ""
    }
    passwordSsid = ssid
  }

  function cancelPasswordPrompt() {
    passwordSsid = ""
    passwordText = ""
    identityText = ""
  }

  // One Wi-Fi action at a time, mirroring the built-in panel. `callback`
  // receives the live WifiNetwork so callers only resolve it once.
  function runWifiAction(kind, network, callback) {
    if (wifiActionKind !== "" || !network) return
    wifiActionSsid = network.name || ""
    wifiActionKind = kind
    wifiFailureSsid = ""
    wifiFailureReason = ""
    callback(network)
    // Safety net: if the completion signal never arrives, don't leave the row
    // stuck on "Connecting…" forever.
    wifiActionTimeout.restart()
  }

  function clearWifiAction() {
    wifiActionTimeout.stop()
    if (wifiActionKind === "connect") cancelPasswordPrompt()
    wifiFailureSsid = ""
    wifiFailureReason = ""
    wifiActionSsid = ""
    wifiActionKind = ""
    syncWifiNetworks()
  }

  function failWifiAction(network, reason) {
    if (!network || wifiActionKind === "" || wifiActionSsid !== (network.name || "")) return
    wifiActionTimeout.stop()
    wifiFailureSsid = wifiActionSsid
    wifiFailureReason = NetModel.networkFailureReason(reason, requiresWifiCredentials(network.security), connectionFailReasons)
    wifiActionSsid = ""
    wifiActionKind = ""
    syncWifiNetworks()
  }

  function checkWifiActionCompletion(network) {
    if (!network || wifiActionKind === "" || wifiActionSsid !== (network.name || "")) return
    if (wifiActionKind === "connect" && network.connected) clearWifiAction()
    else if (wifiActionKind === "disconnect" && !network.connected && !network.stateChanging) clearWifiAction()
    else if (wifiActionKind === "forget" && !network.known && !network.stateChanging) clearWifiAction()
  }

  function connectWifiDirectly(ssid) {
    runWifiAction("connect", networkForSsid(ssid), function(network) { network.connect() })
  }

  function connectWifiWithPassphrase(ssid, passphrase) {
    runWifiAction("connect", networkForSsid(ssid), function(network) { network.connectWithPsk(passphrase) })
  }

  function connectWifiEnterprise(ssid, identity, passphrase) {
    runWifiAction("connect", networkForSsid(ssid), function(network) {
      enterpriseConnect.secret = passphrase
      enterpriseConnect.command = ["bash", "-c", NetModel.enterpriseConnectScript, "nmcli-eap", ssid, identity]
      enterpriseConnect.running = true
    })
  }

  function disconnectWifi(network) {
    if (!network) return
    runWifiAction("disconnect", network, function(net) { net.disconnect() })
  }

  function disconnectWifiRow(ssid) {
    var network = networkForSsid(ssid)
    if (network) disconnectWifi(network)
  }

  function forgetWifi(row) {
    var network = row ? networkForSsid(row.ssid) : null
    runWifiAction("forget", network, function(net) { net.forget() })
  }

  // Left click connects/disconnects; a protected network we have no saved
  // credentials for opens the inline prompt first.
  function activateWifiRow(row) {
    if (!row || wifiBusy) return
    if (row.connected) { disconnectWifiRow(row.ssid); return }
    if (requiresWifiCredentials(row.security) && !row.known) { openPasswordPrompt(row.ssid); return }
    connectWifiDirectly(row.ssid)
  }

  // Right click / press-and-hold forgets a saved but disconnected network.
  function wifiSecondary(row) {
    if (canForgetWifi(row)) forgetWifi(row)
  }

  function startSpeedTest() {
    if (speedProc.running) {
      // A stop's SIGTERM is still in flight; Process.running stays true until
      // the child exits, so queue the fresh run for onExited.
      if (speedExpectedStop) speedPendingRun = true
      return
    }
    speedError = ""
    speedDown = ""
    speedUp = ""
    speedRunning = true
    startSpeedPhase("down")
  }

  function startSpeedPhase(nextPhase) {
    speedExpectedStop = false
    speedPhase = nextPhase
    speedStderr = ""
    speedProc.command = ["omarchy-network-speedtest", nextPhase]
    speedProc.running = true
    speedPhaseTimer.restart()
  }

  function stopSpeedPhase() {
    speedPhaseTimer.stop()
    if (speedProc.running) {
      speedExpectedStop = true
      speedProc.running = false
      return
    }
    finishSpeedPhase()
  }

  function finishSpeedPhase() {
    if (speedPhase === "down") {
      startSpeedPhase("up")
      return
    }
    speedPhase = ""
    speedRunning = false
    speedExpectedStop = false
  }

  function stopSpeedTest() {
    speedPendingRun = false
    speedPhaseTimer.stop()
    // Clear the phase before killing the process: onExited advances to upload
    // when it still reads "down".
    speedPhase = ""
    speedRunning = false
    if (speedProc.running) {
      speedExpectedStop = true
      speedProc.running = false
    }
  }

  function updateSpeedLine(line) {
    var value = parseFloat(line)
    if (!isFinite(value) || value < 0) return
    if (speedPhase === "down") speedDown = String(value)
    else if (speedPhase === "up") speedUp = String(value)
  }

  // -------------------------------------------------------- bluetooth actions
  function openBluetoothPage() {
    page = "bluetooth"
    startBtDiscovery()
  }

  function btDeviceFor(address) {
    if (!address) return null
    for (var i = 0; i < btDevices.length; i++)
      if (btAddr(btDevices[i]) === address) return btDevices[i]
    return null
  }

  function btPendingAction(address) {
    return address && btPending && btPending[address] ? btPending[address] : ""
  }

  function setBtPending(address, action) {
    if (!address) return
    var next = ({})
    for (var k in btPending) next[k] = btPending[k]
    if (action) next[address] = action
    else delete next[address]
    btPending = next
    if (action) btPendingTimeout.restart()
  }

  function btConnect(row) {
    if (!row || !row.address) return
    var d = btDeviceFor(row.address)
    if (d && d.connected) return
    var known = d && (d.paired || d.bonded || d.trusted)
    setBtPending(row.address, "connecting")
    Quickshell.execDetached(["omarchy-bluetooth-device", known ? "connect" : "pair", row.address])
  }

  function btDisconnect(row) {
    if (!row || !row.address) return
    setBtPending(row.address, "disconnecting")
    var d = btDeviceFor(row.address)
    if (d && d.disconnect) d.disconnect()
    Quickshell.execDetached(["omarchy-bluetooth-device", "disconnect", row.address])
  }

  function btForget(row) {
    if (!row || !row.address) return
    setBtPending(row.address, "forgetting")
    Quickshell.execDetached(["omarchy-bluetooth-device", "forget", row.address])
  }

  // Left click toggles the connection; right click forgets a remembered one.
  function btActivate(row) {
    if (!row) return
    if (row.connected) btDisconnect(row)
    else btConnect(row)
  }
  function btSecondary(row, section) {
    if (section === "connected" || section === "known") btForget(row)
  }

  // Drop a pending flag as soon as the live device agrees the action landed.
  function syncBtPending() {
    var next = ({})
    var changed = false
    for (var address in btPending) {
      var action = btPending[address]
      var d = btDeviceFor(address)
      var done = (action === "connecting" && d && d.connected)
              || (action === "disconnecting" && (!d || !d.connected))
              || (action === "forgetting" && (!d || (!d.paired && !d.bonded && !d.trusted)))
      if (done) changed = true
      else next[address] = action
    }
    if (changed) btPending = next
  }

  function startBtDiscovery() {
    if (btAdapter && btAdapter.enabled && !btAdapter.discovering) {
      btOwnsDiscovery = true
      btAdapter.discovering = true
    }
  }

  function stopBtDiscovery() {
    // Only stop discovery this instance started; another client (the built-in
    // Bluetooth panel) may hold its own session.
    if (btAdapter && btAdapter.discovering && btOwnsDiscovery) btAdapter.discovering = false
    btOwnsDiscovery = false
  }

  // ------------------------------------------------------------ theme actions
  // Title-case a slug the same way the omarchy helpers do: "tokyo-night" ->
  // "Tokyo Night". The slug is the key the theme directories use.
  function themeDisplayName(slug) {
    var parts = String(slug || "").split("-")
    var out = []
    for (var i = 0; i < parts.length; i++) {
      if (parts[i] === "") continue
      out.push(parts[i].charAt(0).toUpperCase() + parts[i].slice(1))
    }
    return out.join(" ")
  }

  function openThemePage() {
    page = "themes"
    themeSelected = currentThemeSlug
    themeListProc.running = true
    themeProc.running = true
  }

  function updateThemes(output) {
    var lines = String(output || "").split("\n")
    var rows = []
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].trim() === "") continue
      var parts = lines[i].split("\t")
      var slug = String(parts[0] || "").trim()
      if (slug === "") continue
      rows.push({ slug: slug, name: themeDisplayName(slug), preview: String(parts[1] || "").trim() })
    }
    rows.sort(function(a, b) { return a.name.localeCompare(b.name) })
    themeRows = rows
    if (themeSelected === "") themeSelected = currentThemeSlug
  }

  function themeSelectedRow() {
    for (var i = 0; i < themeRows.length; i++)
      if (themeRows[i].slug === themeEffectiveSlug) return themeRows[i]
    return null
  }

  function selectTheme(slug) {
    themeSelected = String(slug || "")
  }

  function applyTheme() {
    if (themeSetting) return
    var row = themeSelectedRow()
    if (!row || row.slug === currentThemeSlug) return
    themeSetting = true
    themeSetProc.command = ["omarchy-theme-set", row.name]
    themeSetProc.running = true
  }

  // ---------------------------------------------------------- display actions
  function openDisplayPage() {
    page = "display"
    monitorStateProc.running = true
  }

  function updateDisplays(json) {
    var parsed = []
    try { parsed = JSON.parse(String(json || "[]")) } catch (e) { parsed = [] }
    if (!Array.isArray(parsed)) parsed = []
    displays = parsed
    var n = 0
    for (var i = 0; i < parsed.length; i++)
      if (parsed[i] && parsed[i].enabled) n++
    enabledDisplayCount = n
  }

  function toggleDisplay(name, enabled) {
    // Only a plain connector name may pass: it is written into the Lua string
    // eval'd below.
    if (!name || !/^[A-Za-z0-9._-]+$/.test(String(name))) return
    // Never leave the desktop with no display enabled.
    if (enabled && enabledDisplayCount <= 1) return
    // Hyprland 0.56 dropped the legacy `hyprctl keyword monitor` parser; the
    // Lua `hl.monitor` call is what Omarchy's own helpers now use.
    var expr = enabled
      ? 'hl.monitor({ output = "' + name + '", disabled = true })'
      : 'hl.monitor({ output = "' + name + '", disabled = false })'
    monitorToggleProc.command = ["hyprctl", "eval", expr]
    if (!monitorToggleProc.running) monitorToggleProc.running = true
  }

  function setMonitorScale(scale) {
    if (String(scale || "") === "") return
    scaleProc.command = ["bash", "-c", "omarchy-hyprland-monitor-scaling " + scale]
    if (!scaleProc.running) scaleProc.running = true
  }

  function nearestTextStop(px) {
    var best = 0
    var bestDist = 1e9
    for (var i = 0; i < textSizeStops.length; i++) {
      var d = Math.abs(textSizeStops[i] - Number(px))
      if (d < bestDist) { bestDist = d; best = i }
    }
    return best
  }

  function setTextSize(px) {
    textSizeProc.command = ["omarchy-display-text-size", String(px)]
    if (!textSizeProc.running) textSizeProc.running = true
  }

  // ---- scale math, ported from the built-in monitor panel's Model.js ----
  function normalizeScale(scale) {
    var n = parseFloat(String(scale || ""))
    if (!isFinite(n)) return ""
    return String(Math.round(n * 100) / 100)
  }
  function scaleGcd(a, b) {
    while (b) {
      var r = a % b
      a = b
      b = r
    }
    return a
  }
  function cleanScale(scale, width, height) {
    var requested = Number(scale)
    var w = Number(width)
    var h = Number(height)
    if (!isFinite(requested) || !isFinite(w) || !isFinite(h) || requested <= 0 || w <= 0 || h <= 0) return ""
    var divisor = scaleGcd(Math.round(w * 120), Math.round(h * 120))
    var units = Math.round(requested * 120)
    if (units > divisor) units = divisor
    while (divisor % units !== 0) units++
    return normalizeScale(units / 120)
  }
  function matchingScaleIndex(scales, currentScale, width, height) {
    var current = Number(currentScale)
    if (!Array.isArray(scales) || !isFinite(current)) return -1
    var bestIndex = -1
    var bestDistance = Infinity
    var normalized = normalizeScale(current)
    for (var i = 0; i < scales.length; i++) {
      if (cleanScale(scales[i], width, height) !== normalized) continue
      var distance = Math.abs(Number(scales[i]) - current)
      if (distance < bestDistance) { bestIndex = i; bestDistance = distance }
    }
    return bestIndex
  }
  function availableScales(scales, width, height) {
    if (!Array.isArray(scales) || Number(width) <= 0 || Number(height) <= 0) return scales || []
    var byEffective = {}
    for (var i = 0; i < scales.length; i++) {
      var requested = Number(scales[i])
      var effective = Number(cleanScale(requested, width, height))
      if (!isFinite(requested) || !isFinite(effective)) continue
      var key = normalizeScale(effective)
      var existing = byEffective[key]
      if (!existing || Math.abs(requested - effective) < existing.distance)
        byEffective[key] = { value: String(scales[i]), index: i, distance: Math.abs(requested - effective) }
    }
    return Object.keys(byEffective)
      .map(function(key) { return byEffective[key] })
      .sort(function(a, b) { return a.index - b.index })
      .map(function(candidate) { return candidate.value })
  }
  function effectiveScale(scale) {
    if (focusedDisplay) return cleanScale(scale, focusedDisplay.width, focusedDisplay.height)
    return normalizeScale(scale)
  }

  property int brightnessPending: 50
  // DDC/CI reads are slow, so a set gets queued instead of racing the in-flight
  // one (two overlapping ddcutil calls on the same bus fail silently).
  property bool brightnessSetQueued: false

  // Lists the installed themes as "<slug>\t<preview-path>" lines. User themes
  // win over shipped ones on a slug clash; a theme without preview.png falls
  // back to its first background so the row still has a thumbnail.
  readonly property string themeListScript: [
    "declare -A seen",
    "for d in \"$HOME/.config/omarchy/themes\" \"${OMARCHY_PATH:-/usr/share/omarchy}/themes\"; do",
    "  [ -d \"$d\" ] || continue",
    "  for p in \"$d\"/*; do",
    "    [ -d \"$p\" ] || continue",
    "    s=${p##*/}",
    "    [ -n \"${seen[$s]:-}\" ] && continue",
    "    seen[$s]=1",
    "    v=\"\"",
    "    for f in preview.png preview.jpg preview.jpeg preview.webp preview.gif preview.bmp; do",
    "      if [ -f \"$p/$f\" ]; then v=\"$p/$f\"; break; fi",
    "    done",
    "    if [ -z \"$v\" ] && [ -d \"$p/backgrounds\" ]; then",
    "      v=$(find -L \"$p/backgrounds\" -maxdepth 1 -type f \\( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \\) | sort | head -n1)",
    "    fi",
    "    printf '%s\\t%s\\n' \"$s\" \"$v\"",
    "  done",
    "done"
  ].join("\n")

  // -------------------------------------------------------------- processes
  Process {
    id: netProc
    command: ["omarchy-network-status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").split("\n").filter(function(l) { return l.trim() !== "" })
        if (lines.length === 0) { root.netInfo = ({}); return }
        var parts = lines[0].split("\t")
        root.netInfo = { type: String(parts[0] || ""), name: String(parts[1] || "") }
      }
    }
  }

  Process {
    id: netDetailProc
    command: ["omarchy-network-status", "--verbose"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var map = ({})
        var lines = String(text || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
          var kv = lines[i].split("\t")
          if (kv.length >= 2 && kv[0] !== "") map[kv[0]] = kv[1]
        }
        root.netDetail = map
        root.netDetailLoaded = true
      }
    }
  }

  // `omarchy-dns` with no argument prints the active provider (DHCP,
  // Cloudflare, Google or Custom); with one it rewrites NetworkManager's
  // config. The write needs privileges, so the helper shells out to sudo.
  Process {
    id: dnsGetProc
    command: ["omarchy-dns"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.updateDns(text)
    }
  }

  Process {
    id: dnsSetProc
    onExited: function(code) {
      root.dnsPending = ""
      // The helper rewrote the resolver config; re-read the effective provider
      // so a failed write rolls the highlighted pill back.
      dnsGetProc.running = true
    }
  }

  // Creates and activates the 802.1X profile (see NetworkModel.js). The
  // password goes over stdin, never argv.
  Process {
    id: enterpriseConnect
    property string secret: ""
    stdinEnabled: true
    onStarted: {
      write(secret + "\n")
      secret = ""
    }
  }

  Process {
    id: nightlightGetProc
    command: ["omarchy-toggle-nightlight", "--status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var obj = JSON.parse(String(text || "{}"))
          root.nightlight = obj && obj.enabled === true
        } catch (e) {
          // Helper unavailable or no hyprsunset: leave the previous value.
        }
      }
    }
  }

  Process {
    id: dndGetProc
    command: ["omarchy-shell", "notifications", "dndState"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.dnd = String(text || "").trim() === "on"
    }
  }

  Process {
    id: profileGetProc
    command: ["powerprofilesctl", "get"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var p = String(text || "").trim()
        if (p !== "") {
          root.powerProfile = p
          root.profileAvailable = true
        }
      }
    }
  }

  Process {
    id: hostProc
    command: ["uname", "-n"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.hostname = String(text || "").trim()
    }
  }

  // Human-readable name of the active theme (e.g. "Tokyo Night"), shown as the
  // hero's second line. Cheap: the helper only title-cases a state file.
  Process {
    id: themeProc
    command: ["omarchy-theme-current"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.themeName = String(text || "").trim()
    }
  }

  Process {
    id: themeListProc
    command: ["bash", "-c", root.themeListScript]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.updateThemes(text)
    }
  }

  // Applying a theme is heavy: Omarchy runs its theme hooks and repaints the
  // whole desktop, so it only starts from the explicit "Set theme" button.
  Process {
    id: themeSetProc
    onExited: function(code) {
      root.themeSetting = false
      // Re-read the current theme so the check mark follows the applied theme.
      themeProc.running = true
      themeListProc.running = true
    }
  }

  // `omarchy-monitor-state` prints eight lines: brightness, internal monitor,
  // external monitor, internal-enabled, mirror, focused monitor, scale, and a
  // JSON array of displays (name/enabled/focused/width/height).
  Process {
    id: monitorStateProc
    command: ["omarchy-monitor-state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").split("\n")
        // Line 0 is the focused display's brightness. This is the only
        // brightness read: the helper shares one slow DDC/CI call, so issuing
        // it twice per refresh (or during a set) makes the writes fail.
        var b = String(lines[0] || "").trim()
        if (!brightnessSetProc.running && b !== "" && b !== "unavailable") {
          var n = parseInt(b, 10)
          if (isFinite(n)) {
            root.brightness = Math.max(0, Math.min(100, n))
            root.brightnessPending = root.brightness
          }
        }
        root.focusedMonitor = String(lines[5] || "").trim()
        root.monitorScale = root.normalizeScale(String(lines[6] || "").trim())
        root.updateDisplays(String(lines[7] || "[]").trim())
      }
    }
  }

  Process {
    id: brightnessSetProc
    // Pass the monitor explicitly (like the built-in panel) so the helper skips
    // its own focused-monitor lookup. Falls back internally when empty.
    command: ["omarchy-brightness-display", "--no-osd", "--monitor", root.focusedMonitor, root.brightnessPending + "%"]
    onRunningChanged: {
      if (running) return
      if (root.brightnessSetQueued) {
        root.brightnessSetQueued = false
        root.applyBrightness()
      } else {
        // Re-read once the write settled to pick up the real value.
        monitorStateProc.running = true
      }
    }
  }

  Process {
    id: scaleProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: if (!running) root.refresh()
  }

  Process {
    id: monitorToggleProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: if (!running) root.refresh()
  }

  // Rewrites the shell override file; Style picks the new base-size up through
  // its own file watch, so there is nothing to refresh here.
  Process {
    id: textSizeProc
    stdout: StdioCollector { waitForEnd: true }
  }

  Process {
    id: speedProc
    stdout: SplitParser { onRead: function(line) { root.updateSpeedLine(line) } }
    // Exit and stream-finished have no guaranteed order: when a failed exit
    // beat the collector and published the generic message, replace it with
    // the specific one once it lands.
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.speedStderr = String(text || "").trim()
        if (root.speedError !== "" && root.speedStderr !== "") root.speedError = root.speedStderr
      }
    }
    onExited: function(exitCode) {
      speedPhaseTimer.stop()

      if (root.speedPendingRun) {
        root.speedPendingRun = false
        root.speedExpectedStop = false
        if (root.page === "network") Qt.callLater(root.startSpeedTest)
        return
      }

      if (!root.speedExpectedStop && exitCode !== 0) {
        root.speedError = root.speedStderr || "Speed test failed"
        root.speedPhase = ""
        root.speedRunning = false
        return
      }

      root.speedExpectedStop = false
      root.finishSpeedPhase()
    }
  }

  // Keep the default sink live while the panel exists; without a tracker the
  // node can be torn down between reads and the volume would read 0.
  PwObjectTracker {
    objects: root.sink ? [root.sink] : []
  }

  // ------------------------------------------------------------------ timers
  Timer {
    id: pollTimer
    interval: 4000
    repeat: true
    running: root.opened
    onTriggered: root.refresh()
  }

  Timer {
    id: brightnessDebounce
    interval: 130
    repeat: false
    onTriggered: root.applyBrightness()
  }

  Timer {
    id: nightlightTimer
    interval: 900
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    id: dndTimer
    interval: 300
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    id: profileTimer
    interval: 300
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    id: speedPhaseTimer
    interval: 5000
    repeat: false
    onTriggered: root.stopSpeedPhase()
  }

  // Discovery can lapse (BlueZ times scans out), so nudge it back while the
  // Bluetooth page is open. `!btScanning` also stops the nudge once it is up.
  Timer {
    id: btScanTimer
    interval: 1000
    repeat: true
    running: root.page === "bluetooth" && root.btOn && !root.btScanning
    onTriggered: root.startBtDiscovery()
  }

  // An action that never surfaces (device vanished) clears its pending label.
  Timer {
    id: btPendingTimeout
    interval: 20000
    repeat: false
    onTriggered: root.btPending = ({})
  }

  // NetworkManager takes a moment to publish scan results after the scanner is
  // switched on; re-sync once it has had a chance to land and stop showing the
  // scanning state even if the scan came back empty.
  Timer {
    id: wifiScanSettle
    interval: 1500
    repeat: false
    onTriggered: {
      root.syncWifiNetworks()
      root.wifiScanning = false
    }
  }

  // Must outlast NetworkManager's 25s supplicant timeout: a wrong saved PSK
  // fails with WifiAuthTimeout at ~25s, and that failure has to land while the
  // action is still tracked so the row can show "Wrong password".
  Timer {
    id: wifiActionTimeout
    interval: 30000
    repeat: false
    onTriggered: {
      if (!root.wifiActionKind) return
      var reason = root.wifiActionKind === "connect" ? "Timed out connecting"
                 : root.wifiActionKind === "disconnect" ? "Timed out disconnecting"
                 : "Timed out forgetting"
      root.wifiFailureSsid = root.wifiActionSsid
      root.wifiFailureReason = reason
      root.wifiActionSsid = ""
      root.wifiActionKind = ""
      root.syncWifiNetworks()
    }
  }

  Connections {
    target: root.btAdapter
    function onDiscoveringChanged() {
      if (!root.btAdapter || !root.btAdapter.discovering) root.btOwnsDiscovery = false
    }
  }

  // Device connect/disconnect/forget update the row lists; use that to drop
  // the optimistic pending labels.
  Connections {
    target: root
    function onBtListsChanged() { root.syncBtPending() }
  }

  // Once Style's base size catches up to the previewed text-size stop, drop the
  // preview so the slider tracks the live value again.
  Connections {
    target: Style
    function onFontBaseSizeChanged() {
      if (root.textSizePreviewIndex >= 0
          && root.nearestTextStop(Style.font.baseSize) === root.textSizePreviewIndex)
        root.textSizePreviewIndex = -1
    }
  }

  // Scan results (and the device itself) churn as NetworkManager works; rebuild
  // the primitive row list whenever they change.
  onWifiNetworkObjectsChanged: syncWifiNetworks()
  onWifiDeviceChanged: {
    syncWifiNetworks()
    if (root.opened && root.page === "network") setWifiScanner(true)
  }

  // Never leave the radio scanning after this instance goes away.
  Component.onDestruction: {
    if (wifiScannerDevice) wifiScannerDevice.scannerEnabled = false
  }

  // -------------------------------------------------------------------- UI
  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(contentHost.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While the inline passphrase prompt is open the TextField owns the
      // keyboard; without this the "r"/"R" refresh shortcut (and j/k/h/l) would
      // steal keystrokes from the field.
      blocked: root.passwordSsid !== ""
      onCloseRequested: {
        // Esc walks back from a sub-page before it dismisses the panel.
        if (root.page !== "home") root.backToHome()
        else root.close()
      }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
      }

      Item {
        id: contentHost
        width: parent.width
        implicitHeight: root.page === "network" ? networkColumn.implicitHeight
                      : root.page === "bluetooth" ? bluetoothColumn.implicitHeight
                      : root.page === "display" ? displayColumn.implicitHeight
                      : root.page === "themes" ? themesColumn.implicitHeight
                      : column.implicitHeight

      Column {
        id: column
        width: parent.width
        visible: root.page === "home"
        spacing: Style.space(12)

        PanelHero {
          width: parent.width
          title: "Control Panel"
          meta: {
            var host = root.hostname !== "" ? root.hostname.toUpperCase() : "SYSTEM"
            return root.themeName !== "" ? host + "\n" + root.themeName : host
          }
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconComponent: Component {
            Text {
              text: root.glyphPanel
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
        }

        PanelSectionHeader {
          text: "QUICK"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Grid {
          id: quickGrid
          width: parent.width
          columns: 2
          spacing: Style.space(10)
          readonly property real tileW: (width - spacing) / 2

          ToggleTile {
            width: quickGrid.tileW
            icon: root.netIcon
            label: "Network"
            sub: root.netSubtitle
            checked: root.wifiOn
            showSwitch: root.hasWifi
            activateOnClick: true
            onActivated: root.openNetworkPage()
            onToggled: root.toggleWifi()
          }

          ToggleTile {
            width: quickGrid.tileW
            icon: root.btIcon
            label: "Bluetooth"
            sub: root.btSubtitle
            checked: root.btOn
            showSwitch: root.btAdapter !== null
            activateOnClick: true
            onActivated: root.openBluetoothPage()
            onToggled: root.toggleBluetooth()
          }

          ToggleTile {
            width: quickGrid.tileW
            icon: root.glyphMoon
            label: "Night Light"
            sub: root.nightlight ? "On" : "Off"
            checked: root.nightlight
            onToggled: root.toggleNightlight()
          }

          ToggleTile {
            width: quickGrid.tileW
            icon: root.dnd ? root.glyphBellOff : root.glyphBell
            label: "Do Not Disturb"
            sub: root.dnd ? "On" : "Off"
            checked: root.dnd
            onToggled: root.setDnd(!root.dnd)
          }
        }

        PanelSeparator { foreground: root.foreground }

        PanelSectionHeader {
          text: "DISPLAY"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        OpenRow {
          width: parent.width
          icon: root.glyphDisplay
          label: "Display"
          sub: root.displaySubtitle
          onClicked: root.openDisplayPage()
        }

        SliderRow {
          width: parent.width
          icon: root.glyphBrightness
          label: "Brightness"
          valueText: root.brightness >= 0 ? root.brightness + "%" : "--"
          value: root.brightness >= 0 ? root.brightness / 100 : 0
          onMoved: function(v) { root.stageBrightness(v) }
          onReleased: function(v) { root.commitBrightness(v) }
        }

        PanelSeparator { foreground: root.foreground }

        PanelSectionHeader {
          text: "AUDIO"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        SliderRow {
          width: parent.width
          icon: root.muted ? root.glyphMute : root.glyphVolume
          label: "Volume"
          sub: root.sinkName
          valueText: root.muted ? "Muted" : Math.round(root.volume * 100) + "%"
          value: root.muted ? 0 : root.volume
          onMoved: function(v) { root.setVolume(v) }
          onReleased: function(v) { root.setVolume(v) }
          onSecondary: root.toggleMute()
        }

        PanelSeparator { foreground: root.foreground }

        PanelSectionHeader {
          text: "THEMES"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        OpenRow {
          width: parent.width
          icon: root.glyphTheme
          label: "Change theme"
          sub: root.themeName
          onClicked: root.openThemePage()
        }

        PanelSeparator {
          visible: root.hasBattery || root.profileAvailable
          foreground: root.foreground
        }

        PanelSectionHeader {
          visible: root.hasBattery || root.profileAvailable
          text: "POWER"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Item {
          width: parent.width
          visible: root.hasBattery
          implicitHeight: Math.max(batteryIcon.implicitHeight, batteryLabels.implicitHeight)

          Text {
            id: batteryIcon
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.glyphBattery
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
          }

          Column {
            id: batteryLabels
            anchors.left: batteryIcon.right
            anchors.leftMargin: Style.space(10)
            anchors.right: batteryValue.right
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(1)

            Text {
              text: "Battery"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
            Text {
              text: UPower.onBattery ? "Discharging" : "Charging"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Text {
            id: batteryValue
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.batteryText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
          }
        }

        ButtonGroup {
          width: parent.width
          visible: root.profileAvailable
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.fontFamily
          options: [
            { value: "power-saver", label: "Saver" },
            { value: "balanced", label: "Balanced" },
            { value: "performance", label: "Perf" }
          ]
          value: root.powerProfile
          onChanged: function(v) { root.setPowerProfile(v) }
        }
      }

      // ------------------------------------------------------ network page
      Column {
        id: networkColumn
        width: parent.width
        visible: root.page === "network"
        spacing: Style.space(12)

        Item {
          width: parent.width
          implicitHeight: Math.max(backButton.implicitHeight, netHeaderName.implicitHeight)

          Button {
            id: backButton
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            iconText: root.glyphBack
            text: "Network"
            leftAlign: true
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            onClicked: root.backToHome()
          }

          Text {
            id: netHeaderName
            anchors.right: parent.right
            anchors.left: backButton.right
            anchors.leftMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: root.netSubtitle
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideRight
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        InfoRow {
          width: parent.width
          icon: root.netIcon
          label: "Connection"
          value: root.netIface !== "" ? root.netIface : root.netSubtitle
        }

        InfoRow {
          width: parent.width
          icon: root.glyphGlobe
          label: "IP address"
          value: root.netLocalIp !== "" ? root.netLocalIp : "--"
          sub: root.netGateway !== "" ? "Gateway " + root.netGateway : ""
        }

        InfoRow {
          width: parent.width
          icon: root.glyphTimer
          label: "Latency"
          value: root.netPing !== "" ? root.netPing : "--"
        }

        InfoRow {
          width: parent.width
          icon: root.glyphSpeedometer
          label: "Link speed"
          value: root.netLinkSpeed !== "" ? root.netLinkSpeed : "--"
        }

        PanelSeparator {
          visible: root.hasWifi
          foreground: root.foreground
        }

        Column {
          visible: root.hasWifi
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: root.wifiScanning ? "WI-FI NETWORKS · SCANNING" : "WI-FI NETWORKS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          // A busy room can turn up a long list; cap the height and scroll so
          // the card never grows past the screen.
          Flickable {
            id: wifiList
            width: parent.width
            visible: root.wifiNetworks.length > 0
            height: visible ? Math.min(wifiListContent.implicitHeight, Style.space(320)) : 0
            contentHeight: wifiListContent.implicitHeight
            clip: true
            interactive: contentHeight > height
            boundsBehavior: Flickable.StopAtBounds

            Column {
              id: wifiListContent
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.wifiNetworks
                delegate: WifiRow {
                  width: wifiListContent.width
                }
              }
            }
          }

          Text {
            width: parent.width
            visible: root.wifiNetworks.length === 0
            text: {
              if (!root.wifiOn) return "Turn Wi-Fi on to see networks"
              return root.wifiScanning ? "Scanning for networks…" : "No networks found"
            }
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }
        }

        PanelSeparator { foreground: root.foreground }

        Column {
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "DNS PROVIDER"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          ButtonGroup {
            width: parent.width
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            options: root.dnsProviders
            value: root.dnsProvider
            onChanged: function(v) { root.setDns(v) }
          }
        }

        PanelSeparator { foreground: root.foreground }

        BorderSurface {
          id: speedCard
          width: parent.width
          radius: Style.cornerRadius
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
          borderSpec: Border.controlSpec("normal", root.foreground, root.accent)
          implicitHeight: speedBody.implicitHeight + Style.space(24)

          Column {
            id: speedBody
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Style.space(14)
            anchors.rightMargin: Style.space(14)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(12)

            Item {
              width: parent.width
              implicitHeight: Math.max(downBox.implicitHeight, upBox.implicitHeight)

              Column {
                id: downBox
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Row {
                  spacing: Style.space(6)

                  Text {
                    text: root.glyphDownload
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Text {
                    text: "DOWNLOAD"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                Row {
                  spacing: Style.space(4)

                  Text {
                    text: root.speedDownText !== "" ? root.speedDownText : "--"
                    color: root.speedRunning && root.speedPhase === "down" ? root.accent : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.display
                    font.bold: true
                  }
                  Text {
                    text: "Mbps"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    anchors.baseline: parent.baseline
                  }
                }
              }

              Column {
                id: upBox
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Row {
                  spacing: Style.space(6)

                  Text {
                    text: root.glyphUpload
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Text {
                    text: "UPLOAD"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                Row {
                  spacing: Style.space(4)

                  Text {
                    text: root.speedUpText !== "" ? root.speedUpText : "--"
                    color: root.speedRunning && root.speedPhase === "up" ? root.accent : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.display
                    font.bold: true
                  }
                  Text {
                    text: "Mbps"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    anchors.baseline: parent.baseline
                  }
                }
              }
            }

            Button {
              width: parent.width
              bordered: true
              iconText: root.speedRunning ? "" : root.glyphSpeedometer
              text: root.speedRunning
                ? "Stop test"
                : (root.speedHasResult ? "Test again" : "Run speed test")
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              onClicked: root.speedRunning ? root.stopSpeedTest() : root.startSpeedTest()
            }

            Text {
              width: parent.width
              visible: root.speedError !== ""
              text: root.speedError
              color: ShellColor.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
            }
          }
        }
      }

      // ----------------------------------------------------- bluetooth page
      Column {
        id: bluetoothColumn
        width: parent.width
        visible: root.page === "bluetooth"
        spacing: Style.space(12)

        Item {
          width: parent.width
          implicitHeight: Math.max(btBackButton.implicitHeight, btHeaderName.implicitHeight)

          Button {
            id: btBackButton
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            iconText: root.glyphBack
            text: "Bluetooth"
            leftAlign: true
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            onClicked: root.backToHome()
          }

          Text {
            id: btHeaderName
            anchors.right: parent.right
            anchors.left: btBackButton.right
            anchors.leftMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: root.btScanning ? "Scanning…" : root.btSubtitle
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideRight
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        ToggleTile {
          width: parent.width
          icon: root.btIcon
          label: "Bluetooth"
          sub: root.btSubtitle
          checked: root.btOn
          showSwitch: root.btAdapter !== null
          onToggled: root.toggleBluetooth()
        }

        // The device list is capped and scrolls: a busy room can discover a
        // dozen devices and the card must not grow past the screen.
        Flickable {
          id: btList
          width: parent.width
          visible: root.btRowCount > 0
          height: visible ? Math.min(btListContent.implicitHeight, Style.space(320)) : 0
          contentHeight: btListContent.implicitHeight
          clip: true
          interactive: contentHeight > height
          boundsBehavior: Flickable.StopAtBounds

          Column {
            id: btListContent
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              visible: root.btConnectedRows.length > 0
              text: "CONNECTED"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
            Repeater {
              model: root.btConnectedRows
              delegate: BtDeviceRow {
                width: btListContent.width
                section: "connected"
              }
            }

            PanelSectionHeader {
              visible: root.btKnownRows.length > 0
              text: "PAIRED"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
            Repeater {
              model: root.btKnownRows
              delegate: BtDeviceRow {
                width: btListContent.width
                section: "known"
              }
            }

            PanelSectionHeader {
              visible: root.btAvailableRows.length > 0
              text: "AVAILABLE"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
            Repeater {
              model: root.btAvailableRows
              delegate: BtDeviceRow {
                width: btListContent.width
                section: "available"
              }
            }
          }
        }

        Text {
          width: parent.width
          visible: root.btAdapter === null || root.btRowCount === 0
          text: {
            if (root.btAdapter === null) return "No Bluetooth adapter"
            if (!root.btOn) return "Turn Bluetooth on to see devices"
            return "Scanning for nearby devices…"
          }
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }
      }

      // ------------------------------------------------------- display page
      Column {
        id: displayColumn
        width: parent.width
        visible: root.page === "display"
        spacing: Style.space(12)

        Item {
          width: parent.width
          implicitHeight: Math.max(dispBackButton.implicitHeight, dispHeaderName.implicitHeight)

          Button {
            id: dispBackButton
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            iconText: root.glyphBack
            text: "Display"
            leftAlign: true
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            onClicked: root.backToHome()
          }

          Text {
            id: dispHeaderName
            anchors.right: parent.right
            anchors.left: dispBackButton.right
            anchors.leftMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: root.displaySubtitle
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideRight
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        SliderRow {
          width: parent.width
          visible: root.brightness >= 0
          icon: root.glyphBrightness
          label: "Brightness"
          valueText: root.brightness >= 0 ? root.brightness + "%" : "--"
          value: root.brightness >= 0 ? root.brightness / 100 : 0
          onMoved: function(v) { root.stageBrightness(v) }
          onReleased: function(v) { root.commitBrightness(v) }
        }

        SliderRow {
          width: parent.width
          icon: root.glyphDisplay
          label: "Text size"
          valueText: root.textSizePx + " px"
          value: root.textSizeIndex
          maxValue: root.textSizeStops.length - 1
          stepSize: 1
          integerValue: true
          tickCount: root.textSizeStops.length
          onMoved: function(v) { root.textSizePreviewIndex = Math.round(v) }
          onReleased: function(v) { root.setTextSize(root.textSizeStops[Math.round(v)]) }
        }

        PanelSeparator { foreground: root.foreground }

        PanelSectionHeader {
          text: "SCALE"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        ButtonGroup {
          width: parent.width
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.fontFamily
          options: root.scaleOptions
          value: root.currentScaleValue
          onChanged: function(v) { root.setMonitorScale(v) }
        }

        PanelSeparator {
          visible: root.displays.length > 1
          foreground: root.foreground
        }

        PanelSectionHeader {
          visible: root.displays.length > 1
          text: "DISPLAYS"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Repeater {
          model: root.displays
          delegate: DisplayRow {
            width: displayColumn.width
          }
        }
      }

      Column {
        id: themesColumn
        width: parent.width
        visible: root.page === "themes"
        spacing: Style.space(12)

        Item {
          width: parent.width
          implicitHeight: Math.max(themeBackButton.implicitHeight, themeHeaderName.implicitHeight)

          Button {
            id: themeBackButton
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            iconText: root.glyphBack
            text: "Themes"
            leftAlign: true
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            onClicked: root.backToHome()
          }

          Text {
            id: themeHeaderName
            anchors.right: parent.right
            anchors.left: themeBackButton.right
            anchors.leftMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: root.themeName
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideRight
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // The highlighted theme's preview, shown before the switch is committed.
        BorderSurface {
          width: parent.width
          visible: root.themePreviewSource !== ""
          radius: Style.cornerRadius
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
          borderSpec: Border.controlSpec("normal", root.foreground, root.accent)
          implicitHeight: Math.round(width * 9 / 16) + Style.space(12)

          Item {
            id: themePreviewImage
            anchors.fill: parent
            anchors.margins: Style.space(6)
            layer.enabled: true
            layer.effect: MultiEffect {
              maskEnabled: true
              maskSource: themePreviewMask
            }

            Image {
              anchors.fill: parent
              source: root.themePreviewSource
              fillMode: Image.PreserveAspectCrop
              asynchronous: true
              cache: true
              sourceSize.width: 720
            }
          }

          Item {
            id: themePreviewMask
            anchors.fill: themePreviewImage
            visible: false
            layer.enabled: true

            Rectangle {
              anchors.fill: parent
              radius: Style.space(8)
              color: "white"
            }
          }
        }

        Item {
          width: parent.width
          implicitHeight: Math.max(themeSelectedLabel.implicitHeight, themeApplyButton.implicitHeight, Style.space(32))

          Text {
            id: themeSelectedLabel
            anchors.left: parent.left
            anchors.right: themeApplyButton.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: root.themeSelectedName !== "" ? root.themeSelectedName : "Select a theme"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          Button {
            id: themeApplyButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.themeIsCurrent ? "Current theme" : (root.themeSetting ? "Applying…" : "Set theme")
            enabled: !root.themeIsCurrent && !root.themeSetting && root.themeSelected !== ""
            opacity: enabled ? 1 : 0.5
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            onClicked: root.applyTheme()
          }
        }

        PanelSeparator { foreground: root.foreground }

        PanelSectionHeader {
          text: "INSTALLED"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        // A machine can install a couple dozen themes; cap the list and let it
        // scroll like the Bluetooth device list so the card never grows past
        // the screen.
        Flickable {
          id: themeList
          width: parent.width
          visible: root.themeRows.length > 0
          height: visible ? Math.min(themeListContent.implicitHeight, Style.space(320)) : 0
          contentHeight: themeListContent.implicitHeight
          clip: true
          interactive: contentHeight > height
          boundsBehavior: Flickable.StopAtBounds

          Column {
            id: themeListContent
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.themeRows
              delegate: ThemeRow {
                width: themeListContent.width
              }
            }
          }
        }
      }
      }
    }
  }

  // A clickable tile: icon, label, subtitle and a trailing on/off switch.
  // By default the whole tile toggles and the switch only mirrors the state.
  // With `activateOnClick` the body instead emits `activated()` (used to open
  // a sub-page) while the switch stays interactive and emits `toggled()`.
  component ToggleTile: BorderSurface {
    id: tile

    property string icon: ""
    property string label: ""
    property string sub: ""
    property bool checked: false
    property bool showSwitch: true
    property bool activateOnClick: false
    signal toggled()
    signal activated()

    readonly property bool hot: tileMouse.containsMouse
    // A board tile wants to read as a card, not as a transparent row: nudge
    // the resting fill above the shell's 4% row hover and pull it stronger
    // under the cursor. Both derive from the theme's foreground so they keep
    // working on light themes.
    readonly property color restFill: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
    readonly property color hotFill: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)

    radius: Style.cornerRadius
    color: hot ? hotFill : restFill
    borderSpec: Border.controlSpec(hot ? "hover-cursor" : "normal", root.foreground, root.accent)
    implicitHeight: Math.max(tileBody.implicitHeight + Style.space(18), Style.space(50))

    MouseArea {
      id: tileMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: tile.activateOnClick ? tile.activated() : tile.toggled()
    }

    Item {
      id: tileBody
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      implicitHeight: Math.max(tileIcon.implicitHeight, tileLabels.implicitHeight, tileSwitch.implicitHeight)

      Text {
        id: tileIcon
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: tile.icon
        color: tile.checked ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.heading
      }

      Column {
        id: tileLabels
        anchors.left: tileIcon.right
        anchors.leftMargin: Style.space(10)
        anchors.right: tileSwitch.visible ? tileSwitch.left : parent.right
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Text {
          text: tile.label
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
          width: parent.width
        }
        Text {
          text: tile.sub
          visible: text !== ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          width: parent.width
        }
      }

      ToggleSwitch {
        id: tileSwitch
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        visible: tile.showSwitch
        checked: tile.checked
        interactive: tile.activateOnClick
        foreground: root.foreground
        accent: root.accent
        onToggled: tile.toggled()
      }
    }
  }

  // A labelled row with a slider underneath. The label row carries an icon,
  // title, optional subtitle and a right-aligned value; the slider spans the
  // full width so it is comfortable to grab.
  component SliderRow: Item {
    id: row

    property string icon: ""
    property string label: ""
    property string sub: ""
    property string valueText: ""
    property real value: 0
    // Defaults suit the 0..1 volume/brightness sliders; the Display page's
    // text-size row overrides them for its discrete stops.
    property real maxValue: 1
    property real stepSize: 0.02
    property bool integerValue: false
    property int tickCount: 0
    signal moved(real v)
    signal released(real v)
    signal secondary()

    implicitHeight: sliderBody.implicitHeight

    Column {
      id: sliderBody
      width: parent.width
      spacing: Style.space(6)

      Item {
        width: parent.width
        implicitHeight: Math.max(rowIcon.implicitHeight, rowLabels.implicitHeight, rowValue.implicitHeight)

        Text {
          id: rowIcon
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: row.icon
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading
        }

        Column {
          id: rowLabels
          anchors.left: rowIcon.right
          anchors.leftMargin: Style.space(10)
          anchors.right: rowValue.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(1)

          Text {
            text: row.label
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
            width: parent.width
          }
          Text {
            text: row.sub
            visible: text !== ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            width: parent.width
          }
        }

        Text {
          id: rowValue
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: row.valueText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }
      }

      PanelSlider {
        width: parent.width
        bar: root.bar
        value: row.value
        minimum: 0
        maximum: row.maxValue
        step: row.stepSize
        integer: row.integerValue
        tickCount: row.tickCount
        onMoved: function(v) { row.moved(v) }
        onReleased: function(v) { row.released(v) }
        onRightClicked: row.secondary()
      }
    }
  }

  // A read-only detail row: icon, title (with optional subtitle) and a
  // right-aligned value. Used by the Network page.
  component InfoRow: Item {
    id: info

    property string icon: ""
    property string label: ""
    property string value: ""
    property string sub: ""

    implicitHeight: Math.max(infoIcon.implicitHeight, infoLabels.implicitHeight, infoValue.implicitHeight)

    Text {
      id: infoIcon
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: info.icon
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.heading
    }

    Column {
      id: infoLabels
      anchors.left: infoIcon.right
      anchors.leftMargin: Style.space(10)
      anchors.right: infoValue.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      Text {
        text: info.label
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        width: parent.width
      }
      Text {
        text: info.sub
        visible: text !== ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        width: parent.width
      }
    }

    Text {
      id: infoValue
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: info.value
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
    }
  }

  // A Bluetooth device row: icon, name and a status line that also shows the
  // optimistic pending action. Left click connects/disconnects/pairs, right
  // click forgets a remembered device.
  component BtDeviceRow: BorderSurface {
    id: btRow

    required property var modelData
    required property string section

    readonly property var row: btRow.modelData
    readonly property bool hot: btRowMouse.containsMouse
    readonly property bool connected: row ? row.connected === true : false
    readonly property string pending: root.btPendingAction(row ? row.address : "")
    readonly property string status: {
      if (!row) return ""
      if (pending === "forgetting") return "Forgetting…"
      if (pending === "disconnecting") return "Disconnecting…"
      if (pending === "connecting") return "Connecting…"
      if (connected) return row.batteryAvailable ? Math.round(row.battery * 100) + "%" : "Connected"
      if (section === "available") return "Tap to pair"
      return "Tap to connect"
    }

    readonly property color restFill: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
    readonly property color hotFill: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)

    radius: Style.cornerRadius
    color: hot ? hotFill : restFill
    borderSpec: Border.controlSpec(hot ? "hover-cursor" : "normal", root.foreground, root.accent)
    implicitHeight: Math.max(btRowBody.implicitHeight + Style.space(18), Style.space(50))

    MouseArea {
      id: btRowMouse
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      cursorShape: Qt.PointingHandCursor
      onClicked: function(mouse) {
        if (mouse.button === Qt.RightButton) root.btSecondary(btRow.row, btRow.section)
        else root.btActivate(btRow.row)
      }
      onPressAndHold: root.btSecondary(btRow.row, btRow.section)
    }

    Item {
      id: btRowBody
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      implicitHeight: Math.max(btRowIcon.implicitHeight, btRowLabels.implicitHeight)

      Text {
        id: btRowIcon
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: btRow.connected ? root.glyphBtConnected : root.glyphBtOn
        color: btRow.connected ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.heading
      }

      Column {
        id: btRowLabels
        anchors.left: btRowIcon.right
        anchors.leftMargin: Style.space(10)
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Text {
          width: parent.width
          text: btRow.row ? btRow.row.label : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }
        Text {
          width: parent.width
          text: btRow.status
          color: btRow.connected ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }

  // A Wi-Fi network row: signal bars, SSID, lock for protected networks and a
  // status line. Left click connects (or disconnects a connected one, or opens
  // the inline passphrase prompt); right click / press-and-hold forgets a saved
  // but disconnected network.
  component WifiRow: BorderSurface {
    id: wifiRow

    required property var modelData
    readonly property var row: wifiRow.modelData
    readonly property bool isConnected: row ? row.connected === true : false
    readonly property bool requiresCredentials: row ? root.requiresWifiCredentials(row.security) : false
    readonly property bool isEnterprise: row
      ? (row.security === WifiSecurityType.Wpa2Eap || row.security === WifiSecurityType.WpaEap)
      : false
    readonly property bool canForget: root.canForgetWifi(row)
    readonly property bool isBusy: root.wifiActionKind !== "" && root.wifiActionSsid === (row ? row.ssid : "")
    readonly property bool isFailed: root.wifiFailureReason !== "" && root.wifiFailureSsid === (row ? row.ssid : "")
    readonly property bool isPasswordOpen: root.passwordSsid !== "" && root.passwordSsid === (row ? row.ssid : "")
    readonly property bool hot: rowMouse.containsMouse

    function submitCredentials() {
      if (!row || root.wifiBusy || root.passwordText.length === 0) return
      if (!isEnterprise) return root.connectWifiWithPassphrase(row.ssid, root.passwordText)
      if (root.identityText.length > 0) root.connectWifiEnterprise(row.ssid, root.identityText, root.passwordText)
    }

    readonly property string statusText: {
      if (!row) return ""
      if (isPasswordOpen) return ""
      if (isBusy && root.wifiActionKind === "connect") return "Connecting…"
      if (isBusy && root.wifiActionKind === "disconnect") return "Disconnecting…"
      if (isBusy && root.wifiActionKind === "forget") return "Forgetting…"
      if (isFailed) return root.wifiFailureReason || "Failed"
      if (isConnected) return "Connected"
      if (requiresCredentials && !row.known) return "Password required"
      return ""
    }

    readonly property color statusColor: {
      if (isFailed) return ShellColor.urgent
      if (isConnected) return root.foreground
      return root.dim
    }

    readonly property color restFill: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
    readonly property color hotFill: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)

    radius: Style.cornerRadius
    color: hot ? hotFill : restFill
    borderSpec: Border.controlSpec(hot ? "hover-cursor" : "normal", root.foreground, root.accent)
    implicitHeight: wifiRowBody.implicitHeight + Style.space(18)
                  + (isPasswordOpen ? wifiPasswordPanel.implicitHeight + Style.space(10) : 0)

    // Watch the live network behind this row so an action lands (and a failed
    // connect can reprompt) without needing the list to recycle.
    Connections {
      target: wifiRow.row ? root.networkForSsid(wifiRow.row.ssid) : null
      function onConnectionFailed(reason) {
        var ours = root.wifiActionKind === "connect" && root.wifiActionSsid === (wifiRow.row.ssid || "")
        root.failWifiAction(root.networkForSsid(wifiRow.row.ssid), reason)
        if (ours && NetModel.shouldRepromptPassphrase(reason, wifiRow.requiresCredentials, root.connectionFailReasons))
          root.openPasswordPrompt(wifiRow.row.ssid)
      }
      function onConnectedChanged() {
        if (wifiRow.row) root.checkWifiActionCompletion(root.networkForSsid(wifiRow.row.ssid))
      }
      function onKnownChanged() {
        if (wifiRow.row) root.checkWifiActionCompletion(root.networkForSsid(wifiRow.row.ssid))
      }
      function onStateChangingChanged() {
        if (wifiRow.row) root.checkWifiActionCompletion(root.networkForSsid(wifiRow.row.ssid))
      }
    }

    MouseArea {
      id: rowMouse
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      height: wifiRowBody.implicitHeight + Style.space(18)
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      cursorShape: Qt.PointingHandCursor
      enabled: !root.wifiBusy
      onClicked: function(mouse) {
        if (!wifiRow.row) return
        if (mouse.button === Qt.RightButton) root.wifiSecondary(wifiRow.row)
        else root.activateWifiRow(wifiRow.row)
      }
      onPressAndHold: root.wifiSecondary(wifiRow.row)
    }

    Item {
      id: wifiRowBody
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.topMargin: Style.space(9)
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(12)
      implicitHeight: Math.max(wifiRowIcon.implicitHeight, wifiRowLabels.implicitHeight, wifiRowLock.implicitHeight)

      Text {
        id: wifiRowIcon
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: wifiRow.row ? root.wifiIconFor(wifiRow.row.signal) : ""
        color: wifiRow.isConnected ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.heading
      }

      Text {
        id: wifiRowLock
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        visible: wifiRow.requiresCredentials
        text: root.glyphWifiLock
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      Column {
        id: wifiRowLabels
        anchors.left: wifiRowIcon.right
        anchors.leftMargin: Style.space(10)
        anchors.right: wifiRowLock.visible ? wifiRowLock.left : parent.right
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Text {
          width: parent.width
          text: wifiRow.row ? (wifiRow.row.ssid !== "" ? wifiRow.row.ssid : "Hidden network") : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }
        Text {
          width: parent.width
          visible: wifiRow.statusText !== ""
          text: wifiRow.statusText
          color: wifiRow.statusColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }

    // Inline passphrase prompt, shown when a protected network has no saved
    // credentials or a connect failed with the saved passphrase. Enterprise
    // networks also ask for an identity. Enter or the check button connects;
    // Esc cancels.
    Item {
      id: wifiPasswordPanel
      visible: wifiRow.isPasswordOpen
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: wifiRowBody.bottom
      anchors.topMargin: Style.space(6)
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(12)
      implicitHeight: (wifiIdField.visible ? wifiIdField.implicitHeight + Style.space(4) : 0)
                    + wifiPwField.implicitHeight

      TextField {
        id: wifiIdField
        visible: wifiRow.isEnterprise && !wifiRow.isBusy && !wifiRow.isFailed
        anchors.left: parent.left
        anchors.right: wifiConnectBtn.left
        anchors.top: parent.top
        anchors.rightMargin: Style.space(6)
        placeholderText: "Identity (user@domain)"
        foreground: root.foreground
        accent: root.accent
        horizontalPadding: Style.spacing.controlGap
        verticalPadding: Style.spacing.controlPaddingY
        enabled: !wifiRow.isBusy
        text: wifiRow.isPasswordOpen ? root.identityText : ""
        onAccepted: wifiPwField.forceActiveFocus()
        onTextChanged: if (wifiRow.isPasswordOpen && text !== root.identityText) root.identityText = text
        Keys.onEscapePressed: root.cancelPasswordPrompt()
        onVisibleChanged: if (visible) Qt.callLater(forceActiveFocus)
        Component.onCompleted: if (visible) Qt.callLater(forceActiveFocus)
      }

      TextField {
        id: wifiPwField
        visible: !wifiRow.isBusy && !wifiRow.isFailed
        anchors.left: parent.left
        anchors.right: wifiConnectBtn.left
        anchors.bottom: parent.bottom
        anchors.rightMargin: Style.space(6)
        password: true
        placeholderText: "Passphrase"
        foreground: root.foreground
        accent: root.accent
        horizontalPadding: Style.spacing.controlGap
        verticalPadding: Style.spacing.controlPaddingY
        enabled: !wifiRow.isBusy
        text: wifiRow.isPasswordOpen ? root.passwordText : ""
        onAccepted: wifiRow.submitCredentials()
        onTextChanged: if (wifiRow.isPasswordOpen && text !== root.passwordText) root.passwordText = text
        Keys.onEscapePressed: root.cancelPasswordPrompt()
        onVisibleChanged: if (visible && !wifiRow.isEnterprise) Qt.callLater(forceActiveFocus)
        Component.onCompleted: if (visible && !wifiRow.isEnterprise) Qt.callLater(forceActiveFocus)
      }

      BorderSurface {
        visible: wifiRow.isBusy || wifiRow.isFailed
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        implicitHeight: Style.spacing.controlHeight
        color: Style.normalFillFor(root.foreground)
        borderSpec: Border.controlSpec("normal", root.foreground, root.accent)

        Text {
          anchors.fill: parent
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
          text: wifiRow.isFailed ? "Wrong password" : "Connecting…"
          color: wifiRow.isFailed ? ShellColor.urgent : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }

      PanelActionButton {
        id: wifiConnectBtn
        visible: !wifiRow.isBusy && !wifiRow.isFailed
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        enabled: wifiRow.row && wifiPwField.text.length > 0 && (!wifiRow.isEnterprise || wifiIdField.text.length > 0)
        iconText: root.glyphWifiCheck
        tooltipText: "Connect"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: wifiRow.submitCredentials()
      }
    }
  }

  // A full-width card that opens a sub-page: icon, title, optional subtitle and
  // a trailing chevron. Used as the Display section's entry point.
  component OpenRow: BorderSurface {
    id: openRow

    property string icon: ""
    property string label: ""
    property string sub: ""
    signal clicked()

    readonly property bool hot: openMouse.containsMouse
    readonly property color restFill: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
    readonly property color hotFill: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)

    radius: Style.cornerRadius
    color: hot ? hotFill : restFill
    borderSpec: Border.controlSpec(hot ? "hover-cursor" : "normal", root.foreground, root.accent)
    implicitHeight: Math.max(openBody.implicitHeight + Style.space(18), Style.space(50))

    MouseArea {
      id: openMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: openRow.clicked()
    }

    Item {
      id: openBody
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      implicitHeight: Math.max(openIcon.implicitHeight, openLabels.implicitHeight, openChevron.implicitHeight)

      Text {
        id: openIcon
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: openRow.icon
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.heading
      }

      Column {
        id: openLabels
        anchors.left: openIcon.right
        anchors.leftMargin: Style.space(10)
        anchors.right: openChevron.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Text {
          width: parent.width
          text: openRow.label
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }
        Text {
          width: parent.width
          visible: text !== ""
          text: openRow.sub
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Text {
        id: openChevron
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: root.glyphForward
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
    }
  }

  // A monitor row on the Display page: icon, name (marked when focused) and a
  // check when enabled. Click toggles the monitor, unless it is the last one on.
  component DisplayRow: BorderSurface {
    id: displayRow

    required property var modelData
    readonly property var display: displayRow.modelData
    readonly property bool canToggle: display && (!display.enabled || root.enabledDisplayCount > 1)
    readonly property bool hot: displayMouse.containsMouse && canToggle

    readonly property color restFill: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
    readonly property color hotFill: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)

    radius: Style.cornerRadius
    color: hot ? hotFill : restFill
    borderSpec: Border.controlSpec(hot ? "hover-cursor" : "normal", root.foreground, root.accent)
    opacity: canToggle ? 1 : 0.45
    implicitHeight: Math.max(displayBody.implicitHeight + Style.space(18), Style.space(50))

    MouseArea {
      id: displayMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: displayRow.canToggle ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: if (displayRow.canToggle) root.toggleDisplay(displayRow.display.name, displayRow.display.enabled)
    }

    Item {
      id: displayBody
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      implicitHeight: Math.max(displayIcon.implicitHeight, displayLabels.implicitHeight, displayCheck.implicitHeight)

      Text {
        id: displayIcon
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: root.glyphDisplay
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.heading
      }

      Column {
        id: displayLabels
        anchors.left: displayIcon.right
        anchors.leftMargin: Style.space(10)
        anchors.right: displayCheck.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Text {
          width: parent.width
          text: {
            if (!displayRow.display) return ""
            return displayRow.display.name + (displayRow.display.focused ? " · focused" : "")
          }
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }
        Text {
          width: parent.width
          visible: text !== ""
          text: {
            if (!displayRow.display) return ""
            return Math.round(displayRow.display.width) + "×" + Math.round(displayRow.display.height)
          }
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Text {
        id: displayCheck
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: displayRow.display && displayRow.display.enabled ? "󰄬" : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
    }
  }

  // A theme row on the Themes page: a rounded preview thumbnail, the name and a
  // check on the active theme. Clicking highlights the theme for preview; the
  // switch itself is committed from the "Set theme" button above the list.
  component ThemeRow: BorderSurface {
    id: themeRow

    required property var modelData
    readonly property var entry: themeRow.modelData
    readonly property bool selected: entry !== null && entry.slug === root.themeEffectiveSlug
    readonly property bool current: entry !== null && entry.slug === root.currentThemeSlug
    readonly property bool hot: themeRowMouse.containsMouse

    readonly property color restFill: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
    readonly property color hotFill: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
    readonly property color selectedFill: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.16)

    radius: Style.cornerRadius
    color: selected ? selectedFill : (hot ? hotFill : restFill)
    borderSpec: Border.controlSpec(selected ? "selected" : (hot ? "hover-cursor" : "normal"), root.foreground, root.accent)
    implicitHeight: Math.max(themeRowBody.implicitHeight + Style.space(12), Style.space(52))

    MouseArea {
      id: themeRowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: if (themeRow.entry !== null) root.selectTheme(themeRow.entry.slug)
    }

    Item {
      id: themeRowBody
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      implicitHeight: Math.max(themeRowThumb.height, themeRowName.implicitHeight, themeRowCheck.implicitHeight)

      Item {
        id: themeRowThumb
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(60)
        height: Style.space(34)
        layer.enabled: true
        layer.effect: MultiEffect {
          maskEnabled: true
          maskSource: themeRowMask
        }

        Image {
          anchors.fill: parent
          source: themeRow.entry !== null && themeRow.entry.preview !== "" ? "file://" + themeRow.entry.preview : ""
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          cache: true
          sourceSize.width: 160
        }
      }

      Item {
        id: themeRowMask
        anchors.fill: themeRowThumb
        visible: false
        layer.enabled: true

        Rectangle {
          anchors.fill: parent
          radius: Style.space(5)
          color: "white"
        }
      }

      Text {
        id: themeRowName
        anchors.left: themeRowThumb.right
        anchors.leftMargin: Style.space(10)
        anchors.right: themeRowCheck.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        text: themeRow.entry !== null ? themeRow.entry.name : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      Text {
        id: themeRowCheck
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: themeRow.current ? "󰄬" : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
    }
  }
}
