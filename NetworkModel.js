// Pure helpers for the Control Panel's Wi-Fi list on the Network page.
//
// Ported from Omarchy's built-in `omarchy.network` panel model so the two
// behave identically. Kept in a plain JS module (no QML imports) so the
// panel's QML only carries state and UI.

// Wi-Fi signal bars for 0..100 signal strength.
function wifiIconFor(strength) {
  var icons = ["󰤯", "󰤟", "󰤢", "󰤥", "󰤨"]
  var index = Math.max(0, Math.min(4, Math.ceil(strength / 20) - 1))
  return icons[index]
}

// A scan result flattened to primitives only.
//
// Rows become list-model data, so a WifiNetwork here would put a live QObject
// wrapper in every delegate's `modelData`. NetworkManager churn (scans, AP
// removals) can destroy the object while a delegate is still incubating, which
// segfaults quickshell on the dangling wrapper. Callers that need the object
// resolve it by SSID at click time instead.
function wifiRow(network) {
  if (!network) return null
  return {
    connected: !!network.connected,
    known: !!network.known,
    ssid: network.name || "",
    signal: Math.round((network.signalStrength || 0) * 100),
    security: network.security
  }
}

// Connected first, then saved networks, then by descending signal.
function sortWifiRows(rows) {
  var nets = Array.isArray(rows) ? rows.slice() : []
  nets.sort(function(a, b) {
    if (a.connected !== b.connected) return a.connected ? -1 : 1
    if (a.known !== b.known) return a.known ? -1 : 1
    return b.signal - a.signal
  })
  return nets
}

// OWE (Enhanced Open) encrypts traffic without authenticating the user, so it
// has no credentials to collect. Only explicit passwordless types bypass the
// prompt; unknown security stays credentialed as the conservative fallback.
function requiresCredentials(security, openSecurity, oweSecurity) {
  return security !== openSecurity && security !== oweSecurity
}

// Human-readable reason for a failed connect, given whether the network needs
// credentials. `reasons` is the caller's ConnectionFailReason enum map.
function networkFailureReason(reason, needsCredentials, reasons) {
  var r = reasons || {}
  if (needsCredentials && reason === r.NoSecrets) return "Passphrase required"
  if (needsCredentials && reason === r.WifiAuthTimeout) return "Wrong password"
  if (reason === r.WifiNetworkLost) return "Network lost"
  if (reason === r.WifiClientDisconnected) return "Disconnected"
  if (reason === r.WifiClientFailed) return "Connection failed"
  return "Failed to connect"
}

// Whether a failed connect should reopen the passphrase prompt. NoSecrets means
// credentials are missing for a network that actually uses them; an auth timeout
// on such a network means the saved passphrase is wrong, so the user needs a
// chance to re-enter it (connectWithPsk overwrites the stored PSK on submit).
function shouldRepromptPassphrase(reason, needsCredentials, reasons) {
  var r = reasons || {}
  if (!needsCredentials) return false
  return reason === r.NoSecrets || reason === r.WifiAuthTimeout
}

// Creates and activates an 802.1X (WPA-Enterprise) profile. The password
// arrives on stdin and reaches nmcli through the scriptable `connection edit`
// editor -- argv is world-readable in /proc, so the secret must never be an
// argument (printf is a bash builtin, so no extra process spawns with it
// either). Invoke as: bash -c <script> nmcli-eap <ssid> <identity>.
var enterpriseConnectScript =
  "u=$(uuidgen); IFS= read -r pw;" +
  " nmcli connection add type wifi con-name \"$1\" ssid \"$1\" connection.uuid \"$u\"" +
  " wifi-sec.key-mgmt wpa-eap 802-1x.eap peap 802-1x.phase2-auth mschapv2" +
  " 802-1x.identity \"$2\" 802-1x.auth-timeout 8 >/dev/null" +
  " && printf 'set 802-1x.password %s\\nsave\\nquit\\n' \"$pw\" | nmcli connection edit uuid \"$u\" >/dev/null" +
  " && nmcli connection up uuid \"$u\"" +
  " || { nmcli connection delete uuid \"$u\" >/dev/null 2>&1; false; }"
