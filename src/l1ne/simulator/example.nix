# Example L1NE configuration
#
# This file defines runtime limits and service instances for the L1NE orchestrator.
# All values must be within compile-time maximums defined in constants.zig.
#
# Load with: l1ne start --config=src/l1ne/simulator/example.nix /path/to/data

let
  # Container factory: describes how to run a single dumb-server instance
  mkDumbServer = import ./containers/dumb-server.nix { root = ./.; };
in {
  # Runtime resource limits (compose-level, like docker-compose service settings)
  runtime = {
    proxy_connections_max = 256;  # Concurrent proxy connections
    proxy_buffer_size_kb = 4;     # Buffer per connection (KiB)
    cgroup_monitors_max = 4;      # One per service
    systemd_buffer_size_kb = 4;   # systemd notify buffer
  };

  # Service instance definitions (each created via container factory)
  services = {
    max_instances = 4;
    instances = [
      (mkDumbServer {
        name = "demo-frontend";
        port = 8081;
        memory_mb = 64;
        cpu_percent = 20;
      })
      (mkDumbServer {
        name = "demo-api";
        port = 8082;
        memory_mb = 96;
        cpu_percent = 30;
      })
      (mkDumbServer {
        name = "demo-ingest";
        port = 8083;
        memory_mb = 80;
        cpu_percent = 25;
      })
    ];
  };
}
