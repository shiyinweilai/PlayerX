; ============================================================================
;  PlayerX NSIS Setup 脚本（行业标准模板）
;  ----------------------------------------------------------------------------
;  ● 行业规范：
;    1. RequestExecutionLevel admin —— 写 Program Files 必须管理员
;    2. !define MUI_FINISHPAGE_RUN —— 安装完成后可选启动应用
;    3. 安装/卸载前强制 kill PlayerX.exe（用户长期偏好 + 防文件占用）
;    4. 写注册表 Uninstall 项：DisplayName/DisplayVersion/InstallLocation/Publisher/EstimatedSize
;       让"应用与功能"识别 + 让自更新代码读取安装目录
;    5. 写 HKLM\Software\PlayerX\InstallType=installed 标记，
;       供客户端 platformKey() 区分 install / portable
;    6. 静默升级支持 /S /SILENT /CLOSEAPPLICATIONS /RESTARTAPPLICATIONS
;       （/S 由 NSIS 内置；/CLOSEAPPLICATIONS 我们解析后自行 kill）
;    7. /D=<dir> 由调用方（自动更新器）传入，强制同目录覆盖
;
;  ● 调用方式：
;    - 普通用户安装：双击 PlayerX-Setup-x.y.z.exe，UI 引导
;    - 自动升级：PlayerX-Setup-x.y.z.exe /S /CLOSEAPPLICATIONS /RESTARTAPPLICATIONS /D=C:\Program Files\PlayerX
;
;  ● 编译：makensis -DAPP_VERSION=2.0.5 -DSRC_DIR=..\dist\win-x64 PlayerX.nsi
; ============================================================================

Unicode True
SetCompressor /SOLID lzma

!ifndef APP_VERSION
  !define APP_VERSION "0.0.0"
!endif
!ifndef SRC_DIR
  ; 默认从 PlayerX/build/out/bin 收集；建议由 build.py 显式传入 dist 目录
  !define SRC_DIR "..\PlayerX\build\out\bin"
!endif
!ifndef OUT_DIR
  !define OUT_DIR "..\dist"
!endif

!define APP_NAME      "PlayerX"
!define APP_PUBLISHER "rbyang"
!define APP_EXE       "PlayerX.exe"
!define APP_REGKEY    "Software\${APP_NAME}"
!define UNINST_KEY    "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}"

Name           "${APP_NAME} ${APP_VERSION}"
OutFile        "${OUT_DIR}\${APP_NAME}-Setup-${APP_VERSION}.exe"
InstallDir     "$PROGRAMFILES64\${APP_NAME}"
InstallDirRegKey HKLM "${APP_REGKEY}" "InstallDir"
RequestExecutionLevel admin
ShowInstDetails   show
ShowUninstDetails show
BrandingText      "${APP_PUBLISHER}"

VIProductVersion             "${APP_VERSION}.0"
VIAddVersionKey ProductName  "${APP_NAME}"
VIAddVersionKey CompanyName  "${APP_PUBLISHER}"
VIAddVersionKey LegalCopyright "Copyright (c) 2025 ${APP_PUBLISHER}"
VIAddVersionKey FileVersion  "${APP_VERSION}"
VIAddVersionKey ProductVersion "${APP_VERSION}"
VIAddVersionKey FileDescription "${APP_NAME} Installer"

; ─── Modern UI 2 ─────────────────────────────────────────────────────────
!include "MUI2.nsh"
!include "FileFunc.nsh"
!include "LogicLib.nsh"
!include "x64.nsh"

!define MUI_ABORTWARNING
; 图标路径可由 build.py 通过 -DAPP_ICON=... 传入；找不到就用 NSIS 默认图标
!ifdef APP_ICON
  !define MUI_ICON   "${APP_ICON}"
  !define MUI_UNICON "${APP_ICON}"
!endif
!define MUI_FINISHPAGE_RUN "$INSTDIR\${APP_EXE}"
!define MUI_FINISHPAGE_RUN_TEXT "立即启动 ${APP_NAME}"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "SimpChinese"

; ─── 自定义解析：识别 /CLOSEAPPLICATIONS /RESTARTAPPLICATIONS ─────────────
Var SilentClose
Var SilentRestart
Var CmdParam

Function .onInit
  StrCpy $SilentClose   "0"
  StrCpy $SilentRestart "0"

  ${GetParameters} $CmdParam
  ClearErrors
  ${GetOptions} "$CmdParam" "/CLOSEAPPLICATIONS" $0
  ${IfNot} ${Errors}
    StrCpy $SilentClose "1"
  ${EndIf}
  ClearErrors
  ${GetOptions} "$CmdParam" "/RESTARTAPPLICATIONS" $0
  ${IfNot} ${Errors}
    StrCpy $SilentRestart "1"
  ${EndIf}

  ; 64 位强制
  ${IfNot} ${RunningX64}
    MessageBox MB_ICONSTOP "本程序需要 64 位 Windows。"
    Abort
  ${EndIf}
  SetRegView 64
FunctionEnd

; ─── 强制 kill 旧版本进程（防文件占用 / 长期偏好） ───────────────────────
;   优先用 nsProcess 插件，缺失则回退到 taskkill
!macro KillRunningApp
  DetailPrint "正在尝试关闭运行中的 ${APP_NAME} ..."
  ; taskkill 在所有 Windows 版本都自带，作为基线方案
  nsExec::Exec 'taskkill /F /IM "${APP_EXE}" /T'
  Pop $0
  ; 给 OS 一点时间释放句柄
  Sleep 800
!macroend

; ─── 主安装 Section ──────────────────────────────────────────────────────
Section "MainApp" SEC_MAIN
  SectionIn RO
  SetOutPath "$INSTDIR"

  ; 1) 强制结束旧进程（无论 UI / 静默都要做）
  !insertmacro KillRunningApp

  ; 2) 复制全部文件（包含 Qt deploy 后的 plugins、translations 等）
  File /r "${SRC_DIR}\*.*"

  ; 3) 写注册表
  WriteRegStr HKLM "${APP_REGKEY}" "InstallDir"  "$INSTDIR"
  WriteRegStr HKLM "${APP_REGKEY}" "Version"     "${APP_VERSION}"
  WriteRegStr HKLM "${APP_REGKEY}" "InstallType" "installed"

  ; Uninstall 信息（"应用与功能"会显示）
  WriteRegStr HKLM "${UNINST_KEY}" "DisplayName"     "${APP_NAME}"
  WriteRegStr HKLM "${UNINST_KEY}" "DisplayVersion"  "${APP_VERSION}"
  WriteRegStr HKLM "${UNINST_KEY}" "Publisher"       "${APP_PUBLISHER}"
  WriteRegStr HKLM "${UNINST_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKLM "${UNINST_KEY}" "DisplayIcon"     "$INSTDIR\${APP_EXE}"
  WriteRegStr HKLM "${UNINST_KEY}" "UninstallString" '"$INSTDIR\Uninstall ${APP_NAME}.exe"'
  WriteRegStr HKLM "${UNINST_KEY}" "QuietUninstallString" '"$INSTDIR\Uninstall ${APP_NAME}.exe" /S'
  WriteRegDWORD HKLM "${UNINST_KEY}" "NoModify" 1
  WriteRegDWORD HKLM "${UNINST_KEY}" "NoRepair" 1

  ; 估算占用大小（KB）
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  IntFmt $0 "0x%08X" $0
  WriteRegDWORD HKLM "${UNINST_KEY}" "EstimatedSize" "$0"

  ; 4) 写卸载器
  WriteUninstaller "$INSTDIR\Uninstall ${APP_NAME}.exe"

  ; 5) 创建快捷方式（开始菜单 + 桌面）
  CreateDirectory "$SMPROGRAMS\${APP_NAME}"
  CreateShortCut  "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk" "$INSTDIR\${APP_EXE}"
  CreateShortCut  "$SMPROGRAMS\${APP_NAME}\卸载 ${APP_NAME}.lnk" "$INSTDIR\Uninstall ${APP_NAME}.exe"
  CreateShortCut  "$DESKTOP\${APP_NAME}.lnk" "$INSTDIR\${APP_EXE}"
SectionEnd

; ─── 安装完成后回调：静默升级时自动重启应用 ──────────────────────────────
Function .onInstSuccess
  ${If} ${Silent}
    ${If} $SilentRestart == "1"
      ; 用 ShellExecute 异步拉起，避免 setup 阻塞退出
      Exec '"$INSTDIR\${APP_EXE}"'
    ${EndIf}
  ${EndIf}
FunctionEnd

; ─── 卸载 Section ────────────────────────────────────────────────────────
Function un.onInit
  SetRegView 64
FunctionEnd

Section "Uninstall"
  ; 卸载前同样要 kill
  DetailPrint "正在尝试关闭运行中的 ${APP_NAME} ..."
  nsExec::Exec 'taskkill /F /IM "${APP_EXE}" /T'
  Pop $0
  Sleep 500

  ; 删整个安装目录（包含 Qt 子目录）
  RMDir /r "$INSTDIR"

  ; 删快捷方式
  Delete  "$DESKTOP\${APP_NAME}.lnk"
  RMDir /r "$SMPROGRAMS\${APP_NAME}"

  ; 删注册表
  DeleteRegKey HKLM "${UNINST_KEY}"
  DeleteRegKey HKLM "${APP_REGKEY}"
SectionEnd
