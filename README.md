# Enterprise Synthetic results export to Dynatrace

This script allows Dynatrace Enterpise Synthetic to export synthetic results directly from the ESM Agent to Dynatrace Synthetic (SaaS and/or Managed).

Features:
* Exporting of availability and performance metrics for both the whole script and each individual transaction
* Integration of Enterprise Synthetic data with native Dynatrace Synthetic monitoring (HTTP, browser monitors and browser clickpaths)
* Optional generation of testOutage events - Dynatrace will generate problems based on these events
* A drilldown link to a Dynatrace NAM report, allowing users to view screenshots for failed transactions
![Enterprise Synthetic results appearing in Dynatrace, including resolved problems, maintenance windows, and error messages](/images/demo_problems_and_maintenance.jpg)

## Setup and prerequisites

### Storing the files
On the Enterprise Synthetic Agent, the PowerShell script and related files should be stored in a '*DTIntegration*' folder inside the Agent user's Documents folder (i.e. `C:\Users\ESMAgent\Documents\DTIntegration\*`)

### Generating the Dynatrace API Token
1. In Dynatrace, select Settings -> Integration -> Dynatrace API.
2. Create a new API token, and grant it the '*Create and read synthetic monitors, locations, and nodes*' permission
3. Copy and paste the new API token into the `ExportToDynatrace.ps1` script as the `$DynatraceAPIToken` variable
4. Also copy and paste the Dynatrace tenant URL as the ```$DynatraceTenant``` variable
  * `https://*tenantid*.live.dynatrace.com` for Dynatrace SaaS
  * `https://dynatracemanagedurl/e/*environment_id*` for Dynatrace Managed

### Enabling TestParter to call the PowerShell script
1. Open the Agent Recorder, and open the Asset Browser (View -> Asset Browser).
2. Select the Module type, and open the `CVFW_Modifiable_Functions` module
3. Add the following line at the end 
      of both the `UserEndOfAppDriver()` and `UserOnAppError()` Subs:
```vb
            DynatraceExport.ExportToDynatrace
```
4. Back in the Asset Browser, go to the Shared Module tab, and create a new Shared Module. Save it as DynatraceExport, in the Common project. 
5. Copy the entire contents of `DynatraceExport.vb` into the `DynatraceExport` shared module and save it.

### Exporting the ActiveTransactions XML from the Agent Manager

1. Open the Enterprise Synthetic Agent Manager and connect to the ESM Console
2. Select the File menu, and select Export Data.
3. In the Monitoring type dropdown, select Active.
4. Select the Browse button, and set the save location as `{UserProfile}\Documents\DTIntegration\ESMActiveTransactions.xml`
5. Click Preview, and then click Export to save the XML to the script folder.

### Adding custom schedule intervals

Enterprise Synthetic stores the schedule ID for each transaction in the ESMActiveTransactions.xml file. For all scripts using a custom schedule
(i.e. not one of the 4 schedules that is a product default), you need to add the schedule interval (in seconds) into the script.

Two ways to do this are:
1. Manually search the `ESMActiveTransactions.xml` file, and find all unique instances of `<ScheduleID>#</ScheduleID>`. Determine what the schedule interval is for the script where you found the schedule ID, and manually add it into the `$ScheduleID` array as a new array element (padding intermediate gaps with a -1 value if required).
2. Connect to the Agent Manager's SQL database, and run this query to get the mapping between schedule ID and schedule interval
```sql
    SELECT ScheduleID, ScheduleName, FreqDuration from [dbo].[CVSchedule] ORDER BY ScheduleID
```
   Add the values into the `$ScheduleID` array.

For example, to add a schedule ID 6 that runs every 10 minutes, extend the array as follows:
```powershell
$ScheduleID = @(-1
,900
,86400
,3600
,3600
,-1
,600
)
```

## Configurable options
### Controlling Dynatrace problem generation
The PowerShell script has a configurable option ($GenerateDtProblems) for whether to generate Dynatrace problems in the event of a transaction failing to complete. You may not want to have Dynatrace generate problems to start with - set $GenerateDtProblems to $false to prevent problem generation.

### Dynatrace NAM integration
To provide additional details, Dynatrace can provide a 'View details' button which will open a Dynatrace NAM report. For example, the Enterprise Synthetic - Transactions list DMI report shows the screenshots for failed transactions. To configure, edit the $DynatraceNAMUrl variable to link to the Dynatrace NAM DMI report. The Application name will automatically be appended to the URL. Application names with special characters (such as square brackets) should work as well.

### Custom icon
Dynatrace shows a default external synthetic icon in the Synthetic views. By editing the $syntheticEngineIconUrl variable, you can provide a URL link to a custom icon, which Dynatrace will display for all synthetic tests that use the same synthetic engine (i.e. Enterprise Synthetic). Be aware that Dynatrace *must be able to access this icon URL without needing to authenticate*.
 
## Sample files
There are a few sample files that can be used to test the process for a sample "My_Application" Active test. This test has the following 3 transactions:
* My_Application_Launch_To_Close: Results for the overall test run - defined so because the transaction name ends with "Launch_To_Close" (case insensitive)
* 01_Step01: The first step
* 02_Step02: The second step

The 3 sample files are:
* ESMActiveTransactions.xml: Contains a slimmed down version of the Enterprise Synthetic defintions for a single "My_Application" script. Only the required XML tags for each transaction are included (6 of the 30-40 elements are present for each transaction).
* results_success.csv: Contains results for the "My_Application script, completing a single successful synthetic run.
* results_failed.csv: Contains results for the "My_Application script, failing on the second step (wtih an error message of "Step 2 error").

Dynatrace will only accept results where **all the timestamps are within the past 2 hours**. So to use these results in testing, you'll need to edit both the start time and end time for all the transactions. The start and end times use the local time on the ESM Agent (the script will convert the results to UTC time automatically). 

To make a transaction failed, set the end time field to "12:00:00 AM" - this magic time indicates that the transaction didn't end (because of a failure). Also set the error message at the end to something that isn't blank.

## Script process
* The Enterprise Synthetic Agent does the processing of the results and makes the API calls directly to Dynatrace (bypassing the Agent Manager and NAM entirely):
* In the TestPartner database, a call to a new shared module is placed into the CVFW_User_Modifiable_Functions Module in two places: UserEndOfAppDriver (for successful runs), and UserOnAppError (for failed runs).
* The shared module has a function which:
  * Writes out the results of the test run (script name, transaction name, start time, end time, performance, error message) to a local .csv file
  * Calls the PowerShell script, with the script name as a parameter
* The PowerShell script:
  * Reads a saved copy of the XML from the Agent Manager containing the Active transactions:
  * Reads the just-written CSV containing the script results:
  * Loops through the configured transactions that belongs to the scripts, and assembles the JSON payload for the test results.
    * For each transaction that has an end time not equal to "12:00:00 AM", this transaction succeeded
    * For each transaction that has an end time equal to "12:00:00 AM", this transaction failed (no actual end time was saved) – mark the JSON payload as failed, and store the associated error description.
    * Launch_To_Close is used to populate the overall test results.
  * Submits the test results payload to Dynatrace Managed (with single-purpose API token).
  * If the transactions failed, the first error message is put into an "open event" json, and submitted as a unique event to Dynatrace. It then writes this "open event" json to disk.
  * Finally, it reads the last "open event" json from the last script run, and submits a "resolved event" request to Dynatrace. (this means that Dynatrace is able to close problems when the next script run is successful).
