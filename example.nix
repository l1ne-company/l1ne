# Example L1NE configuration
#
# This file defines runtime limits and service instances for the L1NE orchestrator.
# All values must be within compile-time maximums defined in constants.zig.
#
# Load with: l1ne start --config=example.nix /path/to/data

{
  # Runtime resource limits
  # These determine static memory allocation at startup
  runtime = {
    # Maximum concurrent proxy connections (compile-time max: 1024)
    proxy_connections_max = 256;

    # Proxy buffer size in KiB (compile-time max: 16 KiB)
    proxy_buffer_size_kb = 4;

    # Maximum number of cgroup monitors (compile-time max: 16)
    cgroup_monitors_max = 4;

    # Systemd communication buffer size in KiB (compile-time max: 16 KiB)
    systemd_buffer_size_kb = 4;
  };

  # Service instance definitions
  services = {
    # Maximum service instances across all services (compile-time max: 16)
    max_instances = 4;

    # List of service instances to deploy
    instances = [
      {
        name = "demo-1";
        exec = "./dumb-server/result/bin/dumb-server";
        port = 8081;
        memory_mb = 50;  # Memory limit in MiB
        cpu_percent = 25; # CPU limit as percentage
      }
      {
        name = "demo-2";
        exec = "./dumb-server/result/bin/dumb-server";
        port = 8082;
        memory_mb = 50;
        cpu_percent = 25;
      }
      {
        name = "demo-3";
        exec = "./dumb-server/result/bin/dumb-server";
        port = 8083;
        memory_mb = 50;
        cpu_percent = 25;
      }
      {
        name = "demo-4";
        exec = "./dumb-server/result/bin/dumb-server";
        port = 8084;
        memory_mb = 50;
        cpu_percent = 25;
      }
    ];
  };
}
