##############################################################################################
# CommonFunctions.psm1
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.
<#
.SYNOPSIS
    PS modules for LISA test pipeline.
#>
###############################################################################################
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
		} else {
			$LogDir = $env:TEMP
		}
		if (!$LogFileName) {
			$LogFileName = "Test-$(Get-Date -Format 'yyyy-MM-dd').log"
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

function ExecuteSql($connection, $sql, $parameters) {
    try {
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

function QuerySql($connection, $sql, $Parameters) {
    try {
        $dataset = new-object "System.Data.Dataset"
        $command = $connection.CreateCommand()
        $command.CommandText = $sql
        if ($parameters) {
            $parameters.Keys | ForEach-Object { $command.Parameters.AddWithValue($_, $parameters[$_]) | Out-Null } 
        }

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