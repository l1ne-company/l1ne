# Example L1NE Configuration
#
# Deploy with: l1ne start --config=example.nix .

{ pkgs ? import <nixpkgs> {} }:

let
  # Import L1NE utilities (like importing Crane)
  l1ne = import ./lib.nix { inherit pkgs; };

  # Define individual services
  webService = l1ne.mkService {
    name = "web-frontend";
    package = pkgs.nginx;
    port = 8080;

    # Instance scaling (per-service)
    instances = {
      min = 2;    # Always keep 2 instances running
      max = 8;    # Scale up to 8 instances under load
      start = 3;  # Start with 3 instances
    };

    args = [ "-c" "/etc/nginx/nginx.conf" ];
    resources = {
      memory_percent = 60;
      cpu_percent = 70;
    };
    health_check = l1ne.mkHttpHealthCheck {
      path = "/health";
      interval_seconds = 5;
    };
  };

  apiService = l1ne.mkService {
    name = "api-backend";
    package = pkgs.hello;  # Replace with actual API package
    port = 3000;

    # Heavy scaling for API tier
    instances = {
      min = 4;    # Minimum 4 instances for redundancy
      max = 16;   # Scale up to 16 under high load
      start = 6;  # Start with 6 instances
    };

    env = {
      DATABASE_URL = "postgresql://localhost/mydb";
      LOG_LEVEL = "info";
      MAX_CONNECTIONS = "100";
    };
    resources = {
      memory_percent = 80;
      cpu_percent = 75;
    };
    health_check = l1ne.mkHttpHealthCheck {
      path = "/api/health";
      interval_seconds = 10;
      unhealthy_threshold = 5;
    };
  };

  workerService = l1ne.mkService {
    name = "background-worker";
    package = pkgs.hello;  # Replace with actual worker package
    port = 9090;  # Management/metrics port

    # Light scaling for workers
    instances = {
      min = 1;
      max = 4;
      start = 2;
    };

    args = [ "--worker-mode" ];
    resources = {
      memory_percent = 50;
      cpu_percent = 60;
    };
    health_check = l1ne.mkCommandHealthCheck {
      command = [ "systemctl" "is-active" "worker" ];
      interval_seconds = 30;
    };
  };

  # Database service with TCP health check (single instance)
  dbService = l1ne.mkService {
    name = "postgresql";
    package = pkgs.postgresql;
    port = 5432;

    # Single instance (no scaling)
    instances = {
      min = 1;
      max = 1;
      start = 1;
    };

    resources = {
      memory_percent = 70;
      cpu_percent = 50;
    };
    health_check = l1ne.mkTcpHealthCheck {
      interval_seconds = 15;
    };
  };

in
# Create service mesh with all services
l1ne.mkMesh {
  name = "production-stack";

  services = [
    webService
    apiService
    workerService
    dbService
  ];

  # Runtime limits (NASA-style bounds)
  limits = {
    service_instances_count = 4;
    proxy_connections_max = 512;
    proxy_buffer_size_kb = 32;
    cgroup_monitors_count = 4;
    systemd_buffer_size_kb = 8;
  };

  # Enable WAL for deterministic replay
  wal_enabled = true;
  wal_path = "/var/lib/l1ne/production.wal";
}
