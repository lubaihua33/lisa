##############################################################################################
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.
#
# Trigger-AzureDevopsPipeline.ps1
<#
.SYNOPSIS
    This script is to trigger an Azure DevOps pipeline
.PARAMETER
    -OrganizationUrl, The URL of the organization. (https://dev.azure.com/[organization])
    -AzureDevOpsProjectName, The project where the pipeline resides
    -DevOpsPAT, The personal access token
    -PipelineName, The pipeline name
    -Branch, The name of the branch to trigger. When left empty it will use the default configured branch.
    -SuggestedNumber, The Suggested number of images are tested in one pipeline.
Documentation

.NOTES
    Creation Date:
    Purpose/Change:

.EXAMPLE
    Trigger-AzureDevopsPipeline.ps1 -OrganizationUrl $OrganizationUrl -AzureDevOpsProjectName $AzureDevOpsProjectName `
    -PipelineName $PipelineName -DevOpsPAT $DevOpsPAT -Branch $Branch
#>
###############################################################################################
Param
(
    [Parameter(Mandatory = $true)][String]$OrganizationUrl,
    [Parameter(Mandatory = $true)][String]$AzureDevOpsProjectName,
    [Parameter(Mandatory = $true)][String]$DevOpsPAT,
    [Parameter(Mandatory = $true)][String]$PipelineName,
    [Parameter(Mandatory = $false)][String]$Branch,
    [Parameter(Mandatory = $false)][String]$Description = "Automatically triggered release",
    [Parameter(Mandatory = $true)] $AzureSecretsFile,
    [string] $QueryTableName = "AzureFleetSmokeTestDistroList",
    [int] $SuggestedNumber = 700
)

# Read secrets file and terminate if not present.
if (![String]::IsNullOrEmpty($AzureSecretsFile) -and (Test-Path -Path $AzureSecretsFile)) {
    $Secrets = ([xml](Get-Content $AzureSecretsFile))
} else {
    Write-Host "Error: Please provide value for -AzureSecretsFile"
    exit 1
}
if ((![String]::IsNullOrEmpty($Secrets)) -and (![String]::IsNullOrEmpty($Secrets.secrets))) {
    Set-Variable -Name XmlSecrets -Value $Secrets -Scope Global -Force
} else {
    Write-Host "Secrets file not found. Exiting."
    exit 1
}

Function Trigger-ADOPipeline($OrganizationUrl, $AzureDevOpsProjectName, $DevOpsPAT, $PipelineName, $Branch, $TestLocation, $NumberOfImages) {
    # Refer to https://docs.microsoft.com/en-us/rest/api/azure/devops/build/builds/queue?view=azure-devops-rest-6.0
    $baseUri = "$($OrganizationUrl)/$($AzureDevOpsProjectName)/";
    $getUri = "_apis/build/definitions?name=$(${PipelineName})";    
    $buildUri = "$($baseUri)$($getUri)"

    # Base64-encodes the Personal Access Token (PAT) appropriately
    $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("token:{0}" -f $DevOpsPAT)))
    $DevOpsHeaders = @{Authorization = ("Basic {0}" -f $base64AuthInfo)};

    $BuildDefinitions = Invoke-RestMethod -Uri $buildUri -Method Get -ContentType "application/json" -Headers $DevOpsHeaders;
    if ($BuildDefinitions -and $BuildDefinitions.count -eq 1) {
        $PipelineId = $BuildDefinitions.value[0].id
        $runBuild = "_apis/pipelines/$(${PipelineId})/runs?api-version=6.0-preview.1"
        $runBuildUri = "$($baseUri)$($runBuild)"
        $Build = New-Object PSObject -Property @{
            variables = New-Object PSObject -Property @{
                TestLocation = New-Object PSObject -Property @{value = $TestLocation}
                NumberOfImages = New-Object PSObject -Property @{value = $NumberOfImages}
            }
        }
        $jsonbody = $Build | ConvertTo-Json -Depth 100
        try {
            $Result = Invoke-RestMethod -Uri $runBuildUri -Method Post -ContentType "application/json" -Headers $DevOpsHeaders -Body $jsonbody;
            return $($Result.id)
        } catch {
            if($_.ErrorDetails.Message){
                $errorObject = $_.ErrorDetails.Message | ConvertFrom-Json
                foreach($result in $errorObject.customProperties.ValidationResults){
                    Write-Warning $result.message
                }
                Write-Error $errorObject.message
            }
            throw $_.Exception
        }
        Write-Host "Triggered Build: $($Result.id)"
    }
    else {
        Write-Error "Problem occured while getting the build"
    }
}

# $TotalNumber = 1600, $SuggestedNumber = 700
# $OptimalNumberList = (533,533,534)
# $TotalNumber = 1500, $SuggestedNumber = 700
# $OptimalNumberList = (750,750)
# $TotalNumber = 2890, $SuggestedNumber = 700
# $OptimalNumberList = (722,722,722,724)
Function Get-OptimalNumberInOnePipeline([int]$TotalNumber, [int]$SuggestedNumber) {
    $OptimalNumberList = [System.Collections.ArrayList]@()
    $Remainder = [math]::floor($TotalNumber % $SuggestedNumber)
    $Quotient = [math]::floor($TotalNumber / $SuggestedNumber)
    if ($Remainder -eq 0) {
        for ($i = 0; $i -lt $Quotient; $i++) {
            $OptimalNumberList.Add($SuggestedNumber)
        }
    } elseif ($Remainder -gt 0 -and $Remainder/$Quotient -le $SuggestedNumber/10) {
        for ($i = 0; $i -lt ($Quotient - 1); $i++) {
            $OptimalNumberList.Add($SuggestedNumber + [math]::floor($Remainder/$Quotient))
        }
        if ($i -eq ($Quotient - 1)) {
            $OptimalNumberList.Add($SuggestedNumber + [math]::floor($Remainder/$Quotient) +  [math]::floor($Remainder%$Quotient))
        }
    } elseif ($Remainder -gt 0 -and $Remainder/$Quotient -gt $SuggestedNumber/10) {
        # Add one to list count
        $Quotient += 1
        for ($i = 0; $i -lt ($Quotient - 1); $i++) {
            $OptimalNumberList.Add([math]::floor($TotalNumber/$Quotient))
        }
        if ($i -eq ($Quotient - 1)) {
            $OptimalNumberList.Add([math]::floor($TotalNumber/$Quotient) +  [math]::floor($TotalNumber%$Quotient))
        }
    } else {
        Write-Host "Error: Remainder is $Remainder"
    }
    Write-Host "Info: OptimalNumberList is $OptimalNumberList"
    return $OptimalNumberList
}

$server = $XmlSecrets.secrets.DatabaseServer
$dbuser = $XmlSecrets.secrets.DatabaseUser
$dbpassword = $XmlSecrets.secrets.DatabasePassword
$database = $XmlSecrets.secrets.DatabaseName

$SQLQuery="select distinct TestLocation from $QueryTableName"

if ($server -and $dbuser -and $dbpassword -and $database) {
    try {
        Write-Host "Info: SQLQuery:  $SQLQuery"
        $connectionString = "Server=$server;uid=$dbuser; pwd=$dbpassword;Database=$database;Encrypt=yes;TrustServerCertificate=no;Connection Timeout=30;MultipleActiveResultSets=True;"
        $connection = New-Object System.Data.SqlClient.SqlConnection
        $connection.ConnectionString = $connectionString
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = $SQLQuery
        $reader = $command.ExecuteReader()
        # Loop TestLocation
        While ($reader.read()) {
            $TestLocation = $reader.GetValue($reader.GetOrdinal("TestLocation"))
            $SQLQuery="select count(ARMImage) from $QueryTableName where TestLocation like '$TestLocation' and BuildID is NULL and RunStatus is NULL"
            $command1 = $connection.CreateCommand()
            $command1.CommandText = $SQLQuery
            $reader1 = $command1.ExecuteReader()
            if ($reader1.read()) {
                $TotalNumber = $reader1.GetValue(0)
            } else {
                Write-Host "Error: SQLQuery: $SQLQuery"
            }
            if ($TotalNumber -eq 0) {
                Write-Host "Info: No image in the location:  $TestLocation"
                continue
            }
            $OptimalNumberList = Get-OptimalNumberInOnePipeline -TotalNumber $TotalNumber -SuggestedNumber $SuggestedNumber

            # Trigger ADO pipeline
            $i = 0; $count = 0; $retry = 0
            While ($retry -lt 3) {
                $BuildNumber = Trigger-ADOPipeline -OrganizationUrl $OrganizationUrl -AzureDevOpsProjectName $AzureDevOpsProjectName `
                    -PipelineName $PipelineName -DevOpsPAT $DevOpsPAT -Branch $Branch -TestLocation $TestLocation -NumberOfImages $OptimalNumberList[$i]
                if ($BuildNumber) {
                    Write-Host "Info: The pipeline #BuildId $BuildNumber will run $($OptimalNumberList[$i]) images in $TestLocation"
                    break
                }
            }
            if (!$BuildNumber) {
                Write-Host "Error: Failed to Trigger ADO pipeline. Exit.."
                exit 1
            }

            # Loop ARMImage on the TestLocation, then set the BuildID and RunStatus
            $SQLQuery="select * from $QueryTableName where TestLocation like '$TestLocation' and BuildID is NULL and RunStatus is NULL"
            $command2 = $connection.CreateCommand()
            $command2.CommandText = $SQLQuery
            $reader2 = $command2.ExecuteReader()
            while ($reader2.read()) {
                $ARMImage = $reader2.GetValue($reader2.GetOrdinal("ARMImage"))
                $SQLQuery = "Update $QueryTableName Set BuildID=$BuildNumber, RunStatus='START' where ARMImage like '$ARMImage'"
                $command3= $connection.CreateCommand()
                $command3.CommandText = $sqlQuery
                $null = $command3.executenonquery()
                $count += 1
                if (($count -eq $OptimalNumberList[$i]) -and ($OptimalNumberList.Count -gt ($i + 1))) {
                    # Trigger another Pipeline
                    $i+=1; $retry = 0; $count = 0
                    While ($retry -lt 3) {
                        $BuildNumber = Trigger-ADOPipeline -OrganizationUrl $OrganizationUrl -AzureDevOpsProjectName $AzureDevOpsProjectName `
                            -PipelineName $PipelineName -DevOpsPAT $DevOpsPAT -Branch $Branch -TestLocation $TestLocation -NumberOfImages $OptimalNumberList[$i]
                        if ($BuildNumber) {
                            Write-Host "Info: The pipeline #BuildId $BuildNumber will run $($OptimalNumberList[$i]) images in $TestLocation"
                            break
                        }
                    }
                    if (!$BuildNumber) {
                        Write-Host "Error: Failed to Trigger ADO pipeline. Exit.."
                        exit 1
                    }
                }
            }
        }
    } catch {
        Write-Host "Error: Failed to Query data from database"
        $line = $_.InvocationInfo.ScriptLineNumber
        $script_name = ($_.InvocationInfo.ScriptName).Replace($PWD,".")
        $ErrorMessage =  $_.Exception.Message
        Write-Host "Error: EXCEPTION : $ErrorMessage"
        Write-Host "Error: Source : Line $line in script $script_name."
    } finally {
        $connection.Close()
    }
} else {
    Write-Host "Error: Database details are not provided."
}
