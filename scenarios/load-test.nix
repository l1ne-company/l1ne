{
  scenario = {
    name = "load-test";
    type = "load_test";
    duration_us = 5000000;  # 5 seconds (fits within 1024 event limit)
    seed = 99999;

    services = [
      { service_id = 1; port = 8080; }
      { service_id = 2; port = 8081; }
      { service_id = 3; port = 8082; }
      { service_id = 4; port = 8083; }
    ];

    faults = {
      crash_probability = 0.0;
      delay_probability = 0.0;
    };
  };
}
