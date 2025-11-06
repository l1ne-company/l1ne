# L1NE Configuration Library
#
# Provides composable utilities for building L1NE service configurations.
# Inspired by Crane's approach to Docker image building.
#
# Usage:
#   let
#     l1ne = import ./lib.nix;
#   in
#   l1ne.mkService {
#     name = "my-api";
#     package = pkgs.my-api;
#     port = 8080;
#   }

{ pkgs ? import <nixpkgs> {} }:

let
  # Default runtime limits (NASA-style bounded resources)
  defaultLimits = {
    service_instances_count = 4;
    proxy_connections_max = 256;
    proxy_buffer_size_kb = 16;
    cgroup_monitors_count = 4;
    systemd_buffer_size_kb = 4;
  };

  # Default resource limits (cgroup constraints)
  defaultResources = {
    memory_percent = 80;
    cpu_percent = 80;
  };

in rec {
  # Create a service definition
  #
  # Args:
  #   name: Service identifier (must be unique)
  #   package: Nix package containing the executable
  #   port: Service port (1024-65535)
  #   instances: Instance configuration (min, max, start)
  #   args: Optional command-line arguments
  #   env: Optional environment variables
  #   resources: Optional resource limits
  #   health_check: Optional health check configuration
  mkService = {
    name,
    package,
    port,
    instances ? { min = 1; max = 1; start = 1; },
    args ? [],
    env ? {},
    resources ? {},
    health_check ? null,
    restart_policy ? "always",
  }:
  let
    # Default instances if not fully specified
    finalInstances = {
      min = instances.min or 1;
      max = instances.max or 1;
      start = instances.start or (instances.min or 1);
    };

    # Merge resources with defaults
    finalResources = defaultResources // resources;
  in {
    inherit name package port args env restart_policy;

    # Instance configuration (per-service scaling)
    instances = finalInstances;

    # Merge with defaults
    resources = finalResources;

    # Optional health check
    health = if health_check != null then health_check else {
      enabled = false;
    };

    # Validation
    assertions = [
      {
        assertion = port >= 1024 && port <= 65535;
        message = "Service ${name}: port must be in range 1024-65535";
      }
      {
        assertion = builtins.stringLength name > 0;
        message = "Service name cannot be empty";
      }
      {
        assertion = finalResources.memory_percent > 0 && finalResources.memory_percent <= 100;
        message = "Service ${name}: memory_percent must be 1-100";
      }
      {
        assertion = finalResources.cpu_percent > 0 && finalResources.cpu_percent <= 100;
        message = "Service ${name}: cpu_percent must be 1-100";
      }
      {
        assertion = finalInstances.min > 0;
        message = "Service ${name}: instances.min must be > 0";
      }
      {
        assertion = finalInstances.max > 0;
        message = "Service ${name}: instances.max must be > 0";
      }
      {
        assertion = finalInstances.max <= 64;
        message = "Service ${name}: instances.max cannot exceed 64 (L1NE limit)";
      }
      {
        assertion = finalInstances.min <= finalInstances.max;
        message = "Service ${name}: instances.min (${toString finalInstances.min}) must be <= instances.max (${toString finalInstances.max})";
      }
      {
        assertion = finalInstances.start >= finalInstances.min && finalInstances.start <= finalInstances.max;
        message = "Service ${name}: instances.start (${toString finalInstances.start}) must be between min (${toString finalInstances.min}) and max (${toString finalInstances.max})";
      }
    ];
  };

  # Create HTTP health check
  mkHttpHealthCheck = {
    path ? "/health",
    port ? null,  # Defaults to service port
    interval_seconds ? 10,
    timeout_seconds ? 5,
    unhealthy_threshold ? 3,
  }: {
    enabled = true;
    type = "http";
    inherit path interval_seconds timeout_seconds unhealthy_threshold;
    port_override = port;
  };

  # Create TCP health check
  mkTcpHealthCheck = {
    port ? null,  # Defaults to service port
    interval_seconds ? 10,
    timeout_seconds ? 5,
    unhealthy_threshold ? 3,
  }: {
    enabled = true;
    type = "tcp";
    inherit interval_seconds timeout_seconds unhealthy_threshold;
    port_override = port;
  };

  # Create command health check
  mkCommandHealthCheck = {
    command,
    interval_seconds ? 30,
    timeout_seconds ? 10,
    unhealthy_threshold ? 3,
  }: {
    enabled = true;
    type = "command";
    inherit command interval_seconds timeout_seconds unhealthy_threshold;
  };

  # Create a service mesh (multiple services)
  mkMesh = {
    name,
    services,
    limits ? {},
    wal_enabled ? true,
    wal_path ? "/var/lib/l1ne/wal",
  }: {
    inherit name services wal_enabled wal_path;

    # Merge runtime limits with defaults
    limits = defaultLimits // limits;

    # Validate service count doesn't exceed limits
    assertions = [
      {
        assertion = builtins.length services <= limits.service_instances_count;
        message = "Mesh ${name}: service count exceeds limit (${toString (builtins.length services)} > ${toString limits.service_instances_count})";
      }
      {
        assertion = builtins.all (s: s ? name && s ? port) services;
        message = "Mesh ${name}: all services must have 'name' and 'port'";
      }
    ];
  };

  # Create autoscaling configuration
  mkAutoscaler = {
    min_instances ? 1,
    max_instances ? 8,
    target_cpu_percent ? 70,
    target_memory_percent ? 70,
    scale_up_cooldown_seconds ? 60,
    scale_down_cooldown_seconds ? 300,
  }: {
    enabled = true;
    inherit min_instances max_instances;
    inherit target_cpu_percent target_memory_percent;
    inherit scale_up_cooldown_seconds scale_down_cooldown_seconds;

    assertions = [
      {
        assertion = min_instances > 0;
        message = "min_instances must be > 0";
      }
      {
        assertion = max_instances >= min_instances;
        message = "max_instances must be >= min_instances";
      }
      {
        assertion = max_instances <= 64;  # L1NE maximum
        message = "max_instances cannot exceed 64";
      }
    ];
  };

  # Create environment variable set from file
  mkEnvFromFile = path:
    builtins.fromJSON (builtins.readFile path);

  # Create environment variable set from secret (placeholder)
  mkEnvFromSecret = secretName: {
    __secret = secretName;
  };

  # Merge multiple service configurations
  mergeServices = services:
    builtins.foldl' (acc: svc: acc ++ [svc]) [] services;

  # Filter services by label
  filterByLabel = label: value: services:
    builtins.filter (svc:
      svc ? labels && svc.labels ? ${label} && svc.labels.${label} == value
    ) services;

  # Apply common configuration to multiple services
  applyToAll = config: services:
    builtins.map (svc: svc // config) services;

  # Utility: Check assertions and throw if any fail
  checkAssertions = assertions:
    let
      failed = builtins.filter (a: !a.assertion) assertions;
    in
      if builtins.length failed > 0
      then throw (builtins.concatStringsSep "\n" (builtins.map (a: a.message) failed))
      else true;
}
