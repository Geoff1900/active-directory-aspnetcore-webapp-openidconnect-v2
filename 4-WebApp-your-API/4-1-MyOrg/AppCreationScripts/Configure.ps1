
[CmdletBinding()]
param(
    [PSCredential] $Credential,
    [Parameter(Mandatory=$False, HelpMessage='Tenant ID (This is a GUID which represents the "Directory ID" of the AzureAD tenant into which you want to create the apps')]
    [string] $tenantId
)

#Requires -Modules Microsoft.Graph.Applications

<#
 This script creates the Azure AD applications needed for this sample and updates the configuration files
 for the visual Studio projects from the data in the Azure AD applications.

 Before running this script you need to install the Graph cmdlets as an administrator. 
 For this:
 1) Run Powershell as an administrator
 2) in the PowerShell window, type: Install-Module Microsoft.Graph.Applications

 There are four ways to run this script. For more information, read the AppCreationScripts.md file in the same folder as this script.
#>

#OBSOLETE after migration to Graph API
# Create a password that can be used as an application key
Function ComputePassword
{
    $aesManaged = New-Object "System.Security.Cryptography.AesManaged"
    $aesManaged.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aesManaged.Padding = [System.Security.Cryptography.PaddingMode]::Zeros
    $aesManaged.BlockSize = 128
    $aesManaged.KeySize = 256
    $aesManaged.GenerateKey()
    return [System.Convert]::ToBase64String($aesManaged.Key)
}

# Create an application key
# See https://www.sabin.io/blog/adding-an-azure-active-directory-application-and-key-using-powershell/
Function CreateAppKey([DateTime] $fromDate, [double] $durationInMonths)
{
    $key = New-Object Microsoft.Graph.PowerShell.Models.MicrosoftGraphPasswordCredential

    $key.StartDateTime = $fromDate
    $key.EndDateTime = $fromDate.AddMonths($durationInMonths)
    $key.KeyId = (New-Guid).ToString()
    $key.DisplayName = "app secret"

    return $key
}

# Adds the requiredAccesses (expressed as a pipe separated string) to the requiredAccess structure
# The exposed permissions are in the $exposedPermissions collection, and the type of permission (Scope | Role) is 
# described in $permissionType
Function AddResourcePermission($requiredAccess, `
                               $exposedPermissions, [string]$requiredAccesses, [string]$permissionType)
{
    foreach($permission in $requiredAccesses.Trim().Split("|"))
    {
        foreach($exposedPermission in $exposedPermissions)
        {
            if ($exposedPermission.Value -eq $permission)
                {
                $resourceAccess = New-Object Microsoft.Graph.PowerShell.Models.MicrosoftGraphResourceAccess
                $resourceAccess.Type = $permissionType # Scope = Delegated permissions | Role = Application permissions
                $resourceAccess.Id = $exposedPermission.Id # Read directory data
                $requiredAccess.ResourceAccess += $resourceAccess
                }
        }
    }
}

#
# Example: GetRequiredPermissions "Microsoft Graph"  "Graph.Read|User.Read"
# See also: http://stackoverflow.com/questions/42164581/how-to-configure-a-new-azure-ad-application-through-powershell
Function GetRequiredPermissions([string] $applicationDisplayName, [string] $requiredDelegatedPermissions, [string]$requiredApplicationPermissions, $servicePrincipal)
{
    # If we are passed the service principal we use it directly, otherwise we find it from the display name (which might not be unique)
    if ($servicePrincipal)
    {
        $sp = $servicePrincipal
    }
    else
    {
        $sp = Get-MgServicePrincipal -Filter "DisplayName eq '$applicationDisplayName'"
    }
    $appid = $sp.AppId
    $requiredAccess = New-Object Microsoft.Graph.PowerShell.Models.MicrosoftGraphRequiredResourceAccess
    $requiredAccess.ResourceAppId = $appid 
    $requiredAccess.ResourceAccess = New-Object System.Collections.Generic.List[Microsoft.Graph.PowerShell.Models.MicrosoftGraphResourceAccess]

    # $sp.Oauth2Permissions | Select Id,AdminConsentDisplayName,Value: To see the list of all the Delegated permissions for the application:
    if ($requiredDelegatedPermissions)
    {
        AddResourcePermission $requiredAccess -exposedPermissions $sp.Oauth2PermissionScopes -requiredAccesses $requiredDelegatedPermissions -permissionType "Scope"
    }
    
    # $sp.AppRoles | Select Id,AdminConsentDisplayName,Value: To see the list of all the Application permissions for the application
    if ($requiredApplicationPermissions)
    {
        AddResourcePermission $requiredAccess -exposedPermissions $sp.AppRoles -requiredAccesses $requiredApplicationPermissions -permissionType "Role"
    }
    return $requiredAccess
}


Function UpdateLine([string] $line, [string] $value)
{
    $index = $line.IndexOf(':')
    $lineEnd = ''

    if($line[$line.Length - 1] -eq ','){   $lineEnd = ',' }
    
    if ($index -ige 0)
    {
        $line = $line.Substring(0, $index+1) + " " + '"' + $value+ '"' + $lineEnd
    }
    return $line
}

Function UpdateTextFile([string] $configFilePath, [System.Collections.HashTable] $dictionary)
{
    $lines = Get-Content $configFilePath
    $index = 0
    while($index -lt $lines.Length)
    {
        $line = $lines[$index]
        foreach($key in $dictionary.Keys)
        {
            if ($line.Contains($key))
            {
                $lines[$index] = UpdateLine $line $dictionary[$key]
            }
        }
        $index++
    }

    Set-Content -Path $configFilePath -Value $lines -Force
}
<#.Description
   This function creates a new Azure AD scope (OAuth2Permission) with default and provided values
#>  
Function CreateScope( [string] $value, [string] $userConsentDisplayName, [string] $userConsentDescription, [string] $adminConsentDisplayName, [string] $adminConsentDescription)
{
    $scope = New-Object Microsoft.Graph.PowerShell.Models.MicrosoftGraphPermissionScope
    $scope.Id = New-Guid
    $scope.Value = $value
    $scope.UserConsentDisplayName = $userConsentDisplayName
    $scope.UserConsentDescription = $userConsentDescription
    $scope.AdminConsentDisplayName = $adminConsentDisplayName
    $scope.AdminConsentDescription = $adminConsentDescription
    $scope.IsEnabled = $true
    $scope.Type = "User"
    return $scope
}

<#.Description
   This function creates a new Azure AD AppRole with default and provided values
#>  
Function CreateAppRole([string] $types, [string] $name, [string] $description)
{
    $appRole = New-Object Microsoft.Graph.PowerShell.Models.MicrosoftGraphAppRole
    $appRole.AllowedMemberTypes = New-Object System.Collections.Generic.List[string]
    $typesArr = $types.Split(',')
    foreach($type in $typesArr)
    {
        $appRole.AllowedMemberTypes.Add($type);
    }
    $appRole.DisplayName = $name
    $appRole.Id = New-Guid
    $appRole.IsEnabled = $true
    $appRole.Description = $description
    $appRole.Value = $name;
    return $appRole
}

# Pre-requisites
if ($null -eq (Get-Module -ListAvailable -Name "Microsoft.Graph.Applications")) {
    Install-Module "Microsoft.Graph.Applications" -Scope CurrentUser 
}

Import-Module Microsoft.Graph.Applications

Set-Content -Value "<html><body><table>" -Path createdApps.html
Add-Content -Value "<thead><tr><th>Application</th><th>AppId</th><th>Url in the Azure portal</th></tr></thead><tbody>" -Path createdApps.html

$ErrorActionPreference = "Stop"

Function ConfigureApplications
{
    <#.Description
       This function creates the Azure AD applications for the sample in the provided Azure AD tenant and updates the
       configuration files in the client and service project  of the visual studio solution (App.Config and Web.Config)
       so that they are consistent with the Applications parameters
    #> 

    # Connect to the Microsoft Graph API, non-interactive is not supported for the moment (Oct 2021)
    Write-Host "Connecting Microsoft Graph"
    Connect-MgGraph -TenantId $TenantId -Scopes "Application.ReadWrite.All"

   # Create the service AAD application
   Write-Host "Creating the AAD application (New_TodoListService-aspnetcore-webapi)"
   
   # create the application 
   $serviceAadApplication = New-MgApplication -DisplayName "New_TodoListService-aspnetcore-webapi" `
                                                       -Web `
                                                       @{ `
                                                           HomePageUrl = "https://localhost:44351"; `

                                                           ImplicitGrantSettings = @{EnableIdTokenIssuance=$true;EnableAccessTokenIssuance=$false} `
 
                                                         } `
                                                       -SignInAudience AzureADMyOrg `
                                                       #-PublicClient $False
    $serviceIdentifierUri = 'api://'+$serviceAadApplication.AppId
    Update-MgApplication -ApplicationId $serviceAadApplication.Id -IdentifierUris @($serviceIdentifierUri)
    
    # create the service principal of the newly created application 
    $currentAppId = $serviceAadApplication.AppId
    $serviceServicePrincipal = New-MgServicePrincipal -AppId $currentAppId -Tags {WindowsAzureActiveDirectoryIntegratedApp}

    # add the user running the script as an app owner if needed
    $owner = Get-MgApplicationOwner -ApplicationId $serviceAadApplication.Id
    if ($owner -eq $null)
    { 
        New-MgApplicationOwnerByRef -ApplicationId $serviceAadApplication.Id  -BodyParameter = @{"@odata.id" = "htps://graph.microsoft.com/v1.0/directoryObjects/$user.ObjectId"}
        Write-Host "'$($user.UserPrincipalName)' added as an application owner to app '$($serviceServicePrincipal.DisplayName)'"
    }
    
    # rename the user_impersonation scope if it exists to match the readme steps or add a new scope
    $scopes = New-Object System.Collections.Generic.List[Microsoft.Graph.PowerShell.Models.MicrosoftGraphPermissionScope]
   
    # delete default scope i.e. User_impersonation
    $scope = $serviceAadApplication.Api.Oauth2PermissionScopes | Where-Object { $_.Value -eq "User_impersonation" }
    if($scope -ne $null)
    {
        # disable the scope
        $scope.IsEnabled = $false
        Update-MgApplication -ApplicationId $serviceAadApplication.Id -Api @{Oauth2PermissionScopes = $scopes}

        # clear the scope
        $scopes.Clear()
        Update-MgApplication -ApplicationId $serviceAadApplication.Id -Api @{Oauth2PermissionScopes = $scopes}
    }
    if ($scopes.Count -ge 0) 
    {
        $scope = CreateScope -value access_as_user  `
        -userConsentDisplayName "Access New_TodoListService-aspnetcore-webapi"  `
        -userConsentDescription "Allow the application to access New_TodoListService-aspnetcore-webapi on your behalf."  `
        -adminConsentDisplayName "Access New_TodoListService-aspnetcore-webapi"  `
        -adminConsentDescription "Allows the app to have the same access to information in the directory on behalf of the signed-in user."
            
        $scopes.Add($scope)
    
    }
     
    # add/update scopes
    Update-MgApplication -ApplicationId $serviceAadApplication.Id -Api @{Oauth2PermissionScopes = $scopes}
    Write-Host "Done creating the service application (New_TodoListService-aspnetcore-webapi)"

    # URL of the AAD application in the Azure portal
    # Future? $servicePortalUrl = "https://portal.azure.com/#@"+$tenantName+"/blade/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/Overview/appId/"+$serviceAadApplication.AppId+"/objectId/"+$serviceAadApplication.ObjectId+"/isMSAApp/"
    $servicePortalUrl = "https://portal.azure.com/#blade/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/CallAnAPI/appId/"+$serviceAadApplication.AppId+"/objectId/"+$serviceAadApplication.ObjectId+"/isMSAApp/"
    Add-Content -Value "<tr><td>service</td><td>$currentAppId</td><td><a href='$servicePortalUrl'>New_TodoListService-aspnetcore-webapi</a></td></tr>" -Path createdApps.html

   # Create the client AAD application
   Write-Host "Creating the AAD application (New_TodoListClient-aspnetcore-webapi)"
   # Get a 6 months application key for the client Application
   $fromDate = [DateTime]::Now;
   $key = CreateAppKey -fromDate $fromDate -durationInMonths 6
   
   
   # create the application 
   $clientAadApplication = New-MgApplication -DisplayName "New_TodoListClient-aspnetcore-webapi" `
                                                      -Web `
                                                      @{ `
                                                          RedirectUris = "https://localhost:44321/", "https://localhost:44321/signin-oidc"; `
                                                          HomePageUrl = "https://localhost:44321/"; `
                                                          LogoutUrl = "https://localhost:44321/signout-oidc"; `

                                                          ImplicitGrantSettings = @{EnableIdTokenIssuance=$true;EnableAccessTokenIssuance=$false} `
 
                                                        } `
                                                      -SignInAudience AzureADMyOrg `
                                                      #-PublicClient $False
    #add password to the application
    $pwdCredential = Add-MgApplicationPassword -ApplicationId $clientAadApplication.Id -PasswordCredential $key
    $tenantName = (Get-MgApplication -ApplicationId $clientAadApplication.Id).PublisherDomain
    Update-MgApplication -ApplicationId $clientAadApplication.Id -IdentifierUris @("https://$tenantName/New_TodoListClient-aspnetcore-webapi")
    
    # create the service principal of the newly created application 
    $currentAppId = $clientAadApplication.AppId
    $clientServicePrincipal = New-MgServicePrincipal -AppId $currentAppId -Tags {WindowsAzureActiveDirectoryIntegratedApp}

    # add the user running the script as an app owner if needed
    $owner = Get-MgApplicationOwner -ApplicationId $clientAadApplication.Id
    if ($owner -eq $null)
    { 
        New-MgApplicationOwnerByRef -ApplicationId $clientAadApplication.Id  -BodyParameter = @{"@odata.id" = "htps://graph.microsoft.com/v1.0/directoryObjects/$user.ObjectId"}
        Write-Host "'$($user.UserPrincipalName)' added as an application owner to app '$($clientServicePrincipal.DisplayName)'"
    }
    Write-Host "Done creating the client application (New_TodoListClient-aspnetcore-webapi)"

    # URL of the AAD application in the Azure portal
    # Future? $clientPortalUrl = "https://portal.azure.com/#@"+$tenantName+"/blade/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/Overview/appId/"+$clientAadApplication.AppId+"/objectId/"+$clientAadApplication.ObjectId+"/isMSAApp/"
    $clientPortalUrl = "https://portal.azure.com/#blade/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/CallAnAPI/appId/"+$clientAadApplication.AppId+"/objectId/"+$clientAadApplication.ObjectId+"/isMSAApp/"
    Add-Content -Value "<tr><td>client</td><td>$currentAppId</td><td><a href='$clientPortalUrl'>New_TodoListClient-aspnetcore-webapi</a></td></tr>" -Path createdApps.html
    $requiredResourcesAccess = New-Object System.Collections.Generic.List[Microsoft.Graph.PowerShell.Models.MicrosoftGraphRequiredResourceAccess]

    
    # Add Required Resources Access (from 'client' to 'service')
    Write-Host "Getting access from 'client' to 'service'"
    $requiredPermissions = GetRequiredPermissions -applicationDisplayName "New_TodoListService-aspnetcore-webapi" `
        -requiredDelegatedPermissions "access_as_user" `
    

    $requiredResourcesAccess.Add($requiredPermissions)
    Update-MgApplication -ApplicationId $clientAadApplication.Id -RequiredResourceAccess $requiredResourcesAccess
    Write-Host "Granted permissions."
    
    # Update config file for 'service'
    $configFile = $pwd.Path + "\..\TodoListService\appsettings.json"
    Write-Host "Updating the sample code ($configFile)"
   $dictionary = @{ "Domain" = $tenantName;"TenantId" = $tenantId;"ClientId" = $serviceAadApplication.AppId };
   UpdateTextFile -configFilePath $configFile -dictionary $dictionary
    
    # Update config file for 'client'
    $configFile = $pwd.Path + "\..\Client\appsettings.json"
    Write-Host "Updating the sample code ($configFile)"
   $dictionary = @{ "Domain" = $tenantName;"TenantId" = $tenantId;"ClientId" = $clientAadApplication.AppId;"ClientSecret" = $pwdCredential.SecretText;"TodoListScope" = ("api://"+$serviceAadApplication.AppId+"/access_as_user");"TodoListBaseAddress" = $serviceAadApplication.Web.HomePageUrl };
   UpdateTextFile -configFilePath $configFile -dictionary $dictionary
    Write-Host -ForegroundColor Green "------------------------------------------------------------------------------------------------" 
    Write-Host "IMPORTANT: Please follow the instructions below to complete a few manual step(s) in the Azure portal":
    Write-Host "- For service"
    Write-Host "  - Navigate to $servicePortalUrl"
    Write-Host "  - You can run the ..\CreateUsersAndAssignRoles.ps1 command to automatically create a number of users, and assign users to these roles or assign users to this application app roles using the portal.To receive the `roles` claim with the name of the app roles this user is assigned to, make sure that the user accounts you plan to sign-in to this app is assigned to the app roles of this app. The guide, https://docs.microsoft.com/azure/active-directory/manage-apps/assign-user-or-group-access-portal#assign-a-user-to-an-app---portal provides step by step instructions." -ForegroundColor Red 
    Write-Host "- For client"
    Write-Host "  - Navigate to $clientPortalUrl"
    Write-Host "  - You can run the ..\CreateUsersAndAssignRoles.ps1 command to automatically create a number of users, and assign users to these roles or assign users to this application app roles using the portal.To receive the `roles` claim with the name of the app roles this user is assigned to, make sure that the user accounts you plan to sign-in to this app is assigned to the app roles of this app. The guide, https://docs.microsoft.com/azure/active-directory/manage-apps/assign-user-or-group-access-portal#assign-a-user-to-an-app---portal provides step by step instructions." -ForegroundColor Red 
    Write-Host -ForegroundColor Green "------------------------------------------------------------------------------------------------" 
       if($isOpenSSL -eq 'Y')
    {
        Write-Host -ForegroundColor Green "------------------------------------------------------------------------------------------------" 
        Write-Host "You have generated certificate using OpenSSL so follow below steps: "
        Write-Host "Install the certificate on your system from current folder."
        Write-Host -ForegroundColor Green "------------------------------------------------------------------------------------------------" 
    }
    Add-Content -Value "</tbody></table></body></html>" -Path createdApps.html  
}

# Run interactively (will ask you for the tenant ID)
ConfigureApplications -tenantId $TenantId