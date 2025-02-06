<#
.SYNOPSIS
Wrapper around AWS session manager for instance access and SSH tunnels
#>

param(
    [Parameter(Position=0)]
    [ValidateSet("ssh","tunnel","document")]
    [string]$action = "ssh",
    
    [string]$aws_region,
    [string]$aws_profile,
    [int]$tunnel_remote_port = 22,
    [int]$tunnel_local_port = 9999,
    [string]$tunnel_remote_host = "localhost",
    [switch]$interactive_mode,
    [string]$tag_value,
    [string]$ssm_name,
    [string]$instance_id,
    [string]$document_name,
    [string]$document_parameters,
    [string]$github_token_location,
    [string]$cloudwatch_group,
    [switch]$long_running,
    [switch]$help,
    [switch]$version
)

$scriptVersion = "1.1.1"
$default_aws_region = "us-east-1"

function Show-Version {
    Write-Output "aws-connect version $scriptVersion"
}

function Show-Usage {
    Write-Output @"
Usage:
aws-connect.ps1 [-a ssh|tunnel|document] [-i <remote host>] [-d <document>] [-c <parameters>] [-g <github token>] 
[-t <tag>|-m <ssm name>] [-r <region>] [-p <profile>] [-o <port>] [-x <instance id>] [-l] [-s] [-h] [-v]

Options:
  -a -action       Action: ssh, tunnel, or document (default: ssh)
  -i -tunnel_remote_host    Remote host for tunnel (default: localhost)
  -d -document_name         SSM document name
  -w -document_parameters   Document parameters
  -g -github_token_location GitHub token location in SSM
  -c -cloudwatch_group      CloudWatch group (default: aws-connect)
  -l -long_running          Long-running command flag
  -t -tag_value             Instance tag (key or key=value)
  -m -ssm_name              SSM instance name
  -r -aws_region            AWS region (default: us-east-1)
  -p -aws_profile           AWS profile
  -f -tunnel_remote_port    Remote tunnel port (default: 22)
  -o -tunnel_local_port     Local tunnel port (default: 9999)
  -x -instance_id           Direct instance ID
  -s -interactive_mode      Interactive instance selection
  -h -help                  Show help
  -v -version               Show version
"@
    exit
}

function Get-ComparableVersion($version) {
    $parts = $version -split '\.'
    $major = [int]($parts[0] ?? 0)
    $minor = [int]($parts[1] ?? 0)
    $patch = [int]($parts[2] ?? 0)
    $build = [int]($parts[3] ?? 0)
    return ($major * 1000000) + ($minor * 1000) + $patch
}

function Get-InstancesByTag($tag, $region, $profile) {
    $tagParts = $tag -split '=',2
    $tagFilter = if ($tagParts.Count -eq 1) {
        @{Name="tag-key"; Values=$tagParts[0]}
    } else {
        @{Name="tag:$($tagParts[0])"; Values=$tagParts[1]}
    }

    $instances = aws ec2 describe-instances `
        --filters $tagFilter "Name=instance-state-name,Values=running" `
        --query "Reservations[*].Instances[*].[InstanceId,Tags[?Key=='Name'].Value | [0]]" `
        --output text `
        --region $region `
        --profile $profile

    return $instances
}

function Get-InstanceBySSMName($name, $region, $profile) {
    $instance = aws ssm describe-instance-information `
        --filters "Key=tag:Name,Values=$name" `
        --query "InstanceInformationList[?PingStatus=='Online'].InstanceId" `
        --output text `
        --region $region `
        --profile $profile

    return $instance.Split()[0]
}

# Handle version/help requests
if ($version) { Show-Version; exit }
if ($help) { Show-Usage }

# Validate AWS CLI version
$minVersion = "1.16.299"
$currentVersion = (aws --version 2>&1).Split()[0].Split('/')[1]
if ((Get-ComparableVersion $currentVersion) -lt (Get-ComparableVersion $minVersion)) {
    Write-Error "AWS CLI version must be >= $minVersion. Current: $currentVersion"
    exit 1
}

# Install session manager plugin if missing
if (-not (Get-Command session-manager-plugin -ErrorAction SilentlyContinue)) {
    Write-Output "Installing session manager plugin..."
    $tempDir = Join-Path $env:TEMP "sessionmanager"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    
    Invoke-WebRequest "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/windows/SessionManagerPluginSetup.exe" `
        -OutFile "$tempDir\SessionManagerPluginSetup.exe"
    
    Start-Process "$tempDir\SessionManagerPluginSetup.exe" -ArgumentList "/silent /install" -Wait
    Remove-Item $tempDir -Recurse -Force
}

# Region detection
if (-not $aws_region) {
    $aws_region = if ($aws_profile) {
        aws configure get region --profile $aws_profile
    } else {
        aws configure get region
    }
    if (-not $aws_region) { $aws_region = $default_aws_region }
}

# Instance discovery
if (-not $instance_id) {
    if ($tag_value) {
        $instances = Get-InstancesByTag $tag_value $aws_region $aws_profile
    }
    elseif ($ssm_name) {
        $instance_id = Get-InstanceBySSMName $ssm_name $aws_region $aws_profile
    }
}

# Interactive selection
if (-not $instance_id -and $instances) {
    if ($interactive_mode) {
        $choices = $instances -split "`n" | ForEach-Object {
            $parts = $_ -split "`t"
            [PSCustomObject]@{
                Id = $parts[0]
                Name = $parts[1]
            }
        }

        $choices | Format-Table @{Label="Num"; Expression={$choices.IndexOf($_) + 1}}, Id, Name
        $selection = Read-Host "Enter instance number (default 1)"
        $instance_id = if ($selection) { $choices[$selection-1].Id } else { $choices[0].Id }
    }
    else {
        $instance_id = ($instances -split "`n" | Select-Object -First 1).Split()[0]
    }
}

# Execute action
switch ($action) {
    "ssh" {
        $args = @("--target", $instance_id, "--region", $aws_region)
        if ($aws_profile) { $args += "--profile", $aws_profile }
        if ($document_name) { $args += "--document-name", $document_name }
        aws ssm start-session $args
    }
    
    "tunnel" {
        $params = @{
            portNumber = @("$tunnel_remote_port")
            localPortNumber = @("$tunnel_local_port")
            host = @("$tunnel_remote_host")
        } | ConvertTo-Json -Compress

        aws ssm start-session `
            --target $instance_id `
            --document-name AWS-StartPortForwardingSessionToRemoteHost `
            --parameters $params `
            --region $aws_region `
            --profile $aws_profile
    }
    
    "document" {
        $params = @{}
        if ($github_token_location) { $params.githubTokenLocation = $github_token_location }
        if ($document_parameters) { $params.parameters = $document_parameters }
        if ($long_running) { $params.longRunning = "true" }
        
        $cmdArgs = @(
            "--instance-ids", $instance_id,
            "--document-name", $document_name,
            "--comment", "Document run using aws-connect",
            "--region", $aws_region,
            "--cloud-watch-output-config", "{`"CloudWatchLogGroupName`":`"$($cloudwatch_group ?? 'aws-connect')`",`"CloudWatchOutputEnabled`":true}"
        )
        
        if ($params.Count -gt 0) {
            $cmdArgs += "--parameters"
            $cmdArgs += ($params.Keys | ForEach-Object { "$_=$($params[$_])" }) -join ','
        }

        $commandId = aws ssm send-command $cmdArgs --query "Command.CommandId" --output text
        Write-Output "Command ID: $commandId"

        while ($true) {
            $status = aws ssm list-command-invocations `
                --command-id $commandId `
                --query "CommandInvocations[0].Status" `
                --output text
            
            if ($status -eq "Success") {
                Write-Output "Command succeeded"
                break
            }
            elseif ($status -in @("Failed", "Cancelled", "TimedOut")) {
                Write-Error "Command failed: $status"
                exit 1
            }
            Start-Sleep -Seconds 5
        }
    }
    
    default { Write-Error "Invalid action: $action"; Show-Usage }
}
