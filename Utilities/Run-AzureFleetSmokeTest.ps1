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

    $gPublisher = $ARMImage.split(' ')[0]
    $gOffer = $ARMImage.split(' ')[1]
    $gSku = $ARMImage.split(' ')[2]
    $gVersion = $ARMImage.split(' ')[3]

    # Temp code check if have plan
    Write-Host "Info: Get-AzVMImage and check if has plan"
    if ($gVersion -ne "latest") {
        $used_image = Get-AzVMImage -Location $TestLocation -PublisherName $gPublisher -Offer $gOffer -Skus $gSku -Version $gVersion
    } else {
        $used_image = Get-AzVMImage -Location $TestLocation -PublisherName $gPublisher -Offer $gOffer -Skus $gSku
        $used_image = Get-AzVMImage -Location $TestLocation -PublisherName $gPublisher -Offer $gOffer -Skus $gSku -Version $used_image[-1].Version
    }
    if ($used_image.PurchasePlan) {
        Write-Host "Info: The Image $ARMImage has plan. Skip testing the image."
    } else {
        Write-Host "Info: The Image $ARMImage has no plan. Continue testing the image."
        Set-Location -Path ".\lisa"
        Write-Host "Info: poetry run python lisa/main.py -r ..\runbook\smoke.yml -v gPublisher:${gPublisher} -v gOffer:${gOffer} -v gSku:${gSku} -v gVersion:${gVersion} -v location:${TestLocation} -v adminPrivateKeyFile:$($env:LISA_PRI_SECUREFILEPATH)"
        poetry run python lisa/main.py -r ..\runbook\smoke.yml -v gPublisher:${gPublisher} -v gOffer:${gOffer} -v gSku:${gSku} -v gVersion:${gVersion} -v location:${TestLocation} -v adminPrivateKeyFile:"$($env:LISA_PRI_SECUREFILEPATH)"
        Set-Location -Path "..\"
    }
}

$BuildNumber = $env:BUILD_BUILDNUMBER
$sql = "select ARMImage from AzureFleetSmokeTestDistroList where BuildID like '$BuildNumber' and RunStatus like 'START'"

$server = $XmlSecrets.secrets.DatabaseServer
$dbuser = $XmlSecrets.secrets.DatabaseUser
$dbpassword = $XmlSecrets.secrets.DatabasePassword
$database = $XmlSecrets.secrets.DatabaseName

if ($server -and $dbuser -and $dbpassword -and $database) {
    Write-Host "Info: SQLQuery:  $sql"
    $connectionString = "Server=$server;uid=$dbuser; pwd=$dbpassword;Database=$database;Encrypt=yes;TrustServerCertificate=no;Connection Timeout=30;MultipleActiveResultSets=True;"
    $connection = New-Object System.Data.SqlClient.SqlConnection
    $connection.ConnectionString = $connectionString
    $connection.Open()
    $retry = 0
    While ($retry -lt 3) {
        $dataset = new-object "System.Data.Dataset"
        $dataadapter = new-object "System.Data.SqlClient.SqlDataAdapter" ($sql, $connection)
        $recordcount = $dataadapter.Fill($dataset)
        foreach ($row in $dataset.Tables.rows) {
            $image = $row.ARMImage
            Run-SmokeTestbyLISAv3 -ARMImage $image -TestLocation $TestLocation
            $sql = "Update AzureFleetSmokeTestDistroList Set RunStatus='DONE' where ARMImage='$image'"
            $command = $connection.CreateCommand()
            $command.CommandText = $sql
            $null = $command.ExecuteNonQuery()
            $command.Dispose()
            Write-Host "Update AzureFleetSmokeTestDistroList RunStatus to 'DONE' where ARMImage is $image"
        }
        if ($recordcount -eq 0) {
            Start-Sleep -Seconds 5
            $retry += 1
        }
    }
    if ($command) {
        $command.Dispose();
    }
    if ($connection) {
        $connection.Close()
        $connection.Dispose()
    }
} else {
    Write-Host "Error: Database details are not provided."
}
