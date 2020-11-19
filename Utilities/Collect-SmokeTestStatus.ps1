##############################################################################################
# Copyright (c) Microsoft Corporation
# Licensed under the Apache License.
#
# Collect-SmokeTestStatus.ps1
# $TestPass, It is the latest testpass name
# $PreTestPass, It is the previous testpass name, which you want to compare with the lastest testpass
# $TestPassCount, We have a status summary table, here we can list multiple testpass' summary data
#                 TestPassCount is the count of testpass we want to list.
###############################################################################################
Param
(
    [String] $AzureSecretsFile,
    [String] $TestPass,
    [String] $PreTestPass,
    [String] $DbServer,
    [String] $DbName,
    [String] $Title,
    [String] $TestPassCount,
    [String] $TestProject = "Azure Smoke Test"
)

# Load libraries
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Definition
$commonModulePath = Join-Path $scriptPath "CommonFunctions.psm1"
Import-Module $commonModulePath

$StatusNotStarted = "NotStarted"
$StatusRunning = "Running"

$Passed = "PASSED"
$Failed = "FAILED"

function Get-DoneCount($connection, $testPassId, $testResult) {
    $sql = "
    With LatestNewResult as (
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

function Get-NewImagesCount ($connection, $testPassId, $preTestPassId) {
    $sql = "
    with new as (
        select distinct Image from TestPassCache where TestPassId=@TestPassId
    ),
    old as (
        select distinct Image from TestPassCache where TestPassId=@PreTestPassId
    )
    select count(*)
    from new left join old on
    new.Image = old.Image where old.Image is null"

    $parameters = @{"@TestPassId" = $testPassId; "@PreTestPassId" = $preTestPassId}
    $results = QuerySql $connection $sql $parameters
    $count = ($results[0][0]) -as [int]
    Write-LogInfo "The new images count is $count"

    return $count

}

function Get-NotAvailableCount ($connection, $testPassId, $preTestPassId) {
    $sql = "
    with new as (
        select distinct Image from TestPassCache where TestPassId=@TestPassId
    ),
    old as (
        select distinct Image from TestPassCache where TestPassId=@PreTestPassId
    )
    select count(*)
    from old left join new on
    new.Image = old.Image where new.Image is null"

    $parameters = @{"@TestPassId" = $testPassId; "@PreTestPassId" = $preTestPassId}
    $results = QuerySql $connection $sql $parameters
    $count = ($results[0][0]) -as [int]
    Write-LogInfo "The not available images count is $count"

    return $count
}

function Get-SameImagsCount ($connection, $testPassId, $preTestPassId) {
    $sql = "
    with new as (
        select distinct Image from TestPassCache where TestPassId=@TestPassId
    ),
    old as (
        select distinct Image from TestPassCache where TestPassId=@PreTestPassId
    )
    select count(*)
    from old left join new on
    new.Image = old.Image where new.Image is not null"

    $parameters = @{"@TestPassId" = $testPassId; "@PreTestPassId" = $preTestPassId}
    $results = QuerySql $connection $sql $parameters
    $count = ($results[0][0]) -as [int]
    Write-LogInfo "The same images count is $count"

    return $count
}

function Get-NewPassedOldFailedCount ($connection, $testPassId, $preTestPassId) {
    $sql = "
    With LatestNewResult as (
        select *
        from TestResult
        where Id in (
            select max(TestResult.Id)
            from TestResult, TestRun
            where TestResult.RunId = TestRun.Id and 
            TestRun.TestPassId = @TestPassId and
            Image is not null group by image
        )
    ),
    OldResult as (
        select *
        from TestResult
        where Id in (
            select max(TestResult.Id)
            from TestResult, TestRun
            where TestResult.RunId = TestRun.Id and 
            TestRun.TestPassId = @PreTestPassId and
            Image is not null group by image
        )
    )
    select count(*) as number
    from OldResult old, LatestNewResult new
    where old.Image = new.Image and 
    new.Status = 'PASSED' and old.Status = 'FAILED'
    "
    $parameters = @{"@TestPassId" = $testPassId; "@PreTestPassId" = $preTestPassId}
    $results = QuerySql $connection $sql $parameters
    $count = ($results[0][0]) -as [int]
    Write-LogInfo "$count failed in previous run, but passed in the latest run"

    return $count
}

function Get-NewFailedOldPassedCount ($connection, $testPassId, $preTestPassId) {
    $sql = "
    With LatestNewResult as (
        select *
        from TestResult
        where Id in (
            select max(TestResult.Id)
            from TestResult, TestRun
            where TestResult.RunId = TestRun.Id and 
            TestRun.TestPassId = @TestPassId and
            Image is not null group by image
        )
    ),
    OldResult as (
        select *
        from TestResult
        where Id in (
            select max(TestResult.Id)
            from TestResult, TestRun
            where TestResult.RunId = TestRun.Id and 
            TestRun.TestPassId = @PreTestPassId and
            Image is not null group by image
        )
    )
    select count(*) as number
    from OldResult old, LatestNewResult new
    where old.Image = new.Image and 
    new.Status = 'FAILED' and old.Status = 'PASSED'
    "
    $parameters = @{"@TestPassId" = $testPassId; "@PreTestPassId"  = $preTestPassId}
    $results = QuerySql $connection $sql $parameters
    $count = ($results[0][0]) -as [int]
    Write-LogInfo "$count passed in previous run, but failed in the latest run"

    return $count
}

function Get-GapDetails ($connection, $testPassId, $preTestPassId) {
    $sql = "
    With LatestNewResult as (
        select *
        from TestResult
        where Id in (
            select max(TestResult.Id)
            from TestResult, TestRun
            where TestResult.RunId = TestRun.Id and 
            TestRun.TestPassId = @TestPassId and
            Image is not null group by image
        )
    ),
    OldResult as (
        select *
        from TestResult
        where Id in (
            select max(TestResult.Id)
            from TestResult, TestRun
            where TestResult.RunId = TestRun.Id and 
            TestRun.TestPassId = @PreTestPassId and
            Image is not null group by image
        )
    )
    SELECT count(b.id) as Count, a.Status as OldResult, b.Status as NewResult, 
    a.FailureId as OldFailureId, b.FailureId as NewFailureId, c.Reason as OldReason, d.Reason as NewReason
    FROM OldResult a
    inner JOIN LatestNewResult b ON (a.image = b.Image) left join testfailure c on 
    c.id=a.FailureId left join testfailure d on d.id=b.FailureId
    WHERE (a.Status!='PASSED' and b.Status='PASSED') or (a.Status='PASSED' and b.Status!='PASSED')
    group by a.FailureId, b.FailureId, c.Reason, d.Reason, a.Status, b.Status
    order by a.Status, Count desc
    "

    $parameters = @{"@TestPassId" = $testPassId;  "@PreTestPassId"  = $preTestPassId}
    $results = QuerySql $connection $sql $parameters
    return $results
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

function Get-TestPassIdList ($connection, $testProject, $testPassCount) {
    $sql = "
    select top(@TestPassCount) TestPass.Id from TestPass, TestProject
    where TestProject.Name = @testProject and 
    TestProject.Id = TestPass.ProjectId
    order by Id desc
    "
    $parameters = @{"@TestPassCount" = $TestPassCount; "@TestProject" = $testProject}
    $result = Querysql $connection $sql $parameters
    $testPassIdList = @()
    foreach ($_ in $result) {
        $testPassIdList += @($_.Id)
    }
    return $testPassIdList
}

function Get-TestPassId ($connection, $testProject, $testPass) {
    $sql = "
    select TestPass.Id from TestPass, TestProject
    where TestProject.Name = @testProject and 
    TestProject.Id = TestPass.ProjectId and TestPass.Name = @TestPass
    "
    $parameters = @{"@TestPass" = $TestPass; "@TestProject" = $testProject}
    $result = Querysql $connection $sql $parameters
    if ($result -and $result.Id) {
        return $result.Id
    }
}

function Get-TestPassName ($connection, $testPassId) {
    $sql = "
    select Name from TestPass where Id = @testPassId"

    $parameters = @{"@testPassId" = $testPassId}
    $result = Querysql $connection $sql $parameters
    if ($result -and $result.Name) {
        Write-LogInfo "The name of testpass $testPassId is $($result.Name)"
        return $result.Name
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

    # Get the TestPassId list from TestPass table
    $testPassIdList = @()
    if ($testPassCount) {
        $testPassIdList = Get-TestPassIdList $connection $TestProject $TestPassCount
        if (!$testPassIdList) {
            Write-LogErr "There is no record for $TestProject in TestPass table"
            exit 1
        }
    }

    # Get the latest TestPassId and previous TestPassId
    $latestTestPassId = Get-TestPassId $connection $TestProject $TestPass
    if (!$latestTestPassId) {
        Write-LogErr "There is no $TestPass record for $TestProject in TestPass table"
        exit 1
    }

    $preTestPassId = Get-TestPassId $connection $TestProject $PreTestPass
    if (!$preTestPassId) {
        Write-LogErr "There is no $PreTestPass record for $TestProject in TestPass table"
        exit 1
    }

    $statusSummaryList = @()
    if (!$testPassIdList) {
        $testPassIdList = @()
        $testPassIdList += @($latestTestPassId)
        $testPassIdList += @($preTestPassId)
    }
    foreach ($_ in $testPassIdList) {
        $statusSummary = @{}
        $statusSummary["TestPass"] = Get-TestPassName $connection $_
        $statusSummary["Total Images"] = Get-TotalCount $connection $_
        $statusSummary["Not Started"] = Get-NotStartedCount $connection $_
        $statusSummary["Running"] = Get-RunningCount $connection $_
        $statusSummary["Failed"] = Get-DoneCount $connection $_ $Failed
        $statusSummary["Passed"] = Get-DoneCount $connection $_ $Passed
        $statusSummaryList += @($statusSummary)
    }

    $details = Get-Details $connection $latestTestPassId
    $newImagesCount = Get-NewImagesCount $connection $latestTestPassId $preTestPassId
    $notAvailableCount = Get-NotAvailableCount $connection $latestTestPassId $preTestPassId
    $sameImagesCount = Get-SameImagsCount $connection $latestTestPassId $preTestPassId

    $newPassedOldFailedCount = Get-NewPassedOldFailedCount $connection $latestTestPassId $preTestPassId
    $newFailedOldPassedCount = Get-NewFailedOldPassedCount $connection $latestTestPassId $preTestPassId
    $gapDetails = Get-GapDetails $connection $latestTestPassId $preTestPassId
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
  .tm td{font-family:Arial, sans-serif;font-size:13px;padding:8px 5px;border-style:solid;border-width:1px;overflow:hidden;word-break:normal;border-color:#999;color:#444;background-color:#F7FDFA;}
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
$summaryHeader = '
<h3>&bull;&nbsp;STATUS_TITLE</h3>
<table class="tm">
  <tr>
    <td class="tm-7k3a">TestPass</td>
    <td class="tm-7k3a">Total Images</td>
    <td class="tm-7k3a">Not Started</td>
    <td class="tm-7k3a">Running</td>
    <td class="tm-7k3a">Passed</td>
    <td class="tm-7k3a">Failed</td>
  </tr>
'

$summaryNode =
'
  <tr>
    <td class="tm-yw4l">TESTPASS</td>
    <td class="tm-yw4l">TOTAL</td>
    <td class="tm-yw4l">NOTSTARTED</td>
    <td class="tm-yw4l">RUNNING</td>
    <td class="tm-yw4l">PASSED</td>
    <td class="tm-yw4l">FAILED</td>
  </tr>
'

$imagesCountGapHeader = '
<h4>&nbsp;IMAGES_COUNT_GAP</h4>
'
$imagesCountGapNode ='
<table class="tm">
  <tr>
    <td class="tm-7k3a">New Images</td>
    <td class="tm-yw4l">NEW</td>
  </tr>
  <tr>
    <td class="tm-7k3a">Not Available</td>
    <td class="tm-yw4l">NOT_AVAILABLE</td>
  </tr>
  <tr>
    <td class="tm-7k3a">Same Images</td>
    <td class="tm-yw4l">SAME</td>
  </tr>
'

$ResultGapHeader = '
<h3>&bull;&nbsp;RESULTS_GAP_DESC</h3>
<h4>&nbsp;INCONSISTENT_STATUS</h4>
<table class="tm">
  <tr>
    <td class="tm-7k3a">Count</td>
    <td class="tm-7k3a">OldResult</td>
    <td class="tm-7k3a">NewResult</td>
    <td class="tm-7k3a">OldFailureId</td>
    <td class="tm-7k3a">OldReason</td>
    <td class="tm-7k3a">NewFailureId</td>
    <td class="tm-7k3a">NewReason</td>
  </tr>
'
$ResultGapNode =
'
  <tr>
    <td class="tm-yw4l">COUNT</td>
    <td class="tm-yw4l">OLDRESULT</td>
    <td class="tm-yw4l">NEWRESULT</td>
    <td class="tm-yw4l">OLDID</td>
    <td class="tm-yw4l">OLDREASON</td>
    <td class="tm-yw4l">NEWID</td>
    <td class="tm-yw4l">NEWREASON</td>
  </tr>
'

$htmlSubHeader = '
<h3>&bull;&nbsp;DETAILS</h3>
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
    $summaryHeader = $TableStyle + $summaryHeader
}

$summaryHeader = $summaryHeader.Replace("STATUS_TITLE","$Title : $TestPass")
#region build HTML Page
$finalHTMLString = $summaryHeader
foreach ($_ in $statusSummaryList) {
    $currentNode = $summaryNode
    $currentNode = $currentNode.Replace("TESTPASS","$($_["TestPass"])")
    $currentNode = $currentNode.Replace("TOTAL","$($_["Total Images"])")
    $currentNode = $currentNode.Replace("NOTSTARTED","$($_["Not Started"])")
    $currentNode = $currentNode.Replace("RUNNING","$($_["Running"])")
    $currentNode = $currentNode.Replace("PASSED","$($_["Passed"])")
    $currentNode = $currentNode.Replace("FAILED","$($_["Failed"])")
    $finalHTMLString += $currentNode
}
$finalHTMLString += $htmlEnd

# Get the detail information
$imagesCountGap = "Compared with $PretestPass test pass, new images count is $newImagesCount, " + 
                  "$notAvailableCount images are not available, $sameImagesCount images are in both test pass."
$imagesCountGapHeader = $imagesCountGapHeader.Replace("IMAGES_COUNT_GAP", "$imagesCountGap")
$finalHTMLString += $imagesCountGapHeader
$currentNode = $imagesCountGapNode
$currentNode = $currentNode.Replace("NEW","$newImagesCount")
$currentNode = $currentNode.Replace("NOT_AVAILABLE","$notAvailableCount")
$currentNode = $currentNode.Replace("SAME","$sameImagesCount")
$finalHTMLString += $currentNode
$finalHTMLString += $htmlEnd

$inconsistentStatus = "$newFailedOldPassedCount passed in previous test pass, but failed in current. " +
                      "$newPassedOldFailedCount failed in previous test pass, but passed in current."
$ResultGapHeader = $ResultGapHeader.Replace("RESULTS_GAP_DESC", "Gaps with $PreTestPass test pass")
$ResultGapHeader = $ResultGapHeader.Replace("INCONSISTENT_STATUS", "$inconsistentStatus")
$finalHTMLString += $ResultGapHeader
foreach ($_ in $gapDetails) {
    $count = $_.Count
    $OldResult = $_.OldResult
    $NewResult = $_.NewResult
    $OldFailureId = $_.OldFailureId
    $OldReason = $_.OldReason
    $NewFailureId = $_.NewFailureId
    $NewReason = $_.NewReason

    $currentNode = $ResultGapNode
    $currentNode = $currentNode.Replace("COUNT","$count")
    $currentNode = $currentNode.Replace("OLDRESULT","$OldResult")
    $currentNode = $currentNode.Replace("NEWRESULT","$NewResult")
    $currentNode = $currentNode.Replace("OLDID","$OldFailureId")
    $currentNode = $currentNode.Replace("OLDREASON","$OldReason")
    $currentNode = $currentNode.Replace("NEWID","$NewFailureId")
    $currentNode = $currentNode.Replace("NEWREASON","$NewReason")
    $finalHTMLString += $currentNode
}
$finalHTMLString += $htmlEnd

$htmlSubHeader = $htmlSubHeader.Replace("DETAILS", "Details of $TestPass test pass")
$finalHTMLString += $htmlSubHeader
foreach ($_ in $details) {
    $count = $_.Count
    $status = $_.Status
    $failureId = $_.FailureId
    $reason = $_.Reason
    $sampleId = $_.SampleId
    $sampleImage = $_.SampleImage

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
