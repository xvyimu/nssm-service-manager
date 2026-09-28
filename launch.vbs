' Keep this file ASCII: Windows Script Host decodes VBS using the ANSI code page.
' Launch PowerShell 7 with UAC elevation and no console window.
Option Explicit
Dim fso, sh, here, script
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("Shell.Application")
here = fso.GetParentFolderName(WScript.ScriptFullName)
script = here & "\service-manager-gui.ps1"

' ShellExecute(File, Args, Dir, Operation, Show): runas is the fourth argument.
sh.ShellExecute "pwsh.exe", _
  "-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & script & """", _
  here, "runas", 0
