# Docker-compose style example for L1NE
#
# Build the dumb-server flake once:
#   nix build ../../src/l1ne/simulator/dumb-server#dumb-server
# Then wire the resulting binary into each service below.

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
    proxy_connections_max = 256;
    proxy_buffer_size_kb = 4;
    cgroup_monitors_max = 4;
    systemd_buffer_size_kb = 4;
  };

  services = {
    max_instances = 4;
    instances = [
      (mkService {
        name = "demo-frontend";
        port = 8081;
        memory_mb = 64;
        cpu_percent = 20;
      })
      (mkService {
        name = "demo-api";
        port = 8082;
        memory_mb = 96;
        cpu_percent = 30;
      })
      (mkService {
        name = "demo-ingest";
        port = 8083;
        memory_mb = 80;
        cpu_percent = 25;
      })
    ];
  };
}
