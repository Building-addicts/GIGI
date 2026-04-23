Set WshShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
WshShell.CurrentDirectory = dir
WshShell.Run "cmd /c node """ & dir & "\panel.js"" >> """ & dir & "\logs\panel.log"" 2>&1", 0, False
