##############################################################################################
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.
#
# The microsoft-hosted agent has the limit of 6hs timeout. If a capture test cost 8min, 
# the count of 6hs is 45. So the $BatchSize is 45.
#>
###############################################################################################
Param
(
    [parameter(Mandatory=$true)][String] $OrganizationUrl,
    [parameter(Mandatory=$true)][String] $AzureDevOpsProjectName,
    [parameter(Mandatory=$true)][String] $DevOpsPAT,
    [parameter(Mandatory=$true)][String] $ParentPipelineName,
    [parameter(Mandatory=$true)][String] $ChildPipelineName,
    [parameter(Mandatory=$true)][String] $AzureSecretsFile,
    [parameter(Mandatory=$true)][String] $DbServer,
    [parameter(Mandatory=$true)][String] $DbName,
    [int] $Concurrent = 10,
    [int] $BatchSize = 40
)

$StatusNotStarted = "NotStarted"
$StatusRunning = "Running"
$StatusPassed = "Passed"
$StatusFailed = "Failed"
$ExitCode = 0

$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Definition
$commonModulePath = Join-Path $scriptPath "CommonFunctions.psm1"
Import-Module $commonModulePath

$RunningBuildList = New-Object System.Collections.ArrayList

$PipelineLogDir = "trigger-pipeline"
$PipelineLogFileName = "Capture-VHD-$(Get-Date -Format 'yyyy-MM-dd').log"

function Add-RunningBuildList($buildID) {
    $info = @{BuildID = $buildID}
    $RunningBuildList.Add($info) | Out-Null
}

function Initialize-CaptureImageInfo($connection)
{
    $sql = "
    WITH PassedImages AS (
        SELECT * FROM TestResult
        WHERE Id IN (
            SELECT max(TestResult.Id)
            FROM TestResult
            WHERE Status='Passed' GROUP BY TestResult.Image
        )
    ),
    CaptureImages AS (
        SELECT PassedImages.Image, PassedImages.Location
        from PassedImages LEFT JOIN CaptureImageInfo ON
        PassedImages.Image = CaptureImageInfo.ARMImage
        WHERE CaptureImageInfo.ID is null
    )
    INSERT INTO CaptureImageInfo(ARMImage, Location, Status)
    SELECT Image, Location, '$StatusNotStarted'
    FROM CaptureImages"

    Write-LogDbg "Insert into CaptureImageInfo new images"
    ExecuteSql $connection $sql $parameters

    if ($RunningBuildList.Count -gt 0) {
        $List = $RunningBuildList | ForEach-Object {$_.BuildID}
        $buildIdList = [string]::Join(",", $List)
        $sql = "
        UPDATE CaptureImageInfo
        SET Status='$StatusNotStarted'
        WHERE Status='$StatusRunning' and
        Context not in ($buildIdList)"
    } else {
        $sql = "
        UPDATE CaptureImageInfo
        SET Status='$StatusNotStarted'
        WHERE Status='$StatusRunning'"
    }

    Write-LogDbg "Update CaptureImageInfo to set the status NotStarted where the status is Running and the build pipeline stops"
    ExecuteSql $connection $sql $parameters
}

function Sync-RunningBuild ($connection) {
    Write-LogInfo "Sync up with running builds"
    $result = Invoke-Pipeline -OrganizationUrl $OrganizationUrl -AzureDevOpsProjectName $AzureDevOpsProjectName `
                              -PipelineName $ChildPipelineName -DevOpsPAT $DevOpsPAT -OperateMethod "List"

    if ($result -and $result.value) {
        $List = $result.value | ForEach-Object -Process {if ($_.state -eq 'inProgress' -or $_.state -eq 'postponed') {$_.id}}
        if ($List) {
            $buildIdList = [string]::Join(",", $List)
            Write-LogDbg "The builds $buildIdList state is inProgress or postponed"

            $sql = "
            SELECT distinct Context
            FROM CaptureImageInfo
            WHERE Status='$StatusRunning' and
            Context in ($buildIdList)"

            $results = QuerySql $connection $sql
            foreach ($_ in $results) {
                $buildId = $_.Context

                Write-LogInfo "The builds $buildId is still running. Add it into running build list"
                Add-RunningBuildList $buildId $location
            }
        }
    }
}

function Get-MissingCount($connection, $BuildId) {
    $sql = "
    SELECT Count(ARMImage) FROM CaptureImageInfo
    WHERE Context=$BuildId and Status='$StatusRunning'"

    $results = QuerySql $connection $sql
    $count = ($results[0][0]) -as [int]
    Write-LogInfo "The missing image count is $count"

    return $count
}

function Get-PassedCount($connection) {
    $sql = "
    SELECT Count(ARMImage) FROM CaptureImageInfo
    WHERE Status='$StatusPassed'"

    $results = QuerySql $connection $sql
    $count = ($results[0][0]) -as [int]
    Write-LogInfo "The Passed count is $count"

    return $count
}

function Get-FailedCount($connection) {
    $sql = "
    SELECT Count(ARMImage) FROM CaptureImageInfo
    WHERE Status='$StatusFailed'"

    $results = QuerySql $connection $sql
    $count = ($results[0][0]) -as [int]
    Write-LogInfo "The Failed count is $count"

    return $count
}

function Get-RunningCount($connection) {
    $sql = "
    SELECT Count(ARMImage) FROM CaptureImageInfo
    WHERE Status='$StatusRunning'"

    $results = QuerySql $connection $sql
    $count = ($results[0][0]) -as [int]
    Write-LogInfo "The running count is $count"

    return $count
}

function Invoke-BatchTest ($connection, $batchCount) {
    $sql = "
        SELECT Count(ARMImage)
        FROM CaptureImageInfo
        WHERE Status='$StatusNotStarted'"

    $results = QuerySql $connection $sql
    $count = ($results[0][0]) -as [int]
    if ($count -eq 0) {
        return $count
    }
    $imagesCount = [math]::Min($count, $batchCount)


    $BuildBody = New-Object PSObject -Property @{
        variables = New-Object PSObject -Property @{
            BatchCount = New-Object PSObject -Property @{value = $imagesCount}
        }
    }
    $result = Invoke-Pipeline -OrganizationUrl $OrganizationUrl -AzureDevOpsProjectName $AzureDevOpsProjectName `
                              -PipelineName $ChildPipelineName -DevOpsPAT $DevOpsPAT -BuildBody $BuildBody `
                              -OperateMethod "Run"
    if ($result -and $result.id) {
        $buildId = $result.id
        $sql = "
        UPDATE top ($imagesCount) CaptureImageInfo
        SET Status='$StatusRunning', Context=$buildId
        WHERE Status='$StatusNotStarted'"
        ExecuteSql $connection $sql

        Add-RunningBuildList $buildId
        Write-LogInfo "The pipeline #Build $buildId will run $imagesCount images"
        return $imagesCount
    } esle {
        Write-Error "Trigger pipeline failed, exit"
        exit 1
    }
}

###################################################################################################
# The main process
###################################################################################################

# Check if have the same pipeline
do {
    $isAlreadyExist = $false
    $result = Invoke-Pipeline -OrganizationUrl $OrganizationUrl -AzureDevOpsProjectName $AzureDevOpsProjectName `
                            -PipelineName $ParentPipelineName -DevOpsPAT $DevOpsPAT -OperateMethod "List"

    $List = $result.value | ForEach-Object -Process {if ($_.state -eq 'inProgress' -or $_.state -eq 'postponed') {$_}}
    if ($List.count) {
        $isAlreadyExist = $true
        Write-LogInfo "There is already one pipeline to run capture VHD testing. Wait 30s.."
        start-sleep -Seconds 30
        continue
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

    # Sync all the running jobs and initialize table
    Sync-RunningBuild $connection
    Initialize-CaptureImageInfo $connection

    $hasMoreData = $true
    $totalCompleted = 0

    while ($hasMoreData -eq $true -or $RunningBuildList.Count -gt 0) {
        while ($RunningBuildList.Count -lt $Concurrent -and $hasMoreData -eq $true) {
            $runCount = Invoke-BatchTest $connection $BatchSize
            if ($runCount -eq 0) {
                $hasMoreData = $false
            }
        }

        # Check the status of running build
        for ($i = 0; $i -lt $RunningBuildList.Count; $i++) {
            $buildId = $RunningBuildList[$i].BuildID
            $result = Invoke-Pipeline -OrganizationUrl $OrganizationUrl -AzureDevOpsProjectName $AzureDevOpsProjectName `
                                       -PipelineName $ChildPipelineName -DevOpsPAT $DevOpsPAT -BuildID $buildId `
                                       -OperateMethod "Get"
            if ($result -and $result.state -ne "inProgress" -and $result.state -ne "postponed") {
                Write-LogDbg "The pipeline #BuildId $buildId has stopped"
                $totalCompleted++

                Write-LogDbg "Get missing images count in the build $buildId"
                $missingCount = Get-MissingCount $connection $buildId
                if ($missingCount -gt 0) {
                    Write-LogDbg "Update CaptureImageInfo set the status to NotStarted where the status is Running and the Context is $buildId"
                    $sql = "
                    UPDATE CaptureImageInfo
                    SET Status='$StatusNotStarted'
                    WHERE Status='$StatusRunning' and Context=$buildId"
                    ExecuteSql $connection $sql

                    $hasMoreData = $true
                }
                Write-LogDbg "The pipeline #Build $($RunningBuildList[$i].BuildID) has stopped"
                Write-LogDbg "Remove it from the running buildid list"
                $RunningBuildList.RemoveAt($i)
                $i--
            }
        }
        Write-LogInfo "Total $($totalCompleted) completed jobs, still has $($RunningBuildList.Count) running jobs"
        $passedCount = Get-PassedCount $connection
        $failedCount = Get-FailedCount $connection
        $runningCount = Get-RunningCount $connection
        Write-LogInfo "Total $($passedCount) completed images, $($failedCount) failed images, $($runningCount) running images"

        $sql = "
        SELECT Count(ARMImage)
        FROM CaptureImageInfo
        WHERE Status='$StatusNotStarted'"

        $results = QuerySql $connection $sql
        $count = ($results[0][0]) -as [int]
        if ($count -ne 0) {
            $hasMoreData = $true
        }

        if ($hasMoreData -eq $true -or $RunningBuildList.Count -gt 0) {
            start-sleep -Seconds 120
        }
    }
    Write-LogInfo "All builds have completed."
} catch {
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
