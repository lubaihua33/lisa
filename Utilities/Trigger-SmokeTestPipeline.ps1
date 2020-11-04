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
    -PipelineName, The pipeline name
    -suggestedCount, The Suggested number of images are tested in one pipeline
    -TestPass, The TestPass name
Documentation

.NOTES
    Creation Date:
    Purpose/Change:

.EXAMPLE
    Trigger-SmokeTestPipeline.ps1 -OrganizationUrl $OrganizationUrl -AzureDevOpsProjectName $AzureDevOpsProjectName `
    -PipelineName $PipelineName -DevOpsPAT $DevOpsPAT -AzureSecretsFile $env:SECRET_FILE -TestPass $TestPassName
#>
###############################################################################################
Param
(
    [String] $OrganizationUrl,
    [String] $AzureDevOpsProjectName,
    [String] $DevOpsPAT,
    [String] $PipelineName,
    [String] $AzureSecretsFile,
    [String] $TestPass,
    [int] $suggestedCount = 700
)

$StatusNotStarted = "NotStarted"
$StatusRunning = "Running"
$StatusDone = "Done"

$RunningBuildList = New-Object System.Collections.ArrayList
$AllBuildList = New-Object System.Collections.ArrayList

function Add-RunningBuildList($buildID, $location) {
    $info = @{BuildID = $buildID; Location = $location}
    $RunningBuildList.Add($info) | Out-Null
}

function Add-AllBuildList($buildID, $location) {
    $info = @{BuildID = $buildID; Location = $location}
    $AllBuildList.Add($info) | Out-Null
}

Function Invoke-Pipeline(
    $OrganizationUrl, 
    $AzureDevOpsProjectName, 
    $DevOpsPAT, 
    $PipelineName, 
    $BuildBody,
    $BuildID,
    $OperateMethod
) {
    if ($OperateMethod -eq "Run") {
        $runBuild = "runs?api-version=6.0-preview.1"
        $Method = "Post"
    } elseif ($OperateMethod -eq "Get" -and $BuildID) {
        $runBuild = "runs/$(${BuildID})?api-version=6.0-preview.1"
        $Method = "Get"
        $BuildBody = $null
    } else {
        Write-Host "Error: The OperateMethod $OperateMethod is not supported"
        return $null
    }

    $baseUri = "$($OrganizationUrl)/$($AzureDevOpsProjectName)/";
    $getUri = "_apis/build/definitions?name=$(${PipelineName})";
    $buildUri = "$($baseUri)$($getUri)"

    # Base64-encodes the Personal Access Token (PAT) appropriately
    $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("token:{0}" -f $DevOpsPAT)))
    $DevOpsHeaders = @{Authorization = ("Basic {0}" -f $base64AuthInfo)};

    $BuildDefinitions = Invoke-RestMethod -Uri $buildUri -Method Get -ContentType "application/json" -Headers $DevOpsHeaders;
    if ($BuildDefinitions -and $BuildDefinitions.count -eq 1) {
        $PipelineId = $BuildDefinitions.value[0].id
        $runBuildUri = "$($baseUri)_apis/pipelines/$(${PipelineId})/$($runBuild)"
        $jsonbody = $BuildBody | ConvertTo-Json -Depth 100

        try {
            $Result = Invoke-RestMethod -Uri $runBuildUri -Method $Method -ContentType "application/json" -Headers $DevOpsHeaders -Body $jsonbody;
            return $Result
        } catch {
            $line = $_.InvocationInfo.ScriptLineNumber
            $script_name = ($_.InvocationInfo.ScriptName).Replace($PWD,".")
            $ErrorMessage =  $_.Exception.Message
            Write-Error "EXCEPTION : $ErrorMessage"
            Write-Error "Source : Line $line in script $script_name."
        }
    } else {
        Write-Error "Problem occured while getting the build"
    }
}

Function Run-Pipeline ($Location, $ImagesCount) {
    $retry = 0
    $BuildBody = New-Object PSObject -Property @{
        variables = New-Object PSObject -Property @{
            Location   = New-Object PSObject -Property @{value = $Location}
            ImagesCount = New-Object PSObject -Property @{value = $ImagesCount}
        }
    }
    While ($retry -lt 3) {
        $result = Invoke-Pipeline -OrganizationUrl $OrganizationUrl -AzureDevOpsProjectName $AzureDevOpsProjectName `
                                   -PipelineName $PipelineName -DevOpsPAT $DevOpsPAT -BuildBody $BuildBody `
                                   -OperateMethod "Run"
        if ($result -and $result.id) {
            Write-Host "Info: The pipeline #BuildId $($result.id) will run $ImagesCount images in $Location"
            return $result.id
        }
        retry += 1
    }
    return $null
}

# $totalCount = 1600, $suggestedCount = 700
# $countList = (533,533,534)
Function Get-CountInOnePipeline([int]$totalCount, [int]$suggestedCount) {
    $countList = New-Object System.Collections.ArrayList
    $pipelineCount = [math]::ceiling($totalCount / $suggestedCount / 1.1)

    for ($i = 0; $i -lt ($pipelineCount - 1); $i++) {
        $countList.Add([math]::floor($totalCount / $pipelineCount)) | Out-Null
    }
    if ($i -eq ($pipelineCount - 1)) {
        $countList.Add([math]::floor($totalCount / $pipelineCount) + $totalCount % $pipelineCount) | Out-Null
    }

    Write-Host "Info: countList is $countList"
    return $countList
}

function ExecuteSql($connection, $sql, $parameters) {
    try {
        Write-Host "Info: Run sql command: $sql"
        $command = $connection.CreateCommand()
        $command.CommandText = $sql
        if ($parameters) {
            $parameters.Keys | ForEach-Object { $command.Parameters.AddWithValue($_, $parameters[$_]) | Out-Null } 
        }

        $count = $command.ExecuteNonQuery()
        if ($count) {
            Write-Host "Info: $count records are executed successfully"
        }
    }
    finally {
        $command.Dispose()
    }
}

function QuerySql($connection, $sql, $testPass) {
    try {
        Write-Host "Info: Run sql command: $sql"
        $dataset = new-object "System.Data.Dataset"
        $command = $connection.CreateCommand()
        $command.CommandText = $sql
        $command.Parameters.Add("@Testpass", $testPass) | Out-Null
        $dataAdapter = new-object System.Data.SqlClient.SqlDataAdapter
        $dataAdapter.SelectCommand = $command
        $null = $dataAdapter.Fill($dataset)

        $rows = @()
        if ($dataset.Tables.Rows -isnot [array]) {
            $rows = @($dataset.Tables.Rows) 
        } else {
            $rows = $dataset.Tables.Rows
        }
    }
    finally {
        $dataAdapter.Dispose()
        $dataset.Dispose()
        $command.Dispose()
    }
    return $rows
}

function Add-DistroListCache($connection, $testPass) {
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
    insert into TestPassCache(Location, ARMImage, Status, TestPass)
    select Location, FullName, '$StatusNotStarted', @TestPass
    from groups
    where groups.rowNumber=1"

    $parameters = @{"@TestPass" = $testPass }
    ExecuteSql $connection $sql $parameters
}

function Initialize-DistroList($connection, $TestPass)
{
    $sql = "select count(*) from TestPassCache where TestPass=@Testpass"
    $results = QuerySql $connection $sql $TestPass
    $dataNumber = ($results[0][0]) -as [int]

    if ($dataNumber -eq 0) {
        Write-Host "Info: Initialize test pass"
        Add-DistroListCache $connection $testPass
    }
    else {
        # reset running status
        $sql = "
        UPDATE TestPassCache
        SET Status='$StatusNotStarted', UpdatedDate=getdate(), Context=NULL
        WHERE TestPass=@TestPass and Status='$StatusRunning'"
        $parameters = @{"@TestPass" = $testPass }
        ExecuteSql $connection $sql $parameters
        Write-Host "Reuse existing test pass"
    }
}


function Start-TriggerPipeline($location) {
    $sql = "
    select count(ARMImage) from TestPassCache
    where Location='$location' and TestPass=@TestPass and 
    Context is NULL and Status='$StatusNotStarted'
    "
    Write-Host "Info: Run sql command: $sql"
    $results = QuerySql $connection $sql $TestPass

    $totalCount = ($results[0][0]) -as [int]
    if ($totalCount -eq 0) {
        Write-Host "Info: No image need to test in the location: $location"
        return
    } else {
        Write-Host "Info: $totalCount images in the location: $location"
    }

    $countList = Get-CountInOnePipeline $totalCount $suggestedCount

    for ($i = 0; $i -lt $countList.Count; $i++) {
        $buildId = Run-Pipeline $location $countList[$i]
        if (!$buildId) {
            Write-Host "Error: Failed to Trigger ADO pipeline."
            continue
        }

        $sql = "
        update top ($($countList[$i])) TestPassCache
        set Context=$buildId, Status='$StatusRunning', UpdatedDate=getdate()
        where Location='$location' and TestPass=@TestPass and 
        Context is NULL and Status='$StatusNotStarted'
        "
        $parameters = @{"@TestPass" = $testPass }
        ExecuteSql $connection $sql $parameters

        Add-RunningBuildList $buildId $location
        Add-AllBuildList $buildId $location
    }
}

function Update-TestPassCacheDone($connection, $testPass) {
    $sql = "
    With Runnings as (
        select *
        from TestPassCache
        where TestPass=@TestPass
            and Status='$StatusRunning'
    ),
    TestResults as (
        select *
        from TestResult 
        where Id in (
            select max(TestResult.Id)
            from TestPass,TestRun,TestResult
            where TestPass.Name=@TestPass and
            TestPass.Id = TestRun.TestPassId and
            TestRun.Id = TestResult.RunId group by TestResult.Image
        )
    )
    update TestPassCache
    set Status='$StatusDone', UpdatedDate=getdate()
    where TestPass=@TestPass and ID in (
        select Runnings.ID from Runnings left join TestResults on 
            Runnings.Location = TestResults.Location and
            Runnings.ArmImage = TestResults.Image and
            Runnings.UpdatedDate < TestResults.UpdatedDate
        where Runnings.TestPass = @TestPass and TestResults.Id is not null
    )"
    $parameters = @{"@TestPass" = $testPass }
    ExecuteSql $connection $sql $parameters
}

function Get-MissingCount($connection, $TestPass, $BuildId) {
    $sql = "
    select Count(ARMImage) from TestPassCache
    where Context=$BuildId and Status='$StatusRunning'
    "
    Write-Host "Info: Get missing image count of pipeline #$BuildId..."
    Write-Host "Info: Run sql command: $sql"
    $results = QuerySql $connection $sql $TestPass
    $count = ($results[0][0]) -as [int]
    Write-Host "Info: The missing image count is $count"

    return $count
}

function Get-DoneCount($connection, $TestPass) {
    $sql = "
    select Count(ARMImage) from TestPassCache
    where TestPass=@TestPass and Status='$StatusDone'
    "
    Write-Host "Info: Run sql command: $sql"
    $results = QuerySql $connection $sql $TestPass
    $count = ($results[0][0]) -as [int]
    Write-Host "Info: The completed count is $count"

    return $count
}

function Get-RunningCount($connection, $TestPass) {
    $sql = "
    select Count(ARMImage) from TestPassCache
    where TestPass=@TestPass and Status='$StatusRunning'
    "
    Write-Host "Info: Run sql command: $sql"
    $results = QuerySql $connection $sql $TestPass
    $count = ($results[0][0]) -as [int]
    Write-Host "Info: The running count is $count"

    return $count
}

# Read secrets file and terminate if not present.
Write-Host "Info: Check the Azure Secrets File..."
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
    Write-Host "Error: Please provide value for -AzureSecretsFile"
    exit 1
}

# Read variable_database file and terminate if not present.
$variableFile = ".\runbook\variable_database.yml"
if (Test-Path -Path $variableFile) {
    $content = Get-Content -Path $variableFile
    foreach ($line in $content) {
        if ($line.split(':')[0] -eq 'dbServerName') {
            $server = $line.split(':')[1].trim()
        }
        if ($line.split(':')[0] -eq 'dbName') {
            $database = $line.split(':')[1].trim()
        }
    }
} else {
    Write-Host "Error: No variable_database.yml"
    exit 1
}
Write-Host "Info: Check the secrets file and variable_database.yml OK"

if (!$server -or !$dbuser -or !$dbpassword -or !$database) {
    Write-Host "Error: Database details are not provided."
    exit 1
}

$connectionString = "Server=$server;uid=$dbuser;pwd=$dbpassword;Database=$database;" +
                    "Encrypt=yes;TrustServerCertificate=no;Connection Timeout=30;MultipleActiveResultSets=True;"

try {
    Write-Host "Info: SQLQuery: $sql"
    $connection = New-Object System.Data.SqlClient.SqlConnection
    $connection.ConnectionString = $connectionString
    $connection.Open()

    Initialize-DistroList $connection $TestPass
    Update-TestPassCacheDone $connection $TestPass

    # Start pipeline
    $sql = "select distinct Location from TestPassCache where TestPass=@Testpass"
    $parameters = @{"@TestPass" = $testPass}
    $rows = QuerySql $connection $sql $testPass
    foreach ($row in $rows) {
        $location = $row.Location
        Start-TriggerPipeline $location
    }

    # Update status and check completed pipeline
    $totalCompleted = 0
    while ($RunningBuildList.Count -gt 0) {
        for ($i = 0; $i -lt $RunningBuildList.Count; $i++) {
            $buildId = $RunningBuildList[$i].BuildID
            $result = Invoke-Pipeline -OrganizationUrl $OrganizationUrl -AzureDevOpsProjectName $AzureDevOpsProjectName `
                                       -PipelineName $PipelineName -DevOpsPAT $DevOpsPAT -BuildID $buildId `
                                       -OperateMethod "Get"
            if ($result -and $result.state -ne "inProgress" -and $result.state -ne "postponed") {
                $totalCompleted++
                Update-TestPassCacheDone $connection $TestPass

                $missingCount = Get-MissingCount $connection $TestPass $buildId
                if ($missingCount -gt 0) {
                    $location = $RunningBuildList[$i].Location
                    $newBuildId = Run-Pipeline $location $missingCount
                    if ($newBuildId) {
                        $sql = "
                        update TestPassCache
                        set Context = $newBuildId
                        where Context = $buildId and Status='$StatusRunning'
                        "
                        ExecuteSql $connection $sql

                        $RunningBuildList[$i].BuildID = $newBuildId
                        Add-AllBuildList $newBuildId $location
                    } else {
                        Write-Host "Error: Run pipeline failed"
                    }
                } else {
                    Write-Host "Info: The pipeline #BuildId $($RunningBuildList[$i].BuildID) has completed all the tasks"
                    $RunningBuildList.RemoveAt($i)
                }
            }
        }
        Write-Host "$($totalCompleted) completed jobs, $($RunningBuildList.Count) running jobs"
        $doneCount = Get-DoneCount $connection $TestPass
        $runningCount = Get-RunningCount $connection $TestPass
        Write-Host "$($doneCount) completed images, $($runningCount) running images"

        if ($RunningBuildList.Count -gt 0) {
            start-sleep -Seconds 300
            Update-TestPassCacheDone $connection $TestPass
        }
    }
    Write-Host "All builds have completed."
    $AllBuildList
} 
catch {
    Write-Host "Error: Failed to Query data from database"
    $line = $_.InvocationInfo.ScriptLineNumber
    $script_name = ($_.InvocationInfo.ScriptName).Replace($PWD,".")
    $ErrorMessage =  $_.Exception.Message
    Write-Host "Error: EXCEPTION : $ErrorMessage"
    Write-Host "Error: Source : Line $line in script $script_name."
} 
finally {
    if ($null -ne $connection) {
        $connection.Close()
        $connection.Dispose()
    }
}
