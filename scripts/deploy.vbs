Option Explicit
Dim shell, fso, root, pwsh, scriptPath, logPath, rc, details, stream
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
root = fso.GetParentFolderName(WScript.ScriptFullName)
pwsh = shell.ExpandEnvironmentStrings("%ProgramFiles%\PowerShell\7\pwsh.exe")
scriptPath = fso.BuildPath(root, "deploy-local.ps1")
logPath = shell.ExpandEnvironmentStrings("%LOCALAPPDATA%\ServiceManager\deploy.log")
If Not fso.FileExists(pwsh) Then
  MsgBox "PowerShell 7 is required in Program Files.", vbCritical, "Service Manager deployment"
  WScript.Quit 1
End If
rc = shell.Run("""" & pwsh & """ -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & scriptPath & """ -LogPath """ & logPath & """", 0, True)
If rc = 0 Then
  MsgBox "Deployment completed." & vbCrLf & "Log: " & logPath, vbInformation, "Service Manager deployment"
Else
  details = ""
  If fso.FileExists(logPath) Then
    Set stream = CreateObject("ADODB.Stream")
    stream.Type = 2
    stream.Charset = "utf-8"
    stream.Open
    stream.LoadFromFile logPath
    details = Right(stream.ReadText, 1600)
    stream.Close
  End If
  MsgBox "Deployment failed (exit " & rc & ")." & vbCrLf & details & vbCrLf & "Log: " & logPath, vbCritical, "Service Manager deployment"
End If
WScript.Quit rc
