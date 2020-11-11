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
    [parameter(Mandatory=$true)][string] $AzureSecretsFile,
    [parameter(Mandatory=$true)][string] $StorageAccountName,
    [parameter(Mandatory=$true)][string] $ResourceGroupName,
    [parameter(Mandatory=$true)][string] $ContainerName,
    [parameter(Mandatory=$true)][string] $RGIdentifier,
    [parameter(Mandatory=$true)][string] $Location
)

$StatusRunning = "Running"
$BuildId = $env:BUILD_BUILDNUMBER

$scriptPath = Get-Location
$commonModulePath = Join-Path $scriptPath "CommonFunctions.psm1"
Import-Module $commonModulePath

function Update-VHDCaptureCacheDone($connection, $captureImage) {
    Write-LogInfo "Update VHD capture cache done"

    $sql = "
    update VHDCaptureCache
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
    -TestPlatform  'Azure' `
    -ARMImageName $ARMImage `
    -StorageAccount 'ExistingStorage_Standard' `
    -TestIterations 1 `
    -ResourceCleanup Delete `
    -VMGeneration 1 `
    -ForceCustom  -ExitWithZero -EnableTelemetry 
}

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

$server = $XmlSecrets.secrets.DatabaseServer
$dbuser = $XmlSecrets.secrets.DatabaseUser
$dbpassword = $XmlSecrets.secrets.DatabasePassword
$database = $XmlSecrets.secrets.DatabaseName
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
    SELECT ARMImage FROM VHDCaptureCache 
    WHERE Context='$BuildId' and Status='$StatusRunning'"

    $results = QuerySql $connection $sql
    foreach ($_ in $results) {
        $image = $_.ARMImage
        # Not check, we could not check if the vhd file is completeness.
        # Check-StorageAccountBlob $image
        Invoke-CaptureVHDTest $image $Location

        $isExist = Search-StorageAccountBlob $image $Location
        if ($isExist -eq $true) {
            Update-VHDCaptureCacheDone $connection $image
        }
    }
}
finally {
    if ($connection) {
        $connection.Close()
        $connection.Dispose()
    }
}

