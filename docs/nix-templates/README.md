# L1NE Nix Configuration Templates

Declarative service orchestration with TigerStyle resource bounds.

## Overview

Think of L1NE the same way you think about Docker tooling:

- **Service flake** ⇒ Build an executable with an entrypoint (like a `Dockerfile`)
- **Compose definition** ⇒ How many replicas, limits, and orchestration details (like `docker-compose.yml`)

Every service ships its own flake that builds the executable. Run `nix build` inside that flake to materialize `./result/bin/<binary>` and then reference that path from your simulation config.

**Philosophy:**
- **Declarative:** Describe services in Nix
- **Composable:** Build configurations from simple functions
- **Bounded:** All resources have explicit limits (TigerStyle)
- **Validated:** Assertions check configuration at evaluation time

## Quick Start

### 1. Build the service binary

```bash
cd src/l1ne/simulator/dumb-server
nix build .#dumb-server
```

The flake drops `./result/bin/dumb-server`, which is the exact path the simulator needs.

### 2. Compose services (like docker-compose)

```bash
l1ne start --config=my-api.nix .
```

```nix
let
  dumbServer = ../../src/l1ne/simulator/dumb-server/result/bin/dumb-server;
  mkService =
    { name, port, memory_mb ? 50, cpu_percent ? 10 }:
    {
      inherit name port memory_mb cpu_percent;
      exec = dumbServer;
    };
in {
  runtime = {
    proxy_connections_max = 256;
    proxy_buffer_size_kb = 4;
    cgroup_monitors_max = 4;
    systemd_buffer_size_kb = 4;
  };

  services = {
    max_instances = 4;
    instances = [
      (mkService { name = "frontend"; port = 8081; memory_mb = 64; cpu_percent = 20; })
      (mkService { name = "api"; port = 8082; memory_mb = 96; cpu_percent = 30; })
      (mkService { name = "ingest"; port = 8083; memory_mb = 80; cpu_percent = 25; })
    ];
  };
}
```

## Library Functions

The helper utilities in `lib.nix` still exist for richer setups, but you can get started with the simple “flake build → compose config” pattern above.

## Runtime Limits (TigerStyle Bounds)

All resources have explicit maximum values:

| Limit | Default | Maximum | Description |
|-------|---------|---------|-------------|
| `service_instances_count` | 4 | 64 | Maximum service instances |
| `proxy_connections_max` | 256 | 4096 | Concurrent connections |
| `proxy_buffer_size_kb` | 16 | 64 | Buffer size per connection |
| `cgroup_monitors_count` | 4 | 64 | Number of cgroup monitors |
| `systemd_buffer_size_kb` | 4 | 256 | Systemd message buffer |

**Why bounded?** Following TigerBeetle's TigerStyle:
- Prevents runaway resource usage
- Enables static memory allocation
- Makes system behavior predictable
- Simplifies testing and verification

## Instance Scaling (Per-Service)

Each service has independent instance scaling configuration:

```nix
instances = {
  min = 2;    # Minimum instances (always running)
  max = 10;   # Maximum instances (scale up limit)
  start = 4;  # Initial instances at deployment
}
```

**Constraints (TigerStyle bounds):**
- All values must be > 0
- `max` cannot exceed 64 (L1NE system limit)
- `min` ≤ `start` ≤ `max`

**Use Cases:**

1. **Single Instance (Stateful Services)**
   ```nix
   instances = { min = 1; max = 1; start = 1; }
   ```
   - Databases (PostgreSQL, Redis)
   - File servers
   - Services with persistent connections

2. **High Availability (Critical Services)**
   ```nix
   instances = { min = 3; max = 12; start = 4; }
   ```
   - Authentication services
   - Payment processing
   - Core business logic

3. **Auto-Scaling (Traffic-Dependent)**
   ```nix
   instances = { min = 2; max = 20; start = 5; }
   ```
   - Web frontends
   - API gateways
   - Order processing services

4. **Minimal Resources (Background Workers)**
   ```nix
   instances = { min = 1; max = 4; start = 2; }
   ```
   - Cron jobs
   - Batch processors
   - Log aggregators

**Configuration:**
- `min` - Minimum instances to maintain
- `max` - Maximum instances allowed
- `start` - How many instances to start initially

## Configuration Patterns

### 1. Shared Configuration

```nix
let
  commonEnv = {
    REGION = "us-east-1";
    LOG_FORMAT = "json";
  };

  commonResources = {
    memory_percent = 75;
    cpu_percent = 70;
  };
in
l1ne.mkService {
  name = "my-service";
  env = commonEnv // { SERVICE_NAME = "api"; };
  resources = commonResources;
  # ...
}
```

### 2. Service Composition

```nix
let
  mkBackendService = name: port: l1ne.mkService {
    inherit name port;
    package = pkgs.my-backend;
    env = commonConfig;
    health_check = l1ne.mkHttpHealthCheck {};
  };
in
[
  (mkBackendService "api-1" 3001)
  (mkBackendService "api-2" 3002)
  (mkBackendService "api-3" 3003)
]
```

### 3. Import-Based Organization

**services/web.nix:**
```nix
{ pkgs, l1ne }:
l1ne.mkService {
  name = "web";
  package = pkgs.nginx;
  port = 80;
}
```

**services/api.nix:**
```nix
{ pkgs, l1ne }:
l1ne.mkService {
  name = "api";
  package = pkgs.my-api;
  port = 3000;
}
```

**config.nix:**
```nix
{ pkgs ? import <nixpkgs> {} }:

let
  l1ne = import ./lib.nix { inherit pkgs; };
  args = { inherit pkgs l1ne; };
in
l1ne.mkMesh {
  name = "platform";
  services = [
    (import ./services/web.nix args)
    (import ./services/api.nix args)
  ];
}
```

## CLI Usage

```bash
# Start orchestrator
l1ne start --config=my-config.nix .

# View WAL entries
l1ne wal l1ne.wal --lines=50

# Follow WAL
l1ne wal l1ne.wal --follow
```

## Write-Ahead Log (WAL)

The WAL records all events:

**Event Types:**
- `ServiceStart` - Service instance started
- `ServiceStop` - Service instance stopped
- `ProxyAccept` - Connection accepted
- `ProxyClose` - Connection closed
- `ConfigReload` - Configuration reloaded
- `Checkpoint` - System state snapshot

**Usage:**
```bash
# Read WAL entries
l1ne wal l1ne.wal --lines=100

# Follow in real-time
l1ne wal l1ne.wal --follow
```

## Examples

See:
- `example.nix` - Basic service configuration
- `microservices.nix` - Multiple services with shared config
- `schema.nix` - Complete schema documentation

## Design Philosophy

L1NE provides composable Nix utilities for service configuration, similar to how Crane provides utilities for Docker images.

**Key Principles:**
- **Declarative:** Services defined in Nix
- **Composable:** Build configs from simple functions
- **Bounded:** All resources have explicit limits (TigerStyle)
- **Static:** Memory allocated upfront, locked forever

## Usage

1. Create your Nix configuration
2. Start: `l1ne start --config=your-config.nix .`
3. View logs: `l1ne wal l1ne.wal --follow`
