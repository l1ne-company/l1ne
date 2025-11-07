# Compose multiple roles from the same dumb-server binary.
# Build the flake once, then point every service at the resulting exec.

let
  dumbServer = ../../src/l1ne/simulator/dumb-server/result/bin/dumb-server;
  mkService =
    { name, port, memory_mb ? 50, cpu_percent ? 10 }:
    {
      inherit name port memory_mb cpu_percent;
      exec = dumbServer;
    };
in {
  runtime = {
    proxy_connections_max = 512;
    proxy_buffer_size_kb = 8;
    cgroup_monitors_max = 8;
    systemd_buffer_size_kb = 8;
  };

  services = {
    max_instances = 8;
    instances = [
      (mkService {
        name = "auth-service";
        port = 8001;
        memory_mb = 72;
        cpu_percent = 25;
      })
      (mkService {
        name = "user-service";
        port = 8002;
        memory_mb = 64;
        cpu_percent = 20;
      })
      (mkService {
        name = "order-service";
        port = 8003;
        memory_mb = 96;
        cpu_percent = 30;
      })
      (mkService {
        name = "api-gateway";
        port = 8080;
        memory_mb = 80;
        cpu_percent = 35;
      })
    ];
  };
}
