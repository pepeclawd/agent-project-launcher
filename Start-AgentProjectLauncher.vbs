Option Explicit

Dim shell, files, folder, scriptPath, command
Set shell = CreateObject("WScript.Shell")
Set files = CreateObject("Scripting.FileSystemObject")
folder = files.GetParentFolderName(WScript.ScriptFullName)
scriptPath = files.BuildPath(folder, "AgentProjectLauncher.ps1")
command = """" & shell.ExpandEnvironmentStrings("%SystemRoot%") & _
    "\System32\WindowsPowerShell\v1.0\powershell.exe"" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & _
    scriptPath & """"
shell.Run command, 0, False
