param(
    [ValidateSet("setup", "start", "stop", "restart", "logs", "status", "update", "chat", "shell", "remove", "recreate")]
    [string]$Action = "start",

    [string]$Image = $(if ($env:HERMES_IMAGE) { $env:HERMES_IMAGE } else { "nousresearch/hermes-agent:latest" }),
    [string]$RedisImage = $(if ($env:HERMES_REDIS_IMAGE) { $env:HERMES_REDIS_IMAGE } else { "redis:7-alpine" }),
    [string]$ContainerName = $(if ($env:HERMES_CONTAINER_NAME) { $env:HERMES_CONTAINER_NAME } else { "hermes" }),
    [string]$RedisContainerName = $(if ($env:HERMES_REDIS_CONTAINER_NAME) { $env:HERMES_REDIS_CONTAINER_NAME } else { "hermes-redis" }),
    [string]$NetworkName = $(if ($env:HERMES_NETWORK_NAME) { $env:HERMES_NETWORK_NAME } else { "hermesagent_hermes-net" }),
    [string]$DataVolume = $(if ($env:HERMES_DATA_VOLUME) { $env:HERMES_DATA_VOLUME } else { "hermesagent_hermes_data" }),
    [string]$RedisVolume = $(if ($env:HERMES_REDIS_VOLUME) { $env:HERMES_REDIS_VOLUME } else { "hermesagent_redis_data" }),
    [int]$GatewayPort = $(if ($env:HERMES_GATEWAY_PORT) { [int]$env:HERMES_GATEWAY_PORT } else { 8642 }),
    [int]$DashboardPort = $(if ($env:HERMES_DASHBOARD_PORT) { [int]$env:HERMES_DASHBOARD_PORT } else { 9119 }),
    [string[]]$GatewayArgs = $(if ($env:HERMES_GATEWAY_ARGS) { $env:HERMES_GATEWAY_ARGS -split " " } else { @("gateway", "run") }),
    [string]$ConfigFile = $(if ($env:HERMES_CONFIG_FILE) { $env:HERMES_CONFIG_FILE } else { Join-Path $PSScriptRoot "hermes.config.env" }),
    [switch]$SkipPull
)

$ErrorActionPreference = "Stop"

function Load-ConfigFile {
    # Load KEY=VALUE pairs from the user config file into the current process environment.
    if (-not (Test-Path -LiteralPath $ConfigFile)) {
        Write-Host "Config file not found, using defaults and process environment: $ConfigFile"
        return
    }

    Get-Content -LiteralPath $ConfigFile | ForEach-Object {
        $line = $_.Trim()
        if (-not $line -or $line.StartsWith("#")) {
            return
        }

        $parts = $line -split "=", 2
        if ($parts.Count -ne 2) {
            return
        }

        $key = $parts[0].Trim()
        $value = $parts[1].Trim()
        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        [Environment]::SetEnvironmentVariable($key, $value, "Process")
    }
}

function Apply-SettingsFromEnv {
    # Re-apply script settings after loading hermes.config.env.
    if ($env:HERMES_IMAGE) { $script:Image = $env:HERMES_IMAGE }
    if ($env:HERMES_REDIS_IMAGE) { $script:RedisImage = $env:HERMES_REDIS_IMAGE }
    if ($env:HERMES_CONTAINER_NAME) { $script:ContainerName = $env:HERMES_CONTAINER_NAME }
    if ($env:HERMES_REDIS_CONTAINER_NAME) { $script:RedisContainerName = $env:HERMES_REDIS_CONTAINER_NAME }
    if ($env:HERMES_NETWORK_NAME) { $script:NetworkName = $env:HERMES_NETWORK_NAME }
    if ($env:HERMES_DATA_VOLUME) { $script:DataVolume = $env:HERMES_DATA_VOLUME }
    if ($env:HERMES_REDIS_VOLUME) { $script:RedisVolume = $env:HERMES_REDIS_VOLUME }
    if ($env:HERMES_GATEWAY_PORT) { $script:GatewayPort = [int]$env:HERMES_GATEWAY_PORT }
    if ($env:HERMES_DASHBOARD_PORT) { $script:DashboardPort = [int]$env:HERMES_DASHBOARD_PORT }
    if ($env:HERMES_GATEWAY_ARGS) { $script:GatewayArgs = $env:HERMES_GATEWAY_ARGS -split " " }
    if ($env:HERMES_SKIP_PULL -match "^(1|true|yes)$") { $script:SkipPull = $true }
}

function Assert-Docker {
    # Docker Desktop may write warnings to stderr even when the command succeeds.
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw "Docker command was not found. Please install and start Docker Desktop first."
    }

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    docker info *> $null
    $dockerInfoExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference

    if ($dockerInfoExitCode -ne 0) {
        throw "Docker is not available. Please make sure Docker Desktop is running."
    }
}

function Ensure-Network {
    $network = docker network ls --filter "name=^$NetworkName$" --format "{{.Name}}"
    if (-not $network) {
        docker network create $NetworkName | Out-Null
    }
}

function Ensure-Volume {
    param([string]$Name)

    $volume = docker volume ls --filter "name=^$Name$" --format "{{.Name}}"
    if (-not $volume) {
        docker volume create $Name | Out-Null
    }
}

function Get-ContainerId {
    param([string]$Name = $ContainerName)

    docker ps -a --filter "name=^/$Name$" --format "{{.ID}}"
}

function Remove-ContainerIfExists {
    param([string]$Name)

    $existing = Get-ContainerId $Name
    if ($existing) {
        docker rm -f $Name | Out-Null
    }
}

function Stop-ContainerIfExists {
    param([string]$Name)

    $existing = Get-ContainerId $Name
    if ($existing) {
        docker stop $Name | Out-Null
    }
}

function Invoke-DockerPull {
    param([string]$Name)

    if ($SkipPull) {
        Write-Host "Skip pulling image: $Name"
        return
    }

    docker pull $Name
}

function Get-EnvFileArgs {
    if (Test-Path -LiteralPath $ConfigFile) {
        return @("--env-file", (Resolve-Path -LiteralPath $ConfigFile).Path)
    }

    return @()
}

function Invoke-DockerRunSetup {
    Ensure-Network
    Ensure-Volume $DataVolume

    $args = @("run", "--rm", "-it", "--name", "$ContainerName-setup", "--network", $NetworkName)
    $args += @("-v", "${DataVolume}:/opt/data")
    $args += Get-EnvFileArgs
    $args += @($Image, "setup")

    docker @args
}

function Invoke-DockerRunRedis {
    Ensure-Network
    Ensure-Volume $RedisVolume

    $existing = Get-ContainerId $RedisContainerName
    if ($existing) {
        $running = docker ps --filter "name=^/$RedisContainerName$" --format "{{.ID}}"
        if (-not $running) {
            docker start $RedisContainerName | Out-Null
        }
        return
    }

    $args = @("run", "-d", "--name", $RedisContainerName, "--restart", "unless-stopped", "--network", $NetworkName)
    $args += @("-v", "${RedisVolume}:/data", $RedisImage)

    docker @args | Out-Null
}

function Invoke-DockerRunGateway {
    Ensure-Network
    Ensure-Volume $DataVolume
    Invoke-DockerRunRedis

    $existing = Get-ContainerId
    if ($existing) {
        $running = docker ps --filter "name=^/$ContainerName$" --format "{{.ID}}"
        if ($running) {
            Write-Host "Hermes is already running: $ContainerName"
            return
        }

        docker start $ContainerName | Out-Null
        Write-Host "Hermes started: $ContainerName"
        return
    }

    $args = @("run", "-d", "--name", $ContainerName, "--restart", "unless-stopped", "--network", $NetworkName)
    $args += @("-e", "HERMES_DASHBOARD=1")
    $args += @("-p", "${GatewayPort}:8642", "-p", "${DashboardPort}:9119")
    $args += @("-v", "${DataVolume}:/opt/data")
    $args += Get-EnvFileArgs
    $args += @($Image)
    $args += $GatewayArgs

    docker @args | Out-Null

    Write-Host "Hermes has been deployed and started."
    Write-Host "Container: $ContainerName"
    Write-Host "Gateway:   http://localhost:$GatewayPort"
    Write-Host "Dashboard: http://localhost:$DashboardPort"
    Write-Host "Data:      docker volume $DataVolume"
    Write-Host "Config:    $ConfigFile"
}

Load-ConfigFile
Apply-SettingsFromEnv
Assert-Docker

switch ($Action) {
    "setup" {
        Invoke-DockerPull $Image
        Invoke-DockerRunSetup
    }
    "start" {
        Invoke-DockerPull $Image
        Invoke-DockerPull $RedisImage
        Invoke-DockerRunGateway
    }
    "stop" {
        Stop-ContainerIfExists $ContainerName
        Stop-ContainerIfExists $RedisContainerName
    }
    "restart" {
        Invoke-DockerRunRedis
        $existing = Get-ContainerId
        if ($existing) {
            docker restart $ContainerName
        } else {
            Invoke-DockerRunGateway
        }
    }
    "logs" {
        docker logs -f $ContainerName
    }
    "status" {
        docker ps -a --filter "name=^/$ContainerName$"
        docker ps -a --filter "name=^/$RedisContainerName$"
    }
    "update" {
        Invoke-DockerPull $Image
        Invoke-DockerPull $RedisImage
        Remove-ContainerIfExists $ContainerName
        Invoke-DockerRunGateway
    }
    "chat" {
        Ensure-Network
        Ensure-Volume $DataVolume

        $args = @("run", "--rm", "-it", "--network", $NetworkName, "-v", "${DataVolume}:/opt/data")
        $args += Get-EnvFileArgs
        $args += @($Image, "chat")

        docker @args
    }
    "shell" {
        docker exec -it $ContainerName sh
    }
    "remove" {
        Remove-ContainerIfExists $ContainerName
        Remove-ContainerIfExists $RedisContainerName
        Write-Host "Containers removed. Docker volumes are kept: $DataVolume, $RedisVolume"
    }
    "recreate" {
        Invoke-DockerPull $Image
        Invoke-DockerPull $RedisImage
        Remove-ContainerIfExists $ContainerName
        Remove-ContainerIfExists $RedisContainerName
        Invoke-DockerRunGateway
    }
}
