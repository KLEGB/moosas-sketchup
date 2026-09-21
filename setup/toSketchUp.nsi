Unicode True
Name "moosas-sketchup"
Caption "moosas-sketchup RBZ Builder"
OutFile "..\moosas-sketchup-builder.exe"
RequestExecutionLevel user
AutoCloseWindow True
ShowInstDetails show

!include "LogicLib.nsh"

Var BootstrapScript
Var ExitCode

Section "Build moosas-sketchup RBZ"
  ; This EXE intentionally embeds no setup payload. It fetches both public
  ; repositories and Python 3.12 only when the builder is run.
  InitPluginsDir
  StrCpy $BootstrapScript "$PLUGINSDIR\build-rbz.ps1"
  FileOpen $0 $BootstrapScript w
  FileWrite $0 "param([Parameter(Mandatory=$$true)][string]$$OutputRoot)$\r$\n"
  FileWrite $0 "$$ErrorActionPreference = 'Stop'$\r$\n"
  FileWrite $0 "$$ProgressPreference = 'SilentlyContinue'$\r$\n"
  FileWrite $0 "function Get-Archive([string]$$Url, [string]$$Destination) { Invoke-WebRequest -UseBasicParsing -Uri $$Url -OutFile $$Destination }$\r$\n"
  FileWrite $0 "function Expand-Repository([string]$$Archive, [string]$$Destination) { Expand-Archive -LiteralPath $$Archive -DestinationPath $$Destination -Force; return (Get-ChildItem -LiteralPath $$Destination -Directory | Select-Object -First 1).FullName }$\r$\n"
  FileWrite $0 "$$buildRoot = Join-Path $$OutputRoot 'dist\.build'$\r$\n"
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
  FileWrite $0 "  & (Join-Path $$pythonRoot 'python.exe') (Join-Path $$sketchupRoot 'setup\build_rbz.py') --output-root $$OutputRoot --moosas-root $$moosasRoot --sketchup-root $$sketchupRoot --python-root $$pythonRoot$\r$\n"
  FileWrite $0 "  if ($$LASTEXITCODE -ne 0) { throw 'RBZ build script failed.' }$\r$\n"
  FileWrite $0 "  Remove-Item -LiteralPath $$buildRoot -Recurse -Force$\r$\n"
  FileWrite $0 "} finally { Stop-Transcript | Out-Null }$\r$\n"
  FileClose $0

  nsExec::ExecToLog 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PLUGINSDIR\build-rbz.ps1" -OutputRoot "$EXEDIR"'
  Pop $ExitCode
  ${If} $ExitCode != 0
    MessageBox MB_ICONSTOP "moosas-sketchup build failed. See $EXEDIR\dist\.build\logs\build.log."
    Abort
  ${EndIf}
  MessageBox MB_ICONINFORMATION "moosas-sketchup RBZ created at: $EXEDIR\dist\moosas-sketchup.rbz"
SectionEnd
