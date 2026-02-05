#$language = "VBScript"
#$interface = "1.0"

Dim fso, outFile
Dim host, username, password, cdpPath, invPath, outDir
Dim output

If crt.Arguments.Count < 5 Then
    crt.Dialog.MessageBox "Usage: run_show_cdp.vbs <host> <username> <password> <cdpPath> <invPath>"
    crt.Quit
End If

host = crt.Arguments(0)
username = crt.Arguments(1)
password = crt.Arguments(2)
cdpPath = crt.Arguments(3)
invPath = crt.Arguments(4)

Set fso = CreateObject("Scripting.FileSystemObject")
outDir = fso.GetParentFolderName(cdpPath)

If outDir <> "" Then
    If Not fso.FolderExists(outDir) Then
        fso.CreateFolder(outDir)
    End If
End If

outDir = fso.GetParentFolderName(invPath)
If outDir <> "" Then
    If Not fso.FolderExists(outDir) Then
        fso.CreateFolder(outDir)
    End If
End If

crt.Screen.Synchronous = True

On Error Resume Next
crt.Session.Connect "/SSH2 /L " & username & " /PASSWORD " & Chr(34) & password & Chr(34) & " /TIMEOUT 15 " & host
If Err.Number <> 0 Then
    Err.Clear
    crt.Quit
End If
On Error GoTo 0

If Not crt.Session.Connected Then
    crt.Quit
End If

If Not crt.Screen.WaitForString("#", 15) Then
    If Not crt.Screen.WaitForString(">", 10) Then
        crt.Session.Disconnect
        Do While crt.Session.Connected
            crt.Sleep 200
        Loop
        crt.Quit
    End If
End If

crt.Screen.Send "terminal length 0" & vbCr
If Not crt.Screen.WaitForString("#", 10) Then
    crt.Screen.WaitForString(">", 10)
End If

crt.Screen.Send "show cdp neighbors" & vbCr
output = crt.Screen.ReadString("#", ">", 30)

Set outFile = fso.CreateTextFile(cdpPath, True)
outFile.Write output
outFile.Close

crt.Screen.Send "show inventory" & vbCr
output = crt.Screen.ReadString("#", ">", 30)

Set outFile = fso.CreateTextFile(invPath, True)
outFile.Write output
outFile.Close

crt.Session.Disconnect

Do While crt.Session.Connected
    crt.Sleep 200
Loop

crt.Screen.Clear
