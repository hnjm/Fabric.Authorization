#
# Install_Authorization_Windows.ps1
#
param([switch]$noDiscoveryService)
$dosGrain = "dos"
$dataMartsSecurable = "datamarts"
$dosAdminRole = "dosadmin"
$dataMartAdminRole = "DataMartAdmin"
$fabricInstallerClientId = "fabric-installer"

function Get-FullyQualifiedMachineName() {
	return "https://$env:computername.$((Get-WmiObject Win32_ComputerSystem).Domain.tolower())"
}

function Get-DiscoveryServiceUrl() {
    return "$(Get-FullyQualifiedMachineName)/DiscoveryService/v1"
}

function Get-IdentityServiceUrl() {
    return "$(Get-FullyQualifiedMachineName)/Identity"
}

function Get-Headers($accessToken) {
    $headers = @{"Accept" = "application/json"}
    if ($accessToken) {
        $headers.Add("Authorization", "Bearer $accessToken")
    }
    return $headers
}

function Add-DatabaseLogin($userName, $connString) {
    $query = "USE master
            If Not exists (SELECT * FROM sys.server_principals
                WHERE sid = suser_sid(@userName))
            BEGIN
                print '-- creating database login'
                DECLARE @sql nvarchar(4000)
                set @sql = 'CREATE LOGIN ' + QUOTENAME('$userName') + ' FROM WINDOWS'
                EXEC sp_executesql @sql
            END"
    Invoke-Sql $connString $query @{userName = $userName} | Out-Null
}

function Add-DatabaseUser($userName, $connString) {
    $query = "IF( NOT EXISTS (SELECT * FROM sys.database_principals WHERE name = @userName))
            BEGIN
                print '-- Creating user';
                DECLARE @sql nvarchar(4000)
                set @sql = 'CREATE USER ' + QUOTENAME('$userName') + ' FOR LOGIN ' + QUOTENAME('$userName')
                EXEC sp_executesql @sql
            END"
    Invoke-Sql $connString $query @{userName = $userName} | Out-Null
}

function Add-DatabaseUserToRole($userName, $connString, $role) {
    $query = "DECLARE @exists int
            SELECT @exists = IS_ROLEMEMBER(@role, @userName) 
            IF (@exists IS NULL OR @exists = 0)
            BEGIN
                print '-- Adding @role to @userName';
                EXEC sp_addrolemember @role, @userName;
            END"
    Invoke-Sql $connString $query @{userName = $userName; role = $role} | Out-Null
}

function Add-DatabaseSecurity($userName, $role, $connString) {
    Add-DatabaseLogin $userName $connString
    Add-DatabaseUser $userName $connString
    Add-DatabaseUserToRole $userName $connString $role
    Write-Success "Database security applied successfully"
}

function Invoke-Get($url, $accessToken) {
    $headers = Get-Headers -accessToken $accessToken
        
    $getResponse = Invoke-RestMethod -Method Get -Uri $url -Headers $headers
    return $getResponse
}

function Invoke-Post($url, $body, $accessToken) {
    $headers = Get-Headers -accessToken $accessToken

    if (!($body -is [String])) {
        $body = (ConvertTo-Json $body)
    }
    
    $postResponse = Invoke-RestMethod -Method Post -Uri $url -Body $body -ContentType "application/json" -Headers $headers
    Write-Success "    Success."
    Write-Host ""
    return $postResponse
}

function Add-AuthorizationRegistration($clientId, $clientName, $authorizationServiceUrl, $accessToken){
    $url = "$authorizationServiceUrl/clients"
    $body = @{
        id = "$clientId"
        name = $clientName
    }
    try{
        Invoke-Post -url $url -body $body -accessToken $accessToken
    }
    catch {
        $exception = $_.Exception
        if ($exception -ne $null -and $exception.Response -ne $null -and $exception.Response.StatusCode.value__ -eq 409) {
            Write-Success "    Client: $clientId has already been registered with Fabric.Authorization"
            Write-Host ""
        }
        else {
            if ($exception.Response -ne $null) {
                $error = Get-ErrorFromResponse -response $exception.Response
                Write-Error "    There was an error registering $clientId with Fabric.Authorization: $error. Halting installation."
            }
            throw $exception
        }
    }
}

function Get-Group($name, $authorizationServiceUrl, $accessToken){
    $url = "$authorizationServiceUrl/groups/$name"
    return Invoke-Get -url $url -accessToken $accessToken
}

function Get-Role($name, $grain, $securableItem, $authorizationServiceUrl, $accessToken) {
    $url = "$authorizationServiceUrl/roles/$grain/$securableItem/$name"
    $role = Invoke-Get -url $url -accessToken $accessToken
    return $role
}

function Add-Group($authUrl, $name, $source, $accessToken) {
    Write-Host "Adding Group $($name)"
    $url = "$authUrl/groups"
    $body = @{
        groupName     = "$name"
        displayName   = "$name"
        groupSource = "$source"
    }
    return Invoke-Post $url $body $accessToken
}

function Add-User($authUrl, $name, $accessToken) {
    Write-Host "Adding User $($name)"
    $url = "$authUrl/user"
    $body = @{
        subjectId        = "$name"
        identityProvider = "Windows"
    }
    return Invoke-Post $url $body $accessToken
}

function Add-RoleToUser($role, $user, $connString, $clientId) {
    $query = "INSERT INTO RoleUsers
              (CreatedBy, CreatedDateTimeUtc, RoleId, IdentityProvider, IsDeleted, SubjectId)
              VALUES(@clientId, GetUtcDate(), @roleId, @identityProvider, 0, @subjectId)"

    $roleId = $role.Id
    $identityProvider = $user.identityProvider
    $subjectId = $user.subjectId
    Invoke-Sql $connString $query @{roleId = $roleId; identityProvider = $identityProvider; subjectId = $subjectId; clientId = $clientId} | Out-Null
}

function Add-UserToGroup($group, $user, $connString, $clientId)
{
    $query = "INSERT INTO GroupUsers
             (CreatedBy, CreatedDateTimeUtc, GroupId, IdentityProvider, SubjectId, IsDeleted)
             VALUES(@clientId, GETUTCDATE(), @groupId, @identityProvider, @subjectId, 0)"

    $groupId = $group.Id
    $identityProvider = $user.identityProvider
    $subjectId = $user.subjectId
    Invoke-Sql $connString $query @{groupId = $groupId; identityProvider = $identityProvider; subjectId = $subjectId; clientId = $clientId} | Out-Null
}

function Add-ChildGroupToParentGroup($parentGroup, $childGroup, $connString, $clientId)
{
    $query = "INSERT INTO ChildGroups
              (ParentGroupId, ChildGroupId, CreatedBy, CreatedDateTimeUtc, IsDeleted)
              VALUES(@parentGroupId, @childGroupId, @clientId, GETUTCDATE(), 0)"

    $parentGroupId = $parentGroup.Id
    $childGroupId = $childGroup.Id
    Invoke-Sql $connString $query @{parentGroupId = $parentGroupId; childGroupId = $childGroupId; clientId = $clientId} | Out-Null
}

function Add-RoleToGroup($role, $group, $connString, $clientId) {
    Write-Host "Adding Role: $($role.Name) to Group: $($group.Name)"
    $query = "INSERT INTO GroupRoles
              (CreatedBy, CreatedDateTimeUtc, GroupId, IsDeleted, RoleId)
              VALUES(@clientId, GetUtcDate(), @groupId, 0, @roleId)"

    $roleId = $role.Id
    $groupId = $group.Id
    Invoke-Sql $connString $query @{groupId = $groupId; roleId = $roleId; ; clientId = $clientId} | Out-Null
}

function Get-PrincipalContext($domain) {
    [System.Reflection.Assembly]::LoadWithPartialName("System.DirectoryServices.AccountManagement") | Out-Null
    $ct = [System.DirectoryServices.AccountManagement.ContextType]::Domain 
    $pc = New-Object System.DirectoryServices.AccountManagement.PrincipalContext -ArgumentList $ct, $domain
    return $pc
}

function Test-IsUser($samAccountName, $domain) {
    $isUser = $false
    $pc = Get-PrincipalContext -domain $domain
    $user = [System.DirectoryServices.AccountManagement.UserPrincipal]::FindByIdentity($pc, $samAccountName)
    if ($user -ne $null) {
        $isUser = $true
    }
    return $isUser
}

function Test-IsGroup($samAccountName, $domain) {
    $isGroup = $false
    $pc = Get-PrincipalContext -domain $domain
    $group = [System.DirectoryServices.AccountManagement.GroupPrincipal]::FindByIdentity($pc, $samAccountName)
    if ($group -ne $null) {
        $isGroup = $true
    }
    return $isGroup
}

function Get-SamAccountFromAccountName($accountName) {
    $accountNameParts = $accountName.Split('\')
    if ($accountNameParts.Count -ne 2) {
        Write-Error "Please enter an account in the form DOMAIN\account. Halting installation." 
        throw
    }
    $samAccountName = $accountNameParts[1]
    return $samAccountName
}

function Add-AccountToDosAdminGroup($accountName, $domain, $authorizationServiceUrl, $accessToken, $connString) {
    $samAccountName = Get-SamAccountFromAccountName -accountName $accountName
    $group = Get-Group -name $dosAdminGroupName -authorizationServiceUrl $authorizationServiceUrl -accessToken $accessToken
    if (Test-IsUser -samAccountName $samAccountName -domain $domain) {
        try {
            $user = Add-User -authUrl $authorizationServiceUrl -name $accountName -accessToken $accessToken
            Add-UserToGroup -group $group -user $user -connString $connString -clientId $fabricInstallerClientId
        }
        catch {
            $exception = $_.Exception
            if ($exception -ne $null -and $exception.Response -ne $null -and $exception.Response.StatusCode.value__ -eq 409) {
                Write-Success "    User: $accountName has already been registered as $dosAdminRole with Fabric.Authorization"
                Write-Host ""
            }
            else {
                if ($exception.Response -ne $null) {
                    $error = Get-ErrorFromResponse -response $exception.Response
                    Write-Error "    There was an error updating the resource: $error. Halting installation."
                }
                throw $exception
            }
        }
    }
    elseif (Test-IsGroup -samAccountName $samAccountName -domain $domain) {
        try {
            $childGroup = Add-Group -authUrl $authorizationServiceUrl -name $accountName -source "Windows" -accessToken $accessToken
            Add-ChildGroupToParentGroup -parentGroup $group -childGroup $childGroup -connString $connString -clientId $fabricInstallerClientId
        }
        catch {
            $exception = $_.Exception
            if ($exception -ne $null -and $exception.Response -ne $null -and $exception.Response.StatusCode.value__ -eq 409) {
                Write-Success "    Group: $accountName has already been registered as $dosAdminRole with Fabric.Authorization"
                Write-Host ""
            }
            else {
                if ($exception.Response -ne $null) {
                    $error = Get-ErrorFromResponse -response $exception.Response
                    Write-Error "    There was an error updating the resource: $error. Halting installation."
                }
                throw $exception
            }
        }
    }
    else {
        Write-Error "$samAccountName is not a valid principal in the $domain domain. Please enter a valid account. Halting installation."
        throw
    }
}

function Invoke-MonitorShallow($authorizationUrl) {
    $url = "$authorizationUrl/_monitor/shallow"
    Invoke-RestMethod -Method Get -Uri $url
}

function Get-EdwAdminUsersAndGroups($connectionString) {	
    $connection = New-Object System.Data.SqlClient.SqlConnection($connectionString)	
    $sql = "SELECT i.IdentityID, i.IdentityNM, r.RoleNM	
            FROM [CatalystAdmin].[RoleBASE] r	
            INNER JOIN [CatalystAdmin].[IdentityRoleBASE] ir	
                ON r.RoleID = ir.RoleID	
            INNER JOIN [CatalystAdmin].[IdentityBASE] i	
                ON ir.IdentityID = i.IdentityID	
            WHERE RoleNM = 'EDW Admin'";	
    $command = New-Object System.Data.SqlClient.SqlCommand($sql, $connection)	
    
    $usersAndGroups = @();	
    try {	
        $connection.Open()    	
        $reader = $command.ExecuteReader()	
        while ($reader.Read()) {	
            $usersAndGroups += $reader['IdentityNM']	
        }	
        $connection.Close()        	
    
    }	
    catch [System.Data.SqlClient.SqlException] {	
        Write-Error "An error ocurred while executing the command. Please ensure the connection string is correct and the metadata database has been setup. Connection String: $($connectionString). Error $($_.Exception.Message)"  -ErrorAction Stop	
    }    	
    
    return $usersAndGroups;	
}	
    	
function Add-ListOfUsersToDosAdminGroup($edwAdminUsers, $connString, $authorizationServiceUrl, $accessToken) {	   
    # Get the group once, should be same for every user.
    $group = Get-Group -name $dosAdminGroupName -authorizationServiceUrl $authorizationServiceUrl -accessToken $accessToken

    # For each user, loop and try to add the user to the API.  
    # Do not validate it to AD like the Add-AccountToDosAdminGroup function.
    foreach ($edwAdmin in $edwAdminUsers) {	
        if ([string]::IsNullOrWhiteSpace($edwAdmin)) {
            continue
        }

        try {  
            $user = Add-User -authUrl $authorizationServiceUrl -name $edwAdmin -accessToken $accessToken
            Add-UserToGroup -group $group -user $user -connString $connString -clientId $fabricInstallerClientId
        }
        catch {
            # If there is an exception, the function will print the error. We will want to 
            # continue with the next user, so we will catch and swallow the exception.
            $exception = $_.Exception
            if ($exception -ne $null -and $exception.Response -ne $null -and $exception.Response.StatusCode.value__ -eq 409) {
                Write-Success "    User: $accountName has already been registered as Dos Admin with Fabric.Authorization"
                Write-Host ""
            }
            else {
                if ($exception.Response -ne $null) {
                    $error = Get-ErrorFromResponse -response $exception.Response
                    Write-Error "    There was an error updating the resource: $error. "
                }
            }
        }        
    }	
}

function Add-DosAdminGroup($authUrl, $accessToken, $groupName)
{
    try {
        $group = Add-Group -authUrl $authUrl -name $groupName -source "custom" -accessToken $accessToken
        return $group
    }
    catch {
        $exception = $_.Exception
        if ($exception -ne $null -and $exception.Response -ne $null -and $exception.Response.StatusCode.value__ -eq 409) {
            $group = Get-Group -authorizationServiceUrl $authUrl -name $groupName -accessToken $accessToken
            Write-Success "$groupName group already exists..."
            return $group;
        }
        else{
            if ($exception.Response -ne $null) {
                $error = Get-ErrorFromResponse -response $exception.Response
                Write-Error "    There was an error adding the Dos Admin group: $error. Halting installation."
            }
            throw $exception
        }
    }
}

function Add-DosAdminRoleUsersToDosAdminGroup([GUID]$groupId, $connectionString, $clientId, $roleName, $securableName)
{
    $query = "INSERT INTO GroupUsers
              (CreatedBy, CreatedDateTimeUtc, GroupId, IdentityProvider, SubjectId, IsDeleted)
              SELECT @clientId, GETUTCDATE(), @dosAdminGroupId, u.IdentityProvider, ru.subjectid, 0 from RoleUsers ru
              INNER JOIN Roles r ON r.RoleId = ru.RoleId
              INNER JOIN Users u ON u.SubjectId = ru.SubjectId
              INNER JOIN SecurableItems s on r.SecurableItemId = s.SecurableItemId
              WHERE r.[Name] = @roleName
              AND s.[Name] = @securableName
              AND ru.IsDeleted = 0;"
    try{
        Write-Host "Migrating $dosAdminRole role users to Dos Admin group..."
        Invoke-Sql -connectionString $connectionString -sql $query -parameters @{dosAdminGroupId=$groupId;clientId=$clientId;roleName=$roleName;securableName=$securableName} | Out-Null
    }catch{
        Write-Error $_.Exception
        throw $_.Exception
    }
}

function Remove-UsersFromDosAdminRole($connectionString, $clientId, $roleName, $securableName)
{
    $sql = "UPDATE ru 
            SET ru.IsDeleted = 1,
                ru.ModifiedBy = @clientId,
                ru.ModifiedDateTimeUtc = GETUTCDATE()
            FROM roleusers ru
            INNER JOIN roles r ON ru.RoleId = r.RoleId
            INNER JOIN SecurableItems s on r.SecurableItemId = s.SecurableItemId
            WHERE r.[Name] = @roleName
            AND s.[Name] = @securableName
            AND ru.IsDeleted = 0;"
    
    Write-Host "Removing users from $dosAdminRole role..."
    try{
        Invoke-Sql $connectionString $sql @{clientId=$clientId;roleName=$roleName;securableName=$securableName} | Out-Null
    }catch{
        Write-Error $_.Exception
        throw $_.Exception
    }
}

function Add-DosAdminGroupRolesToDosAdminChildGroups([GUID]$groupId, $connectionString, $clientId, $roleName, $securableName)
{
    $query = "INSERT INTO ChildGroups
              (ParentGroupId, ChildGroupId, CreatedBy, CreatedDateTimeUtc, IsDeleted)
              SELECT @dosAdminGroupId, g.GroupId, @clientId, GETUTCDATE(), 0 
              FROM GroupRoles gr
              INNER JOIN Roles r ON r.RoleId = gr.RoleId
              INNER JOIN Groups g ON g.GroupId = gr.GroupId
              INNER JOIN SecurableItems s on r.SecurableItemId = s.SecurableItemId
              WHERE r.[Name] = @roleName
              AND s.[Name] = @securableName
              AND g.Source != 'custom'
              AND r.IsDeleted = 0;"

    try{
        Write-Host "Migrating $dosAdminRole role groups to Dos Admin group..."
        Invoke-Sql $connectionString $query @{dosAdminGroupId = $groupId;clientId=$clientId;roleName=$roleName;securableName=$securableName} | Out-Null
    }catch{
        Write-Error $_.Exception
        throw
    }
}

function Remove-GroupsFromDosAdminRole($connectionString, $clientId, $roleName, $securableName)
{
    $sql = "UPDATE gr
            SET gr.IsDeleted = 1, 
                gr.ModifiedBy = @clientId, 
                gr.ModifiedDateTimeUtc = GETUTCDATE()
            FROM GroupRoles gr
            INNER JOIN Roles r ON gr.RoleId = r.RoleId
            INNER JOIN SecurableItems s on r.SecurableItemId = s.SecurableItemId
            WHERE r.[Name] = @roleName
            AND s.[Name] = @securableName
            AND gr.IsDeleted = 0;"

    Write-Host "Removing groups from $dosAdminRole role..."
    try{
        Invoke-Sql $connectionString $sql @{clientId=$clientId;roleName=$roleName;securableName=$securableName} | Out-Null
    }catch{
        Write-Error $_.Exception
        throw $_.Exception
    }
}

function Add-DosAdminRoleToDosAdminGroup([GUID]$groupId, $connectionString, $clientId, $roleName, $securableName)
{
    $query = "INSERT INTO GroupRoles
              (CreatedBy, CreatedDateTimeUtc, GroupId, RoleId, IsDeleted)
              SELECT @clientId, GETUTCDATE(), @dosAdminGroupId, r.RoleId, 0
              FROM Roles r
              INNER JOIN SecurableItems s on r.SecurableItemId = s.SecurableItemId
              WHERE r.[Name] = @roleName
              AND s.[Name] = @securableName
              AND r.IsDeleted = 0;"
    try{
        Write-Host "Associating $dosAdminRole role to Dos Admin group..."
        Invoke-Sql $connectionString $query @{dosAdminGroupId = $groupId;clientId=$clientId;roleName=$roleName;securableName=$securableName} | Out-Null
    }catch{
        Write-Error $_.Exception
        throw
    }
}

function Update-DosAdminRoleToDataMartAdmin($connectionString, $clientId, $oldRoleName, $newRoleName, $securableName)
{
    $sql = "UPDATE r
            SET r.[Name]  = @newRoleName, 
                r.DisplayName = 'DataMart Admin', 
                r.ModifiedBy = @clientId, 
                r.ModifiedDateTimeUtc = GETUTCDATE()
            FROM Roles r
            INNER JOIN SecurableItems s on r.SecurableItemId = s.SecurableItemId
            WHERE r.[Name] = @oldRoleName
            AND s.[Name] = @securableName
            AND r.IsDeleted = 0;"

    Write-Host "Renaming $dosAdminRole role to $dataMartAdminRole..."
    try{
        Invoke-Sql $connectionString $sql @{clientId=$clientId;oldRoleName=$oldRoleName;newRoleName=$newRoleName;securableName=$securableName} | Out-Null
    }catch{
        Write-Error $_.Exception
        throw
    }
}

function Remove-DosAdminRole($connectionString, $clientId, $roleName, $securableName)
{
    $sql = "UPDATE r
            SET r.IsDeleted = 1,
                r.ModifiedBy = @clientId,
                r.ModifiedDateTimeUtc = GETUTCDATE()
            FROM Roles r
            INNER JOIN SecurableItems s on r.SecurableItemId = s.SecurableItemId
            WHERE r.[Name] = @roleName
            AND s.[Name] = @securableName
            AND r.IsDeleted = 0;"

    Write-Host "Deleting $dosAdminRole role..."
    try{
        Invoke-Sql $connectionString $sql @{clientId=$clientId;roleName=$roleName;securableName=$securableName} | Out-Null
    }catch{
        Write-Error $_.Exception
        throw
    }
}

function Test-FabricRegistrationStepAlreadyComplete($authUrl, $accessToken)
{
    try{
        $dataMartAdminRole = Get-Role -name $dataMartAdminRole -grain $dosGrain -securableItem $dataMartsSecurable -authorizationServiceUrl $authUrl -accessToken $accessToken
        $dosAdminRole = Get-Role -name $dosAdminRole -grain $dosGrain -securableItem $dataMartsSecurable -authorizationServiceUrl $authUrl -accessToken $accessToken
        if($dataMartAdminRole -ne $null -and $dosAdminRole -ne $null){
            return $true
        }
        return $false
    }
    catch {
        $exception = $_.Exception
        if ($exception.Response -ne $null) {
            $error = Get-ErrorFromResponse -response $exception.Response
            Write-Error "    There was an error getting the resource: $error. "
        }
        throw $exception
    }      
}

function Move-DosAdminRoleToDosAdminGroup($authUrl, $accessToken, $connectionString, $groupName)
{
    $group = Add-DosAdminGroup -authUrl $authUrl -accessToken $accessToken -groupName $groupName
    $groupId = $group.Id
    Add-DosAdminRoleUsersToDosAdminGroup -groupId $groupId -connectionString $connectionString -clientId $fabricInstallerClientId -roleName $dosAdminRole -securableName $dataMartsSecurable
    Remove-UsersFromDosAdminRole -connectionString $connectionString -clientId $fabricInstallerClientId -roleName $dosAdminRole -securableName $dataMartsSecurable
    Add-DosAdminGroupRolesToDosAdminChildGroups -groupId $groupId -connectionString $connectionString -clientId $fabricInstallerClientId -roleName $dosAdminRole -securableName $dataMartsSecurable
    Remove-GroupsFromDosAdminRole -connectionString $connectionString -clientId $fabricInstallerClientId -roleName $dosAdminRole -securableName $dataMartsSecurable
    if((Test-FabricRegistrationStepAlreadyComplete -authUrl $authUrl -accessToken $accessToken)){
        Remove-DosAdminRole -connectionString $connectionString -clientId $fabricInstallerClientId -roleName $dosAdminRole -securableName $dataMartsSecurable
        $dataMartAdminRoleModel = Get-Role -name $dataMartAdminRole -grain $dosGrain -securableItem $dataMartsSecurable -authorizationServiceUrl $authUrl -accessToken $accessToken
        Add-RoleToGroup -role $dataMartAdminRoleModel -group $group -connString $connectionString -clientId $fabricInstallerClientId
    }
    else{
        Add-DosAdminRoleToDosAdminGroup -groupId $groupId -connectionString $connectionString -clientId $fabricInstallerClientId -roleName $dosAdminRole -securableName $dataMartsSecurable
        Update-DosAdminRoleToDataMartAdmin -connectionString $connectionString -clientId $fabricInstallerClientId -oldRoleName $dosAdminRole -newRoleName $dataMartAdminRole -securableName $dataMartsSecurable
    }
}

if (!(Test-Path .\Fabric-Install-Utilities.psm1)) {
    Invoke-WebRequest -Uri https://raw.githubusercontent.com/HealthCatalyst/InstallScripts/master/common/Fabric-Install-Utilities.psm1 -OutFile Fabric-Install-Utilities.psm1
}
Import-Module -Name .\Fabric-Install-Utilities.psm1 -Force

if (!(Test-IsRunAsAdministrator)) {
    Write-Error "You must run this script as an administrator. Halting configuration."
    throw
}

$installSettings = Get-InstallationSettings "authorization"
$zipPackage = $installSettings.zipPackage
$webroot = $installSettings.webroot
$appName = $installSettings.appName
$iisUser = $installSettings.iisUser
$encryptionCertificateThumbprint = $installSettings.encryptionCertificateThumbprint -replace '[^a-zA-Z0-9]', ''
$appInsightsInstrumentationKey = $installSettings.appInsightsInstrumentationKey
$siteName = $installSettings.siteName
$sqlServerAddress = $installSettings.sqlServerAddress
$identityServiceUrl = $installSettings.identityService
$metadataDbName = $installSettings.metadataDbName
$authorizationDbName = $installSettings.authorizationDbName
$authorizationDatabaseRole = $installSettings.authorizationDatabaseRole
$fabricInstallerSecret = $installSettings.fabricInstallerSecret
$hostUrl = $installSettings.hostUrl
$authorizationServiceUrl = $installSettings.authorizationService
$storedIisUser = $installSettings.iisUser
$adminAccount = $installSettings.adminAccount
$currentUserDomain = $env:userdnsdomain
$workingDirectory = Get-CurrentScriptDirectory
$dosAdminGroupName = "DosAdmins"
$dosAdminGroupDisplayName = "Dos Admins"

if ([string]::IsNullOrEmpty($installSettings.discoveryService)) {
    $discoveryServiceUrl = Get-DiscoveryServiceUrl
}
else {
    $discoveryServiceUrl = $installSettings.discoveryService
}

if ([string]::IsNullOrEmpty($installSettings.identityService)) {
    $identityServiceUrl = Get-IdentityServiceUrl
}
else {
    $identityServiceUrl = $installSettings.identityService
}

if ([string]::IsNullOrEmpty($installSettings.authorizationService)) {
    $authorizationServiceUrl = "$(Get-FullyQualifiedMachineName)/Authorization"
}
else {
    $authorizationServiceUrl = $installSettings.authorizationService
}

Write-Host ""
Write-Host "Checking prerequisites..."
Write-Host ""

if (!(Test-PrerequisiteExact "*.NET Core*Windows Server Hosting*" 1.1.30503.82)) {    
    try {
        Write-Console "Windows Server Hosting Bundle version 1.1.30503.82 not installed...installing version 1.1.30503.82"        
        Invoke-WebRequest -Uri https://go.microsoft.com/fwlink/?linkid=848766 -OutFile $env:Temp\bundle.exe
        Start-Process $env:Temp\bundle.exe -Wait -ArgumentList '/quiet /install'
        net stop was /y
        net start w3svc
        Write-Console "Windows Server Hosting Bundle installed successfully."
    }
    catch {
        Write-Error "Could not install .NET Windows Server Hosting bundle. Please install the hosting bundle before proceeding. https://go.microsoft.com/fwlink/?linkid=844461."
        throw
    }
    try {
        Remove-Item $env:Temp\bundle.exe
    }
    catch {        
        $e = $_.Exception        
        Write-Warning "Unable to remove Server Hosting bundle exe" 
        Write-Warning $e.Message
    }

}
else {
    Write-Success ".NET Core Windows Server Hosting Bundle installed and meets expectations."
    Write-Host ""
}

if (!(Test-Prerequisite "*IIS URL Rewrite Module 2" 7.2.1952)) {
    try{
        Write-Console "IIS URL Rewrite Module 2 not installed...installing latest version."
        Invoke-WebRequest -Uri "http://download.microsoft.com/download/D/D/E/DDE57C26-C62C-4C59-A1BB-31D58B36ADA2/rewrite_amd64_en-US.msi" -OutFile $env:Temp\rewrite_amd64_en-US.msi
        Start-Process msiexec.exe -Wait -ArgumentList "/i $($env:Temp)\rewrite_amd64_en-US.msi /qn"
        Write-Console "IIS URL Rewrite Module 2 installed successfully."
    }catch{
        Write-Error "Could not install IIS URL Rewrite Module 2. Please install the IIS URL Rewrite Module 2 before proceeding: https://www.iis.net/downloads/microsoft/url-rewrite."
        throw
    }
    try {
        Remove-Item $env:Temp\rewrite_amd64_en-US.msi
    }
    catch {        
        $e = $_.Exception        
        Write-Warning "Unable to remove IIS Rewrite msi installer." 
        Write-Warning $e.Message
    }
}

try {
    $sites = Get-ChildItem IIS:\Sites
    if ($sites -is [array]) {
        $sites |
            ForEach-Object {New-Object PSCustomObject -Property @{
                'Id'            = $_.id;
                'Name'          = $_.name;
                'Physical Path' = [System.Environment]::ExpandEnvironmentVariables($_.physicalPath);
                'Bindings'      = $_.bindings;
            }; } |
            Format-Table Id, Name, 'Physical Path', Bindings -AutoSize

        $selectedSiteId = Read-Host "Select a web site by Id"
        Write-Host ""
        $selectedSite = $sites[$selectedSiteId - 1]
    }
    else {
        $selectedSite = $sites
    }

    $webroot = [System.Environment]::ExpandEnvironmentVariables($selectedSite.physicalPath)    
    $siteName = $selectedSite.name

}
catch {
    Write-Error "Could not select a website."
    throw
}

if ([string]::IsNullOrEmpty($encryptionCertificateThumbprint)) {
    try {

        $allCerts = Get-CertsFromLocation Cert:\LocalMachine\My
        $index = 1
        $allCerts |
            ForEach-Object {New-Object PSCustomObject -Property @{
                'Index'      = $index;
                'Subject'    = $_.Subject; 
                'Name'       = $_.FriendlyName; 
                'Thumbprint' = $_.Thumbprint; 
                'Expiration' = $_.NotAfter
            };
            $index ++} |
            Format-Table Index, Name, Subject, Expiration, Thumbprint  -AutoSize

        $selectionNumber = Read-Host  "Select an encryption certificate by Index"
        Write-Host ""
        if ([string]::IsNullOrEmpty($selectionNumber)) {
            Write-Error "You must select a certificate so Fabric.Identity can sign access and identity tokens."
            throw
        }
        $selectionNumberAsInt = [convert]::ToInt32($selectionNumber, 10)
        if (($selectionNumberAsInt -gt $allCerts.Count) -or ($selectionNumberAsInt -le 0)) {
            Write-Error "Please select a certificate with index between 1 and $($allCerts.Count)." 
            throw
        }
        $certThumbprint = Get-CertThumbprint $allCerts $selectionNumberAsInt       
        $encryptionCertificateThumbprint = $certThumbprint -replace '[^a-zA-Z0-9]', ''
    }
    catch {
        $scriptDirectory = Get-CurrentScriptDirectory
        Set-Location $scriptDirectory
        Write-Error "Could not set the certificate thumbprint. Error $($_.Exception.Message)"
        throw
    }

}

try {
    $encryptionCert = Get-Certificate $encryptionCertificateThumbprint
}
catch {
    Write-Host "Could not get encryption certificate with thumbprint $encryptionCertificateThumbprint. Please verify that the encryptionCertificateThumbprint setting in install.config contains a valid thumbprint for a certificate in the Local Machine Personal store. Halting installation."
    throw $_.Exception
}


$userEnteredFabricInstallerSecret = Read-Host  "Enter the Fabric Installer Secret or hit enter to accept the default [$fabricInstallerSecret]"
Write-Host ""
if (![string]::IsNullOrEmpty($userEnteredFabricInstallerSecret)) {   
    $fabricInstallerSecret = $userEnteredFabricInstallerSecret
}

if ((Test-Path $zipPackage)) {
    $path = [System.IO.Path]::GetDirectoryName($zipPackage)
    if (!$path) {
        $zipPackage = [System.IO.Path]::Combine($workingDirectory, $zipPackage)
        Write-Host "zipPackage: $zipPackage"
        Write-Host ""
    }
}
else {
    Write-Host "Could not find file or directory $zipPackage, please verify that the zipPackage configuration setting in install.config is the path to a valid zip file that exists. Halting installation."
    exit 1
}

$userEnteredAuthorizationServiceUrl = Read-Host  "Enter the URL for the Authorization Service or hit enter to accept the default [$authorizationServiceUrl]"
Write-Host ""
if (![string]::IsNullOrEmpty($userEnteredAuthorizationServiceUrl)) {   
    $authorizationServiceUrl = $userEnteredAuthorizationServiceUrl
}

$userEnteredIdentityServiceUrl = Read-Host  "Enter the URL for the Identity Service or hit enter to accept the default [$identityServiceUrl]"
Write-Host ""
if (![string]::IsNullOrEmpty($userEnteredIdentityServiceUrl)) {   
    $identityServiceUrl = $userEnteredIdentityServiceUrl
}

if (!($noDiscoveryService)) {
    $userEnteredDiscoveryServiceUrl = Read-Host "Press Enter to accept the default DiscoveryService URL [$discoveryServiceUrl] or enter a new URL"
    Write-Host ""
    if (![string]::IsNullOrEmpty($userEnteredDiscoveryServiceUrl)) {   
        $discoveryServiceUrl = $userEnteredDiscoveryServiceUrl
    }

}


if (![string]::IsNullOrEmpty($storedIisUser)) {
    $userEnteredIisUser = Read-Host "Press Enter to accept the default IIS App Pool User '$($storedIisUser)' or enter a new App Pool User"
    if ([string]::IsNullOrEmpty($userEnteredIisUser)) {
        $userEnteredIisUser = $storedIisUser
    }
}
else {
    $userEnteredIisUser = Read-Host "Please enter a user account for the App Pool"
}

if (![string]::IsNullOrEmpty($userEnteredIisUser)) {
    
    $iisUser = $userEnteredIisUser
    $useSpecificUser = $true
    $userEnteredPassword = Read-Host "Enter the password for $iisUser" -AsSecureString
    $credential = New-Object -TypeName "System.Management.Automation.PSCredential" -ArgumentList $iisUser, $userEnteredPassword
    [System.Reflection.Assembly]::LoadWithPartialName("System.DirectoryServices.AccountManagement") | Out-Null
    $ct = [System.DirectoryServices.AccountManagement.ContextType]::Domain
    $pc = New-Object System.DirectoryServices.AccountManagement.PrincipalContext -ArgumentList $ct, $credential.GetNetworkCredential().Domain
    $isValid = $pc.ValidateCredentials($credential.GetNetworkCredential().UserName, $credential.GetNetworkCredential().Password)
    if (!$isValid) {
        Write-Error "Incorrect credentials for $iisUser"
        throw
    }
    Write-Success "Credentials are valid for user $iisUser"
    Write-Host ""
}
else {
    Write-Error "No user account was entered, please enter a valid user account."
    throw
}

$userEnteredAppInsightsInstrumentationKey = Read-Host  "Enter Application Insights instrumentation key or hit enter to accept the default [$appInsightsInstrumentationKey]"
Write-Host ""

if (![string]::IsNullOrEmpty($userEnteredAppInsightsInstrumentationKey)) {   
    $appInsightsInstrumentationKey = $userEnteredAppInsightsInstrumentationKey
}

$userEnteredSqlServerAddress = Read-Host "Press Enter to accept the default Sql Server address '$($sqlServerAddress)' or enter a new Sql Server address" 
Write-Host ""

if (![string]::IsNullOrEmpty($userEnteredSqlServerAddress)) {
    $sqlServerAddress = $userEnteredSqlServerAddress
}

$userEnteredAuthorizationDbName = Read-Host "Press Enter to accept the default Authorization DB Name '$($authorizationDbName)' or enter a new Authorization DB Name"
if (![string]::IsNullOrEmpty($userEnteredAuthorizationDbName)) {
    $authorizationDbName = $userEnteredAuthorizationDbName
}

$authorizationDbConnStr = "Server=$($sqlServerAddress);Database=$($authorizationDbName);Trusted_Connection=True;MultipleActiveResultSets=True;"

Invoke-Sql $authorizationDbConnStr "SELECT TOP 1 ClientId FROM Clients" | Out-Null
Write-Success "Identity DB Connection string: $authorizationDbConnStr verified"
Write-Host ""

if (!($noDiscoveryService)) {
    $userEnteredMetadataDbName = Read-Host "Press Enter to accept the default Metadata DB Name '$($metadataDbName)' or enter a new Metadata DB Name"
    if (![string]::IsNullOrEmpty($userEnteredMetadataDbName)) {
        $metadataDbName = $userEnteredMetadataDbName
    }

    $metadataConnStr = "Server=$($sqlServerAddress);Database=$($metadataDbName);Trusted_Connection=True;MultipleActiveResultSets=True;"
    Invoke-Sql $metadataConnStr "SELECT TOP 1 RoleID FROM CatalystAdmin.RoleBASE" | Out-Null
    Write-Success "Metadata DB Connection string: $metadataConnStr verified"
    Write-Host ""
}

$userEnteredDomain = Read-Host "Press Enter to accept the default domain '$($currentUserDomain)' that the user/group who will administrate dos is a member or enter a new domain" 
Write-Host ""

if (![string]::IsNullOrEmpty($userEnteredDomain)) {
    $currentUserDomain = $userEnteredDomain
}

if ([string]::IsNullOrEmpty($adminAccount)) {
    $userEnteredAdminAccount = Read-Host "Please enter the user/group account for dos administration in the format [DOMAIN\user]"
}
else {
    $userEnteredAdminAccount = Read-Host "Press Enter to accept the default admin account '$($adminAccount)' for the user/group who will administrate dos or enter a new account"
}

Write-Host ""

if (![string]::IsNullOrEmpty($userEnteredAdminAccount)) {
    $adminAccount = $userEnteredAdminAccount
}

$samAccountName = Get-SamAccountFromAccountName -accountName $adminAccount
$adminAccountIsUser = $false
if (Test-IsUser -samAccountName $samAccountName -domain $currentUserDomain) {
    $adminAccountIsUser = $true
}
elseif (Test-IsGroup -samAccountName $samAccountName -domain $currentUserDomain) {
    $adminAccountIsUser = $false
}
else {
    Write-Error "$samAccountName is not a valid principal in the $currentUserDomain domain. Please enter a valid account. Halting installation."
    throw
}


Write-Host ""
Write-Host "Prerequisite checks complete...installing."
Write-Host ""

$appDirectory = [System.IO.Path]::Combine($webroot, $appName)
New-AppRoot $appDirectory $iisUser
Write-Host "App directory is: $appDirectory"
New-AppPool $appName $iisUser $credential
New-App $appName $siteName $appDirectory
Publish-WebSite $zipPackage $appDirectory $appName
Add-DatabaseSecurity $iisUser $authorizationDatabaseRole $authorizationDbConnStr

if (!($noDiscoveryService)) {
    Write-Host ""
    Write-Host "Adding Service User to Discovery."
    Write-Host ""
    Add-ServiceUserToDiscovery $credential.UserName $metadataConnStr
    Write-Host ""
    Write-Host "Registering Fabric.Authorization with Discovery Service."
    Write-Host ""
    $discoveryAuthorizationPostBody = @{
        buildVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo("$appDirectory\Fabric.Authorization.API.dll").FileVersion;
        serviceName = "AuthorizationService";
        serviceVersion = 1;
        friendlyName = "Fabric.Authorization";
        description = "The Fabric.Authorization service provides centralized authentication across the Fabric ecosystem.";
        serviceUrl = "$authorizationServiceUrl/v1";
    }
    Add-DiscoveryRegistration $discoveryServiceUrl $credential $discoveryAuthorizationPostBody
    Write-Host ""

    Write-Host "Registering Fabric.AccessControl with Discovery Service."
    Write-Host ""
    $discoveryAccessControlPostBody = @{
        buildVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo("$appDirectory\Fabric.Authorization.API.dll").FileVersion;
        serviceName = "AccessControl";
        serviceVersion = 1;
        friendlyName = "Fabric.AccessControl";
        description = "Fabric.AccessControl provides a UI to manage permissions across DOS.";
        serviceUrl = "$authorizationServiceUrl";
        discoveryType = "Application";
        isHidden = $false;
    }
    Add-DiscoveryRegistration $discoveryServiceUrl $credential $discoveryAccessControlPostBody
    Write-Host ""
}

Set-Location $workingDirectory

Write-Host ""
Write-Host "Getting access token for installer, at URL: $identityServiceUrl"
$accessToken = Get-AccessToken $identityServiceUrl $fabricInstallerClientId "fabric/identity.manageresources" $fabricInstallerSecret

#Register authorization api
$body = @'
{
    "name":"authorization-api",
    "userClaims":["name","email","role","groups"],
    "scopes":[{"name":"fabric/authorization.read"}, {"name":"fabric/authorization.write"}, {"name":"fabric/authorization.dos.write"}, {"name":"fabric/authorization.manageclients"}]
}
'@

Write-Host "Registering Fabric.Authorization API."
$authorizationApiSecret = ([string](Add-ApiRegistration -authUrl $identityServiceUrl -body $body -accessToken $accessToken)).Trim()

if (![string]::IsNullOrWhiteSpace($authorizationApiSecret) -and ![string]::IsNullOrEmpty($authorizationApiSecret)) {
    Write-Success "Fabric.Authorization apiSecret: $authorizationApiSecret"
    Write-Host ""
}

#Register Fabric.Authorization client
$body = @'
{
    "clientId":"fabric-authorization-client", 
    "clientName":"Fabric Authorization Client", 
    "requireConsent":"false", 
    "allowedGrantTypes": ["client_credentials"], 
    "allowedScopes": ["fabric/identity.read", "fabric/identity.searchusers"]
}
'@

Write-Host "Registering Fabric.Authorization Client."
$authorizationClientSecret = ([string](Add-ClientRegistration -authUrl $identityServiceUrl -body $body -accessToken $accessToken)).Trim()

if (![string]::IsNullOrWhiteSpace($authorizationClientSecret) -and ![string]::IsNullOrEmpty($authorizationClientSecret)) {
    Write-Success "Fabric.Authorization clientSecret: $authorizationClientSecret"
    Write-Host ""
}

#Write environment variables
Write-Host "Loading up environment variables..."
$environmentVariables = @{"StorageProvider" = "sqlserver"}

if ($clientName) {
    $environmentVariables.Add("ClientName", $clientName)
}

if ($encryptionCertificateThumbprint) {
    $environmentVariables.Add("EncryptionCertificateSettings__EncryptionCertificateThumbprint", $encryptionCertificateThumbprint)
}

if ($appInsightsInstrumentationKey) {
    $environmentVariables.Add("ApplicationInsights__Enabled", "true")
    $environmentVariables.Add("ApplicationInsights__InstrumentationKey", $appInsightsInstrumentationKey)
}

if ($authorizationClientSecret) {
    $encryptedSecret = Get-EncryptedString $encryptionCert $authorizationClientSecret
    $environmentVariables.Add("IdentityServerConfidentialClientSettings__ClientSecret", $encryptedSecret)
}

$environmentVariables.Add("IdentityServerConfidentialClientSettings__Authority", $identityServiceUrl)

if ($authorizationDbConnStr) {
    $environmentVariables.Add("ConnectionStrings__AuthorizationDatabase", $authorizationDbConnStr)
}

if ($adminAccount) {
    $environmentVariables.Add("AdminAccount__Name", $adminAccount)
}

if ($adminAccountIsUser) {
    $environmentVariables.Add("AdminAccount__Type", "user")
}
else {
    $environmentVariables.Add("AdminAccount__Type", "group")}

if ($authorizationApiSecret) {
    $encryptedSecret = Get-EncryptedString $encryptionCert $authorizationApiSecret
    $environmentVariables.Add("IdentityServerApiSettings__ApiSecret", $encryptedSecret)
}

if ($authorizationServiceUrl) {
    $environmentVariables.Add("ApplicationEndpoint", $authorizationServiceUrl)
}

if ($discoveryServiceUrl) {
	$environmentVariables.Add("AccessControlSettings__DiscoveryServiceSettings__Value", $discoveryServiceUrl)
}

Set-EnvironmentVariables $appDirectory $environmentVariables | Out-Null
Write-Host ""

$accessToken = Get-AccessToken $identityServiceUrl $fabricInstallerClientId "fabric/identity.manageresources fabric/authorization.read fabric/authorization.write fabric/authorization.dos.write fabric/authorization.manageclients" $fabricInstallerSecret
Write-Host "Registering Fabric.Installer Client with Fabric.Authorization."
Add-AuthorizationRegistration -clientId $fabricInstallerClientId -clientName "Fabric Installer" -authorizationServiceUrl "$authorizationServiceUrl/v1" -accessToken $accessToken | Out-Null
Move-DosAdminRoleToDosAdminGroup -authUrl "$authorizationServiceUrl/v1" -accessToken $accessToken -connectionString $authorizationDbConnStr -groupName $dosAdminGroupName

Write-Host "Setting up Default Dos Admin account."
Add-AccountToDosAdminGroup -accountName $adminAccount -domain $currentUserDomain -authorizationServiceUrl "$authorizationServiceUrl/v1" -accessToken $accessToken -connString $authorizationDbConnStr

Set-Location $workingDirectory

if ($fabricInstallerSecret) { Add-SecureInstallationSetting "common" "fabricInstallerSecret" $fabricInstallerSecret $encryptionCert | Out-Null}
if ($encryptionCertificateThumbprint) { Add-InstallationSetting "common" "encryptionCertificateThumbprint" $encryptionCertificateThumbprint | Out-Null}
if ($encryptionCertificateThumbprint) { Add-InstallationSetting "authorization" "encryptionCertificateThumbprint" $encryptionCertificateThumbprint | Out-Null}
if ($appInsightsInstrumentationKey) { Add-InstallationSetting "authorization" "appInsightsInstrumentationKey" "$appInsightsInstrumentationKey" | Out-Null}
if ($appInsightsInstrumentationKey) { Add-InstallationSetting "common" "appInsightsInstrumentationKey" "$appInsightsInstrumentationKey" | Out-Null}
if ($sqlServerAddress) { Add-InstallationSetting "common" "sqlServerAddress" "$sqlServerAddress" | Out-Null}
if ($metadataDbName) { Add-InstallationSetting "common" "metadataDbName" "$metadataDbName" | Out-Null}
if ($identityServiceUrl) { Add-InstallationSetting "common" "identityService" "$identityServiceUrl" | Out-Null}
if ($discoveryServiceUrl) { Add-InstallationSetting "common" "discoveryService" "$discoveryServiceUrl" | Out-Null}
if ($authorizationServiceUrl) { Add-InstallationSetting "authorization" "authorizationService" "$authorizationServiceUrl" | Out-Null}
if ($authorizationServiceUrl) { Add-InstallationSetting "common" "authorizationService" "$authorizationServiceUrl" | Out-Null}
if ($iisUser) { Add-InstallationSetting "authorization" "iisUser" "$iisUser" | Out-Null}
if ($siteName) {Add-InstallationSetting "authorization" "siteName" "$siteName" | Out-Null}
if ($adminAccount) {Add-InstallationSetting "authorization" "adminAccount" "$adminAccount" | Out-Null}

Invoke-MonitorShallow "$authorizationServiceUrl"

Write-Host "Upgrading all the users with an 'EDW Admin' role to also be a member of the Dos Admin Fabric.Auth custom group."
# There are no groups that will have 'EDW Admin'.  Should be only users.
# For more information check out PBI 143708
$edwAdminUsers = Get-EdwAdminUsersAndGroups -connectionString $metadataConnStr	
Write-Host "There are $($edwAdminUsers.Count) users with this role"	
Write-Host ""	
Add-ListOfUsersToDosAdminGroup -edwAdminUsers $edwAdminUsers -connString $authorizationDbConnStr -authorizationServiceUrl "$authorizationServiceUrl/v1" -accessToken $accessToken


$corsOrigin = Get-FullyQualifiedMachineName

#Register Fabric.Authorization.AccessControl client
$accessControlClient = @{
		clientId = "fabric-access-control"
		clientName = "Fabric Authorization Access Control Client"
		requireConsent = "false"
		allowedScopes = "openid", "profile", "fabric.profile", "fabric/authorization.read", "fabric/authorization.write", "fabric/idprovider.searchusers", "fabric/authorization.dos.write"
		allowOfflineAccess = $false
		allowAccessTokensViaBrowser = $true
		enableLocalLogin = $false
		accessTokenLifetime = 1200
    }

$accessControlClient.allowedGrantTypes = @("implicit")
$accessControlClient.redirectUris = "$authorizationServiceUrl/client/oidc-callback.html", "$authorizationServiceUrl/client/silent.html"
$accessControlClient.allowedCorsOrigins = @("$corsOrigin")
$accessControlClient.postLogoutRedirectUris = @("$authorizationServiceUrl/client/logged-out")

$body = $accessControlClient | ConvertTo-Json

Write-Host "Registering Fabric.Authorization.AccessControl Client with Fabric.Identity."
Add-ClientRegistration -authUrl $identityServiceUrl -body $body -accessToken $accessToken
Write-Host "Registering Fabric.Authorization.AccessControl Client with Fabric.Authorization."
Add-AuthorizationRegistration -clientId "fabric-access-control" -clientName "Fabric.AccessControl" -authorizationServiceUrl "$authorizationServiceUrl/v1" -accessToken $accessToken | Out-Null

Read-Host -Prompt "Installation complete, press Enter to exit"
