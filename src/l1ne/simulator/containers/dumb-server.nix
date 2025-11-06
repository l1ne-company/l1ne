# Dumb server container definition
#
# This module provides a reusable factory for L1NE service instances backed by
# the dumb-server binary. It plays a similar role to a Dockerfile: define how a
# single service (container) should be started, while the higher level compose
# file decides how many instances to run and with which limits.
#
# Usage:
#   let
#     mkDumbServer = import ../containers/dumb-server.nix { root = ../.; };
#   in mkDumbServer { name = "api"; port = 8080; }

{ root ? ../. }:
{ name, port, memory_mb ? 50, cpu_percent ? 10 }:
{
  inherit name port memory_mb cpu_percent;
  exec = "${root}/dumb-server/result/bin/dumb-server";
}
