﻿configuration ConfigureDCVM
{
    param
    (
        [Parameter(Mandatory)] [String]$DomainFQDN,
        [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Admincreds,
        [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$AdfsSvcCreds,
        [Parameter(Mandatory)] [String]$PrivateIP,
        [Parameter(Mandatory)] [Boolean]$ConfigureADFS
    )

    Import-DscResource -ModuleName xActiveDirectory, NetworkingDsc, xPSDesiredStateConfiguration, ActiveDirectoryCSDsc, CertificateDsc, cADFS, xDnsServer, ComputerManagementDsc
    [String] $DomainNetbiosName = (Get-NetBIOSName -DomainFQDN $DomainFQDN)
    [System.Management.Automation.PSCredential] $DomainCredsNetbios = New-Object System.Management.Automation.PSCredential ("${DomainNetbiosName}\$($Admincreds.UserName)", $Admincreds.Password)
    [System.Management.Automation.PSCredential] $AdfsSvcCredsQualified = New-Object System.Management.Automation.PSCredential ("${DomainNetbiosName}\$($AdfsSvcCreds.UserName)", $AdfsSvcCreds.Password)
    $Interface = Get-NetAdapter| Where-Object Name -Like "Ethernet*"| Select-Object -First 1
    $InterfaceAlias = $($Interface.Name)
    $ComputerName = Get-Content env:computername
    [String] $SPTrustedSitesName = "SPSites"
    [String] $ADFSSiteName = "ADFS"

    Node localhost
    {
        LocalConfigurationManager
        {
            ConfigurationMode = 'ApplyOnly'
            RebootNodeIfNeeded = $true
        }

        WindowsFeature ADDS { Name = "AD-Domain-Services"; Ensure = "Present" }
        WindowsFeature DNS  { Name = "DNS"; Ensure = "Present" }

        Script script1
        {
            SetScript =  {
                Set-DnsServerDiagnostics -All $true
                Write-Verbose -Verbose "Enabling DNS client diagnostics" 
            }
            GetScript =  { @{} }
            TestScript = { $false }
            DependsOn = "[WindowsFeature]DNS"
        }

        WindowsFeature DnsTools { Name = "RSAT-DNS-Server"; Ensure = "Present" }

        DnsServerAddress DnsServerAddress 
        {
            Address        = '127.0.0.1' 
            InterfaceAlias = $InterfaceAlias
            AddressFamily  = 'IPv4'
            DependsOn = "[WindowsFeature]DNS"
        }

        xADDomain FirstDS
        {
            DomainName = $DomainFQDN
            DomainAdministratorCredential = $DomainCredsNetbios
            SafemodeAdministratorPassword = $DomainCredsNetbios
            DatabasePath = "C:\NTDS"
            LogPath = "C:\NTDS"
            SysvolPath = "C:\SYSVOL"
            DependsOn = "[DnsServerAddress]DnsServerAddress"
        }

        PendingReboot Reboot1
        {
            Name = "RebootServer"
            DependsOn = "[xADDomain]FirstDS"
        }       

        #**********************************************************
        # Misc: Set email of AD domain admin and add remote AD tools
        #**********************************************************
        xADUser SetEmailOfDomainAdmin
        {
            DomainAdministratorCredential = $DomainCredsNetbios
            DomainName = $DomainFQDN
            UserName = $Admincreds.UserName
            Password = $Admincreds
            EmailAddress = $Admincreds.UserName + "@" + $DomainFQDN
            PasswordAuthentication = 'Negotiate'
            Ensure = "Present"
            PasswordNeverExpires = $true
            DependsOn = "[PendingReboot]Reboot1"
        }

        WindowsFeature AddADFeature1    { Name = "RSAT-ADLDS";          Ensure = "Present"; DependsOn = "[PendingReboot]Reboot1" }
        WindowsFeature AddADFeature2    { Name = "RSAT-ADDS-Tools";     Ensure = "Present"; DependsOn = "[PendingReboot]Reboot1" }

        #**********************************************************
        # Configure AD CS
        #**********************************************************
        WindowsFeature AddCertAuthority       { Name = "ADCS-Cert-Authority"; Ensure = "Present"; DependsOn = "[PendingReboot]Reboot1" }
        WindowsFeature AddADCSManagementTools { Name = "RSAT-ADCS-Mgmt";      Ensure = "Present"; DependsOn = "[PendingReboot]Reboot1" }
        ADCSCertificationAuthority ADCS
        {
            IsSingleInstance = "Yes"
            CAType = "EnterpriseRootCA"
            Ensure = "Present"
            Credential = $DomainCredsNetbios
            DependsOn = "[WindowsFeature]AddCertAuthority"
        }

        if ($ConfigureADFS -eq $true) {
            #**********************************************************
            # Configure AD FS
            #**********************************************************
            WaitForCertificateServices WaitAfterADCSProvisioning
            {
                CAServerFQDN = "$ComputerName.$DomainFQDN"
                CARootName = "$DomainNetbiosName-$ComputerName-CA"
                DependsOn = '[ADCSCertificationAuthority]ADCS'
                PsDscRunAsCredential = $DomainCredsNetbios
            }

            CertReq ADFSSiteCert
            {
                CARootName                = "$DomainNetbiosName-$ComputerName-CA"
                CAServerFQDN              = "$ComputerName.$DomainFQDN"
                Subject                   = "$ADFSSiteName.$DomainFQDN"
                FriendlyName              = "$ADFSSiteName.$DomainFQDN site certificate"
                KeyLength                 = '2048'
                Exportable                = $true
                ProviderName              = '"Microsoft RSA SChannel Cryptographic Provider"'
                OID                       = '1.3.6.1.5.5.7.3.1'
                KeyUsage                  = '0xa0'
                CertificateTemplate       = 'WebServer'
                AutoRenew                 = $true
                SubjectAltName            = "dns=certauth.$ADFSSiteName.$DomainFQDN&dns=$ADFSSiteName.$DomainFQDN"
                Credential                = $DomainCredsNetbios
                DependsOn = '[WaitForCertificateServices]WaitAfterADCSProvisioning'
            }

            CertReq ADFSSigningCert
            {
                CARootName                = "$DomainNetbiosName-$ComputerName-CA"
                CAServerFQDN              = "$ComputerName.$DomainFQDN"
                Subject                   = "$ADFSSiteName.Signing"
                FriendlyName              = "$ADFSSiteName Signing"
                KeyLength                 = '2048'
                Exportable                = $true
                ProviderName              = '"Microsoft RSA SChannel Cryptographic Provider"'
                OID                       = '1.3.6.1.5.5.7.3.1'
                KeyUsage                  = '0xa0'
                CertificateTemplate       = 'WebServer'
                AutoRenew                 = $true
                Credential                = $DomainCredsNetbios
                DependsOn = '[WaitForCertificateServices]WaitAfterADCSProvisioning'
            }

            CertReq ADFSDecryptionCert
            {
                CARootName                = "$DomainNetbiosName-$ComputerName-CA"
                CAServerFQDN              = "$ComputerName.$DomainFQDN"
                Subject                   = "$ADFSSiteName.Decryption"
                FriendlyName              = "$ADFSSiteName Decryption"
                KeyLength                 = '2048'
                Exportable                = $true
                ProviderName              = '"Microsoft RSA SChannel Cryptographic Provider"'
                OID                       = '1.3.6.1.5.5.7.3.1'
                KeyUsage                  = '0xa0'
                CertificateTemplate       = 'WebServer'
                AutoRenew                 = $true
                Credential                = $DomainCredsNetbios
                DependsOn = '[WaitForCertificateServices]WaitAfterADCSProvisioning'
            }

            xADUser CreateAdfsSvcAccount
            {
                DomainAdministratorCredential = $DomainCredsNetbios
                DomainName = $DomainFQDN
                UserName = $AdfsSvcCreds.UserName
                Password = $AdfsSvcCreds
                Ensure = "Present"
                PasswordAuthentication = 'Negotiate'
                PasswordNeverExpires = $true
                DependsOn = "[CertReq]ADFSSiteCert", "[CertReq]ADFSSigningCert", "[CertReq]ADFSDecryptionCert"
            }

            Group AddAdfsSvcAccountToDomainAdminsGroup
            {
                GroupName='Administrators'   
                Ensure= 'Present'             
                MembersToInclude= $AdfsSvcCredsQualified.UserName
                Credential = $DomainCredsNetbios    
                PsDscRunAsCredential = $DomainCredsNetbios
                DependsOn = "[xADUser]CreateAdfsSvcAccount"
            }

            WindowsFeature AddADFS { Name = "ADFS-Federation"; Ensure = "Present"; DependsOn = "[Group]AddAdfsSvcAccountToDomainAdminsGroup" }

            xDnsRecord AddADFSHostDNS {
                Name = $ADFSSiteName
                Zone = $DomainFQDN
                Target = $PrivateIP
                Type = "ARecord"
                Ensure = "Present"
                DependsOn = "[PendingReboot]Reboot1"
            }

            cADFSFarm CreateADFSFarm
            {
                ServiceCredential = $AdfsSvcCredsQualified
                InstallCredential = $DomainCredsNetbios
                #CertificateThumbprint = $siteCert
                DisplayName = "$ADFSSiteName.$DomainFQDN"
                ServiceName = "$ADFSSiteName.$DomainFQDN"
                #SigningCertificateThumbprint = $signingCert
                #DecryptionCertificateThumbprint = $decryptionCert
                CertificateName = "$ADFSSiteName.$DomainFQDN"
                SigningCertificateName = "$ADFSSiteName.Signing"
                DecryptionCertificateName = "$ADFSSiteName.Decryption"
                Ensure= 'Present'
                PsDscRunAsCredential = $DomainCredsNetbios
                DependsOn = "[WindowsFeature]AddADFS"
            }

            cADFSRelyingPartyTrust CreateADFSRelyingParty
            {
                Name = $SPTrustedSitesName
                Identifier = "urn:federation:sharepoint"
                ClaimsProviderName = @("Active Directory")
                WsFederationEndpoint = "https://$SPTrustedSitesName.$DomainFQDN/_trust/"
                AdditionalWSFedEndpoint = @("https://*.$DomainFQDN/")
                IssuanceAuthorizationRules = '=> issue(Type = "http://schemas.microsoft.com/authorization/claims/permit", value = "true");'
                IssuanceTransformRules = @"
@RuleTemplate = "LdapClaims"
@RuleName = "AD"
c:[Type == "http://schemas.microsoft.com/ws/2008/06/identity/claims/windowsaccountname", Issuer == "AD AUTHORITY"]
=> issue(
store = "Active Directory", 
types = ("http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress", "http://schemas.microsoft.com/ws/2008/06/identity/claims/role"), 
query = ";mail,tokenGroups(longDomainQualifiedName);{0}", 
param = c.Value);
"@
                ProtocolProfile = "WsFed-SAML"
                Ensure= 'Present'
                PsDscRunAsCredential = $DomainCredsNetbios
                DependsOn = "[cADFSFarm]CreateADFSFarm"
            }

            xScript ExportCertificates
            {
                SetScript = 
                {
                    Write-Verbose -Message "Exporting the public key of the ADFS signing certifiacte and its issuer..."
                    $ADFSSiteName = $using:ADFSSiteName
                    $destinationPath = "C:\Setup"
                    $adfsSigningCertFileName = "ADFS Signing.cer"
                    $adfsSigningIssuerCertFileName = "ADFS Signing issuer.cer"
                    New-Item $destinationPath -Type directory -ErrorAction SilentlyContinue

                    $signingCert = Get-ChildItem -Path "cert:\LocalMachine\My\" -DnsName "$ADFSSiteName.Signing"
                    $signingCert| Export-Certificate -FilePath ([System.IO.Path]::Combine($destinationPath, $adfsSigningCertFileName))
                    Get-ChildItem -Path "cert:\LocalMachine\Root\"| Where-Object{$_.Subject -eq  $signingCert.Issuer}| Select-Object -First 1| Export-Certificate -FilePath ([System.IO.Path]::Combine($destinationPath, $adfsSigningIssuerCertFileName))
                    Write-Verbose -Message "Public key of the ADFS signing certifiacte and its issuer successfully exported"
                }
                GetScript =  
                {
                    # This block must return a hashtable. The hashtable must only contain one key Result and the value must be of type String.
                    return @{ "Result" = "false" }
                }
                TestScript = 
                {
                    # If it returns $false, the SetScript block will run. If it returns $true, the SetScript block will not run.
                return $false
                }
                DependsOn = "[CertReq]ADFSSiteCert", "[CertReq]ADFSSigningCert", "[CertReq]ADFSDecryptionCert"
            }
        } else {
            xScript ExportCertificates
            {
                SetScript = 
                {
                    # gpupdate triggers the creation of a certificate "CN=DCName.DomainFQDN" issued by certificate authority
                    gpupdate.exe /force
                    
                    Write-Verbose -Message "Exporting the public key of the certificate authority..."
                    $ComputerName = $using:ComputerName
                    $DomainFQDN = $using:DomainFQDN
                    $destinationPath = "C:\Setup"
                    $rootCAFileName = "ADFS Signing issuer.cer"
                    New-Item $destinationPath -Type directory -ErrorAction SilentlyContinue
                    
                    # Find the root certificate authority by 1st getting certificate "CN=DCName.DomainFQDN", and then its issuer (easiest way I found)
                    $machineCert = Get-ChildItem -Path "cert:\LocalMachine\My\" | Where-Object {$_.Subject -eq "CN=$ComputerName.$DomainFQDN"}
                    Get-ChildItem -Path "cert:\LocalMachine\Root\"| Where-Object{$_.Subject -eq  $machineCert.Issuer}| Select-Object -First 1| Export-Certificate -FilePath ([System.IO.Path]::Combine($destinationPath, $rootCAFileName))
                    Write-Verbose -Message "The public key of the certificate authority successfully exported"
                }
                GetScript =  
                {
                    # This block must return a hashtable. The hashtable must only contain one key Result and the value must be of type String.
                    return @{ "Result" = "false" }
                }
                TestScript = 
                {
                    # If it returns $false, the SetScript block will run. If it returns $true, the SetScript block will not run.
                return $false
                }
                DependsOn = "[ADCSCertificationAuthority]ADCS"
            }
        }
    }
}

function Get-NetBIOSName
{
    [OutputType([string])]
    param(
        [string]$DomainFQDN
    )

    if ($DomainFQDN.Contains('.')) {
        $length=$DomainFQDN.IndexOf('.')
        if ( $length -ge 16) {
            $length=15
        }
        return $DomainFQDN.Substring(0,$length)
    }
    else {
        if ($DomainFQDN.Length -gt 15) {
            return $DomainFQDN.Substring(0,15)
        }
        else {
            return $DomainFQDN
        }
    }
}


<#
# Azure DSC extension logging: C:\WindowsAzure\Logs\Plugins\Microsoft.Powershell.DSC\2.21.0.0
# Azure DSC extension configuration: C:\Packages\Plugins\Microsoft.Powershell.DSC\2.21.0.0\DSCWork

Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
Install-Module -Name xAdcsDeployment
Install-Module -Name xCertificate
Install-Module -Name xPSDesiredStateConfiguration
Install-Module -Name xCredSSP
Install-Module -Name xWebAdministration
Install-Module -Name xDisk
Install-Module -Name xNetworking

help ConfigureDCVM

$Admincreds = Get-Credential -Credential "yvand"
$AdfsSvcCreds = Get-Credential -Credential "adfssvc"
$DomainFQDN = "contoso.local"
$PrivateIP = "10.0.1.4"
$ConfigureADFS = $false

$outputPath = "C:\Packages\Plugins\Microsoft.Powershell.DSC\2.80.0.0\DSCWork\ConfigureDCVM.0\ConfigureDCVM"
ConfigureDCVM -Admincreds $Admincreds -AdfsSvcCreds $AdfsSvcCreds -DomainFQDN $DomainFQDN -PrivateIP $PrivateIP -ConfigureADFS $ConfigureADFS -ConfigurationData @{AllNodes=@(@{ NodeName="localhost"; PSDscAllowPlainTextPassword=$true })} -OutputPath $outputPath
Set-DscLocalConfigurationManager -Path $outputPath
Start-DscConfiguration -Path $outputPath -Wait -Verbose -Force

https://github.com/PowerShell/xActiveDirectory/issues/27
Uninstall-WindowsFeature "ADFS-Federation"
https://msdn.microsoft.com/library/mt238290.aspx
\\.\pipe\MSSQL$MICROSOFT##SSEE\sql\query
#>
