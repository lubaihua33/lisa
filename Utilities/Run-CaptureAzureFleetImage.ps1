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
    [parameter(Mandatory=$true)][string] $DatabaseSecretsFile,
    [parameter(Mandatory=$true)][string] $AzureSecretsFile,
    [parameter(Mandatory=$true)][string] $StorageAccountName,
    [parameter(Mandatory=$true)][string] $ResourceGroupName,
    [parameter(Mandatory=$true)][string] $ContainerName,
    [parameter(Mandatory=$true)][string] $RGIdentifier,
    [parameter(Mandatory=$true)][string] $dbServerName,
    [parameter(Mandatory=$true)][string] $dbName
)

$StatusRunning = "Running"
$StatusPassed = "Passed"
$StatusFailed = "Failed"

$org = "https://dev.azure.com/microsoft"
$project = "LSG"
$BuildId = $env:BUILD_BUILDNUMBER
$BuildUrl =  "$($org)/$($project)/_build/results?buildId=$($BuildId)"

$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Definition
Write-Host "scriptpath: $scriptPath"
$commonModulePath = Join-Path $scriptPath "CommonFunctions.psm1"
Import-Module $commonModulePath

$PipelineLogDir = ".\TestResults\pipeline"
$PipelineLogFileName = "pipeline-$(Get-Date -Format 'yyyy-MM-dd').log"

function Update-CaptureImageInfoDone($connection, $captureImage, $status, $uri) {
    if ($uri) {
        $sql = "
        UPDATE CaptureImageInfo
        SET Status='$status', VhdUri='$uri', BuildUrl='$BuildUrl', UpdatedDate=getdate()
        WHERE ARMImage='$captureImage'"
    } else {
        $sql = "
        UPDATE CaptureImageInfo
        SET Status='$status', BuildUrl='$BuildUrl', UpdatedDate=getdate()
        WHERE ARMImage='$captureImage'"
    }

    ExecuteSql $connection $sql
    Write-LogInfo "Update the status of $captureImage $status"
}

Function Search-StorageAccountBlob ($image, $location) {
    $armImage = $image.split(' ')
    if ($armImage[3].ToLower() -eq "latest") {
        $images = Get-AzVMImage -Location $location -PublisherName $armImage[0] -Offer $armImage[1] -Skus $armImage[2]
        $azureBlobName = "$($armImage[0])/$($armImage[1])/$($armImage[2])/$($images[-1].Version).vhd"
    } else {
        $azureBlobName = "$($armImage[0])/$($armImage[1])/$($armImage[2])/$($armImage[3]).vhd"
    }

    .\Utilities\AddAzureRmAccountFromSecretsFile.ps1 -customSecretsFilePath $env:LISA_TESTONLY_SECUREFILEPATH

    $context = (Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName).context
    $blob =  Get-AzStorageBlob -Blob $azureBlobName -Container $ContainerName -Context $context -ErrorAction Ignore
    if ($blob -and $blob.IsDeleted -eq $false) {
        return $blob.ICloudBlob.Uri.OriginalString
    }
}

Function Invoke-CaptureVHDTest($ARMImage, $TestLocation)
{
    Write-LogInfo "Run Capture VHD test for $ARMImage in $TestLocation"
    $startTime = Get-Date

    .\Run-LisaV2.ps1 `
    -TestLocation $TestLocation `
    -RGIdentifier $RGIdentifier `
    -TestPlatform  "Azure" `
    -ARMImageName $ARMImage `
    -StorageAccount "ExistingStorage_Standard" `
    -TestNames "CAPTURE-VHD-BEFORE-TEST" `
    -XMLSecretFile $AzureSecretsFile `
    -ResourceCleanup Delete `
    -ForceCustom -EnableTelemetry

    Write-LogInfo "Get the test result..."
    if (Test-Path -Path ".\Report") {
        $report = Get-ChildItem ".\Report" | Where-Object {($_.FullName).EndsWith("-junit.xml")} | Where-object {$_.CreationTime -gt $startTime}
        if ($report -and $report.GetType().BaseType.Name -eq 'FileSystemInfo') {
            $resultXML = [xml](Get-Content "$($report.FullName)" -ErrorAction SilentlyContinue)
            if (($resultXML.testsuites.testsuite.failures -eq 0) -and
                ($resultXML.testsuites.testsuite.errors -eq 0) -and
                ($resultXML.testsuites.testsuite.skipped -eq 0) -and
                ($resultXML.testsuites.testsuite.tests -gt 0)) {
                    return "$StatusPassed"
            } else {
                    return $StatusFailed
            }
        }
    }
    Write-LogErr "There is no or more than one report. We can't get the test result."
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
    SELECT ARMImage,Location FROM CaptureImageInfo 
    WHERE Context='$BuildId' and Status='$StatusRunning'"

    $results = QuerySql $connection $sql
    foreach ($_ in $results) {
        $image = $_.ARMImage
        $location = $_.Location

        # Not check, we could not check if the vhd file is completeness, just run test
        # If we can't get the result of the test, nothing need to do. This image will rerun
        $ret = Invoke-CaptureVHDTest $image $Location
        if ($ret -eq $StatusPassed) {
            # The vhd may exist even if the test is failed
            $vhdUri = Search-StorageAccountBlob $image $Location
            if ($vhdUri) {
                Update-CaptureImageInfoDone $connection $image $StatusPassed $vhdUri
            } else {
                Write-LogErr "The CAPTURE-VHD-BEFORE-TEST of $image is passed, but no vhd file in storage account"
            }
        } elseif ($ret -eq $StatusFailed) {
            Update-CaptureImageInfoDone $connection $image $StatusFailed
        }
    }
} catch {
    $line = $_.InvocationInfo.ScriptLineNumber
    $script_name = ($_.InvocationInfo.ScriptName).Replace($PWD,".")
    $ErrorMessage =  $_.Exception.Message

    Write-LogErr "EXCEPTION: $ErrorMessage"
    Write-LogErr "Source: Line $line in script $script_name."
} finally {
    if ($connection) {
        $connection.Close()
        $connection.Dispose()
    }
}

