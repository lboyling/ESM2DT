Option Explicit
'
' To send results to Dynatrace, a few prerequisites are required:
'   1. Inside the Agent Recorder, add the contents of this file into a new Shared Module, 
'      and save it as DynatraceExport
'   2. Open the CVFW_User_Modifiable_Functions, and add the following line at the end 
'      of both the UserEndOfAppDriver() and UserOnAppError() Subs:
'
'            DynatraceExport.SendToDynatrace
'

'Location where the all the files for the DT Integration are stored - by default, all files
' are saved in a DTIntegration folder inside the running user's Documents folder
Public Const DTIntegrationFolder As String = Environ("HOMEPATH") + "\Documents\DTIntegration"

Public Const DtIntegrationResults As String = DTIntegrationFolder + "\results.csv"
Public Const DtIntegrationScript As String = DTIntegrationFolder + "\ExportToDynatrace.ps1"

Public Sub ExportToDynatrace

    Dim ResultFileNo As Integer
    ResultFileNo = FreeFile
    Open DtIntegrationResults For Output As #ResultFileNo

    'Write CSV headers first
    Print #ResultFileNo, "ScriptName,TransactionID,TransactionName,StartTime,EndTime,PerformanceSeconds,ErrorDescription"

    Dim Trans As tCVTransaction
    Dim ResultLine As String
    Dim i As Integer
    i = 0

    'Write the results for each transaction
    For i = 0 to UBound(CVTransactions)
        Trans = CVTransactions(i)
        ResultLine = Trans.sAppName & "," & i & "," & Trans.sTransName & "," & trans.sStartTime & "," & _
        trans.sEndTime & "," & trans.iPerformance & "," & trans.sErrMessage
        Print #ResultFileNo, ResultLine
    Next

    Close #ResultFileNo

    'Launch PowerShell script, passing the ESM script's name as a paramater
    LaunchAppWithParm "powershell.exe", "-Command """ & DtIntegrationScript & """ " & AppName

End Sub