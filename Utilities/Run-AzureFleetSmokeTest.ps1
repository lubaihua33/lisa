##############################################################################################
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.
#
# Run-AzureFleetSmokeTest.ps1
<#
.SYNOPSIS
    This script is to run Azure Fleet Smoke test
.PARAMETER

Documentation

.NOTES
    Creation Date:
    Purpose/Change:

.EXAMPLE
    Run-AzureFleetSmokeTest.ps1 -TestLocation "eastus" -NumberOfImagesInOnePipeline 700
#>
###############################################################################################
Param
(
    [string] $AzureSecretsFile,
    [string] $QueryTableName = "AzureFleetSmokeTestDistroList",
    [string] $TestLocation,
    [int] $NumberOfImagesInOnePipeline
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

if (!$NumberOfImagesInOnePipeline -or $NumberOfImagesInOnePipeline -eq 0) {
    Write-Host "Error: NumberOfImagesInOnePipeline is NULL or is zero."
    exit 1
}

Function Run-SmokeTestbyLISAv3($ARMImage, $TestLocation)
{
    Set-Location -Path ".\lisa"

    $gPublisher = $ARMImage.split(' ')[0]
    $gOffer = $ARMImage.split(' ')[1]
    $gSku = $ARMImage.split(' ')[2]
    $gVersion = $ARMImage.split(' ')[3]
    poetry run python lisa/main.py -r ..\runbook\smoke.yml -v gPublisher:${gPublisher} -v gOffer:${gOffer} -v gSku:${gSku} -v gVersion:${gVersion} -v location:${TestLocation}-v adminPrivateKeyFile:$env:LISA_PRI_SECUREFILEPATH
    Set-Location Path "..\"
}

Function Install-LISAv3() {
    git submodule init
    git submodule update

    Write-Host "Install poetry..."
    (Invoke-WebRequest -Uri https://raw.githubusercontent.com/python-poetry/poetry/master/get-poetry.py -UseBasicParsing).Content | python - --preview --version 1.1.0b4
    $env:PATH += ";$env:USERPROFILE\.poetry\bin"
    poetry self update --preview 1.1.0b4

    Set-Location -Path ".\lisa"
    poetry install

    Write-Host "Copy secret file from $env:LISA_SECUREFILEPATH to ./lsg-lisa/runbook"
    Copy-Item -Path $env:LISA_SECUREFILEPATH  -Destination "./lsg-lisa/runbook" -Force

    $secret_file = Split-Path -Path $env:LISA_SECUREFILEPATH -Leaf
    Write-Host "Rename $secret_file to secret.yml"
    Rename-Item -Path "./lsg-lisa/runbook/$secret_file" -NewName "./lsg-lisa/runbook/secret.yml"
    Set-Location Path "..\"
}

Install-LISAv3

$BuildNumber = $env:BUILD_BUILDNUMBER
$SQLQuery="select * from $QueryTableName where BuildID like '$BuildNumber' and RunStatus like 'START' and TestLocation like '$TestLocation'"

$server = $XmlSecrets.secrets.DatabaseServer
$dbuser = $XmlSecrets.secrets.DatabaseUser
$dbpassword = $XmlSecrets.secrets.DatabasePassword
$database = $XmlSecrets.secrets.DatabaseName

if ($server -and $dbuser -and $dbpassword -and $database) {
    try {
        Write-Host "Info: SQLQuery:  $SQLQuery"
        $connectionString = "Server=$server;uid=$dbuser; pwd=$dbpassword;Database=$database;Encrypt=yes;TrustServerCertificate=no;Connection Timeout=30;MultipleActiveResultSets=True;"
        $connection = New-Object System.Data.SqlClient.SqlConnection
        $connection.ConnectionString = $connectionString
        $connection.Open()
        $count = 0
        $retry = 0
        While ($count -ne $NumberOfImagesInOnePipeline) {
            $command = $connection.CreateCommand()
            $command.CommandText = $SQLQuery
            $reader = $command.ExecuteReader()
            While ($reader.read()) {
                $ARMImage = $reader.GetValue($reader.GetOrdinal("ARMImage"))
                Run-SmokeTestbyLISAv3 -ARMImage $ARMImage -TestLocation $TestLocation
                # Upload status to database
                $sqlCommand = "Update $QueryTableName Set RunStatus='DONE' where ARMImage like '$ARMImage'"
                $command1 = $connection.CreateCommand()
                $command1.CommandText = $sqlCommand
                $null = $command1.executenonquery()
                Write-Host "Update $QueryTableName RunStatus to 'DONE' where ARMImage is $ARMImage"
                $count += 1
            }
            Start-Sleep -Seconds 10
            $retry += 1
            if ($retry -gt 180) {
                Write-Host "Error: The number of 'DONE' images is not equal to $NumberOfImagesInOnePipeline"
                break
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
