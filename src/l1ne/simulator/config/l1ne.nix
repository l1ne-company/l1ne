# L1NE Simulation Config
#
# Everything lives in this file so it is easy to reason about replicas during
# simulator runs. Each service describes its executable plus a scaling block that
# records the intended minimum, starting, and maximum replica counts. The core
# orchestrator still reads the standard fields (name/exec/port/memory/cpu),
# while the extra `scaling` attribute is purely informational for simulation.

{
  services = {
    max_instances = 12;

    instances = [
      {
        name = "frontend";
        exec = "../dumb-server/result/bin/dumb-server";
        port = 8081;
        memory_mb = 64;
        cpu_percent = 20;
        scaling = {
          min = 1;
          start = 2;
          max = 4;
        };
      }

      {
        name = "api";
        exec = "../dumb-server/result/bin/dumb-server";
        port = 8082;
        memory_mb = 96;
        cpu_percent = 30;
        scaling = {
          min = 2;
          start = 3;
          max = 6;
        };
      }

      {
        name = "worker";
        exec = "../dumb-server/result/bin/dumb-server";
        port = 8083;
        memory_mb = 80;
        cpu_percent = 25;
        scaling = {
          min = 1;
          start = 1;
          max = 3;
        };
      }

      {
        name = "ingest";
        exec = "../dumb-server/result/bin/dumb-server";
        port = 8084;
        memory_mb = 72;
        cpu_percent = 22;
        scaling = {
          min = 1;
          start = 1;
          max = 2;
        };
      }
    ];
  };

  runtime = {
    proxy_connections_max = 256;
    proxy_buffer_size_kb = 4;
    cgroup_monitors_max = 4;
    systemd_buffer_size_kb = 4;
  };
}
