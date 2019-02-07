#Requires -RunAsAdministrator
#Requires -Version 5.1
#Requires -Modules PowerShellGet, PackageManagement

[CmdletBinding()] param(
    [PSCredential] $credential,
    [ValidateScript({
        if (!(Test-Path $_)) {
            throw "Path $_ does not exist. Please enter valid path to the install.config."
        }
        if (!(Test-Path $_ -PathType Leaf)) {
            throw "Path $_ is not a file. Please enter a valid path to the install.config."
        }
        return $true
    })] 
    [string] $installConfigPath = "$PSScriptRoot\install.config",
    [switch] $quiet
)

Import-Module -Name "$PSScriptRoot\AzureAD-Utilities.psm1" -Force
Import-Module -Name "$PSScriptRoot\Install-Authorization-Utilities.psm1" -Force
Import-Module -Name "$PSScriptRoot\Install-Identity-Utilities.psm1" -Force
Import-Module ActiveDirectory

# Import Fabric Install Utilities
$fabricInstallUtilities = "$PSScriptRoot\Fabric-Install-Utilities.psm1"
if (!(Test-Path $fabricInstallUtilities -PathType Leaf)) {
    Write-DosMessage -Level "Warning" -Message "Could not find fabric install utilities. Manually downloading and installing"
    Invoke-WebRequest -Uri https://raw.githubusercontent.com/HealthCatalyst/InstallScripts/master/common/Fabric-Install-Utilities.psm1 -Headers @{"Cache-Control" = "no-cache"} -OutFile $fabricInstallUtilities
}
Import-Module -Name $fabricInstallUtilities -Force

$credentials = @{}

function Get-NonMigratedActiveDirectoryGroups {
    param(
        [Parameter(Mandatory=$true)]
        [string] $connectionString
    )

    $connection = New-Object System.Data.SqlClient.SqlConnection($connectionString)	
    $sql = "SELECT GroupId, Name, IdentityProvider, ExternalIdentifier, TenantId
              FROM Groups
              WHERE IsDeleted = 0
              AND IdentityProvider = 'Windows'
              AND Source = 'Directory'"
    $command = New-Object System.Data.SqlClient.SqlCommand($sql, $connection)
    
    Write-DosMessage -Level "Information" -Message "Retrieving groups for migration..."

    $groups = @();
    try {	
        $connection.Open()
        $adapter = New-Object System.Data.sqlclient.sqlDataAdapter $command
        $groups = New-Object System.Data.DataTable
        $adapter.Fill($groups) | Out-Null
        $connection.Close()
    }
    catch [System.Data.SqlClient.SqlException] {
        Write-DosMessage -Level "Fatal" -Message "An error occurred while executing the command to retrieve non-migrated AD groups. Connection String: $($connectionString). Error $($_.Exception)"
    }    	
    
    Write-DosMessage -Level Information -Message "$($groups.Rows.Count) group(s) found for migration"
    return $groups;
}

function Get-AzureADGroupBySID {
    param(
        [Parameter(Mandatory=$true)]
        [string] $tenantId,
        [Parameter(Mandatory=$true)]
        [string] $groupSID
    )

    $azureADGroups = @()
    # connect to Azure AD
    if ($null -ne $credentials[$tenantId]) {
        Write-DosMessage -Level Information "Using cached credentials to connect to tenant $($tenantId)"
        Connect-AzureADTenant -tenantId $tenantId -credential $credentials[$tenantId]
    } else {
        Write-DosMessage -Level Information "Credentials not cached - prompting user for credentials to connect to tenant $($tenantId)"
        $authenticationFailed = $true
        do {
            try {
                $credential = Connect-AzureADTenant -tenantId $tenantId
                if (!$credentials.ContainsKey($tenantId)) {
                    Write-DosMessage -Level Information -Message "Caching credentials for tenant $($tenantId)."
                    $credentials.Add($tenantId, $credential)
                }

                Write-DosMessage -Level "Information" -Message "Retrieving group $($groupSID) from Azure AD Tenant $($tenantId)..."
                $azureADGroups = Get-AzureADGroup -Filter "onPremisesSecurityIdentifier eq '$($groupSID)'"
                $authenticationFailed = $false
            }
            catch [Microsoft.Open.Azure.AD.CommonLibrary.AadAuthenticationFailedException], [Microsoft.Open.Azure.AD.CommonLibrary.AadNeedAuthenticationException] {
                Write-DosMessage -Level Error -Message "Error authenticating user with Azure AD tenant $($tenantId). Please try again."
                $authenticationFailed = $true
            }
            # Connect-AzureADTenant will not throw an exception if a valid username (i.e., user@domain, even if user is not in tenant
            # and/or invalid password is entered). This catch block handles the 403 that is returned when Get-AzureADGroup fails
            # for this scenario
            catch [Microsoft.Open.AzureAD16.Client.ApiException] {
                if ($_.Exception.ErrorCode -eq 403) {
                    Write-DosMessage -Level Information -Message "403 error when retrieving Azure AD group."
                    # reset cached credentials for this tenantId
                    $credentials.Remove($tenantId)
                    $authenticationFailed = $true
                }
                else {
                    throw
                }
            }
            catch {
                $errorMsg = "Unexpected error while connecting to Azure AD: $($_.Exception)"
                Write-DosMessage -Level Error -Message $errorMsg
                throw $errorMsg
            }
        } while ($authenticationFailed -eq $true)
    }

    # disconnect from Azure AD
    try {
        Disconnect-AzureAD
    }
    catch {
        $errorMsg = "There was an unexpected error error while disconnecting from Azure AD tenant: $($tenantId)"
        Write-DosMessage -Level Error -Message $errorMsg
        throw $errorMsg
    }

    if ($azureADGroups.Count -eq 1) {
        return $azureADGroups[0]
    }
    elseif ($azureADGroups.Count -eq 0) {
        $errorMsg = "No match found for SID $($groupSID) in Azure AD Tenant $($tenantId)."
        Write-DosMessage -Level Information -Message $errorMsg
        throw $errorMsg
    }
    else {
        $errorMsg = "Multiple matches found for group SID $($groupSID)."
        Write-DosMessage -Level Error -Message $errorMsg
        throw $errorMsg
    }
}

function Move-ActiveDirectoryGroupsToAzureAD {
     param(
        [Parameter(Mandatory=$true)]
        [string] $connString
    )

    Write-DosMessage -Level Information -Message "Migrating AD groups to Azure AD..."

    $allowedTenantIds = @()

    try {
        $allowedTenantIds = Get-AzureADTenants -installConfigPath $installConfigPath
    }
    catch {
        Write-DosMessage -Level Fatal -Message "Error retrieving Azure AD Tenants. Check to ensure the installConfigPath ($($installConfigPath)) is correct."
        throw
    }
    if ($null -eq $allowedTenantIds -or $allowedTenantIds.Count -eq 0) {
        Write-DosMessage -Level Fatal -Message  "No tenants were found in the install.config"
        throw
    }

    # retrieve all groups from Auth DB    
    try {
        $results = Get-NonMigratedActiveDirectoryGroups -connectionString $connString
    }
    catch {
        Write-DosMessage -Level Fatal -Message "An error occurred while retrieving non-migrated AD groups. Connection String: $($connString). Error $($_.Exception)"
        throw
    }

    if ($results.Count -eq 0) {
        Write-DosMessage -Level Information -Message "No groups found to migrate."
    }

    foreach ($group in $results) {
        # query AD for SID (example SID: S-1-5-21-406681558-3692380417-1824333429-2607)
        $adGroupSID = ""
        try {
            $authGroupNameParts = $group.Name.Split('\')
            $adGroupName = ""
            if ($authGroupNameParts.Count -eq 1) {
                $adGroupName = $authGroupNameParts[0]
            }
            else {
                $adGroupName = $authGroupNameParts[1]
            }
            $adGroup = Get-ADGroup -Identity $adGroupName
            $adGroupSID = $adGroup.SID.Value
        }
        catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
            Write-DosMessage -Level Error -Message "Group $($group.Name) could not be found in Active Directory. Unable to migrate."
            continue
        }
        catch {
            Write-DosMessage -Level Error -Message "An unexpected error occurred while retrieving AD Group $($group.Name) from Active Directory. Error $($_.Exception)"
            continue
        }

        foreach ($tenantId in $allowedTenantIds) {
            # query Azure AD to get external ID
            try {
                $azureADGroup = Get-AzureADGroupBySID -tenantId $tenantId -groupSID $adGroupSID
            }
            catch {
                Write-DosMessage -Level Debug -Message "Error occurred while processing group $($group.Name) for tenant ($tenantId)"
                continue
            }

            # if group exists, then it's a match so migrate
            if ($null -ne $azureADGroup) {
                $sql = "UPDATE g 
                SET g.IdentityProvider = 'AzureActiveDirectory',
                    g.TenantId = @tenantId,
                    g.ExternalIdentifier = @externalIdentifier,
                    g.ModifiedBy = 'fabric-installer',
                    g.ModifiedDateTimeUtc = GETUTCDATE()
                FROM Groups g
                WHERE g.[GroupId] = @groupId;"
    
                Write-DosMessage -Level "Information" -Message "Migrating group $($group.Name) to Azure AD Tenant $tenantId..."
                try {
                    Invoke-Sql $connString $sql @{groupId=$group.GroupId;tenantId=$tenantId;externalIdentifier=$($azureADGroup.ObjectId)} | Out-Null
                }
                catch {
                    Write-DosMessage -Level Error -Message "An error occurred while migrating AD groups to Azure AD. Connection String: $($connectionString). Error $($_.Exception)"
                }

                break
            }
        }
    }
}

$identityInstallSettings = Get-InstallationSettings "identity" -installConfigPath $installConfigPath
$useAzureAD = $identityInstallSettings.useAzureAD
if ($null -eq $useAzureAD -or $true -eq $useAzureAD) {
    $authInstallSettings = Get-InstallationSettings "authorization" -installConfigPath $installConfigPath
    $sqlServerAddress = Get-SqlServerAddress -sqlServerAddress $authInstallSettings.sqlServerAddress -installConfigPath $installConfigPath -quiet $quiet
    $authorizationDatabase = Get-AuthorizationDatabaseConnectionString -authorizationDbName $authInstallSettings.authorizationDbName -sqlServerAddress $sqlServerAddress -installConfigPath $installConfigPath -quiet $quiet
    Move-ActiveDirectoryGroupsToAzureAD -connString $authorizationDatabase.DbConnectionString
}
else {
    Write-DosMessage -Level "Information" "The useAzureAD configuration setting in install.config 'identity' section is disabled. This must be enabled to run the migration script."
}