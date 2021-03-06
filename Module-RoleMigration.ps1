#################################################
## vCenter VIRole Copy Module

#region App Functions
###################################################################
## Get-VIRoleComparison
## Gathers and compares the Roles of a Source and Target vCenter
## Outputs a custom object summarizing the data
###################################################################
Function Get-VIRoleComparison {
	[cmdletbinding()]
	param(
		[parameter(Mandatory=$true)]$SourceVC,
		[parameter(Mandatory=$true)]$TargetVC
	)

	$AllRoleData = @()

	$SourceRoles = Get-VIRole -Server $SourceVC | Where-Object IsSystem -eq $false | Sort-Object Name -Descending
	if (!$SourceRoles) {
		Write-Warning "No User-Defined Source VIRoles found on `'$SourceVC`'"
		return $null
	}

	$TargetRoles =  Get-VIRole -Server $TargetVC | Where-Object IsSystem -eq $false | Sort-Object Name -Descending
	
	## Gather the Role Data into an array
	ForEach ($SourceRole in $SourceRoles) {
		$RoleItem = '' | Select-Object SourceRole,SourceRolePrivs,TargetRole,TargetRoleExists,TargetRolePrivs,TargetRoleIdentical,SourcePrivCount,TargetPrivCount
		$RoleItem.SourceRole = $SourceRole
		$RoleItem.SourceRolePrivs = Get-VIPrivilege -Role $SourceRole | Sort-Object ID
		$RoleItem.SourcePrivCount = ($RoleItem.SourceRolePrivs).count
		$TargetRole = $TargetRoles | Where-Object Name -EQ $SourceRole.Name

		## Get Dest Role Info (if exists)
		if ($TargetRole) {
			$RoleItem.TargetRole = $TargetRole
			$RoleItem.TargetRoleExists = $true
			$RoleItem.TargetRolePrivs = Get-VIPrivilege -Role $TargetRole | Sort-Object ID
			$RoleItem.TargetPrivCount = ($RoleItem.TargetRolePrivs).count
			
			## Check if SOURCE and TARGET RolePrivs are identical
			if (Compare-Object $RoleItem.SourceRolePrivs $RoleItem.TargetRolePrivs) {
				$RoleItem.TargetRoleIdentical = $false
			} else {
				$RoleItem.TargetRoleIdentical = $true
			}
		} else {
			$RoleItem.TargetRole = $null
			$RoleItem.TargetRoleExists = $false
			$RoleItem.TargetRolePrivs = $null
			$RoleItem.TargetRoleIdentical = $false
			$RoleItem.TargetPrivCount = 0
		}
		
		## Append to the Array
		$AllRoleData += $RoleItem
	}
	return $AllRoleData | Sort-Object TargetRoleExists,TargetRoleIdentical
}

#endregion

Do {
	# Get SOURCE User-Defined vCenter VIRoles
	$VIRoleComparisonData = @(Get-VIRoleComparison -SourceVC $SourceVC -TargetVC $TargetVC | Where-Object TargetRoleIdentical -EQ $False)
	if (!$VIRoleComparisonData) {
		Write-Warning "No VIRoles differences between `'$SourceVC`' and `'$TargetVC`'. Exiting."
		Start-Sleep 3
		return $null
	}

	Write-Host "****************************************************************************" -ForegroundColor Cyan
	Write-Host " VIRole Differences [SourceVC: $SourceVC]: [TargetVC: $TargetVC]" -ForegroundColor Cyan
	Write-Host "****************************************************************************" -ForegroundColor Cyan
	$VIRoleComparisonData | Format-Table SourceRole,TargetRoleExists,TargetRoleIdentical,SourcePrivCount,TargetPrivCount -AutoSize | Out-Default
	$VIRoleComparisonData += '' | Select-Object SourceRole
	$VIRoleComparisonData[-1].SourceRole = 'Exit'
	
	# Select the Role to copy from SOURCE to DESTINATION
	$RoleInfo2Copy = Get-Selection -SelectionTitle "Select the SOURCE VIRole you would like to copy from `'$SourceVC`' to `'$TargetVC`'" -SelectionList $VIRoleComparisonData -SelectionProperty SourceRole
	
	$SourceRole = $RoleInfo2Copy.SourceRole
	if ($SourceRole -eq 'Exit') {
		return $null
	}
	
	$TargetRole = $RoleInfo2Copy.TargetRole

	# Check if TARGET already exists
	if ($TargetRole) {
		Write-Host "-> VIRole `'$SourceRole`' already exists on `'$TargetVC`' but is different" -ForegroundColor Yellow
		$OverWrite = Get-YesNo -Question "Would you like to Overwrite the TARGET VIRole with the SOURCE VIRole?"
		if ($OverWrite) {
			$Process = "OVERWRITE"
		} else {
			$ProcessAnother = Get-YesNo -Question "Process another VIRole?"
			continue
		}
	} else {
		Write-Host "-> VIRole not found on `'$TargetVC`'. Proceeding with VIRole Duplication!" -ForegroundColor Green
		$OverWrite = $false
		$Process = "DUPLICATION"
	}

	# Print out SOURCE and TARGET Summary
	Write-Host "******************* SOURCE VIRole INFO [$SourceVC : $SourceRole] *******************" -ForegroundColor Cyan
	$RoleInfo2Copy.SourceRolePrivs | Format-Table Name,ID,Description | Out-Default
	Write-Host "******************* SOURCE VIRole INFO [$SourceVC : $SourceRole] *******************" -ForegroundColor Cyan
	
	if ($OverWrite) {
		Write-Host "******************* TARGET (To Be Overwritted!) VIRole INFO [$TargetVC : $TargetRole] *******************" -ForegroundColor Cyan
		$RoleInfo2Copy.TargetRolePrivs | Format-Table Name,ID,Description | Out-Default
		Write-Host "******************* TARGET (To Be Overwritted!) VIRole INFO [$TargetVC : $TargetRole] *******************" -ForegroundColor Cyan
	
		Write-Host "******************* DIFFERENCES [<= $SourceVC] & [$TargetVC =>] *******************" -ForegroundColor Cyan
		$Differences = Compare-Object $RoleInfo2Copy.SourceRolePrivs $RoleInfo2Copy.TargetRolePrivs
		$Differences | Sort-Object SideIndicator | Out-Default
		Write-Host "******************* DIFFERENCES *******************" -ForegroundColor Cyan
	}

	Write-Host "Source PrivCount: $($RoleInfo2Copy.SourcePrivCount)" -ForegroundColor Green
	Write-Host "Target PrivCount: $($RoleInfo2Copy.TargetPrivCount)" -ForegroundColor Green
	Write-Host "***************************" -ForegroundColor Cyan
	Write-Host "Verify VIRole/Privs above" -ForegroundColor Green

	# Prompt to Proceed
	if (!(Get-YesNo -Question "Proceed with role $Process from `'$SourceVC`' TO `'$TargetVC`'")) {
		Write-Host "** Canceling $Process Operation **" -ForegroundColor Yellow
		$ProcessAnother = Get-YesNo -Question "Process another VIRole?"
		continue
	}

	if ($OverWrite) {
		## Clear Role Privs from TARGET Role
		Write-Host "-> Clearing `'$TargetRole`' Privs on `'$TargetVC`'" -ForegroundColor Green
		Set-VIRole -Role $TargetRole -RemovePrivilege $RoleInfo2Copy.TargetRolePrivs
	} else {
		## Create Target VIRole
		Write-Host "-> Creating `'$SourceRole`' on `'$TargetVC`'" -ForegroundColor Green
		$TargetRole = New-VIRole -Name $SourceRole.Name -Server $TargetVC
		if (!$TargetRole) {
			Write-Warning "Unable to create Target VIRole [$SourceRole]"
			$ProcessAnother = Get-YesNo -Question "Process another VIRole?"
			continue
		}
	}
	
	## Add Privs to VIRole
	Write-Host "-> Adding Privs to `'$TargetRole`' on `'$TargetVC`'" -ForegroundColor Green
	Set-VIRole -Role $TargetRole -AddPrivilege (Get-VIPrivilege -id (($RoleInfo2Copy.SourceRolePrivs).ID) -Server $TargetVC)
	
	## Verify result
	$NewTargetRolePrivs = Get-VIPrivilege -Role $TargetRole | Sort-Object ID
	$NewTargetRolePrivCount = $NewTargetRolePrivs.count
	
	Write-Host "******************* New TARGET VIRole Info [$TargetVC : $TargetRole] *******************" -ForegroundColor Cyan
	$NewTargetRolePrivs | Format-Table Name,ID,Description | Out-Default
	Write-Host "******************* New TARGET VIRole Info [$TargetVC : $TargetRole] *******************" -ForegroundColor Cyan
	Write-Host "Source PrivCount: $($RoleInfo2Copy.SourcePrivCount)" -ForegroundColor Green
	Write-Host "Target PrivCount: $NewTargetRolePrivCount" -ForegroundColor Green

	$ProcessAnother = Get-YesNo -Question "Process another VIRole?"
} while ($ProcessAnother)

