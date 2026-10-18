Option Explicit

' Task Scheduler starts wscript.exe without a console window. This launches the
' container sweep the same way run-main-sync.vbs launches the main sync: hidden,
' and only as a fallback for when the delivery loop is not cycling. The sweep's
' own six-hour due gate and lock make a run here a no-op when the loop has
' already swept.
Dim fileSystem, shell, folder, scriptPath, logPath, command, exitCode

Set fileSystem = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

folder = fileSystem.GetParentFolderName(WScript.ScriptFullName)
scriptPath = fileSystem.BuildPath(folder, "container-sweep.ps1")
logPath = fileSystem.BuildPath(fileSystem.BuildPath(folder, "logs"), "container-sweep-task.log")

command = "cmd.exe /c pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " & Quote(scriptPath) & _
  " -Apply >> " & Quote(logPath) & " 2>&1"
exitCode = shell.Run(command, 0, True)

WScript.Quit exitCode

Function Quote(value)
  Quote = Chr(34) & value & Chr(34)
End Function