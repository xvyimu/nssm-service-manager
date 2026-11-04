' Keep this file ASCII: Windows Script Host decodes VBS using the ANSI code page.
' Launch PowerShell 7 with UAC elevation and no console window.
Option Explicit
Dim fso, sh, sh2, here, script, pwsh
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("Shell.Application")
Set sh2 = CreateObject("WScript.Shell")
here = fso.GetParentFolderName(WScript.ScriptFullName)
script = here & "\service-manager-gui.ps1"

' Only the Program Files copy of PowerShell 7 is accepted. PATH and %USERPROFILE%\scoop
' are user-writable: a medium-integrity process could plant pwsh.exe there and get it
' launched elevated on the next double-click + UAC consent.
pwsh = sh2.ExpandEnvironmentStrings("%ProgramFiles%") & "\PowerShell\7\pwsh.exe"
If Not fso.FileExists(pwsh) Then
  MsgBox "PowerShell 7 not found at:" & vbCrLf & pwsh & vbCrLf & vbCrLf & _
         "Install PowerShell 7 under Program Files and retry.", vbCritical, "Missing dependency"
  WScript.Quit 1
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
