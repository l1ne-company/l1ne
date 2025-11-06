# Docker-compose style example for L1NE
#
# 1. Container: describe how to start a single dumb-server instance
# 2. Compose: choose ports, limits, and how many instances to run

let
  mkDumbServer = {
    root ? ../../src/l1ne/simulator/dumb-server
  }:
  { name, port, memory_mb ? 50, cpu_percent ? 10 }:
    {
      inherit name port memory_mb cpu_percent;
      exec = "${root}/result/bin/dumb-server";
    };

  container = mkDumbServer {};

  # Compose tiered services out of the same container recipe
  frontend = container {
    name = "demo-frontend";
    port = 8081;
    memory_mb = 64;
    cpu_percent = 20;
  };

  api = container {
    name = "demo-api";
    port = 8082;
    memory_mb = 96;
    cpu_percent = 30;
  };

  ingest = container {
    name = "demo-ingest";
    port = 8083;
    memory_mb = 80;
    cpu_percent = 25;
  };
in
{
  runtime = {
    proxy_connections_max = 256;
    proxy_buffer_size_kb = 4;
    cgroup_monitors_max = 4;
    systemd_buffer_size_kb = 4;
  };

  services = {
    max_instances = 4;
    instances = [
      frontend
      api
      ingest
    ];
  };
}
