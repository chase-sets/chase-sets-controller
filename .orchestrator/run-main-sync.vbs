Option Explicit

' Task Scheduler starts wscript.exe without allocating a console window. This
' avoids the brief focus-stealing flash that powershell.exe can show even when
' it is passed -WindowStyle Hidden.
Dim fileSystem, shell, scriptPath, command, exitCode

Set fileSystem = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

scriptPath = fileSystem.BuildPath( _
  fileSystem.GetParentFolderName(WScript.ScriptFullName), _
  "run-main-sync.ps1" _
)

command = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " & Quote(scriptPath)
exitCode = shell.Run(command, 0, True)

WScript.Quit exitCode

Function Quote(value)
  Quote = Chr(34) & value & Chr(34)
End Function
