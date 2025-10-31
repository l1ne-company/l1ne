{
  scenario = {
    name = "transaction-stress";
    type = "transaction_stress";
    duration_us = 1000000;  # 1 second (transactions generate many events)
    seed = 54321;

    services = [
      { service_id = 1; port = 8080; }
      { service_id = 2; port = 8081; }
    ];

    faults = {
      crash_probability = 0.01;
      delay_probability = 0.05;
      delay_min_us = 500;
      delay_max_us = 50000;
    };
  };
}
