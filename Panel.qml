import QtQuick
import QtQuick.Controls as QC
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

Panel {
  id: root

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  property bool connected: false
  property string connName: ""
  property bool needsConfirm: false
  property string portal: ""
  property string device: ""
  property string ip: ""
  property string gateway: ""
  property string dns: ""
  property string since: ""
  property int sinceEpoch: 0
  property string publicIp: ""
  property string country: ""
  property string city: ""
  property string lastError: ""
  property string durationText: ""

  // What the widget itself is doing: "connecting", "disconnecting",
  // "switching", "authenticating" or "pinning" ("" = idle). `busy` is
  // derived so every `enabled: !root.busy` binding keeps working.
  property string phase: ""
  readonly property bool busy: phase !== ""
  // True while the phase reflects an action started OUTSIDE the widget
  // (CLI `nmcli con up`, a terminal `smc-vpn-refresh`), detected via the
  // status helper. Internal actions clear it.
  property bool externalPhase: false

  // Authenticating details.
  property int authPid: 0            // pid of a running smc-vpn-refresh (0 = unknown)
  property bool authGraceOver: false // 2.5s grace before "waiting for you" UI + notification
  property int authElapsed: 0        // seconds spent authenticating
  property bool authCancelRequested: false
  property bool authRoundOpen: false // notification round open (from auth start to final outcome)
  property string refreshError: ""   // last "ERROR: ..." line from smc-vpn-refresh stderr
  property int notifyId: 0           // notification id for replace-on-finish

  // Multi-endpoint support (populated by gp-vpn-status >= v2; empty for
  // legacy single-endpoint setups, which keep the old behaviour).
  property var endpoints: []             // [{id, portal, connName, state, connected}]
  property string endpointId: ""         // selected endpoint id
  readonly property bool hasEndpoints: root.endpoints.length > 0

  property bool _wasTryingConnect: false
  property bool ipCopied: false
  property bool publicIpCopied: false

  readonly property string helperPath: Qt.resolvedUrl("gp-vpn-status").toString().replace("file://", "")

  // Glyphs (Nerd Font / Material Design Icons range):
  //   F0565 security-network  — connected
  //   F099C shield-off        — disconnected
  //   F18B7 shield-alert      — waiting for browser sign-in (present in
  //                             JetBrainsMono Nerd Font, verified)
  readonly property string iconConnected: "\u{F0565}"
  readonly property string iconDisconnected: "\u{F099C}"
  readonly property string iconAuthPending: "\u{F18B7}"

  function formatDuration(ms) {
    var sec = Math.floor(ms / 1000)
    if (sec < 0) return ""
    if (sec < 60) return "just now"
    var min = Math.floor(sec / 60)
    var h = Math.floor(min / 60)
    var d = Math.floor(h / 24)
    if (d > 0) return d + "d " + (h % 24) + "h"
    if (h > 0) return h + "h " + (min % 60) + "m"
    return min + "m"
  }

  function mmss(totalSec) {
    var s = Math.max(0, Math.floor(totalSec))
    return Math.floor(s / 60) + ":" + ("0" + (s % 60)).slice(-2)
  }

  function statusLabel() {
    if (phase === "connecting") return "Connecting…"
    if (phase === "disconnecting") return "Disconnecting…"
    if (phase === "switching") return "Switching…"
    if (phase === "pinning") return "Saving…"
    if (phase === "authenticating") return authGraceOver ? "Waiting for sign-in…" : "Authenticating…"
    return connected ? "Connected" : "Disconnected"
  }

  // Central phase switch: manages the auth timers; the notification round
  // stays open (authRoundOpen) until the final outcome arrives — the [2/4]
  // "browser done, connecting now" transition does not close it.
  function setPhase(p) {
    if (root.phase === p) return
    var wasAuth = root.phase === "authenticating"
    root.phase = p
    if (p === "authenticating") {
      root.authElapsed = 0
      root.authGraceOver = false
      root.authCancelRequested = false
      root.authRoundOpen = true
      authGraceTimer.restart()
      authElapsedTimer.restart()
    } else if (wasAuth) {
      stopAuthTimers()
    }
  }

  function stopAuthTimers() {
    authGraceTimer.stop()
    authElapsedTimer.stop()
    authNotifyRetry.stop()
  }

  // Close the auth round and replace the pending notification with the
  // outcome. Callers pass the authoritative outcome (exit code for the
  // widget-started flow, current state for the externally-started one).
  function finishAuthRound(outcome) {
    if (!root.authRoundOpen) return
    root.authRoundOpen = false
    stopAuthTimers()
    root.authGraceOver = false
    if (root.notifyId !== 0) closeAuthNotify(outcome)
    root.notifyId = 0
    root.authCancelRequested = false
    root.authPid = 0
    root.authBrowser = ""
  }

  function cancelAuth() {
    if (root.phase !== "authenticating") return
    root.authCancelRequested = true
    if (root.authPid > 0) {
      Quickshell.execDetached(["kill", "-TERM", String(root.authPid)])
    } else if (refreshProc.running) {
      refreshProc.signal(15)   // SIGTERM
    }
    // The script prints "Cancelled.", exits 130 and removes its state file;
    // refreshState() then resolves the phase (refreshProc.onExited when we
    // started it, external sync otherwise).
  }

  // Auth details for the banner/notification.
  property string authBrowser: ""    // e.g. "Chrome (stagwellglobal.com)"; "" = generic text

  // Called on every status parse. When no internal action is running, an
  // externally started tunnel change (nmcli CLI) or sign-in (state file)
  // drives the phase.
  function syncExternalPhase(data) {
    var refresh = (data.refresh && data.refresh.pid > 0) ? data.refresh : null
    if (refresh) {
      root.authPid = refresh.pid
      root.authBrowser = String(refresh.browserLabel || "")
    }

    if (root.phase !== "" && !root.externalPhase) return  // internal action owns the phase

    var want = ""
    if (refresh) {
      // Only the browser phase is "waiting for sign-in"; once the script
      // moves on to secrets/reconnect it is plain connecting. Scripts
      // without a step field are treated as still authenticating.
      want = String(refresh.step || "auth") === "auth" ? "authenticating" : "connecting"
    } else if (String(data.state || "") === "activating") {
      want = "connecting"
    } else if (String(data.state || "") === "deactivating") {
      want = "disconnecting"
    }

    if (want !== root.phase) {
      if (want !== "") {
        root.externalPhase = true
        setPhase(want)
      } else if (root.externalPhase) {
        root.externalPhase = false
        setPhase("")
        // Externally started run ended (state file gone): the script's
        // refresh-last.json is the authority — its exit code wins over a
        // Cancel request the script may have ignored (post-auth), and its
        // error text names the real failure.
        if (root.authRoundOpen) {
          var last = data.refreshLast
          var outcome = "stopped"
          if (last && last.pid === root.authPid && last.exit === 0) {
            outcome = "connected"
          } else if (last && last.pid === root.authPid && last.exit === 130) {
            outcome = "cancelled"
          } else if (last && last.pid === root.authPid && last.exit !== 0) {
            outcome = "failed"
            if (root.lastError === "") lastError = String(last.error || "Refresh failed")
          } else if (root.authCancelRequested) {
            outcome = "cancelled"
          } else if (root.connected) {
            outcome = "connected"
          }
          finishAuthRound(outcome)
        }
      }
    } else if (want !== "") {
      root.externalPhase = true
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function refreshState() {
    statusProc.running = true
  }

  function refreshGeo() {
    geoProc.running = true
  }

  function toggleVpn() {
    if (root.busy) return
    _wasTryingConnect = !root.connected
    root.lastError = ""
    root.externalPhase = false
    setPhase(root.connected ? "disconnecting" : "connecting")
    toggleProc.running = true
  }

  function authenticate() {
    if (root.busy) return
    root.lastError = ""
    root.refreshError = ""
    root.externalPhase = false
    setPhase("authenticating")
    // Pass --endpoint only when the helper reported endpoints (i.e. the
    // installed smc-vpn-refresh supports it — older versions would reject it).
    refreshProc.command = root.hasEndpoints && root.endpointId !== ""
      ? ["smc-vpn-refresh", "--endpoint", root.endpointId]
      : ["smc-vpn-refresh"]
    refreshProc.running = true
  }

  function pinDetected() {
    if (root.busy) return
    root.lastError = ""
    root.externalPhase = false
    setPhase("pinning")
    pinProc.running = true
  }

  function endpointById(id) {
    for (var i = 0; i < root.endpoints.length; i++) {
      if (root.endpoints[i].id === id) return root.endpoints[i]
    }
    return null
  }

  function selectEndpoint(id) {
    if (root.busy || !root.hasEndpoints || id === root.endpointId) return
    var target = root.endpointById(id)
    if (!target) return

    // Another endpoint is currently connected → switch tunnels: down, then up.
    var activeEp = null
    for (var i = 0; i < root.endpoints.length; i++) {
      var ep = root.endpoints[i]
      if (ep.connected && ep.id !== id) activeEp = ep
    }

    root.lastError = ""
    root.externalPhase = false
    setPhase("switching")
    selectProc.targetId = id
    selectProc.thenSwitch = activeEp !== null
    if (activeEp) {
      // Build the switch command now; switchProc is started by selectProc
      // once the selection has been persisted. Connection names travel as
      // positional args — never spliced into the command string.
      switchProc.command = ["bash", "-c",
        'nmcli connection down "$1" >/dev/null 2>&1; nmcli connection up "$2"',
        "_", activeEp.connName, target.connName]
    }
    selectProc.running = true
  }

  function cycleEndpoint() {
    if (!root.hasEndpoints || root.endpoints.length < 2) return
    var idx = 0
    for (var i = 0; i < root.endpoints.length; i++) {
      if (root.endpoints[i].id === root.endpointId) idx = i
    }
    selectEndpoint(root.endpoints[(idx + 1) % root.endpoints.length].id)
  }

  Component.onCompleted: refreshState()
  onOpenedChanged: if (opened) {
    refreshState()
    if (root.connected) geoDelayTimer.restart()
  }
  onConnectedChanged: {
    // A tunnel that came up invalidates stale errors like
    // "Authentication required" from an earlier failed attempt.
    if (connected && root.lastError !== "") root.lastError = ""
    if (!opened) return
    if (connected) {
      geoDelayTimer.restart()
    } else {
      geoDelayTimer.stop()
      refreshGeo()
    }
  }
  onSinceEpochChanged: {
    if (root.connected && root.sinceEpoch) {
      durationText = formatDuration(Date.now() - root.sinceEpoch * 1000)
    } else {
      durationText = ""
    }
  }

  Process {
    id: statusProc
    command: [root.helperPath]
    running: false
    stdout: StdioCollector {
      id: statusStdout
      waitForEnd: true
      onStreamFinished: {
        try {
          var data = JSON.parse(String(statusStdout.text || "{}"))
          root.connected = !!data.connected
          root.connName = String(data.connName || "VPN")
          root.needsConfirm = !!data.needsConfirm
          root.portal = String(data.portal || "")
          root.device = String(data.device || "")
          root.ip = String(data.ip || "")
          root.gateway = String(data.gateway || "")
          root.dns = String(data.dns || "")
          root.since = String(data.since || "")
          root.sinceEpoch = Number(data.sinceEpoch || 0)
          root.endpoints = Array.isArray(data.endpoints) ? data.endpoints : []
          root.endpointId = String(data.endpoint || "")
          root.syncExternalPhase(data)
        } catch (e) {
          console.log("gp-vpn failed to parse status:", e)
        }
      }
    }
  }

  Process {
    id: toggleProc
    command: root.connected
      ? ["nmcli", "connection", "down", root.connName]
      : ["nmcli", "connection", "up", root.connName]
    running: false
    onExited: function(exitCode, exitStatus) {
      if (_wasTryingConnect && exitCode !== 0 && root.phase === "connecting") {
        lastError = "Authentication required"
      }
      _wasTryingConnect = false
      if (exitCode === 0) lastError = ""
      externalPhase = false
      setPhase("")
      refreshState()
    }
  }

  Process {
    id: pinProc
    command: [root.helperPath, "--pin", root.connName]
    running: false
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0) lastError = "Failed to save connection"
      externalPhase = false
      setPhase("")
      refreshState()
    }
  }

  Process {
    // Persist the endpoint selection; optionally chain into a tunnel switch.
    id: selectProc
    property string targetId: ""
    property bool thenSwitch: false
    command: root.hasEndpoints ? [root.helperPath, "--select", selectProc.targetId] : []
    running: false
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0) {
        externalPhase = false
        setPhase("")
        lastError = "Failed to select endpoint"
        refreshState()
        return
      }
      if (selectProc.thenSwitch) {
        selectProc.thenSwitch = false
        switchProc.running = true   // command was built by selectEndpoint()
      } else {
        externalPhase = false
        setPhase("")
        refreshState()
      }
    }
  }

  Process {
    // Switch tunnels: bring the active endpoint down, then the selected one up.
    id: switchProc
    running: false
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0) lastError = "Endpoint switch failed"
      else lastError = ""
      externalPhase = false
      setPhase("")
      refreshState()
      if (opened) geoDelayTimer.restart()
    }
  }

  Process {
    id: refreshProc
    command: ["smc-vpn-refresh"]
    running: false
    stdout: SplitParser {
      onRead: function(line) {
        // "[1/4] …" / "[3/4] …" progress lines: any step after [1/4] means
        // the browser phase is over — switch to the plain connecting state.
        if (line.indexOf("[2/4]") === 0 || line.indexOf("[3/4]") === 0 || line.indexOf("[4/4]") === 0) {
          if (root.phase === "authenticating") {
            root.externalPhase = true  // let status sync own it from here
            setPhase("connecting")
          }
        }
      }
    }
    stderr: SplitParser {
      onRead: function(line) {
        if (line.indexOf("ERROR: ") === 0) root.refreshError = line.substring(7).trim()
      }
    }
    onExited: function(exitCode, exitStatus) {
      var cancelled = exitCode !== 0 && (root.authCancelRequested || exitCode === 130)
      if (cancelled) {
        lastError = "Authentication cancelled"
      } else if (exitCode !== 0) {
        lastError = root.refreshError !== "" ? root.refreshError : "Refresh failed"
      } else {
        lastError = ""
      }
      externalPhase = false
      setPhase("")
      // The script itself verifies "activated" before exiting 0, so the
      // exit code is authoritative for the outcome notification.
      finishAuthRound(cancelled ? "cancelled" : exitCode === 0 ? "connected" : "failed")
      refreshState()
    }
  }

  Process {
    id: geoProc
    command: root.connected && root.device !== ""
      ? ["curl", "-s", "--max-time", "5", "--interface", root.device, "https://ipinfo.io/json"]
      : ["curl", "-s", "--max-time", "5", "https://ipinfo.io/json"]
    running: false
    stdout: StdioCollector {
      id: geoStdout
      waitForEnd: true
      onStreamFinished: {
        try {
          var data = JSON.parse(String(geoStdout.text || "{}"))
          root.publicIp = String(data.ip || "")
          root.country = String(data.country || "")
          root.city = String(data.city || "")
        } catch (e) {
          console.log("gp-vpn geo lookup failed:", e)
        }
      }
    }
  }

  Timer {
    id: geoDelayTimer
    interval: 1500
    running: false
    repeat: false
    onTriggered: refreshGeo()
  }

  Timer {
    id: durationTimer
    interval: 60000
    running: root.opened && root.connected
    repeat: true
    onTriggered: {
      if (root.sinceEpoch) {
        root.durationText = formatDuration(Date.now() - root.sinceEpoch * 1000)
      }
    }
  }

  // ── authenticating UX ────────────────────────────────────────────────────
  // Grace period: with a valid cached cookie the whole sign-in finishes in
  // ~1s, so the urgent "waiting for you" UI and the notification are held
  // back until the browser phase has demonstrably taken longer.
  Timer {
    id: authGraceTimer
    interval: 2500
    running: false
    onTriggered: {
      if (root.phase !== "authenticating") return
      root.authGraceOver = true
      var pid = root.authPid
      if (pid <= 0 && refreshProc.running) pid = refreshProc.processId
      if (pid <= 0) { authNotifyRetry.restart(); return }  // pid not known yet
      sendAuthNotify(pid)
    }
  }

  // The refresh pid shows up via the state file ≤1s after it is written;
  // retry briefly before giving the notification a pid to guard on.
  Timer {
    id: authNotifyRetry
    interval: 500
    repeat: true
    running: false
    onTriggered: {
      if (root.phase !== "authenticating" || !root.authGraceOver) { stop(); return }
      var pid = root.authPid
      if (pid <= 0 && refreshProc.running) pid = refreshProc.processId
      if (pid > 0) {
        stop()
        sendAuthNotify(pid)
      }
    }
  }

  function sendAuthNotify(pid) {
    if (root.phase !== "authenticating" || !root.authGraceOver) return
    authNotifyProc.pid = pid
    authNotifyProc.title = root.connName + " VPN — sign-in required"
    authNotifyProc.body = root.authBrowser !== ""
      ? "Complete the login in " + root.authBrowser + "."
      : "Complete the login in your browser window."
    authNotifyProc.running = true
  }

  Timer {
    id: authElapsedTimer
    interval: 1000
    running: false
    repeat: true
    onTriggered: root.authElapsed += 1
  }

  // Notification for "sign-in required"; -p prints the id so the outcome
  // notification below can replace the same bubble. Two guards:
  //  - title/body travel as positional bash args ($1/$2), never spliced
  //    into the command string — error text can contain quotes and $.
  //  - one widget instance per monitor, so a flock on a lock FILE serialises
  //    them: only the winner sends (and records its id). The lock dies with
  //    the process — no stale-lock state can mute later notifications.
  Process {
    id: authNotifyProc
    property int pid: 0
    property string title: ""
    property string body: ""
    command: ["bash", "-c",
              'd="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/smc-gp-vpn"; mkdir -p "$d"; ' +
              'exec 9>>"$d/.auth-lock" || exit 0; flock -n 9 || exit 0; ' +
              '[ "$(cat "$d/.auth-notified" 2>/dev/null)" = "$1" ] && exit 0; ' +
              'echo "$1" > "$d/.auth-notified"; ' +
              'exec notify-send -a "GlobalProtect VPN" -u normal -p "$2" "$3"',
              "_", String(authNotifyProc.pid), authNotifyProc.title, authNotifyProc.body]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var n = parseInt(String(text).trim())
        // Ignore a result arriving after its round closed (e.g. cancelled
        // while the notify-send was in flight) — it would otherwise hijack
        // the next round's replace target.
        if (n > 0 && root.authRoundOpen) root.notifyId = n
      }
    }
  }

  function closeAuthNotify(outcome) {
    if (root.notifyId === 0) return
    var title = root.connName + " VPN — "
    var body = ""
    if (outcome === "connected") {
      title += "connected"
      body = "Sign-in complete."
    } else if (outcome === "cancelled") {
      title += "sign-in cancelled"
      body = "Authentication stopped."
    } else if (outcome === "failed") {
      title += "sign-in failed"
      body = root.lastError
    } else {
      title += "stopped"
      body = ""
    }
    // Only the instance that sent the opening notification (notifyId set)
    // replaces it; the marker file is freed for the next auth round.
    Quickshell.execDetached(["bash", "-c",
      'd="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/smc-gp-vpn"; rm -f "$d/.auth-notified" 2>/dev/null; ' +
      'exec notify-send -a "GlobalProtect VPN" -u normal -r "$1" "$2" "$3"',
      "_", String(root.notifyId), title, body])
    root.notifyId = 0
  }

  // ── live state watchers ──────────────────────────────────────────────────
  // 1. NetworkManager events: tunnel up/down started from the CLI, the
  //    dispatcher, or the widget — the bar icon stays truthful without
  //    waiting for the periodic poll.
  Process {
    id: nmMonitor
    command: ["nmcli", "monitor"]
    running: true
    stdout: SplitParser {
      onRead: function(data) { nmDebounce.restart() }
    }
    onExited: watcherRespawn.restart()
  }

  // 2. smc-vpn-refresh state file: a sign-in started from a terminal shows
  //    up in the widget too (pending UI + Cancel). Event-driven inotify
  //    watch on the state dir (no polling forks); any create/move/delete
  //    there — state file appearing, step update, marker cleanup — prints
  //    one line and lets the debounce coalesce the burst.
  Process {
    id: refreshStateWatcher
    command: ["bash", "-c",
              'd="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/smc-gp-vpn"; mkdir -p "$d"; ' +
              'while :; do if inotifywait -q -e create,delete,modify,move,close_write "$d" >/dev/null 2>&1; ' +
              'then echo change; else sleep 2; fi; done']
    running: true
    stdout: SplitParser {
      onRead: function(data) { nmDebounce.restart() }
    }
    onExited: watcherRespawn.restart()
  }

  Timer {
    id: nmDebounce
    interval: 300
    running: false
    onTriggered: root.refreshState()
  }

  // Watchers are long-lived but mortal — restart whichever died.
  Timer {
    id: watcherRespawn
    interval: 2000
    running: false
    onTriggered: {
      if (!nmMonitor.running) nmMonitor.running = true
      if (!refreshStateWatcher.running) refreshStateWatcher.running = true
    }
  }

  // Safety net if both watchers miss something.
  Timer {
    id: pollTimer
    interval: 60000
    running: true
    repeat: true
    onTriggered: root.refreshState()
  }

  Timer {
    id: ipCopyTimer
    interval: 1500
    running: false
    repeat: false
    onTriggered: root.ipCopied = false
  }

  Timer {
    id: publicIpCopyTimer
    interval: 1500
    running: false
    repeat: false
    onTriggered: root.publicIpCopied = false
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    tooltipText: {
      if (root.phase === "authenticating")
        return root.authGraceOver
          ? root.connName + " VPN: waiting for browser sign-in…"
          : root.connName + " VPN: authenticating…"
      if (root.phase === "connecting") return root.connName + " VPN: connecting…"
      if (root.phase === "disconnecting") return root.connName + " VPN: disconnecting…"
      if (root.phase === "switching") return root.connName + " VPN: switching…"
      if (root.phase === "pinning") return "Saving VPN connection…"
      return root.connected
        ? root.connName + " VPN connected"
        : root.connName + " VPN disconnected"
    }
    onPressed: root.toggle()
    iconComponent: Component {
      Item {
        anchors.fill: parent
        property real pulse: 1.0

        // Soft opacity pulse while an action is running; the glyph itself
        // never disappears. Only the sign-in state gets the urgent color.
        SequentialAnimation on pulse {
          running: root.busy
          loops: Animation.Infinite
          NumberAnimation { to: 0.35; duration: 800; easing.type: Easing.InOutSine }
          NumberAnimation { to: 1.0; duration: 800; easing.type: Easing.InOutSine }
        }

        readonly property bool authPending: root.phase === "authenticating" && root.authGraceOver

        Text {
          anchors.centerIn: parent
          visible: true
          opacity: root.busy ? parent.pulse : 1.0
          text: parent.authPending ? root.iconAuthPending
                : root.connected ? root.iconConnected : root.iconDisconnected
          color: parent.authPending ? root.urgent
                : root.connected ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.bar.iconFont
          textFormat: Text.PlainText
        }
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(420))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTextKey: function(t) {
        if (t === "t" || t === "T") root.toggleVpn()
        else if (t === "r") root.authenticate()
        else if (t === "c" || t === "C") root.cancelAuth()
        else if (t === "e" || t === "E") root.cycleEndpoint()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        QC.ScrollBar.vertical: QC.ScrollBar { policy: QC.ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: root.connName + " VPN"
            meta: (root.endpointId !== "" ? root.endpointId + " · " : "")
                  + root.statusLabel()
            detail: root.device || ""
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                readonly property bool authPending: root.phase === "authenticating" && root.authGraceOver
                text: authPending ? root.iconAuthPending
                      : root.connected ? root.iconConnected : root.iconDisconnected
                color: authPending ? root.urgent
                      : root.connected ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
                textFormat: Text.PlainText
              }
            }
            trailingControl: Component {
              RowLayout {
                spacing: Style.space(8)

                QC.BusyIndicator {
                  visible: root.busy
                  running: root.busy
                  implicitWidth: Style.space(16)
                  implicitHeight: Style.space(16)
                }

                ToggleSwitch {
                  checked: root.connected
                  busy: root.busy
                  interactive: !root.busy
                  foreground: root.foreground
                  onToggled: root.toggleVpn()
                }
              }
            }
          }

          // Waiting-for-browser-sign-in banner. Hidden during the 2.5s grace
          // period (a cached cookie finishes that fast) and replaced by
          // "Connecting…" as soon as the script moves past the browser step.
          RowLayout {
            width: parent.width
            spacing: Style.space(8)
            visible: root.phase === "authenticating" && root.authGraceOver

            Column {
              spacing: Style.space(2)
              Layout.fillWidth: true

              Text {
                width: parent.width
                text: "Waiting for browser sign-in · " + root.mmss(root.authElapsed)
                color: root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                text: root.authBrowser !== ""
                      ? "Complete the login in " + root.authBrowser + "."
                      : "Complete the login in your browser window."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                text: "Browser window closed? Cancel and retry."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                visible: root.authElapsed >= 180
                elide: Text.ElideRight
              }
            }

            Button {
              text: "Cancel"
              enabled: root.phase === "authenticating"
              fontFamily: root.fontFamily
              foreground: root.foreground
              onClicked: root.cancelAuth()
            }
          }

          RowLayout {
            width: parent.width
            spacing: Style.space(8)
            visible: root.endpoints.length > 1

            Repeater {
              model: root.endpoints

              delegate: Button {
                required property var modelData
                readonly property bool isSelected: root.endpointId === modelData.id
                text: (isSelected ? "\uf192 " : "\uf10c ")
                      + modelData.id
                      + (modelData.connected ? " \u{F0565}" : "")
                enabled: !root.busy
                fontFamily: root.fontFamily
                foreground: isSelected ? root.foreground : root.dim
                onClicked: root.selectEndpoint(modelData.id)
              }
            }
          }

          RowLayout {
            width: parent.width
            spacing: Style.space(8)
            visible: root.lastError !== ""

            Text {
              text: root.lastError
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
              Layout.fillWidth: true
            }

            Button {
              text: "Authenticate"
              visible: root.lastError !== ""
              enabled: !root.busy
              fontFamily: root.fontFamily
              foreground: root.foreground
              onClicked: root.authenticate()
            }
          }

          RowLayout {
            width: parent.width
            spacing: Style.space(8)
            visible: root.needsConfirm

            Text {
              text: "Using detected connection: " + root.connName
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
              Layout.fillWidth: true
            }

            Button {
              text: "Confirm"
              enabled: !root.busy
              fontFamily: root.fontFamily
              foreground: root.foreground
              onClicked: root.pinDetected()
            }

            Button {
              text: "Skip"
              enabled: !root.busy
              fontFamily: root.fontFamily
              foreground: root.foreground
              onClicked: root.needsConfirm = false
            }
          }

          PanelSectionHeader {
            text: "CONNECTION DETAILS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          GridLayout {
            width: parent.width
            columns: 2
            columnSpacing: Style.space(20)
            rowSpacing: Style.spacing.labelGap

            Text {
              text: "Status"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
            Text {
              text: root.statusLabel()
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              text: "Portal"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              visible: root.portal !== ""
            }
            Text {
              text: root.portal || "--"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              visible: root.portal !== ""
              elide: Text.ElideRight
              Layout.fillWidth: true
            }

            Text {
              text: "Device"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
            Text {
              text: root.device || "--"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              text: "Tunnel IP"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
            Text {
              id: tunnelIpText
              text: root.ip || "--"
              color: root.ipCopied ? root.urgent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
              Layout.fillWidth: true

              MouseArea {
                id: tunnelIpMouse
                anchors.fill: parent
                enabled: root.ip !== ""
                hoverEnabled: enabled
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: {
                  Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(root.ip) + " | wl-copy"])
                  root.ipCopied = true
                  ipCopyTimer.restart()
                }
              }

              PanelToolTip {
                visible: tunnelIpMouse.enabled && tunnelIpMouse.containsMouse
                text: "Copy IP"
                fontFamily: root.fontFamily
              }
            }

            Text {
              text: "Gateway"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              visible: root.gateway !== ""
            }
            Text {
              text: root.gateway || "--"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              visible: root.gateway !== ""
              Layout.fillWidth: true
            }

            Text {
              text: "DNS"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              visible: root.dns !== ""
            }
            Text {
              text: root.dns || "--"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.Wrap
              visible: root.dns !== ""
              Layout.fillWidth: true
            }

            Text {
              text: "Duration"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              visible: root.connected
            }
            Text {
              text: root.durationText || "--"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              visible: root.connected
            }
          }

          PanelSectionHeader {
            text: "PUBLIC ADDRESS"
            foreground: root.foreground
            fontFamily: root.fontFamily
            visible: root.publicIp !== "" || root.country !== ""
          }

          GridLayout {
            width: parent.width
            columns: 2
            columnSpacing: Style.space(20)
            rowSpacing: Style.spacing.labelGap
            visible: root.publicIp !== "" || root.country !== ""

            Text {
              text: "IP"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              visible: root.publicIp !== ""
            }
            Text {
              id: publicIpText
              text: root.publicIp || "--"
              color: root.publicIpCopied ? root.urgent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              visible: root.publicIp !== ""
              elide: Text.ElideRight
              Layout.fillWidth: true

              MouseArea {
                id: publicIpMouse
                anchors.fill: parent
                enabled: root.publicIp !== ""
                hoverEnabled: enabled
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: {
                  Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(root.publicIp) + " | wl-copy"])
                  root.publicIpCopied = true
                  publicIpCopyTimer.restart()
                }
              }

              PanelToolTip {
                visible: publicIpMouse.enabled && publicIpMouse.containsMouse
                text: "Copy IP"
                fontFamily: root.fontFamily
              }
            }

            Text {
              text: "Country"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              visible: root.country !== ""
            }
            Text {
              text: root.country + (root.city ? " (" + root.city + ")" : "")
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              visible: root.country !== ""
            }
          }

          PanelSeparator {
            foreground: root.foreground
          }

          RowLayout {
            width: parent.width
            spacing: Style.space(8)

            Button {
              // Hidden while a sign-in is already running — the banner
              // (with its Cancel) takes over.
              text: root.connected ? "Re-authenticate" : "Authenticate"
              visible: root.phase !== "authenticating"
              enabled: !root.busy
              fontFamily: root.fontFamily
              foreground: root.foreground
              onClicked: root.authenticate()
            }
          }
        }
      }
    }
  }
}
