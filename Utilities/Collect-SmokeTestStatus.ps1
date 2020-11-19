##############################################################################################
# Copyright (c) Microsoft Corporation
# Licensed under the Apache License.
#
# Collect-SmokeTestStatus.ps1
###############################################################################################
Param
(
    [String] $AzureSecretsFile,
    [String] $TestPass,
    [String] $DbServer,
    [String] $DbName,
    [String] $Title,
    [String] $TestProject = "Azure Smoke Test"
)

#Load libraries
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Definition
$commonModulePath = Join-Path $scriptPath "CommonFunctions.psm1"
Import-Module $commonModulePath

$StatusNotStarted = "NotStarted"
$StatusRunning = "Running"
$StatusDone = "Done"

$Passed = "PASSED"
$Failed = "FAILED"

function Get-DoneCount($connection, $testPassId, $testResult) {
    $sql = "
    With 
    LatestNewResult as (
        select *
        from TestResult
        where Id in (
            select max(TestResult.Id)
            from TestResult, TestRun
            where TestResult.RunId = TestRun.Id and 
            TestRun.TestPassId = @TestPassId and
            Image is not null group by image
        )
    )
    select count(*) from LatestNewResult where status='$testResult'"

    $parameters = @{"@TestPassId" = $testPassId}
    $results = QuerySql $connection $sql $parameters
    $count = ($results[0][0]) -as [int]
    Write-LogInfo "The $testResult count is $count"

    return $count
}

function Get-TotalCount($connection, $testPassId) {
    $sql = "
    select Count(Image) from TestPassCache
    where TestPassId=@TestPassId"

    $parameters = @{"@TestPassId" = $testPassId}
    $results = QuerySql $connection $sql $parameters
    $count = ($results[0][0]) -as [int]
    Write-LogInfo "The total count is $count"

    return $count
}

function Get-RunningCount($connection, $testPassId) {
    $sql = "
    select Count(Image) from TestPassCache
    where TestPassId=@TestPassId and Status='$StatusRunning'"

    $parameters = @{"@TestPassId" = $testPassId}
    $results = QuerySql $connection $sql $parameters
    $count = ($results[0][0]) -as [int]
    Write-LogInfo "The running count is $count"

    return $count
}

function Get-NotStartedCount($connection, $testPassId) {
    $sql = "
    select Count(Image) from TestPassCache
    where TestPassId=@TestPassId and Status='$StatusNotStarted'"

    $parameters = @{"@TestPassId" = $testPassId}
    $results = QuerySql $connection $sql $parameters
    $count = ($results[0][0]) -as [int]
    Write-LogInfo "The not started count is $count"

    return $count
}

function Get-Details ($connection, $testPassId) {
    $sql = "
    With LatestResult as (
        select *
        from TestResult
        where Id in (
            select max(TestResult.Id)
            from TestResult, TestRun
            where TestResult.RunId=TestRun.id and
            TestRun.TestPassId=@TestPassId and
            Image is not null group by Image
        )
    ),
    FailureSummary as (
        select count(a.Id) as Count, a.STATUS as Status, a.FailureId, c.Reason
        from LatestResult a, TestRun b, TestFailure c
        where a.RunId=b.id and 
        a.id in (
            select Id from LatestResult
        ) and 
        c.id=a.FailureId
        group by a.STATUS, a.FailureId, c.Reason
    ),
    FailureSample as (
        select max(id) id, FailureId
        from LatestResult a
        group by FailureId
    )
    select a.*, b.Id as SampleId, b.Image as SampleImage, b.Message as SampleMessage
    from FailureSummary a left join LatestResult b on a.FailureId = b.FailureId
    where b.id in (
        select id from FailureSample)
    order by a.status, count desc"

    $parameters = @{"@TestPassId" = $testPassId}
    $results = QuerySql $connection $sql $parameters
    return $results
}

function Get-TestPassId ($connection, $testPass, $testProject) {
    $sql = "
    select TestPass.Id from TestPass, TestProject
    where TestProject.Name = @testProject and 
    TestProject.Id = TestPass.ProjectId and TestPass.Name = @TestPass
    "
    $parameters = @{"@TestPass" = $testPass; "@TestProject" = $testProject}
    $result = Querysql $connection $sql $parameters
    if ($result -and $result.Id) {
        $Id = $result.Id
        return $Id
    }
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

    # Get the TestPassId from TestPass table
    $testPassId = Get-TestPassId $connection $TestPass $TestProject
    if (!$testPassId) {
        Write-LogErr "There is no $TestPass record in TestPass table"
        exit 1
    }

    $totalCount = Get-TotalCount $connection $testPassId
    $notStartedCount = Get-NotStartedCount $connection $testPassId
    $runningCount = Get-RunningCount $connection $testPassId
    $failedCount = Get-DoneCount $connection $testPassId $Failed
    $passedCount = Get-DoneCount $connection $testPassId $Passed
    $details = Get-Details $connection $testPassId
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
# border="0" cellpadding="0" cellspacing="0" style="border-collapse:collapse"
$htmlHeader = '
<h3>&bull;&nbsp;STATUS_TITLE</h3>
<table class="tm">
  <tr>
    <th class="tm-dk6e" colspan="9">Azure Fleet Smoke Test Status</th>
  </tr>
  <tr>
    <td class="tm-7k3a">Total Images Count</td>
    <td class="tm-7k3a">Not Started</td>
    <td class="tm-7k3a">Running</td>
    <td class="tm-7k3a">Passed</td>
    <td class="tm-7k3a">Failed</td>
  </tr>
'

$htmlNode =
'
  <tr>
    <td class="tm-yw4l">TOTAL</td>
    <td class="tm-yw4l">NOTSTARTED</td>
    <td class="tm-yw4l">RUNNING</td>
    <td class="tm-yw4l">PASSED</td>
    <td class="tm-yw4l">FAILED</td>
  </tr>
'

$htmlSubHeader = '
<h4>&bull;&nbsp;Details</h4>
<table class="tm">
  <tr>
    <td class="tm-7k3a">Count</td>
    <td class="tm-7k3a">Status</td>
    <td class="tm-7k3a">FailureId</td>
    <td class="tm-7k3a">Reason</td>
    <td class="tm-7k3a">SampleId</td>
    <td class="tm-7k3a">SampleImage</td>
  </tr>
'

$htmlSubNode =
'
  <tr>
    <td class="tm-yw4l">COUNT</td>
    <td class="tm-yw4l">STATUS</td>
    <td class="tm-yw4l">FAILUREID</td>
    <td class="tm-yw4l">REASON</td>
    <td class="tm-yw4l">SAMPLEID</td>
    <td class="tm-yw4l">SAMPLEIMAGE</td>
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

$htmlHeader = $htmlHeader.Replace("STATUS_TITLE","$Title : $TestPass")
#endregion

#region build HTML Page
$finalHTMLString = $htmlHeader
$currentNode = $htmlNode
$currentNode = $currentNode.Replace("TOTAL","$totalCount")
$currentNode = $currentNode.Replace("NOTSTARTED","$notStartedCount")
$currentNode = $currentNode.Replace("RUNNING","$runningCount")
$currentNode = $currentNode.Replace("PASSED","$passedCount")
$currentNode = $currentNode.Replace("FAILED","$failedCount")
$finalHTMLString += $currentNode
$finalHTMLString += $htmlEnd

$finalHTMLString += $htmlSubHeader
foreach ($_ in $details) {
    $count = $_.Count
    $status = $_.Status
    $failureId = $_.FailureId
    $reason = $_.Reason
    $sampleId = $_.SampleId
    $sampleImage = $_.SampleImage
    $sampleMessage = $_.SampleMessage

    $currentNode = $htmlSubNode
    $currentNode = $currentNode.Replace("COUNT","$count")
    $currentNode = $currentNode.Replace("STATUS","$status")
    $currentNode = $currentNode.Replace("FAILUREID","$failureId")
    $currentNode = $currentNode.Replace("REASON","$reason")
    $currentNode = $currentNode.Replace("SAMPLEID","$sampleId")
    $currentNode = $currentNode.Replace("SAMPLEIMAGE","$sampleImage")
    $finalHTMLString += $currentNode
}

$finalHTMLString += $htmlEnd

Add-Content -Value $finalHTMLString -Path $ReportHTMLFile
Write-Host "Azure Fleet Smoke Test report is ready."
#endregion
