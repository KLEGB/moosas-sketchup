Unicode True
Name "moosas-sketchup"
Caption "moosas-sketchup RBZ Builder"
OutFile "..\dist\moosas-sketchup-builder.exe"
RequestExecutionLevel user
AutoCloseWindow True
ShowInstDetails show

!include "LogicLib.nsh"
!include "nsDialogs.nsh"

Var BootstrapScript
Var ExitCode
Var Dialog
Var OutputDirectory
Var OutputName
Var OutputDirectoryField
Var OutputNameField
Var BrowseButton
Var ProxyEnabled
Var ProxyPortField
Var ProxyPort

Page custom BuilderSettings BuilderSettingsLeave
Page instfiles

Function .onInit
  StrCpy $OutputDirectory "$EXEDIR"
  StrCpy $OutputName "moosas-sketchup.rbz"
  StrCpy $ProxyPort "7890"
FunctionEnd

Function BuilderSettings
  nsDialogs::Create 1018
  Pop $Dialog
  ${If} $Dialog == error
    Abort
  ${EndIf}

  ${NSD_CreateLabel} 0u 0u 100% 20u "Choose where to export the RBZ package."
  Pop $0
  ${NSD_CreateGroupBox} 0u 20u 100% 72u "Output"
  Pop $0
  ${NSD_CreateLabel} 10u 38u 100u 12u "Output folder:"
  Pop $0
  ${NSD_CreateText} 112u 36u 210u 13u "$OutputDirectory"
  Pop $OutputDirectoryField
  ${NSD_CreateButton} 326u 36u 62u 13u "Browse..."
  Pop $BrowseButton
  ${NSD_OnClick} $BrowseButton BrowseOutputDirectory
  ${NSD_CreateLabel} 10u 60u 100u 12u "RBZ file name:"
  Pop $0
  ${NSD_CreateText} 112u 58u 276u 13u "$OutputName"
  Pop $OutputNameField

  ${NSD_CreateGroupBox} 0u 100u 100% 78u "Network"
  Pop $0
  ${NSD_CreateCheckbox} 10u 118u 370u 12u "Use a local HTTP proxy to download from GitHub"
  Pop $ProxyEnabled
  ${NSD_OnClick} $ProxyEnabled ToggleProxy
  ${NSD_CreateLabel} 10u 142u 100u 12u "Local proxy port:"
  Pop $0
  ${NSD_CreateText} 112u 140u 80u 13u "$ProxyPort"
  Pop $ProxyPortField
  EnableWindow $ProxyPortField 0
  ${NSD_CreateLabel} 198u 142u 190u 12u "Example: 7890 uses http://127.0.0.1:7890"
  Pop $0

  GetDlgItem $0 $HWNDPARENT 1
  SendMessage $0 ${WM_SETTEXT} 0 "STR:Process"
  nsDialogs::Show
FunctionEnd

Function BrowseOutputDirectory
  ${NSD_GetText} $OutputDirectoryField $0
  nsDialogs::SelectFolderDialog "Select the RBZ export folder" "$0"
  Pop $1
  ${If} $1 != error
    ${NSD_SetText} $OutputDirectoryField "$1"
  ${EndIf}
FunctionEnd

Function ToggleProxy
  ${NSD_GetState} $ProxyEnabled $0
  ${If} $0 == ${BST_CHECKED}
    EnableWindow $ProxyPortField 1
  ${Else}
    EnableWindow $ProxyPortField 0
  ${EndIf}
FunctionEnd

Function BuilderSettingsLeave
  ${NSD_GetText} $OutputDirectoryField $OutputDirectory
  ${NSD_GetText} $OutputNameField $OutputName
  ${If} $OutputDirectory == ""
    MessageBox MB_ICONEXCLAMATION "Choose an output folder before processing."
    Abort
  ${EndIf}
  ${If} $OutputName == ""
    MessageBox MB_ICONEXCLAMATION "Enter an RBZ file name before processing."
    Abort
  ${EndIf}
  StrCpy $0 $OutputName 4 -4
  ${If} $0 != ".rbz"
    StrCpy $OutputName "$OutputName.rbz"
  ${EndIf}
  CreateDirectory "$OutputDirectory"
  IfErrors 0 +3
    MessageBox MB_ICONSTOP "The output folder could not be created."
    Abort
  ${NSD_GetState} $ProxyEnabled $0
  ${If} $0 == ${BST_CHECKED}
    ${NSD_GetText} $ProxyPortField $ProxyPort
    ${If} $ProxyPort == ""
      MessageBox MB_ICONEXCLAMATION "Enter a local proxy port or turn off proxy support."
      Abort
    ${EndIf}
    IntCmp $ProxyPort 1 ProxyPortInvalid ProxyPortUpperBound ProxyPortUpperBound
    ProxyPortUpperBound:
      IntCmp $ProxyPort 65535 ProxyPortValid ProxyPortValid ProxyPortInvalid
    ProxyPortInvalid:
      MessageBox MB_ICONEXCLAMATION "Enter a proxy port from 1 to 65535."
      Abort
    ProxyPortValid:
  ${Else}
    StrCpy $ProxyPort ""
  ${EndIf}
FunctionEnd

Section "Process RBZ Build"
  InitPluginsDir
  StrCpy $BootstrapScript "$PLUGINSDIR\build-rbz.ps1"
  FileOpen $0 $BootstrapScript w
  FileWrite $0 "param([Parameter(Mandatory=$$true)][string]$$OutputDirectory, [Parameter(Mandatory=$$true)][string]$$OutputName, [string]$$ProxyPort)$\r$\n"
  FileWrite $0 "$$ErrorActionPreference = 'Stop'$\r$\n"
  FileWrite $0 "$$ProgressPreference = 'SilentlyContinue'$\r$\n"
  FileWrite $0 "$$proxyUri = $$null; if ($$ProxyPort) { $$proxyUri = 'http://127.0.0.1:' + $$ProxyPort; $$env:HTTP_PROXY = $$proxyUri; $$env:HTTPS_PROXY = $$proxyUri }$\r$\n"
  FileWrite $0 "function Get-Archive([string]$$Url, [string]$$Destination) { if ($$proxyUri) { Invoke-WebRequest -UseBasicParsing -Uri $$Url -OutFile $$Destination -Proxy $$proxyUri } else { Invoke-WebRequest -UseBasicParsing -Uri $$Url -OutFile $$Destination } }$\r$\n"
  FileWrite $0 "function Expand-Repository([string]$$Archive, [string]$$Destination) { Expand-Archive -LiteralPath $$Archive -DestinationPath $$Destination -Force; return (Get-ChildItem -LiteralPath $$Destination -Directory | Select-Object -First 1).FullName }$\r$\n"
  FileWrite $0 "$$buildRoot = Join-Path $$OutputDirectory '.build'$\r$\n"
  FileWrite $0 "if (Test-Path -LiteralPath $$buildRoot) { Remove-Item -LiteralPath $$buildRoot -Recurse -Force }$\r$\n"
  FileWrite $0 "$$null = New-Item -ItemType Directory -Path $$buildRoot -Force$\r$\n"
  FileWrite $0 "$$logRoot = Join-Path $$buildRoot 'logs'; $$null = New-Item -ItemType Directory -Path $$logRoot -Force$\r$\n"
  FileWrite $0 "Start-Transcript -Path (Join-Path $$logRoot 'bootstrap.log') -Force$\r$\n"
  FileWrite $0 "try {$\r$\n"
  FileWrite $0 "  $$sourceRoot = Join-Path $$buildRoot 'sources'; $$null = New-Item -ItemType Directory -Path $$sourceRoot -Force$\r$\n"
  FileWrite $0 "  $$moosasZip = Join-Path $$sourceRoot 'moosas.zip'; Get-Archive 'https://codeload.github.com/KLEGB/moosas/zip/refs/heads/main' $$moosasZip$\r$\n"
  FileWrite $0 "  $$sketchupZip = Join-Path $$sourceRoot 'moosas-sketchup.zip'; Get-Archive 'https://codeload.github.com/KLEGB/moosas-sketchup/zip/refs/heads/main' $$sketchupZip$\r$\n"
  FileWrite $0 "  $$moosasRoot = Expand-Repository $$moosasZip (Join-Path $$sourceRoot 'moosas')$\r$\n"
  FileWrite $0 "  $$sketchupRoot = Expand-Repository $$sketchupZip (Join-Path $$sourceRoot 'moosas-sketchup')$\r$\n"
  FileWrite $0 "  $$pythonZip = Join-Path $$buildRoot 'python-3.12.10-embed-amd64.zip'; Get-Archive 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-embed-amd64.zip' $$pythonZip$\r$\n"
  FileWrite $0 "  $$pythonRoot = Join-Path $$buildRoot 'python'; Expand-Archive -LiteralPath $$pythonZip -DestinationPath $$pythonRoot -Force$\r$\n"
  FileWrite $0 "  $$pth = Join-Path $$pythonRoot 'python312._pth'; Set-Content -LiteralPath $$pth -Value @('python312.zip','.','Lib','import site') -Encoding ascii$\r$\n"
  FileWrite $0 "  $$outputPath = Join-Path $$OutputDirectory $$OutputName$\r$\n"
  FileWrite $0 "  & (Join-Path $$pythonRoot 'python.exe') (Join-Path $$sketchupRoot 'setup\build_rbz.py') --output-path $$outputPath --moosas-root $$moosasRoot --sketchup-root $$sketchupRoot --python-root $$pythonRoot$\r$\n"
  FileWrite $0 "  if ($$LASTEXITCODE -ne 0) { throw 'RBZ build script failed.' }$\r$\n"
  FileWrite $0 "  Remove-Item -LiteralPath $$buildRoot -Recurse -Force$\r$\n"
  FileWrite $0 "} finally { Stop-Transcript | Out-Null }$\r$\n"
  FileClose $0

  nsExec::ExecToLog 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PLUGINSDIR\build-rbz.ps1" -OutputDirectory "$OutputDirectory" -OutputName "$OutputName" -ProxyPort "$ProxyPort"'
  Pop $ExitCode
  ${If} $ExitCode != 0
    MessageBox MB_ICONSTOP "Build failed. See $OutputDirectory\.build\logs\build.log for details."
    Abort
  ${EndIf}
  MessageBox MB_ICONINFORMATION "RBZ package created at: $OutputDirectory\$OutputName"
SectionEnd
