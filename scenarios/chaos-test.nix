{
  scenario = {
    name = "chaos-test";
    type = "chaos_test";
    duration_us = 60000000;  # 60 seconds
    seed = 12345;

    services = [
      { service_id = 1; port = 8080; }
      { service_id = 2; port = 8081; }
      { service_id = 3; port = 8082; }
    ];

    faults = {
      crash_probability = 0.05;
      delay_probability = 0.1;
      delay_min_us = 1000;
      delay_max_us = 100000;
    };
  };
}
