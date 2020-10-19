##############################################################################################
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.
#
# Get-SmokeTestDistroList.ps1
<#
.SYNOPSIS
	This script can Get the distro list from table [AzureMarketplaceDistroInfo] in database.
	Then upload the distro list to the table [AzureFleetSmokeTestDistroList]

.PARAMETER
	-AzureSecretsFile, the path of Azure secrets file

.NOTES
	Creation Date:
	Purpose/Change:

.EXAMPLE
	Get-SmokeTestDistroList.ps1 -XMLSecretFile $pathToSecret

#>
###############################################################################################
Param
(
	[string] $AzureSecretsFile,
	[string] $QueryTableName = "AzureMarketplaceDistroInfo",
	[string] $UploadTableName = "AzureFleetSmokeTestDistroList",
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

$server = $XmlSecrets.secrets.DatabaseServer
$dbuser = $XmlSecrets.secrets.DatabaseUser
$dbpassword = $XmlSecrets.secrets.DatabasePassword
$database = $XmlSecrets.secrets.DatabaseName

$SQLQuery="select distinct FullName,Location from $QueryTableName where IsAvailable like '1'"

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
		While ($reader.read()) {
			$ARMImage = $reader.GetValue($reader.GetOrdinal("FullName"))
			$SQLQuery="select * from $QueryTableName where FullName like '$ARMImage'"
			$command1 = $connection.CreateCommand()
			$command1.CommandText = $SQLQuery
			$reader1 = $command1.ExecuteReader()
			if ($reader1.read()) {
				$Location = $reader1.GetValue($reader1.GetOrdinal("Location"))
			} else {
				Write-Host "Error: No this Image $ARMImage in $QueryTableName"
				continue
			}
			$sqlQuery = "insert into $UploadTableName (ARMImage, TestLocation) VALUES ('$ARMImage', '$Location')"
			$command2 = $connection.CreateCommand()
			$command2.CommandText = $sqlQuery
			$command2.executenonquery()
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
