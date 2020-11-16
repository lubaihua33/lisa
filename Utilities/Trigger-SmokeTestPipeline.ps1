##############################################################################################
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.
#
# Trigger-SmokeTestPipeline.ps1
<#
.SYNOPSIS
    This script is to trigger Azure Fleet Smoke Test pipeline
.PARAMETER
    -OrganizationUrl, The URL of the organization. (https://dev.azure.com/[organization])
    -AzureDevOpsProjectName, The project where the pipeline resides
    -DevOpsPAT, The personal access token
    -ParentPipelineName, The parent pipeline name
    -ChildPipelineName, The child pipeline name
    -BatchSize, The count of images are tested in one pipeline
    -TestPass, The TestPass name
Documentation

.NOTES
    Creation Date:
    Purpose/Change:

.EXAMPLE
    Trigger-SmokeTestPipeline.ps1 -OrganizationUrl $OrganizationUrl -AzureDevOpsProjectName $AzureDevOpsProjectName `
    -ParentPipelineName $ParentPipelineName -ChildPipelineName $ChildPipelineName -DevOpsPAT $DevOpsPAT `
    -AzureSecretsFile $env:SECRET_FILE -TestPass $TestPassName
#>
###############################################################################################
Param
(
    [String] $OrganizationUrl,
    [String] $AzureDevOpsProjectName,
    [String] $DevOpsPAT,
    [String] $ParentPipelineName,
    [String] $ChildPipelineName,
    [String] $AzureSecretsFile,
    [String] $TestPass,
    [String] $DbServer,
    [String] $DbName,
    [int] $Concurrent = 80,
    [int] $BatchSize = 20
)

$StatusNotStarted = "NotStarted"
$StatusRunning = "Running"
$StatusDone = "Done"
$NotRun = "NOTRUN"
$Running = "RUNNING"
$ExitCode = 0

$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Definition
$commonModulePath = Join-Path $scriptPath "CommonFunctions.psm1"
Import-Module $commonModulePath

$RunningBuildList = New-Object System.Collections.ArrayList

$PipelineLogDir = "trigger-pipeline"
$PipelineLogFileName = "smoke-test-$(Get-Date -Format 'yyyy-MM-dd').log"

function Add-RunningBuildList($buildID, $location) {
    $info = @{BuildID = $buildID; Location = $location}
    $RunningBuildList.Add($info) | Out-Null
}

function Get-TestPassId ($connection, $TestPass) {
    $sql = "
    select Id from TestPass
    where ProjectId = 1 and Name = @TestPass
    "

    $parameters = @{"@TestPass" = $testPass}
    $result = Querysql $connection $sql $parameters
    if ($result -and $result.Id) {
        $Id = $result.Id
        return $Id
    } else {
        $sql = "
        insert into TestPass(ProjectId, Name, StartedDate, CreateDate)
        values ('1', @TestPass, getutcdate(), getutcdate())
        select Id from TestPass
        Where ProjectId = 1 and Name = @TestPass
        "

        $parameters = @{"@TestPass" = $testPass}
        $result = QuerySql $connection $sql $parameters
        if ($result -and $result.Id) {
            $Id = $result.Id
            return $Id
        }
    }
}

function Add-TestPassCache($connection, $testPassId) {
    $sql = "
    with groups as (
        select 
            [AzureMarketplaceDistroInfo].Location,
            FullName,
            ROW_NUMBER() OVER (
                PARTITION BY FullName
                ORDER BY Priority) as RowNumber
        from [AzureMarketplaceDistroInfo], [AzureLocationInfo]
        where IsAvailable=1 and [AzureMarketplaceDistroInfo].location = [AzureLocationInfo].location
        )
    insert into TestPassCache(Location, Image, Status, TestPassId, CreatedDate)
    select Location, FullName, '$StatusNotStarted', @TestPassId, getutcdate()
    from groups
    where groups.rowNumber=1"

    $parameters = @{"@TestPassId" = $testPassId }
    ExecuteSql $connection $sql $parameters
}

function Initialize-TestPassCache($connection, $testPassId)
{
    $sql = "select count(*) from TestPassCache where TestPassId=@TestPassId"
    $parameters = @{"@TestPassId" = $testPassId }
    $results = QuerySql $connection $sql $parameters
    $dataNumber = ($results[0][0]) -as [int]

    if ($dataNumber -eq 0) {
        Write-LogInfo "Initialize test pass cahce"
        Add-TestPassCache $connection $testPassId
    }
    else {
        # reset running status
        if ($RunningBuildList.Count -gt 0) {
            $List = $RunningBuildList | ForEach-Object {$_.BuildID}
            $buildIdList = [string]::Join(",", $List)
            $sql = "
            UPDATE TestPassCache
            SET Status='$StatusNotStarted', UpdatedDate=getutcdate()
            WHERE TestPassId=@TestPassId and Status='$StatusRunning' and
            Context not in ($buildIdList)"
        } else {
            $sql = "
            UPDATE TestPassCache
            SET Status='$StatusNotStarted', UpdatedDate=getutcdate()
            WHERE TestPassId=@TestPassId and Status='$StatusRunning'"
        }
        $parameters = @{"@TestPassId" = $testPassId }
        ExecuteSql $connection $sql $parameters
        Write-LogInfo "Reuse existing test pass cache"
    }
}

function Sync-RunningBuild ($connection, $testPassId) {
    Write-LogInfo "Sync up with running builds"
    $result = Invoke-Pipeline -OrganizationUrl $OrganizationUrl -AzureDevOpsProjectName $AzureDevOpsProjectName `
                              -PipelineName $ChildPipelineName -DevOpsPAT $DevOpsPAT -OperateMethod "List"

    if ($result -and $result.value) {
        $List = $result.value | ForEach-Object -Process {if ($_.state -eq 'inProgress' -or $_.state -eq 'postponed') {$_.id}}
        if ($List) {
            $buildIdList = [string]::Join(",", $List)
            Write-LogDbg "The builds $buildIdList state is inProgress or postponed"

            $sql = "
            select distinct Context, Location
            from TestPassCache 
            where TestPassId=@TestPassId and Status='$StatusRunning' and 
            Context in ($buildIdList)"

            $parameters = @{"@TestPassId" = $testPassId}
            $results = QuerySql $connection $sql $parameters
            foreach ($_ in $results) {
                $buildId = $_.Context
                $location = $_.Location

                Write-LogInfo "The builds $buildId is still running. Add it into running build list"
                Add-RunningBuildList $buildId $location
            }
        }
    }
}

function Invoke-BatchTest($connection, $location, $batchCount) {
    $sql = "
    select count(Image) from TestPassCache
    where Location='$location' and TestPassId=@TestPassId and 
    Status='$StatusNotStarted'"

    $parameters = @{"@TestPassId" = $testPassId}
    $results = QuerySql $connection $sql $parameters
    $count = ($results[0][0]) -as [int]
    if ($count -eq 0) {
        Write-LogInfo "No image in the location $location need to trigger testing"
        return $count
    }
    $imagesCount = [math]::Min($count, $batchCount)

    $BuildBody = New-Object PSObject -Property @{
        variables = New-Object PSObject -Property @{
            Location   = New-Object PSObject -Property @{value = $location}
            ImagesCount = New-Object PSObject -Property @{value = $ImagesCount}
            TestPass = New-Object PSObject -Property @{value = $TestPass}
        }
    }
    $result = Invoke-Pipeline -OrganizationUrl $OrganizationUrl -AzureDevOpsProjectName $AzureDevOpsProjectName `
                                -PipelineName $ChildPipelineName -DevOpsPAT $DevOpsPAT -BuildBody $BuildBody `
                                -OperateMethod "Run"
    if ($result -and $result.id) {
        $buildId = $result.id
        $sql = "
        update top ($imagesCount) TestPassCache
        set Context=$buildId, Status='$StatusRunning', UpdatedDate=getutcdate()
        where Location='$location' and TestPassId=@TestPassId and 
        Status='$StatusNotStarted'"

        $parameters = @{"@TestPassId" = $testPassId }
        ExecuteSql $connection $sql $parameters

        Add-RunningBuildList $buildId $location
        Write-LogInfo "The pipeline #Build $($buildId) will run $ImagesCount images in $location"
        return $ImagesCount
    } else {
        Write-LogErr "Failed to Trigger ADO pipeline"
    }
}

function Update-TestPassCacheDone($connection, $testPassId) {
    Write-LogInfo "Update test pass cache done"
    $sql = "
    With Runnings as (
        select *
        from TestPassCache
        where TestPassId=@TestPassId
            and Status='$StatusRunning'
    ),
    TestResults as (
        select *
        from TestResult 
        where Id in (
            select max(TestResult.Id)
            from TestRun,TestResult
            where TestRun.TestPassId = @TestPassId  and
            TestRun.Id = TestResult.RunId and
            TestResult.Status <> '$NotRun' and
            TestResult.Status <> '$Running' group by TestResult.Image
        )
    )
    update TestPassCache
    set Status='$StatusDone', UpdatedDate=getutcdate()
    where TestPassId=@TestPassId and ID in (
        select Runnings.ID from Runnings left join TestResults on 
            Runnings.Location = TestResults.Location and
            Runnings.Image = TestResults.Image and
            Runnings.UpdatedDate < TestResults.UpdatedDate
        where Runnings.TestPassId = @TestPassId and TestResults.Id is not null
    )"
    $parameters = @{"@TestPassId" = $testPassId }
    ExecuteSql $connection $sql $parameters
}

function Get-MissingCount($connection, $testPassId, $BuildId) {
    $sql = "
    select Count(Image) from TestPassCache
    where Context=$BuildId and Status='$StatusRunning'"

    $parameters = @{"@TestPassId" = $testPassId}
    $results = QuerySql $connection $sql $parameters
    $count = ($results[0][0]) -as [int]
    Write-LogInfo "The missing image count is $count"

    return $count
}

function Get-DoneCount($connection, $testPassId) {
    $sql = "
    select Count(Image) from TestPassCache
    where TestPassId=@TestPassId and Status='$StatusDone'"

    $parameters = @{"@TestPassId" = $testPassId}
    $results = QuerySql $connection $sql $parameters
    $count = ($results[0][0]) -as [int]
    Write-LogInfo "The completed count is $count"

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

###################################################################################################
# The main process
###################################################################################################

# Check if have the same TestPass pipeline
do {
    $isAlreadyExist = $false
    $result = Invoke-Pipeline -OrganizationUrl $OrganizationUrl -AzureDevOpsProjectName $AzureDevOpsProjectName `
                            -PipelineName $ParentPipelineName -DevOpsPAT $DevOpsPAT -OperateMethod "List"

    $List = $result.value | ForEach-Object -Process {if ($_.state -eq 'inProgress' -or $_.state -eq 'postponed') {$_}}
    if ($List.count) {
        foreach ($_ in $List) {
            if ($_.name -imatch "$TestPass") {
                $isAlreadyExist = $true
                Write-LogInfo "There is already one pipeline to run $TestPass testing. Wait 30s.."
                start-sleep -Seconds 30
                continue
            }
        }
    }
} while ($isAlreadyExist -eq $true)

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
    $testPassId = Get-TestPassId $connection $TestPass

    # Sync all the running job of the same test pass
    Sync-RunningBuild $connection $testPassId
    Initialize-TestPassCache $connection $testPassId

    $totalCompleted = 0
    $hasMoreData = $true

    # We should distinct location for the scenario of tip session
    $sql = "select distinct Location from TestPassCache where TestPassId=@TestPassId"
    $parameters = @{"@TestPassId" = $testPassId}
    $rows = QuerySql $connection $sql $parameters
    $hasMoreDataOfLocation = @()
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $hasMoreDataOfLocation += @($true)
    }

    while ($hasMoreData -eq $true -or $RunningBuildList.Count -gt 0) {
        Update-TestPassCacheDone $connection $testPassId
        for ($i = 0; $i -lt $rows.Count; $i++) {
            $location = $rows[$i].Location
            # todo all the query need location
            while ($RunningBuildList.Count -lt $Concurrent -and $hasMoreDataOfLocation[$i] -eq $true) {
                $runCount = Invoke-BatchTest $connection $location $BatchSize
                if ($runCount -eq 0) {
                    $hasMoreDataOfLocation[$i] = $false
                }
            }
        }

        $sum = 0
        $hasMoreDataOfLocation | ForEach-Object {$sum += [int]$_}
        $hasMoreData = [bool]$sum

        # Check the status of running build
        for ($i = 0; $i -lt $RunningBuildList.Count; $i++) {
            $buildId = $RunningBuildList[$i].BuildID
            $result = Invoke-Pipeline -OrganizationUrl $OrganizationUrl -AzureDevOpsProjectName $AzureDevOpsProjectName `
                                      -PipelineName $ChildPipelineName -DevOpsPAT $DevOpsPAT -BuildID $buildId `
                                      -OperateMethod "Get"
            if ($result -and $result.state -ne "inProgress" -and $result.state -ne "postponed") {
                Write-LogDbg "The pipeline #Build $buildId has stopped"
                $totalCompleted++
                Update-TestPassCacheDone $connection $testPassId

                Write-LogDbg "Get missing images count in the build $buildId"
                $missingCount = Get-MissingCount $connection $testPassId $buildId
                if ($missingCount -gt 0) {
                    Write-LogDbg "Update TestPassCache set the status to NotStarted where the status is Running and the Context is $buildId"
                    $sql = "
                    update TestPassCache
                    set Status = '$StatusNotStarted'
                    where Context = $buildId and Status='$StatusRunning'"

                    ExecuteSql $connection $sql
                    $hasMoreData = $true
                }
                Write-LogDbg "The pipeline #Build $($RunningBuildList[$i].BuildID) has stopped"
                Write-LogDbg "Remove it from the running buildid list"
                $RunningBuildList.RemoveAt($i)
                $i--
            }
        }
        Write-LogInfo "Total $($totalCompleted) completed jobs, $($RunningBuildList.Count) running jobs"
        $doneCount = Get-DoneCount $connection $testPassId
        $runningCount = Get-RunningCount $connection $testPassId
        Write-LogInfo "Total $($doneCount) completed images, $($runningCount) running images"

        $sql = "
        select count(Image) from TestPassCache
        where TestPassId=@TestPassId and Status='$StatusNotStarted'"

        $parameters = @{"@TestPassId" = $TestPassId}
        $results = QuerySql $connection $sql $parameters
        $count = ($results[0][0]) -as [int]
        if ($count -ne 0) {
            $hasMoreData = $true
        }

        if ($hasMoreData -eq $true -or $RunningBuildList.Count -gt 0) {
            start-sleep -Seconds 120
        }
    }
    Write-LogInfo "All builds have completed."
} 
catch {
    $line = $_.InvocationInfo.ScriptLineNumber
    $script_name = ($_.InvocationInfo.ScriptName).Replace($PWD,".")
    $ErrorMessage =  $_.Exception.Message
    Write-LogErr "EXCEPTION : $ErrorMessage"
    Write-LogErr "Source : Line $line in script $script_name."
    $ExitCode = 1
    exit $ExitCode
} 
finally {
    if ($null -ne $connection) {
        $connection.Close()
        $connection.Dispose()
    }

    exit $ExitCode
}
