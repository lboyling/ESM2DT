param (
    [Parameter(Mandatory=$true, HelpMessage="The ESM Script Name for which to publish results to Dynatrace Managed")][String]$scriptName
)
# CONFIGURATION OPTIONS

# Add your full Dynatrace tenant address here
# https://*tenantid*.live.dynatrace.com for Dynatrace SaaS
# https://dynatracemanagedurl/e/*environment_id* for Dynatrace Managed
$DynatraceTenant = "https://*tenantid*.live.dynatrace.com"

# Dynatrace API token generated in the Dynatrace Tenant from above.
# Requires API permission 'Create and read synthetic monitors, locations, and nodes'
$DynatraceApiToken = ""

# Validates whether provided API token has the correct permissions.
# Can disable once confident that API token is correct and need to run this on a large scale.
$CheckApiToken = $true

# Array for converting the schedule ID to the schedule interval (in seconds).
# Values are stored in the dbo.CVSchedule table inside the Agent Manager SQL database.
# The default ESM schedule values are defined:
#   1 = Default 15 minutes (15 minutes)
#   2 = Default reboot schedule (24 hours)
#   3 = Hourly - 24/7 (1 hour)
#   4 = Hourly - Business (1 hour)
$ScheduleID = @(-1
,900
,86400
,3600
,3600
)

# If true, sets the resolution of the synthetic graphs to the schedule interval,
# If false, sets the resolution to 60 seconds
$UseScheduleAsGraphResolution = $true

#Determines whether to raise problems within Dynatrace for Enterprise Synthetic problems. 
$GenerateDtProblems = $true

# Optional - A URL that links to an icon image, which Dynatrace can display as the icon for 
#       Enterprise Synthetic results. Dynatrace must be able to access this icon URL without needing
#       to authenticate to the web server.
$syntheticEngineIconUrl = ""

# Optional - link to main Dynatrace NAM Server - used for adding link to detailed DMI report.
$DynatraceNAMUrl = 'https://NAMServer/LSServlet?lsEntryName=Enterprise%20Synthetic%20-%20Transaction%20list&dmiAction=Generate&pTime_RangeId_=1h'

# SCRIPT START
Add-Type -AssemblyName System.Web
$ScriptLocation = $PSScriptRoot

# Gets the current Unix UTC timestamp in milliseconds
function Get-Timestamp
{
    return ([DateTimeOffset](Get-Date)).ToUnixTimeMilliseconds()
}


Write-Output "Enterprise Synthetic results export to Dynatrace - https://github.com/lboyling/ESM2DT"
Write-Output ""

if($CheckApiToken)
{
    Write-Output "Validating Dynatrace endpoint and API token..."
    try
    {
        # Set TLS 1.2 as Security Protocols - Powershell doesn't do this by default :(
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        $DtTokenLookupEndpoint = $DynatraceTenant + "/api/v1/tokens/lookup"

        $POST_headers = @{ 
            Authorization = "Api-Token $DynatraceApiToken" ;
            Accept = "application/json";
            "Content-Type" = "application/json"
        }
        $TokenLookupPayload = @{
            "token" = $DynatraceApiToken
        }

        $TokenResult = Invoke-RestMethod -Uri $DtTokenLookupEndpoint -Method 'POST' -Headers $POST_headers -Body ($TokenLookupPayload | ConvertTo-Json -Depth 2 | Out-String)
        
        if( $null -ne $TokenResult.scopes -And ($TokenResult.scopes.contains("ExternalSyntheticIntegration")))
        {
            Write-Output "API Token validated successfully."
        }
        else {
            Write-Output "API token does not have required permission 'Create and read synthetic monitors, locations, and nodes'"
            exit 
        }
    }
    catch
    {
        Write-Output "Unable to validate API Token: $_"
        exit 
    }
}

# Set up main payload object, with 
$TestsPayload = @{
    "messageTimestamp" = Get-Timestamp;
    "syntheticEngineName" = "Enterprise Synthetic";
    "locations" = @(
        @{
            "id" = $env:computername;
            "name" = $env:computername;
            "ip" = (Get-NetIPAddress -AddressState Preferred -AddressFamily IPV4 )[1].IPAddress;
        }
    )
    "tests" = @();
    "testResults" = @();
}

# Optional attributes
if($syntheticEngineIconURL -ne "")
{
    $TestsPayload.syntheticEngineIconUrl = $syntheticEngineIconUrl
}

$Results = Import-CSV -Path "$ScriptLocation\results.csv"
$ESMXML = [xml](Get-Content -Path "$ScriptLocation\ESMActiveTransactions.xml")

#Sort transactions by ScriptName, then TransactionName. Assumes that transactions are named/numbered in alphabetical order
#Also remove duplicate transactions from list.
$Transactions = $ESMXML.CVBulkInsert.TPQALCollection | Sort-Object -Property @{Expression = {$_.ScriptName}; Ascending=$True}, @{Expression = {$_.TransactionName}; Ascending=$True} -Unique
if($scriptName -ne "")
{
    $Transactions = $Transactions | Where-Object -Property ScriptName -eq -Value $scriptName
}

$TestResultsPayload = ""
$TestPayload = ""
$StepResultPayload = ""
$CurrentScriptName = ""
$StepCounter = 0
$FirstError = ""
$FirstErrorTimeStamp = $null

Write-Host "Found the following results in $ScriptLocation\results.csv:"
Write-Host $Results

Write-Output "Preparing tests payload..."
#Assemble test results payload
foreach($Transaction in $Transactions)
{
    $Result = $Results | Where-Object -Property TransactionName -eq -Value $Transaction.TransactionName
    
    #Start a new test - populate results that apply to the whole test
    if($CurrentScriptName -ne $Transaction.ScriptName)
    {
        if($CurrentScriptName -ne "")
        {
            #Looped onto a new test - got the previous test to add to the main payload
            $TestsPayload.tests += $TestPayload
            $TestsPayload.testResults += $TestResultsPayload
        }

        $StepCounter = 0
        $FirstError = ""
        $FirstErrorTimeStamp = $null

        $CurrentScriptName = $Transaction.ScriptName
        #12:00:00 AM is a hard-coded value - there is no time recorded if a step/script fails
        $ScriptSuccess = $Results[0].EndTime -ne "12:00:00 AM"
        
        $ScriptStartTime = [datetime]::ParseExact($Result.StartTime, "dd/MM/yyyy h:mm:ss tt", $null)
        #Definition of a single test - to start with, use results from first transaction.
        #If a Launch_To_Close transaction is found later, these results are overridden with the Launch_To_Close results.
        $TestPayload = @{
            "id" = $Transaction.ScriptName;
            "name" = $Transaction.ScriptName;
            "description" = $Transaction.ScriptName;
            "testSetup" = "Active transaction";
            "enabled" = $true;
            "deleted" = $false;
            #Determines graph resolution, value in settings. For testing, set to 60 seconds.
            "scheduleIntervalInSeconds" = $ScheduleID[$Transaction.ScheduleId];
            #Time before Dynatrace will show "no data" on the availability graphs (must be a minimum of 5 minutes). Default to twice the schedule interval
            "noDataTimeout" = [math]::max($ScheduleID[$Transaction.ScheduleId] * 2, 300);
            #Drilldown link to Dynatrace NAM DMI report, with the Application Name passed as a filter
            "drilldownLink" = $DynatraceNAMUrl + "&FILTER_bgAppl=" + [System.Web.HttpUtility]::UrlEncode($Transaction.ApplicationName);
            "locations" = @(
                @{
                    "id" = $TestsPayload.locations[0].id;
                    "enabled" = $true;
                }
            );
            "steps" = @();
        }
        if(!$UseScheduleAsGraphResolution)
        {
            $TestPayload.scheduleIntervalInSeconds = 60
        }
        $TestResultsPayload = @{
            "id" = $Transaction.ScriptName;
            "totalStepCount" = "0";
            "locationResults" = @(
                @{
                    "id" = $TestsPayload.locations[0].id;
                    "startTimestamp" = ([DateTimeOffset]($ScriptStartTime)).ToUnixTimeMilliseconds();
                    "success" = $ScriptSuccess
                    "responseTimeMillis" = [int]([double]($Results[0].PerformanceSeconds) * 1000);
                    "stepResults" = @()
                }
            )
        }
    }
    # Results for overall transaction are retrieved from Launch_To_Close
    if($Transaction.TransactionName -ilike "*Launch_To_Close")
    {
        $TestResultsPayload.locationResults[0].startTimestamp = ([DateTimeOffset]([datetime]::ParseExact($Result.StartTime, "dd/MM/yyyy h:mm:ss tt", $null))).ToUnixTimeMilliseconds()
        $TestResultsPayload.locationResults[0].responseTimeMillis = [int]([double]($Result.PerformanceSeconds) * 1000);
        $TestResultsPayload.locationResults[0].success = ($Result.EndTime -ne "12:00:00 AM")
    }
    # Individual step result
    else {
        $TestPayload.steps += @{
            "id" = $StepCounter;
            "title" = $Transaction.TransactionName;
        }
        
        $StepSuccess = $Result.EndTime -ne "12:00:00 AM"
        $StepStartTime = [datetime]::ParseExact($result.StartTime, "dd/MM/yyyy h:mm:ss tt", $null)
        $StepResultPayload = @{
            "id" = [string]$StepCounter;
            "startTimestamp" = ([DateTimeOffset]($StepStartTime)).ToUnixTimeMilliseconds();
            "responseTimeMillis" = [int]([double]($Result.PerformanceSeconds) * 1000);
            "success" = $StepSuccess;
        }
        if($null -ne $Result.ErrorDescription -and $Result.ErrorDescription -ne "")
        {
            #Add error message to step result
            $StepResultPayload.error = @{
                "code" = -1;
                "message" = $Result.ErrorDescription;
            }
            if($FirstError -eq "")
            {
                $FirstError = $Result.ErrorDescription
                $FirstErrorTimeStamp = ([DateTimeOffset]($StepStartTime)).ToUnixTimeMilliseconds();
            }
        }
        $TestResultsPayload.locationResults[0].stepResults += $StepResultPayload
        
        $StepCounter = $StepCounter + 1
        $TestResultsPayload.totalStepCount = [String]($StepCounter)


    }
}
#Add last test payload to the main tests payload
if($CurrentScriptName -ne "")
{
    $TestsPayload.tests += $TestPayload
    $TestsPayload.testResults += $TestResultsPayload
}

# Prepare the connection to Dynatrace

# Set TLS 1.2 as Security Protocols - Powershell doesn't do this by default :(
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$DtTestsEndpoint = $DynatraceTenant + "/api/v1/synthetic/ext/tests"

$POST_headers = @{ 
    Authorization = "Api-Token $DynatraceApiToken" ;
    Accept = "application/json";
    "Content-Type" = "application/json"
}

$TestsJSON = ($TestsPayload | ConvertTo-Json -Depth 8 | Out-String)
#Write-Host $TestsJSON

#Send tests payload to Dynatrace
Write-Output "Sending test results to $DtTestsEndpoint..."
Invoke-WebRequest -Uri $DtTestsEndpoint -Method 'POST' -Headers $POST_headers -Body $TestsJson
#And save to disk for troubleshooting
$TestsJSON | out-File "$scriptLocation\testspayload.json"
Write-Output "Tests JSON saved to $scriptLocation\testspayload.json"
$DtEventsEndpoint = $DynatraceTenant + "/api/v1/synthetic/ext/events"

#If error was raised on a previous run, and we saved it to disk, resolve the error in Dynatrace
if(Test-Path -Path "$ScriptLocation\errorpayload_$CurrentScriptName.json")
{
    Write-Output "Found open event at $ScriptLocation\errorpayload_$CurrentScriptName.json"
    $LastError = Get-Content -Path "$ScriptLocation\errorpayload_$CurrentScriptName.json" | ConvertFrom-Json

    Write-Output "Preparing to resolve event $($LastError.open.eventId)..."
    $ResolvedPayload = @{
        "syntheticEngineName" = "Enterprise Synthetic";
        "resolved" = @(
            @{
                "testId" = $LastError.open.testId
                "eventId" = $LastError.open.eventId
                "endTimestamp" = Get-Timestamp
            }
        )
        "messageTimestamp" = Get-Timestamp
    }

    $ResolvedJson = $ResolvedPayload | ConvertTo-Json | Out-String
    Write-Output "Sending resolve event to $DtEventsEndpoint..."
    Invoke-WebRequest -Uri $DtEventsEndpoint -Method 'POST' -Headers $POST_headers -Body $ResolvedJson

    #Delete error event from disk (don't need to keep re-resolving it)
    Remove-Item -Path "$ScriptLocation\errorpayload_$CurrentScriptName.json"
}

if($GenerateDtProblems -And $FirstError -ne "")
{
    #Raise a new event
    "Raising an open event because of '$FirstError'..."
    $OpenPayload = @{
        "syntheticEngineName" = "Enterprise Synthetic"
        "open" = @(
            @{
                "testId" = $CurrentScriptName
                "eventId" = "Availability_degraded_$($CurrentScriptName)_$FirstErrorTimestamp"
                "name" = "Synthetic transaction failed"
                "eventType" = "testOutage"
                "reason" = $FirstError
                "locationIds" = @($TestsPayload.locations[0].id);
                "startTimestamp" = $FirstErrorTimeStamp
            }
        )
        "messageTimestamp" = Get-Timestamp
    }

    #Send the event to Dynatrace
    $OpenJson = $OpenPayload | ConvertTo-Json -Depth 4| Out-String
    Write-Output "Sending open event to $DtEventsEndpoint..."
    Invoke-WebRequest -Uri $DtEventsEndpoint -Method 'POST' -Headers $POST_headers -Body $OpenJson

    $OpenJson | Out-File -FilePath "$ScriptLocation\errorpayload_$CurrentScriptName.json"
}
