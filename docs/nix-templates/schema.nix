# L1NE Configuration Schema
#
# Complete type definitions and validation for L1NE configurations.
# This serves as both documentation and runtime validation.

{ pkgs ? import <nixpkgs> {} }:

rec {
  # Service Definition Schema
  ServiceSchema = {
    # Required fields
    name = "string";              # Unique service identifier
    package = "derivation";       # Nix package with executable
    port = "integer (1024-65535)"; # Service port

    # Optional fields
    instances = "InstancesSchema"; # Instance scaling configuration (per-service)
    args = "list of strings";     # Command-line arguments
    env = "attribute set";        # Environment variables
    resources = "ResourcesSchema";
    health_check = "HealthCheckSchema";
    restart_policy = "enum: always|on-failure|never";
    labels = "attribute set";     # Key-value labels for filtering/organization

    # Computed fields
    assertions = "list of AssertionSchema";
  };

  # Instances Configuration Schema (per-service scaling)
  InstancesSchema = {
    min = "integer (1-64)";       # Minimum instances (always running)
    max = "integer (1-64)";       # Maximum instances (scale limit)
    start = "integer (1-64)";     # Initial instances (at deployment)

    # Invariants (enforced by assertions):
    # - min > 0
    # - max > 0
    # - max <= 64 (L1NE system limit)
    # - min <= max
    # - min <= start <= max
  };

  # Resource Limits Schema
  ResourcesSchema = {
    memory_percent = "integer (1-100)";  # Percentage of system memory
    cpu_percent = "integer (1-100)";     # Percentage of CPU
  };

  # Health Check Schema
  HealthCheckSchema = {
    enabled = "boolean";
    type = "enum: http|tcp|command";

    # HTTP health check fields
    path = "string";              # HTTP path (default: /health)
    port_override = "integer | null"; # Override service port

    # TCP health check fields (uses service port or port_override)

    # Command health check fields
    command = "list of strings";  # Command to execute

    # Common fields
    interval_seconds = "integer"; # How often to check
    timeout_seconds = "integer";  # Timeout for each check
    unhealthy_threshold = "integer"; # Consecutive failures before unhealthy
  };

  # Service Mesh Schema
  MeshSchema = {
    # Required fields
    name = "string";              # Mesh identifier
    services = "list of ServiceSchema";

    # Optional fields
    limits = "RuntimeLimitsSchema";
    wal_enabled = "boolean";      # Enable Write-Ahead Log
    wal_path = "string";          # WAL file path

    # Computed fields
    assertions = "list of AssertionSchema";
  };

  # Runtime Limits Schema (NASA-style bounds)
  RuntimeLimitsSchema = {
    service_instances_count = "integer (1-64)";  # Max service instances
    proxy_connections_max = "integer (1-4096)";  # Max concurrent connections
    proxy_buffer_size_kb = "integer (1-64)";     # Buffer size in KiB
    cgroup_monitors_count = "integer (1-64)";    # Cgroup monitors
    systemd_buffer_size_kb = "integer (1-256)";  # Systemd buffer in KiB
  };

  # Autoscaler Schema
  AutoscalerSchema = {
    enabled = "boolean";
    min_instances = "integer (1-64)";
    max_instances = "integer (1-64)";
    target_cpu_percent = "integer (1-100)";
    target_memory_percent = "integer (1-100)";
    scale_up_cooldown_seconds = "integer";
    scale_down_cooldown_seconds = "integer";
  };

  # Assertion Schema
  AssertionSchema = {
    assertion = "boolean expression";
    message = "string";           # Error message if assertion fails
  };

  # Complete Configuration Example (for reference)
  ExampleConfig = {
    # Single service (minimal)
    simple = {
      name = "my-service";
      package = "pkgs.my-app";
      port = 8080;
      # instances defaults to { min = 1; max = 1; start = 1; }
    };

    # Single instance (explicit)
    singleton = {
      name = "database";
      package = "pkgs.postgresql";
      port = 5432;
      instances = {
        min = 1;
        max = 1;
        start = 1;
      };
    };

    # Scaled service
    scaled = {
      name = "api";
      package = "pkgs.my-api";
      port = 3000;
      instances = {
        min = 2;    # Always keep 2 running
        max = 10;   # Scale up to 10
        start = 4;  # Start with 4
      };
    };

    # Service with full options
    complete = {
      name = "full-service";
      package = "pkgs.my-app";
      port = 8080;
      instances = {
        min = 3;
        max = 12;
        start = 5;
      };
      args = [ "--flag" "value" ];
      env = {
        VAR1 = "value1";
        VAR2 = "value2";
      };
      resources = {
        memory_percent = 75;
        cpu_percent = 70;
      };
      health_check = {
        enabled = true;
        type = "http";
        path = "/health";
        interval_seconds = 10;
        timeout_seconds = 5;
        unhealthy_threshold = 3;
      };
      restart_policy = "always";
      labels = {
        team = "platform";
        env = "prod";
      };
    };

    # Service mesh
    mesh = {
      name = "my-platform";
      services = [
        # ... services ...
      ];
      limits = {
        service_instances_count = 8;
        proxy_connections_max = 1024;
        proxy_buffer_size_kb = 32;
        cgroup_monitors_count = 8;
        systemd_buffer_size_kb = 16;
      };
      wal_enabled = true;
      wal_path = "/var/lib/l1ne/platform.wal";
    };
  };

  # Validation constraints
  Constraints = {
    ports = {
      min = 1024;
      max = 65535;
      reserved = [ 22 80 443 ];  # Common system ports to avoid
    };

    limits = {
      max_service_instances = 64;
      max_proxy_connections = 4096;
      max_proxy_buffer_kb = 64;
      max_cgroup_monitors = 64;
      max_systemd_buffer_kb = 256;
    };

    percentages = {
      min = 1;
      max = 100;
    };
  };

  # Reserved keywords (cannot be used as service names)
  ReservedNames = [
    "system"
    "l1ne"
    "master"
    "orchestrator"
    "proxy"
    "wal"
    "health"
    "metrics"
  ];
}
