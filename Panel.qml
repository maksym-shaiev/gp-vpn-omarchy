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
  property bool busy: false
  property string lastError: ""
  property string durationText: ""

  property bool _wasTryingConnect: false
  property bool ipCopied: false
  property bool publicIpCopied: false

  readonly property string helperPath: Qt.resolvedUrl("gp-vpn-status").toString().replace("file://", "")

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

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function refreshState() {
    lastError = ""
    statusProc.running = true
  }

  function refreshGeo() {
    geoProc.running = true
  }

  function toggleVpn() {
    busy = true
    _wasTryingConnect = !root.connected
    toggleProc.running = true
  }

  function authenticate() {
    busy = true
    refreshProc.command = ["smc-vpn-refresh"]
    refreshProc.running = true
  }

  function pinDetected() {
    busy = true
    pinProc.running = true
  }

  Component.onCompleted: refreshState()
  onOpenedChanged: if (opened) {
    refreshState()
    if (root.connected) geoDelayTimer.restart()
  }
  onConnectedChanged: {
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
    onExited: {
      busy = false
      refreshState()
      if (_wasTryingConnect && !root.connected) {
        lastError = "Authentication required"
      }
      _wasTryingConnect = false
    }
  }

  Process {
    id: pinProc
    command: [root.helperPath, "--pin", root.connName]
    running: false
    onExited: {
      busy = false
      refreshState()
    }
  }

  Process {
    id: refreshProc
    command: ["smc-vpn-refresh"]
    running: false
    onExited: {
      busy = false
      refreshState()
      if (!root.connected && lastError === "") {
        lastError = "Refresh failed"
      }
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
    tooltipText: root.connected
      ? root.connName + " VPN connected"
      : root.connName + " VPN disconnected"
    onPressed: root.toggle()
    iconComponent: Component {
      Item {
        anchors.fill: parent

        Text {
          anchors.centerIn: parent
          visible: !root.busy
          text: root.connected ? "\uf023" : "\uf09c"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.bar.iconFont
          textFormat: Text.PlainText
        }

        QC.BusyIndicator {
          anchors.centerIn: parent
          visible: root.busy
          running: root.busy
          implicitWidth: Style.bar.iconFont
          implicitHeight: Style.bar.iconFont
          palette {
            accent: root.foreground
            highlight: root.foreground
          }
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
            meta: root.connected ? "Connected" : "Disconnected"
            detail: root.device || ""
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                text: root.connected ? "\uf023" : "\uf09c"
                color: root.connected ? root.foreground : root.dim
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
              text: root.connected ? "Connected" : "Disconnected"
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
            Item {
              Layout.fillWidth: true
              Text {
                id: tunnelIpText
                text: root.ip || "--"
                color: root.ipCopied ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              MouseArea {
                anchors.fill: tunnelIpText
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  if (root.ip !== "") {
                    Clipboard.copy(root.ip)
                    root.ipCopied = true
                    ipCopyTimer.restart()
                  }
                }
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
            Item {
              Layout.fillWidth: true
              Text {
                id: publicIpText
                text: root.publicIp || "--"
                color: root.publicIpCopied ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                visible: root.publicIp !== ""
              }
              MouseArea {
                anchors.fill: publicIpText
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  if (root.publicIp !== "") {
                    Clipboard.copy(root.publicIp)
                    root.publicIpCopied = true
                    publicIpCopyTimer.restart()
                  }
                }
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
              text: root.connected ? "Re-authenticate" : "Authenticate"
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
