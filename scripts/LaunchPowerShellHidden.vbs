Option Explicit

If WScript.Arguments.Count <> 2 Then
    WScript.Quit 64
End If

Dim command
Dim shell

command = """" & WScript.Arguments(0) & """" & _
    " -NoProfile -NonInteractive -ExecutionPolicy Bypass" & _
    " -WindowStyle Hidden -File """ & WScript.Arguments(1) & """"

Set shell = CreateObject("WScript.Shell")
Call shell.Run(command, 0, False)
