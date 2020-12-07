##############################################################################################
# Copyright (c) Microsoft Corporation
# Licensed under the Apache License.
#
# Collect-CaptureImagesStatus.ps1
###############################################################################################
Param
(
    [String] $AzureSecretsFile,
    [String] $TestPass,
    [String] $DbServer,
    [String] $DbName,
    [String] $Title
)

#Load libraries
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Definition
$commonModulePath = Join-Path $scriptPath "CommonFunctions.psm1"
Import-Module $commonModulePath

$StatusNotStarted = "NotStarted"
$StatusRunning = "Running"
$StatusPassed = "Passed"

function Get-PassedCount($connection) {
    $sql = "
    select Count(ARMImage) from CaptureImageInfo
    where Status='$StatusPassed'"

    $results = QuerySql $connection $sql
    $count = ($results[0][0]) -as [int]
    Write-LogInfo "The passed count is $count"

    return $count
}

function Get-RunningCount($connection) {
    $sql = "
    select Count(ARMImage) from CaptureImageInfo
    where Status='$StatusRunning'"

    $results = QuerySql $connection $sql
    $count = ($results[0][0]) -as [int]
    Write-LogInfo "The running count is $count"

    return $count
}

function Get-NotStartedCount($connection) {
    $sql = "
    select Count(ARMImage) from CaptureImageInfo
    where Status='$StatusNotStarted'"

    $results = QuerySql $connection $sql
    $count = ($results[0][0]) -as [int]
    Write-LogInfo "The not started count is $count"

    return $count
}

# Read secrets file and terminate if not present
Write-LogInfo "Check the Azure Secrets File..."
if (![String]::IsNullOrEmpty($AzureSecretsFile) -and (Test-Path -Path $AzureSecretsFile)) {
    $content = Get-Content -Path $AzureSecretsFile
    foreach ($line in $content) {
        if ($line.split(':')[0] -eq 'dbUserName') {
            $dbuser = $line.split(':')[1].trim()
        }
        if ($line.split(':')[0] -eq 'dbPassword') {
            $dbpassword = $line.split(':')[1].trim()
        }
    }
} else {
    Write-LogErr "Please provide value for -AzureSecretsFile"
    exit 1
}

$server = $DbServer
$database = $DbName
if (!$server -or !$dbuser -or !$dbpassword -or !$database) {
    Write-LogErr "Database details are not provided."
    exit 1
}

$connectionString = "Server=$server;uid=$dbuser;pwd=$dbpassword;Database=$database;" +
                    "Encrypt=yes;TrustServerCertificate=no;Connection Timeout=30;MultipleActiveResultSets=True;"

try {
    $connection = New-Object System.Data.SqlClient.SqlConnection
    $connection.ConnectionString = $connectionString
    $connection.Open()

    $notStartedCount = Get-NotStartedCount $connection
    $runningCount = Get-RunningCount $connection
    $passedCount = Get-PassedCount $connection
} catch {
    $line = $_.InvocationInfo.ScriptLineNumber
    $script_name = ($_.InvocationInfo.ScriptName).Replace($PWD,".")
    $ErrorMessage =  $_.Exception.Message
    Write-LogErr "EXCEPTION : $ErrorMessage"
    Write-LogErr "Source : Line $line in script $script_name."
    exit 1
} 
finally {
    if ($null -ne $connection) {
        $connection.Close()
        $connection.Dispose()
    }
}

# region HTML File structure
$TableStyle = '
<style type="text/css">
  .tm  {border-collapse:collapse;border-spacing:0;border-color:#999;}
  .tm td{font-family:Arial, sans-serif;font-size:14px;padding:10px 5px;border-style:solid;border-width:1px;overflow:hidden;word-break:normal;border-color:#999;color:#444;background-color:#F7FDFA;}
  .tm th{font-family:Arial, sans-serif;font-size:14px;font-weight:normal;padding:10px 5px;border-style:solid;border-width:1px;overflow:hidden;word-break:normal;border-color:#999;color:#fff;background-color:#26ADE4;}
  .tm .tm-dk6e{font-weight:bold;color:#ffffff;text-align:center;vertical-align:top}
  .tm .tm-xa7z{background-color:#ffccc9;vertical-align:top}
  .tm .tm-ys9u{background-color:#b3ffd9;vertical-align:top}
  .tm .tm-7k3a{background-color:#D2E4FC;font-weight:bold;text-align:center;vertical-align:top}
  .tm .tm-yw4l{vertical-align:top}
  .tm .tm-6k2t{background-color:#D2E4FC;vertical-align:top}
</style>
'

$htmlHeader = '
<h2>&bull;&nbsp;STATUS_TITLE</h2>
<table border="0" cellpadding="0" cellspacing="0" style="border-collapse:collapse" class="tm">
  <tr>
    <td class="tm-7k3a">Pending</td>
    <td class="tm-7k3a">Capturing</td>
    <td class="tm-7k3a">Captured</td>
  </tr>
'

$htmlNodeRed =
'
  <tr>
    <td class="tm-yw4l">PENDING</td>
    <td class="tm-yw4l">CAPTURING</td>
    <td class="tm-yw4l">CAPTURED</td>
  </tr>
'

$htmlEnd =
'
</table>
'
#endregion
$ReportHTMLFile = "AzureFleetSmokeTestStatus.html"
if (!(Test-Path -Path ".\AzureFleetSmokeTestStatus.html")) {
    $htmlHeader = $TableStyle + $htmlHeader
}

#region Get Title...

$htmlHeader = $htmlHeader.Replace("STATUS_TITLE","All Azure Marketplace Images Captured until now:")
#endregion

#region build HTML Page
$finalHTMLString = $htmlHeader

$currentNode = $htmlNodeRed
$currentNode = $currentNode.Replace("PENDING","$notStartedCount")
$currentNode = $currentNode.Replace("CAPTURING","$runningCount")
$currentNode = $currentNode.Replace("CAPTURED","$passedCount")
$finalHTMLString += $currentNode
$finalHTMLString += $htmlEnd

Add-Content -Value $finalHTMLString -Path $ReportHTMLFile
Write-Host "Azure Fleet Smoke Test report is ready."
#endregion
