# Example L1NE configuration
#
# Build the demo server first:
#   cd src/l1ne/simulator/dumb-server
#   nix build .#dumb-server
#
# This produces ./result/bin/dumb-server, which the simulator uses below.
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
      {
        name = "demo-frontend";
        exec = "./dumb-server/result/bin/dumb-server";
        port = 8081;
        memory_mb = 64;
        cpu_percent = 20;
      }
      {
        name = "demo-api";
        exec = "./dumb-server/result/bin/dumb-server";
        port = 8082;
        memory_mb = 96;
        cpu_percent = 30;
      }
      {
        name = "demo-ingest";
        exec = "./dumb-server/result/bin/dumb-server";
        port = 8083;
        memory_mb = 80;
        cpu_percent = 25;
      }
    ];
  };
}
