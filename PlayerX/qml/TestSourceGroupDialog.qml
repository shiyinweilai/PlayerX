import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtQuick.Window
import PlayerX 1.0

Dialog {
    id: testSourceGroupDialog
    property var root: null
    modal: true
    anchors.centerIn: parent
    standardButtons: Dialog.NoButton
    closePolicy: Popup.NoAutoClose
    implicitWidth: 440

    property var    _groups: []
    property string _defaultGroup: ""
    property string _configName: ""

    function openWith(groups, defGroup, cfgName) {
        _groups = groups || []
        _defaultGroup = defGroup || ""
        _configName = cfgName || ""
        open()
    }

    Overlay.modal: Rectangle { color: "#aa000000" }

    background: Rectangle {
        color: "#1e1e22"
        border.color: "#3a3a42"
        border.width: 1
        radius: 6
    }

    header: Rectangle {
        color: "#1a2f4a"
        implicitHeight: 46
        radius: 6
        // 盖住 header 底部圆角，与内容区平直衔接
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 6
            color: "#1a2f4a"
        }
        Text {
            anchors.left: parent.left
            anchors.leftMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            text: "📦 选择测试源组别"
            color: "#f0f0f3"
            font.pixelSize: 14
            font.bold: true
        }
        Text {
            anchors.right: parent.right
            anchors.rightMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            visible: testSourceGroupDialog._configName.length > 0
            text: testSourceGroupDialog._configName
            color: "#9a9aa8"
            font.pixelSize: 12
        }
    }

    contentItem: Item {
        implicitWidth: 408
        implicitHeight: groupCol.implicitHeight

        Column {
            id: groupCol
            anchors.fill: parent
            spacing: 10
            topPadding: 14
            bottomPadding: 14

            Text {
                width: parent.width
                text: "该测试源包含多个组别，请选择要导入对比的一组："
                color: "#c8c8cc"
                font.pixelSize: 12
                wrapMode: Text.WordWrap
            }

            Repeater {
                model: testSourceGroupDialog._groups
                delegate: Rectangle {
                    id: gBtn
                    width: parent ? parent.width : 0
                    height: 42
                    radius: 6
                    property bool isDefault: modelData === testSourceGroupDialog._defaultGroup
                    color: gMa.containsMouse ? "#2a2a35" : (isDefault ? "#22303f" : "#222228")
                    border.color: isDefault ? "#5a8fd8" : "#3a3a45"
                    border.width: isDefault ? 1.5 : 1

                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: 14
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData
                        color: "#e8e8ec"
                        font.pixelSize: 14
                        font.bold: gBtn.isDefault
                    }
                    Text {
                        anchors.right: parent.right
                        anchors.rightMargin: 14
                        anchors.verticalCenter: parent.verticalCenter
                        visible: gBtn.isDefault
                        text: "默认"
                        color: "#5a8fd8"
                        font.pixelSize: 11
                    }
                    MouseArea {
                        id: gMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            testSourceGroupDialog.close()
                            Logic._tsOnGroupChosen(modelData)
                        }
                    }
                }
            }

            Item {
                width: parent ? parent.width : 0
                height: 32
                Rectangle {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: 76
                    height: 30
                    radius: 5
                    color: gCancelMa.containsMouse ? "#33333c" : "#26262c"
                    border.color: "#3a3a45"
                    border.width: 1
                    Text {
                        anchors.centerIn: parent
                        text: "取消"
                        color: "#c8c8cc"
                        font.pixelSize: 12
                    }
                    MouseArea {
                        id: gCancelMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            testSourceGroupDialog.close()
                            Logic._tsOnGroupCancel()
                        }
                    }
                }
            }
        }
    }
}
