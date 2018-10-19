##################################################
#                                                #
#                 Public  Functions              #
#                                                #
##################################################

Function Lock-AzureAutomationAccount
{
    [CmdletBinding()]
    [OutputType([void])]
    Param
    (
        [Parameter(Mandatory = $true)]
        [String]
        $ResourceGroupName,
        [Parameter(Mandatory = $true)]
        [String]
        $AutomationAccountName,
        [Parameter(Mandatory = $true)]
        [String]
        $InstanceID,
        [Parameter()]
        [String]
        $LockName="Mutex",
        #This is how long before cleanup will automatically release the lock
        #Unable to create schedules of under 6 minutes (Azure limitation)
        [Parameter()]
        [ValidateRange(360, [int]::MaxValue)]
        [int]
        $MutexTimeout=600,
        #This is how long the script will wait before failing to aquire a lock
        [Parameter()]
        [int]
        $ScriptTimeout=600,
        [Parameter()]
        [Switch]
        $CleanUp
    )

    $StartTime = [datetime]::Now

    do
    {
        Wait-AutomationLock -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -LockName $LockName -Timeout ($ScriptTimeout - ([datetime]::UtcNow - $StartTime).TotalSeconds)
        $LockStatus = New-AutomationLock -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -InstanceID $InstanceID -LockName $LockName
    }
    while ($LockStatus -ne $true -and ([datetime]::UtcNow - $StartTime).TotalSeconds -lt $ScriptTimeout)

    if ($CleanUp)
    {
        #WARNING: highly alpha code, do not trust
        Register-AzureAutomationMutexCleanUpRunbook -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -InstanceID $InstanceID -LockName $LockName -Timeout $MutexTimeout
    }

    if ( -NOT $LockStatus)
    {
        #Timeout must have occured
        Throw "Unable to get lock $LockName for instance $InstanceID"
    }
}

Function Unlock-AzureAutomationAccount
{
    [CmdletBinding()]
    [OutputType([void])]
    Param
    (
        [Parameter(Mandatory = $true)]
        [String]
        $ResourceGroupName,
        [Parameter(Mandatory = $true)]
        [String]
        $AutomationAccountName,
        [Parameter(Mandatory = $true)]
        [String]
        $InstanceID,
        [Parameter()]
        [String]
        $LockName="Mutex",
        [Parameter()]
        [Switch]
        $CleanUp
    )

    Write-Verbose -Message "Unlocking instance $InstanceID"

    Remove-AutomationLock -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -InstanceID $InstanceID -LockName $LockName

    if ($CleanUp)
    {
        Unregister-AzureAutomationMutexCleanUpRunbook -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -InstanceID $InstanceID -LockName $LockName
    }
}

Function Register-AzureAutomationMutexCleanUpRunbook
{
    [CmdletBinding()]
    [OutputType([void])]
    Param
    (
        [Parameter(Mandatory = $true)]
        [String]
        $InstanceID,
        [Parameter(Mandatory = $true)]
        [String]
        $ResourceGroupName,
        [Parameter(Mandatory = $true)]
        [String]
        $AutomationAccountName,
        [Parameter(Mandatory = $true)]
        [String]
        $LockName,
        [Parameter()]
        [int]
        $Timeout=600
    )

    $RunbookName = "Timeout-$InstanceID-$LockName"
    $StartTime = Get-Date
    $StartTime = $StartTime.AddSeconds($Timeout+10) #add 10 seconds to allow for minimum time requirement in azure when specifying the minimum time
    $TimeZone = ([System.TimeZoneInfo]::Local).Id

    $TmpFile = New-TemporaryFile
    $ScriptContent = @"
    `$connectionName = "AzureRunAsConnection"
    try
    {
        # Get the connection "AzureRunAsConnection "
        `$servicePrincipalConnection=Get-AutomationConnection -Name `$connectionName         

        "Logging in to Azure..."
        Add-AzureRmAccount ``
            -ServicePrincipal ``
            -TenantId `$servicePrincipalConnection.TenantId ``
            -ApplicationId `$servicePrincipalConnection.ApplicationId ``
            -CertificateThumbprint `$servicePrincipalConnection.CertificateThumbprint
    }
    catch
    {
        if (!`$servicePrincipalConnection)
        {
            `$ErrorMessage = "Connection `$connectionName not found."
            throw `$ErrorMessage
        } 
        else
        {
            Write-Error -Message `$_.Exception
            throw `$_.Exception
        }
    }
    `$CurrentValue = Get-AzureRmAutomationVariable -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $LockName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
    if (`$CurrentValue.Value -eq '$InstanceID')
    {
        Write-Output "Removing lock $LockName"
        Remove-AzureRmAutomationVariable -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $LockName
    }
    elseif (`$null -eq `$CurrentValue.Value)
    {
        Write-Output "Lock doesn't currently exist"
    }
    else
    {
        Write-Output "Lock is currently owned by instance `$(`$CurrentValue.Value)"
    }

    Remove-AzureRmAutomationRunbook -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $RunbookName -Force
"@
    Out-File -InputObject $ScriptContent -FilePath $TmpFile.FullName
    New-AzureRmAutomationRunbook -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $RunbookName -Type PowerShell -Description "Cleans up mutexes after a specific amount of time"
    #Import command can only accept .ps1 files
    $tmpFile = Rename-Item -Path $TmpFile.FullName -NewName "$($TmpFile.BaseName).ps1" -PassThru
    Import-AzureRmAutomationRunbook -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $RunbookName -Path $TmpFile.FullName -Force -Published -Type PowerShell
    New-AzureRmAutomationSchedule -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -OneTime -StartTime $StartTime -TimeZone $TimeZone -Name $RunbookName
    Register-AzureRmAutomationScheduledRunbook -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -RunbookName $RunbookName -ScheduleName $RunbookName
}

Function Unregister-AzureAutomationMutexCleanUpRunbook
{
    [CmdletBinding()]
    [OutputType([void])]
    Param
    (
        [Parameter(Mandatory = $true)]
        [String]
        $InstanceID,
        [Parameter(Mandatory = $true)]
        [String]
        $ResourceGroupName,
        [Parameter(Mandatory = $true)]
        [String]
        $AutomationAccountName,
        [Parameter(Mandatory = $true)]
        [String]
        $LockName
    )

    $RunbookName = "Timeout-$InstanceID-$LockName"

    Remove-AzureRmAutomationRunbook -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $RunbookName -Force
}

##################################################
#                                                #
#                 Private Functions              #
#                                                #
##################################################

Function New-AutomationLock
{
    [CmdletBinding()]
    [OutputType([bool])]
    Param
    (
        [Parameter(Mandatory = $true)]
        [String]
        $ResourceGroupName,
        [Parameter(Mandatory = $true)]
        [String]
        $AutomationAccountName,
        [Parameter(Mandatory = $true)]
        [String]
        $InstanceID,
        [Parameter(Mandatory = $true)]
        [String]
        $LockName
    )

    Write-Verbose "Attempting to create a new Lock"
    try
    {
    New-AzureRmAutomationVariable `
        -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $AutomationAccountName `
        -Name $LockName `
        -Value $InstanceID `
        -Encrypted $false `
        -ErrorAction Stop | Out-Null
    }
    catch
    {
        #Error creating the lock, assume another runbook got there first
        return $false
    }
    Start-Sleep -Seconds 5 #give Azure a chance to update
    $CurrentValue = Get-CurrentLockValue -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -LockName $LockName

    if ($CurrentValue -eq $InstanceID)
    {
        Write-Verbose "New Lock confirmed"
        return $true
    }
    else
    {
        Write-Verbose "Instance $CurrentValue currently owns the Lock $LockName"
        #Someone else got to the mutex before this script
        return $false
    }
}

Function Wait-AutomationLock
{
    [CmdletBinding()]
    [OutputType([void])]
    Param
    (
        [Parameter(Mandatory = $true)]
        [String]
        $ResourceGroupName,
        [Parameter(Mandatory = $true)]
        [String]
        $AutomationAccountName,
        [Parameter(Mandatory = $true)]
        [Int]
        $Timeout,
        [Parameter(Mandatory = $true)]
        [String]
        $LockName
    )

    $StartTime = [datetime]::Now
    #Wait for the return value to be null as that means that the variable does not exist in Azure anymore
    do
    {
        Write-Verbose -Message "Waiting for Lock $LockName to release"
        $CurrentValue = Get-AzureRmAutomationVariable -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $LockName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        Start-Sleep -Seconds 1
    }
    while (([datetime]::Now - $StartTime).TotalSeconds -lt $Timeout -and $null -ne $CurrentValue)

    if ($null -ne $CurrentValue)
    {
        #timeout must have happened
        Throw "Unable to get lock $LockName"
    }

    Write-Verbose -Message "Lock $LockName released"
    
    return
}

Function Get-CurrentLockValue
{
    Param
    (
        [Parameter(Mandatory = $true)]
        [String]
        $ResourceGroupName,
        [Parameter(Mandatory = $true)]
        [String]
        $AutomationAccountName,
        [Parameter(Mandatory = $true)]
        [String]
        $LockName
    )

    $CurrentValue = Get-AzureRmAutomationVariable -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $LockName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue

    return $CurrentValue.Value
}

Function Remove-AutomationLock
{
    Param
    (
        [Parameter(Mandatory = $true)]
        [String]
        $ResourceGroupName,
        [Parameter(Mandatory = $true)]
        [String]
        $AutomationAccountName,
        [Parameter(Mandatory = $true)]
        [String]
        $InstanceID,
        [Parameter(Mandatory = $true)]
        [String]
        $LockName,
        [Parameter()]
        [Switch]
        $Force
    )

    $CurrentValue = Get-CurrentLockValue -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -LockName $LockName

    if ($CurrentValue -eq $InstanceID)
    {
        Remove-AzureRmAutomationVariable -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $LockName
    }
    else 
    {
        if (-Not $Force)
        {
            throw "Lock not currently owned by this instance"    
        }
        else
        {
            Write-Verbose -Message "Lock not currently owned by this instance"
        }
    }

    return
}

##################################################
#                                                #
#                       Class                    #
#                                                #
##################################################

Write-Verbose -Message "Loading Class"

class AzureAutoMutex {
    [string]
    $InstanceID

    [String]
    $ResourceGroup

    [String]
    $AutomationAccount

    [String]
    $MutexName

    [Bool]
    $CleanUp

    AzureAutoMutex([String]$ResourceGroupName, [String]$AutomationAccountName)
    {
        $this.InstanceID = [guid]::NewGuid().guid
        $this.ResourceGroup = $ResourceGroupName
        $this.AutomationAccount = $AutomationAccountName
        Write-Verbose "Checking that the Automation Account exists"
        #Check that the automation account exists and that the user has previously logged in to Azure
        Get-AzureRmAutomationAccount -ResourceGroupName $ResourceGroupName -Name $AutomationAccountName -ErrorAction Stop

        Write-Verbose "Automation Account found successfully"
    }

    [void]Lock()
    {
        Lock-AzureAutomationAccount -InstanceID $this.InstanceID -ResourceGroupName $this.ResourceGroup -AutomationAccountName $this.AutomationAccount
    }

    [void]Lock([String]$LockName)
    {
        Lock-AzureAutomationAccount -InstanceID $this.InstanceID -LockName $LockName -ResourceGroupName $this.ResourceGroup -AutomationAccountName $this.AutomationAccount
    }

    [void]Lock([int]$Timeout)
    {
        Lock-AzureAutomationAccount -InstanceID $this.InstanceID -ResourceGroupName $this.ResourceGroup -AutomationAccountName $this.AutomationAccount -Timeout $Timeout
    }

    [void]Lock([String]$LockName, [int]$Timeout)
    {
        Lock-AzureAutomationAccount -InstanceID $this.InstanceID -LockName $LockName -ResourceGroupName $this.ResourceGroup -AutomationAccountName $this.AutomationAccount -Timeout $Timeout
    }

    [void]LockWithCleanUp()
    {
        Lock-AzureAutomationAccount -InstanceID $this.InstanceID -ResourceGroupName $this.ResourceGroup -AutomationAccountName $this.AutomationAccount -CleanUp
        $this.CleanUp = $true
    }

    [void]LockWithCleanUpPSUGSpecial()
    {
        Lock-AzureAutomationAccount -InstanceID $this.InstanceID -ResourceGroupName $this.ResourceGroup -AutomationAccountName $this.AutomationAccount -CleanUp -MutexTimeout 360
        $this.CleanUp = $true
    }

    [void]LockWithCleanUp([String]$LockName)
    {
        Lock-AzureAutomationAccount -InstanceID $this.InstanceID -LockName $LockName -ResourceGroupName $this.ResourceGroup -AutomationAccountName $this.AutomationAccount -CleanUp
    }

    [void]LockWithCleanUp([int]$Timeout)
    {
        Lock-AzureAutomationAccount -InstanceID $this.InstanceID -ResourceGroupName $this.ResourceGroup -AutomationAccountName $this.AutomationAccount -Timeout $Timeout -CleanUp
    }

    [void]LockWithCleanUp([String]$LockName, [int]$Timeout)
    {
        Lock-AzureAutomationAccount -InstanceID $this.InstanceID -LockName $LockName -ResourceGroupName $this.ResourceGroup -AutomationAccountName $this.AutomationAccount -Timeout $Timeout -CleanUp
    }

    [void]Unlock()
    {
        Unlock-AzureAutomationAccount -InstanceID $this.InstanceID -ResourceGroupName $this.ResourceGroup -AutomationAccountName $this.AutomationAccount -CleanUp $this.CleanUp
    }

    [void]Unlock([String]$LockName)
    {
        Unlock-AzureAutomationAccount -InstanceID $this.InstanceID -LockName $LockName -ResourceGroupName $this.ResourceGroup -AutomationAccountName $this.AutomationAccount -CleanUp $this.CleanUp
    }
}