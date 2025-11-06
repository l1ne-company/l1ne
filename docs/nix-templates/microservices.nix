# Compose multiple roles from the same dumb-server container blueprint.
# This mirrors docker-compose: shared image, different instance settings.

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

  auth = container {
    name = "auth-service";
    port = 8001;
    memory_mb = 72;
    cpu_percent = 25;
  };

  user = container {
    name = "user-service";
    port = 8002;
    memory_mb = 64;
    cpu_percent = 20;
  };

  orders = container {
    name = "order-service";
    port = 8003;
    memory_mb = 96;
    cpu_percent = 30;
  };

  gateway = container {
    name = "api-gateway";
    port = 8080;
    memory_mb = 80;
    cpu_percent = 35;
  };
in
{
  runtime = {
    proxy_connections_max = 512;
    proxy_buffer_size_kb = 8;
    cgroup_monitors_max = 8;
    systemd_buffer_size_kb = 8;
  };

  services = {
    max_instances = 8;
    instances = [
      auth
      user
      orders
      gateway
    ];
  };
}
