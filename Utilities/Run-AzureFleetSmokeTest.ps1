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
    Run-AzureFleetSmokeTest.ps1 -TestLocation "eastus"
#>
###############################################################################################
Param
(
    [string] $AzureSecretsFile,
    [string] $TestLocation
)

# Read secrets file and terminate if not present.
Write-Host "Info: Check the Azure Secrets File..."
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
Write-Host "Info: Check the Azure Secrets File OK"

Function Run-SmokeTestbyLISAv3($ARMImage, $TestLocation)
{
    Write-Host "Info: Run smoke test for $ARMImage in $TestLocation"
    Set-Location -Path ".\lisa"

    $gPublisher = $ARMImage.split(' ')[0]
    $gOffer = $ARMImage.split(' ')[1]
    $gSku = $ARMImage.split(' ')[2]
    $gVersion = $ARMImage.split(' ')[3]
    #poetry run python lisa/main.py -r ..\runbook\smoke.yml -v gPublisher:${gPublisher} -v gOffer:${gOffer} -v gSku:${gSku} -v gVersion:${gVersion} -v location:${TestLocation}-v adminPrivateKeyFile:$env:LISA_PRI_SECUREFILEPATH
    Set-Location -Path "..\"
}

Function Install-LISAv3() {
    git submodule init
    git submodule update

    Write-Host "Install poetry..."
    (Invoke-WebRequest -Uri https://raw.githubusercontent.com/python-poetry/poetry/master/get-poetry.py -UseBasicParsing).Content | python - --preview --version 1.1.0b4
    $env:PATH += ";$env:USERPROFILE\.poetry\bin"
    poetry self update --preview 1.1.0b4

    Write-Host "Info: Change directory .\lisa"
    Set-Location -Path ".\lisa"
    poetry install
    Write-Host "Info: Change directory ..\"
    Set-Location -Path "..\"

    Write-Host "Copy secret file from $env:LISA_SECUREFILEPATH to ./runbook"
    Copy-Item -Path $env:LISA_SECUREFILEPATH  -Destination "./runbook" -Force

    $secret_file = Split-Path -Path $env:LISA_SECUREFILEPATH -Leaf
    Write-Host "Rename $secret_file to secret.yml"
    Set-Location -Path ".\runbook"
    Rename-Item -Path "$secret_file" -NewName "secret.yml"
    Set-Location -Path "..\"
}

Write-Host "Info: Install LISAv3..."
Install-LISAv3

$BuildNumber = $env:BUILD_BUILDNUMBER
$sql = "select ARMImage from AzureFleetSmokeTestDistroList where BuildID like '$BuildNumber' and RunStatus like 'START'"

$server = $XmlSecrets.secrets.DatabaseServer
$dbuser = $XmlSecrets.secrets.DatabaseUser
$dbpassword = $XmlSecrets.secrets.DatabasePassword
$database = $XmlSecrets.secrets.DatabaseName

if ($server -and $dbuser -and $dbpassword -and $database) {
    try {
        Write-Host "Info: SQLQuery:  $sql"
        $connectionString = "Server=$server;uid=$dbuser; pwd=$dbpassword;Database=$database;Encrypt=yes;TrustServerCertificate=no;Connection Timeout=30;MultipleActiveResultSets=True;"
        $connection = New-Object System.Data.SqlClient.SqlConnection
        $connection.ConnectionString = $connectionString
        $connection.Open()
        $retry = 0
        While ($true) {
            $dataset = new-object "System.Data.Dataset"
            $dataadapter = new-object "System.Data.SqlClient.SqlDataAdapter" ($sql, $connection)
            $recordcount = $dataadapter.Fill($dataset)
            foreach ($row in $dataset.Tables.rows) {
                $image = $row.ARMImage
                Run-SmokeTestbyLISAv3 -ARMImage $image -TestLocation $TestLocation
                $sql = "Update AzureFleetSmokeTestDistroList Set RunStatus='DONE' where ARMImage='$image'"
                $command = $connection.CreateCommand()
                $command.CommandText = $sql
                $null = $command.executenonquery()
                Write-Host "Update AzureFleetSmokeTestDistroList RunStatus to 'DONE' where ARMImage is $image"
            }
            if ($recordcount -eq 0) {
                Start-Sleep -Seconds 5
                $retry += 1
            }
            if ($retry -gt 3) {
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
