# L1NE Configuration
#
# This Nix file defines the static memory allocation limits for L1NE.
# All resources are allocated at startup based on these limits.
#
# After reading this config, L1NE will:
# 1. Allocate exactly the specified amount of memory
# 2. Lock the allocator (transition to static mode)
# 3. Run forever with bounded memory (no further allocation)

{
  # Service instances configuration
  services = {
    # Maximum number of service instances (compile-time limit: 64)
    max_instances = 4;

    # List of services to deploy
    instances = [
      {
        name = "dumb-server-1";
        exec = "./dumb-server/result/bin/dumb-server";
        port = 8080;
        memory_mb = 50;    # Memory limit in MiB
        cpu_percent = 10;  # CPU limit as percentage
      }
      {
        name = "dumb-server-2";
        exec = "./dumb-server/result/bin/dumb-server";
        port = 8081;
        memory_mb = 50;
        cpu_percent = 10;
      }
      {
        name = "dumb-server-3";
        exec = "./dumb-server/result/bin/dumb-server";
        port = 8082;
        memory_mb = 50;
        cpu_percent = 10;
      }
      {
        name = "dumb-server-4";
        exec = "./dumb-server/result/bin/dumb-server";
        port = 8083;
        memory_mb = 50;
        cpu_percent = 10;
      }
    ];
  };

  # Runtime resource limits
  # These determine static memory allocation at startup
  runtime = {
    # Maximum concurrent proxy connections (compile-time limit: 4096)
    # When this limit is reached, new connections are rejected (natural backpressure)
    proxy_connections_max = 256;

    # Size of read buffer per proxy connection in KiB (compile-time limit: 64 KiB)
    # Total proxy memory = proxy_connections_max × proxy_buffer_size_kb
    # Example: 256 connections × 4 KiB = 1 MiB
    proxy_buffer_size_kb = 4;

    # Maximum number of cgroup monitors (typically one per service)
    # (compile-time limit: 64)
    cgroup_monitors_max = 4;

    # Size of systemd notification/status message buffer in KiB
    # (compile-time limit: 16 KiB)
    systemd_buffer_size_kb = 4;
  };

  # Expected memory usage with these settings:
  #
  # Service instances:    4 × ~512 B      = ~2 KiB
  # Proxy connections:    256 × ~256 B    = ~64 KiB
  # Proxy buffers:        256 × 4 KiB     = 1 MiB
  # Cgroup monitors:      4 × ~128 B      = ~512 B
  # Systemd buffer:       4 KiB           = 4 KiB
  # IOPs bitset overhead: 8 B × 4 pools   = 32 B
  # -----------------------------------------------
  # Total:                                ~1.1 MiB
  #
  # This is deterministic and bounded. No allocation after startup.
}
