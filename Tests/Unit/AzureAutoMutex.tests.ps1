$CurrentPath = $PSScriptRoot
$ModuleName = 'AzureAutoMutex'

$RootPath = Split-Path -Path (Split-Path -Path $CurrentPath -Parent) -Parent
$ModulePath = Join-Path -Path $RootPath -ChildPath "$($ModuleName).psd1"

Import-Module $ModulePath -Force

Describe "Function Tests" {
    $InstanceID = [guid]::NewGuid().guid
    Context "Lock a Resource" {
        It "Resource Locks Sucessfully" {
            Lock-AzureAutomationAccount -InstanceID $InstanceID
        }
    }
}


Describe "Class Tests" {
    Context "Class Tests" {
        It "Instance of the class can be created" {
            $mutex = & (Get-Module $ModuleName).NewBoundScriptBlock({[AzureAutoMutex]::new("RGName", "AutoAccName")})
        }
        
    }
}
