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
    -SuggestedCount, The Suggested number of images are tested in one pipeline
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
    [String] $ParentPipelineName,
    [String] $ChildPipelineName,
    [String] $AzureSecretsFile,
    [String] $TestPass,
    [String] $DbServer,
    [String] $DbName,
    [int] $Cocurrent,
    [int] $SuggestedCount = 700
)

$StatusNotStarted = "NotStarted"
$StatusRunning = "Running"
$StatusDone = "Done"
$NotRun = "NOTRUN"
$Running = "RUNNING"

$RunningBuildList = New-Object System.Collections.ArrayList
$AllBuildList = New-Object System.Collections.ArrayList

$LogDir = "trigger-pipeline"
$LogFileName = "Smoke-Test-$(Get-Date -Format 'yyyy-MM-dd-HH-mm-ss-ffff').log"

Function Write-Log() {
	param
	(
		[ValidateSet('INFO','WARN','ERROR','DEBUG', IgnoreCase = $false)]
		[string]$logLevel,
		[string]$text
	)

	if ($password) {
		$text = $text.Replace($password,"******")
	}
	$now = [Datetime]::Now.ToUniversalTime().ToString("MM/dd/yyyy HH:mm:ss")
	$logType = $logLevel.PadRight(5, ' ')
	$finalMessage = "$now : [$logType] $text"
	$fgColor = "White"
	switch ($logLevel) {
		"INFO"	{$fgColor = "White"; continue}
		"WARN"	{$fgColor = "Yellow"; continue}
		"ERROR"	{$fgColor = "Red"; continue}
		"DEBUG"	{$fgColor = "DarkGray"; continue}
	}
	Write-Host $finalMessage -ForegroundColor $fgColor

	try {
		if ($LogDir) {
			if (!(Test-Path $LogDir)) {
				New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
			}
		}
		if (!$LogFileName) {
			$LogFileName = "Smoke-Test-$(Get-Date -Format 'yyyy-MM-dd-HH-mm-ss-ffff').log"
		}
		$LogFileFullPath = Join-Path $LogDir $LogFileName
		if (!(Test-Path $LogFileFullPath)) {
			New-Item -path $LogDir -name $LogFileName -type "file" | Out-Null
		}
		Add-Content -Value $finalMessage -Path $LogFileFullPath -Force
	} catch {
		Write-Output "[LOG FILE EXCEPTION] : $now : $text"
	}
}

Function Write-LogInfo($text) {
	Write-Log "INFO" $text
}

Function Write-LogErr($text) {
	Write-Log "ERROR" $text
}

Function Write-LogWarn($text) {
	Write-Log "WARN" $text
}

Function Write-LogDbg($text) {
	Write-Log "DEBUG" $text
}
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
    } elseif ($OperateMethod -eq "List") {
        $runBuild = "runs?api-version=6.0-preview.1"
        $Method = "Get"
    } else {
        Write-LogErr "The OperateMethod $OperateMethod is not supported"
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
            Write-LogErr "EXCEPTION : $ErrorMessage"
            Write-LogErr "Source : Line $line in script $script_name."
        }
    } else {
        Write-LogErr "Problem occured while getting the build"
    }
}

Function Run-Pipeline ($Location, $ImagesCount) {
    $retry = 0
    $BuildBody = New-Object PSObject -Property @{
        variables = New-Object PSObject -Property @{
            Location   = New-Object PSObject -Property @{value = $Location}
            ImagesCount = New-Object PSObject -Property @{value = $ImagesCount}
            TestPass = New-Object PSObject -Property @{value = $TestPass}
        }
    }
    While ($retry -lt 3) {
        $result = Invoke-Pipeline -OrganizationUrl $OrganizationUrl -AzureDevOpsProjectName $AzureDevOpsProjectName `
                                   -PipelineName $ChildPipelineName -DevOpsPAT $DevOpsPAT -BuildBody $BuildBody `
                                   -OperateMethod "Run"
        if ($result -and $result.id) {
            Write-LogInfo "The pipeline #BuildId $($result.id) will run $ImagesCount images in $Location"
            return $result.id
        }
        retry += 1
    }
    return $null
}

# $totalCount = 1600, $SuggestedCount = 700
# $countList = (533,533,534)
Function Get-CountInOnePipeline([int]$totalCount, [int]$SuggestedCount) {
    $countList = New-Object System.Collections.ArrayList
    if ($Cocurrent) {
        $pipelineCount = $Cocurrent
    } else {
        $pipelineCount = [math]::ceiling($totalCount / $SuggestedCount / 1.1)
    }

    for ($i = 0; $i -lt ($pipelineCount - 1); $i++) {
        $count = [math]::floor($totalCount / $pipelineCount)
        if ($count -ne 0) {
            $countList.Add($count) | Out-Null
        }
    }
    if ($i -eq ($pipelineCount - 1)) {
        $count = [math]::floor($totalCount / $pipelineCount) + $totalCount % $pipelineCount
        if ($count -ne 0) {
            $countList.Add($count) | Out-Null
        }
    }

    Write-LogInfo "countList is $countList"
    return $countList
}

function ExecuteSql($connection, $sql, $parameters) {
    try {
        Write-LogDbg "Run sql command: $sql"
        $command = $connection.CreateCommand()
        $command.CommandText = $sql
        if ($parameters) {
            $parameters.Keys | ForEach-Object { $command.Parameters.AddWithValue($_, $parameters[$_]) | Out-Null } 
        }

        $count = $command.ExecuteNonQuery()
        if ($count) {
            Write-LogInfo "$count records are executed successfully"
        }
    }
    finally {
        $command.Dispose()
    }
}

function QuerySql($connection, $sql, $testPass) {
    try {
        Write-LogDbg "Run sql command: $sql"
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

function Add-TestPassCache($connection, $testPass) {
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

function Initialize-TestPassCache($connection, $TestPass)
{
    $sql = "select count(*) from TestPassCache where TestPass=@Testpass"
    $results = QuerySql $connection $sql $TestPass
    $dataNumber = ($results[0][0]) -as [int]

    if ($dataNumber -eq 0) {
        Write-LogInfo "Initialize test pass cahce"
        Add-TestPassCache $connection $testPass
    }
    else {
        # reset running status
        if ($RunningBuildList.Count -gt 0) {
            $List = $RunningBuildList | ForEach-Object {$_.BuildID}
            $buildIdList = [string]::Join(",", $List)
            $sql = "
            UPDATE TestPassCache
            SET Status='$StatusNotStarted', UpdatedDate=getdate(), Context=NULL
            WHERE TestPass=@TestPass and Status='$StatusRunning' and
            Context not in ($buildIdList)"
        } else {
            $sql = "
            UPDATE TestPassCache
            SET Status='$StatusNotStarted', UpdatedDate=getdate(), Context=NULL
            WHERE TestPass=@TestPass and Status='$StatusRunning'"
        }
        $parameters = @{"@TestPass" = $testPass }
        ExecuteSql $connection $sql $parameters
        Write-LogInfo "Reuse existing test pass cache"
    }
}

function Sync-RunningBuild ($connection, $TestPass) {
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
            where TestPass=@TestPass and Status='$StatusRunning' and 
            Context in ($buildIdList)"

            $results = QuerySql $connection $sql $TestPass
            foreach ($_ in $results) {
                $buildId = $_.Context
                $location = $_.Location

                Write-LogInfo "The builds $buildId is still running. Add it into running build list"
                Add-RunningBuildList $buildId $location
                Add-AllBuildList $buildId $location
            }
        }
    }
}

function Start-TriggerPipeline($location) {
    $sql = "
    select count(ARMImage) from TestPassCache
    where Location='$location' and TestPass=@TestPass and 
    Context is NULL and Status='$StatusNotStarted'"

    $results = QuerySql $connection $sql $TestPass

    $totalCount = ($results[0][0]) -as [int]
    if ($totalCount -eq 0) {
        Write-LogInfo "No image in the location $location need to trigger testing pipeline"
        return
    } else {
        Write-LogInfo "$totalCount images in the location $location need to trigger testing pipeline"
    }

    $countList = Get-CountInOnePipeline $totalCount $SuggestedCount

    for ($i = 0; $i -lt $countList.Count; $i++) {
        $buildId = Run-Pipeline $location $countList[$i]
        if (!$buildId) {
            Write-LogErr "Failed to Trigger ADO pipeline"
            continue
        }

        $sql = "
        update top ($($countList[$i])) TestPassCache
        set Context=$buildId, Status='$StatusRunning', UpdatedDate=getdate()
        where Location='$location' and TestPass=@TestPass and 
        Context is NULL and Status='$StatusNotStarted'"

        $parameters = @{"@TestPass" = $testPass }
        ExecuteSql $connection $sql $parameters

        Add-RunningBuildList $buildId $location
        Add-AllBuildList $buildId $location
    }
}

function Update-TestPassCacheDone($connection, $testPass) {
    Write-LogInfo "Update test pass cache done"
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
            TestRun.Id = TestResult.RunId and
            TestResult.Status <> '$NotRun' and
            TestResult.Status <> '$Running' group by TestResult.Image
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
    where Context=$BuildId and Status='$StatusRunning'"

    $results = QuerySql $connection $sql $TestPass
    $count = ($results[0][0]) -as [int]
    Write-LogInfo "The missing image count is $count"

    return $count
}

function Get-DoneCount($connection, $TestPass) {
    $sql = "
    select Count(ARMImage) from TestPassCache
    where TestPass=@TestPass and Status='$StatusDone'"

    $results = QuerySql $connection $sql $TestPass
    $count = ($results[0][0]) -as [int]
    Write-LogInfo "The completed count is $count"

    return $count
}

function Get-RunningCount($connection, $TestPass) {
    $sql = "
    select Count(ARMImage) from TestPassCache
    where TestPass=@TestPass and Status='$StatusRunning'"

    $results = QuerySql $connection $sql $TestPass
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

# Read secrets file and terminate if not present.
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
Write-LogInfo "Check the secrets file and variable_database.yml OK"

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

    # Sync all the running job of the same test pass
    Sync-RunningBuild $connection $TestPass
    Initialize-TestPassCache $connection $TestPass
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
                                       -PipelineName $ChildPipelineName -DevOpsPAT $DevOpsPAT -BuildID $buildId `
                                       -OperateMethod "Get"
            if ($result -and $result.state -ne "inProgress" -and $result.state -ne "postponed") {
                Write-LogInfo "The pipeline #BuildId $buildId has stopped"
                $totalCompleted++                
                Update-TestPassCacheDone $connection $TestPass

                Write-LogInfo "Get missing images count in the build $buildId"
                $missingCount = Get-MissingCount $connection $TestPass $buildId
                if ($missingCount -gt 0) {
                    Write-LogInfo "Need to trigger testing pipeline"
                    $location = $RunningBuildList[$i].Location
                    $newBuildId = Run-Pipeline $location $missingCount
                    if ($newBuildId) {
                        $sql = "
                        update TestPassCache
                        set Context = $newBuildId
                        where Context = $buildId and Status='$StatusRunning'"

                        ExecuteSql $connection $sql

                        $RunningBuildList[$i].BuildID = $newBuildId
                        Add-AllBuildList $newBuildId $location
                    } else {
                        Write-LogErr "Run pipeline failed"
                    }
                } else {
                    Write-LogInfo "The pipeline #BuildId $($RunningBuildList[$i].BuildID) has completed all the tasks"
                    Write-LogInfo "Remove it from the running buildid list"
                    $RunningBuildList.RemoveAt($i)
                    $i--
                }
            }
        }
        Write-LogInfo "Total $($totalCompleted) completed jobs, $($RunningBuildList.Count) running jobs"
        $doneCount = Get-DoneCount $connection $TestPass
        $runningCount = Get-RunningCount $connection $TestPass
        Write-LogInfo "Total $($doneCount) completed images, $($runningCount) running images"

        if ($RunningBuildList.Count -gt 0) {
            start-sleep -Seconds 120
            Update-TestPassCacheDone $connection $TestPass
        }
    }
    Write-LogInfo "All builds have completed."
    $AllBuildList
} 
catch {
    $line = $_.InvocationInfo.ScriptLineNumber
    $script_name = ($_.InvocationInfo.ScriptName).Replace($PWD,".")
    $ErrorMessage =  $_.Exception.Message
    Write-LogErr "EXCEPTION : $ErrorMessage"
    Write-LogErr "Source : Line $line in script $script_name."
} 
finally {
    if ($null -ne $connection) {
        $connection.Close()
        $connection.Dispose()
    }
}
