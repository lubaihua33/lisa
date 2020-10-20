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
	[string] $UploadTableName = "AzureFleetSmokeTestDistroList"
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

$sql = "select distinct FullName from $QueryTableName where IsAvailable like '1'"
if ($server -and $dbuser -and $dbpassword -and $database) {
	try {
		Write-Host "Info: SQLQuery:  $sql"
		$connectionString = "Server=$server;uid=$dbuser; pwd=$dbpassword;Database=$database;Encrypt=yes;TrustServerCertificate=no;Connection Timeout=30;MultipleActiveResultSets=True;"
		$connection = New-Object System.Data.SqlClient.SqlConnection
		$connection.ConnectionString = $connectionString
		$connection.Open()		
		$dataset = new-object "System.Data.Dataset"
		$dataadapter = new-object "System.Data.SqlClient.SqlDataAdapter" ($sql, $connection)
		$dataadapter.Fill($dataset)
		foreach ($row in $dataset.Tables.rows) {
			$image = $row.FullName
			$sql = "select Location from $QueryTableName where FullName like '$image'"
			$dataset_location = new-object "System.Data.Dataset"
			$dataadapter = new-object "System.Data.SqlClient.SqlDataAdapter" ($sql, $connection)
			$dataadapter.Fill($dataset_location)
			if ($dataset_location.Tables.rows) {
				$location = $dataset_location.Tables.rows[0].Location
			} else {
				Write-Host "Error: No this Image $image in $QueryTableName"
				continue
			}
			# Insert record
			$sql = "insert into $UploadTableName (ARMImage, TestLocation) VALUES ('$image', '$location')"
			$command = $connection.CreateCommand()
			$command.CommandText = $sql
			$null = $command.executenonquery()
			Write-Host "$image $location is inserted."
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
