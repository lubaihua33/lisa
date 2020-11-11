##############################################################################################
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.
#
# Run-CaptureVHD.ps1
# This script is to run CAPTURE-VHD-BEFORE-TEST for Azure fleet images
#
###############################################################################################
Param
(
    [string] $DatabaseSecretsFile,
    [string] $AzureSecretsFile,
    [string] $StorageAccountName,
    [string] $ResourceGroupName,
    [string] $ContainerName,
    [string] $RGIdentifier,
    [string] $dbServerName,
    [string] $dbName
)

$StatusRunning = "Running"
$BuildId = $env:BUILD_BUILDNUMBER

$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Definition
Write-Host "scriptpath: $scriptPath"
$commonModulePath = Join-Path $scriptPath "CommonFunctions.psm1"
Import-Module $commonModulePath

function Update-CaptureImageInfoDone($connection, $captureImage) {
    Write-LogInfo "Update VHD capture cache done"

    $sql = "
    update CaptureImageInfo
    set Status='$StatusDone', UpdatedDate=getdate()
    where ARMImage='$captureImage'
    )"

    ExecuteSql $connection $sql
}

Function Search-StorageAccountBlob ($ARMImage, $location) {
    if ($ARMImage.ToLower().contains(" latest")) {
        $images = Get-AzVMImage -Location $location -PublisherName $ARMImage[0] -Offer $ARMImage[1] -Skus $ARMImage[2]
        $azureBlobName = "$($ARMImage[0])/$($ARMImage[1])/$($ARMImage[2])/$($images[-1].Version)"
    } else {
        $azureBlobName = "$($ARMImage[0])/$($ARMImage[1])/$($ARMImage[2])/$($ARMImage[3])"
    }

    $context = (Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName).context
    $blob =  Get-AzStorageBlob -Blob $azureBlobName -Container $ContainerName -Context $context -ErrorAction Ignore
    if ($blob -and $blob.IsDeleted -eq $false) {
        return $true
    } esle {
        return $false
    }
}
Function Invoke-CaptureVHDTest($ARMImage, $TestLocation)
{
    Write-LogInfo "Run Capture VHD test for $ARMImage in $TestLocation"

    .\Run-LisaV2.ps1 `
    -TestLocation $TestLocation `
    -RGIdentifier $RGIdentifier `
    -TestPlatform  "Azure" `
    -ARMImageName $ARMImage `
    -StorageAccount "ExistingStorage_Standard" `
    -TestNames "CAPTURE-VHD-BEFORE-TEST" `
    -XMLSecretFile $AzureSecretsFile `
    -TestIterations 1 `
    -ResourceCleanup Delete `
    -VMGeneration 1 `
    -ForceCustom  -ExitWithZero -EnableTelemetry
}

# Read secrets file and terminate if not present.
Write-Host "Info: Check the Database Secrets File..."
if (![String]::IsNullOrEmpty($DatabaseSecretsFile) -and (Test-Path -Path $DatabaseSecretsFile)) {
    $content = Get-Content -Path $DatabaseSecretsFile
    foreach ($line in $content) {
        if ($line.split(':')[0] -eq 'dbUserName') {
            $dbuser = $line.split(':')[1].trim()
        }
        if ($line.split(':')[0] -eq 'dbPassword') {
            $dbpassword = $line.split(':')[1].trim()
        }
    }
} else {
    Write-LogErr "Please provide value for -DatabaseSecretsFile"
    exit 1
}

$database = $dbName
$server = $dbServerName

if (!$server -or !$dbuser -or !$dbpassword -or !$database) {
    Write-LogErr "Database details are not provided."
    exit 1
}

$connectionString = "Server=$server;uid=$dbuser; pwd=$dbpassword;Database=$database;Encrypt=yes;" +
                    "TrustServerCertificate=no;Connection Timeout=30;MultipleActiveResultSets=True;"

try {
    $connection = New-Object System.Data.SqlClient.SqlConnection
    $connection.ConnectionString = $connectionString
    $connection.Open()

    $sql = "
    SELECT ARMImage FROM CaptureImageInfo 
    WHERE Context='$BuildId' and Status='$StatusRunning'"

    $results = QuerySql $connection $sql
    foreach ($_ in $results) {
        $image = $_.ARMImage
        $location = $_.Location
        # Not check, we could not check if the vhd file is completeness.
        # Check-StorageAccountBlob $image
        Invoke-CaptureVHDTest $image $Location

        $isExist = Search-StorageAccountBlob $image $Location
        if ($isExist -eq $true) {
            Update-CaptureImageInfoDone $connection $image
        }
    }
}
finally {
    if ($connection) {
        $connection.Close()
        $connection.Dispose()
    }
}

