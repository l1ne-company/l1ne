# Microservices Configuration for L1NE
#
# Example showing multiple services with shared configuration.
#
# Deploy with: l1ne start --config=microservices.nix .

{ pkgs ? import <nixpkgs> {} }:

let
  l1ne = import ./lib.nix { inherit pkgs; };

  # Import shared configuration (like Kubernetes ConfigMaps)
  commonConfig = {
    env = {
      ENVIRONMENT = "production";
      REGION = "us-east-1";
      LOG_FORMAT = "json";
    };
    resources = {
      memory_percent = 75;
      cpu_percent = 70;
    };
  };

  # Shared labels (like Kubernetes labels for service discovery)
  labels = {
    team = "platform";
    version = "v1.2.3";
    managed_by = "l1ne";
  };

  # Microservices that compose the application
  microservices = [
    (l1ne.mkService {
      name = "auth-service";
      package = pkgs.hello;
      port = 8001;

      # Auth: critical service, keep multiple instances
      instances = {
        min = 3;
        max = 12;
        start = 4;
      };

      env = commonConfig.env // {
        SERVICE_NAME = "auth";
        JWT_SECRET_FILE = "/run/secrets/jwt";
      };
      resources = commonConfig.resources;
      health_check = l1ne.mkHttpHealthCheck {
        path = "/health";
      };
    } // { inherit labels; })

    (l1ne.mkService {
      name = "user-service";
      package = pkgs.hello;
      port = 8002;

      # User: moderate scaling
      instances = {
        min = 2;
        max = 8;
        start = 3;
      };

      env = commonConfig.env // {
        SERVICE_NAME = "user";
        AUTH_URL = "http://auth-service:8001";
      };
      resources = commonConfig.resources;
      health_check = l1ne.mkHttpHealthCheck {
        path = "/health";
      };
    } // { inherit labels; })

    (l1ne.mkService {
      name = "order-service";
      package = pkgs.hello;
      port = 8003;

      # Order: high scaling for peak traffic
      instances = {
        min = 4;
        max = 20;
        start = 6;
      };

      env = commonConfig.env // {
        SERVICE_NAME = "order";
        USER_URL = "http://user-service:8002";
      };
      resources = commonConfig.resources;
      health_check = l1ne.mkHttpHealthCheck {
        path = "/health";
      };
    } // { inherit labels; })

    (l1ne.mkService {
      name = "payment-service";
      package = pkgs.hello;
      port = 8004;

      # Payment: critical, limited scaling (stateful)
      instances = {
        min = 2;
        max = 6;
        start = 3;
      };

      env = commonConfig.env // {
        SERVICE_NAME = "payment";
        STRIPE_API_KEY_FILE = "/run/secrets/stripe";
      };
      resources = {
        memory_percent = 80;  # Higher for payment processing
        cpu_percent = 75;
      };
      health_check = l1ne.mkHttpHealthCheck {
        path = "/health";
        unhealthy_threshold = 2;  # Stricter for payments
      };
    } // { inherit labels; })
  ];

  # API Gateway (entry point)
  gateway = l1ne.mkService {
    name = "api-gateway";
    package = pkgs.nginx;
    port = 443;

    # Gateway: high availability with load balancing
    instances = {
      min = 2;   # Always keep 2 for HA
      max = 10;  # Scale for traffic spikes
      start = 3;
    };

    env = {
      BACKEND_SERVICES = "auth,user,order,payment";
      SSL_CERT_FILE = "/run/secrets/ssl-cert";
    };
    resources = {
      memory_percent = 60;
      cpu_percent = 80;
    };
    health_check = l1ne.mkHttpHealthCheck {
      path = "/";
      port = 8080;  # Health check on different port
    };
  } // {
    labels = labels // { role = "gateway"; };
  };

in
# Declarative application manifest (like k8s Deployment)
l1ne.mkMesh {
  name = "microservices-platform";

  # All services in the mesh
  services = [ gateway ] ++ microservices;

  # Platform-wide resource limits
  limits = {
    service_instances_count = 8;     # Max 8 services
    proxy_connections_max = 1024;    # Max 1024 concurrent connections
    proxy_buffer_size_kb = 64;       # 64 KiB buffers
    cgroup_monitors_count = 8;       # Monitor all services
    systemd_buffer_size_kb = 16;     # 16 KiB systemd buffer
  };

  # Write-Ahead Log for deterministic replay and debugging
  wal_enabled = true;
  wal_path = "/var/lib/l1ne/platform.wal";
}
