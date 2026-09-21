Unicode True
Name "moosas-sketchup"
Caption "moosas-sketchup RBZ Builder"
OutFile "..\moosas-sketchup-builder.exe"
RequestExecutionLevel user
AutoCloseWindow True
ShowInstDetails show

!include "LogicLib.nsh"

Var ExitCode

Section "Build moosas-sketchup RBZ"
  InitPluginsDir
  SetOutPath "$PLUGINSDIR\bootstrap"
  File "build_rbz.py"
  File "get-pip.py"
  File "python311._pth"
  File "pydot3k-1.0.17.tar.gz"
  File "db_eplusout_reader-0.3.1-py2.py3-none-any.whl"

  ; The released RBZ is built from the repository root.  The temporary
  ; bootstrap files above are extracted by NSIS and removed automatically.
  nsExec::ExecToLog 'python.exe "$PLUGINSDIR\bootstrap\build_rbz.py" --repo-root "$EXEDIR" --bootstrap-root "$PLUGINSDIR\bootstrap"'
  Pop $ExitCode
  ${If} $ExitCode != 0
    MessageBox MB_ICONSTOP "moosas-sketchup build failed. See $EXEDIR\\dist\\.build\\logs\\build.log."
    Abort
  ${EndIf}
  MessageBox MB_ICONINFORMATION "moosas-sketchup RBZ created at: $EXEDIR\dist\moosas-sketchup.rbz"
SectionEnd
