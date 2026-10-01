' Keep this file ASCII: Windows Script Host decodes VBS using the ANSI code page.
' Launch PowerShell 7 with UAC elevation and no console window.
Option Explicit
Dim fso, sh, sh2, here, script, pwsh, scoopPwsh
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("Shell.Application")
Set sh2 = CreateObject("WScript.Shell")
here = fso.GetParentFolderName(WScript.ScriptFullName)
script = here & "\service-manager-gui.ps1"

' Prefer an absolute pwsh path (SCOOP or Program Files) before falling back to PATH
' (finding 8: a bare "pwsh.exe" relies on PATH, which may not be loaded under wscript).
' Environ is a method of WScript.Shell, not a global VBScript function; calling it
' bare throws "Type mismatch" and aborts before ShellExecute (no pwsh starts, no log).
pwsh = "pwsh.exe"  ' PATH fallback: only when scoop/Program Files both miss
scoopPwsh = sh2.ExpandEnvironmentStrings("%USERPROFILE%") & "\scoop\shims\pwsh.exe"
If fso.FileExists(scoopPwsh) Then
  pwsh = scoopPwsh
ElseIf fso.FileExists("C:\Program Files\PowerShell\7\pwsh.exe") Then
  pwsh = "C:\Program Files\PowerShell\7\pwsh.exe"
End If

' ShellExecute(File, Args, Dir, Operation, Show): runas is the fourth argument.
' Catch COM error when user denies UAC (finding 8): show a readable prompt
' instead of VBScript's internal error dialog.
On Error Resume Next
sh.ShellExecute pwsh, _
  "-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & script & """", _
  here, "runas", 0
If Err.Number <> 0 Then
  If Err.Number = -2147211006 Or Err.Number = 5 Then
    ' 1223 (ShellExecute runas cancelled) maps to WScript.Shell 5 / COM 0x80070005
    MsgBox "Service Manager needs administrator privileges." & vbCrLf & vbCrLf & _
           "Please allow the UAC prompt, or run as administrator.", _
           vbExclamation, "Service Manager"
  Else
    MsgBox "Launch failed (error " & Err.Number & "): " & Err.Description, _
           vbExclamation, "Service Manager"
  End If
  WScript.Quit 1
End If
On Error GoTo 0
