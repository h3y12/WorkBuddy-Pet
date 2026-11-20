Option Explicit
Dim shell, fs, root, command, host
Set shell = CreateObject("WScript.Shell")
Set fs = CreateObject("Scripting.FileSystemObject")
root = fs.GetParentFolderName(WScript.ScriptFullName)
host = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
command = Chr(34) & host & Chr(34) & " -NoProfile -ExecutionPolicy Bypass -STA -File " & Chr(34) & root & "\Launch.ps1" & Chr(34)
shell.Run command, 0, False
