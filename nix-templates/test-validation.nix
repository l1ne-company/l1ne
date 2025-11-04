# Test: Instance Validation
#
# This demonstrates L1NE's TigerStyle validation in action.
# Uncomment invalid configurations to see assertion errors.

{ pkgs ? import <nixpkgs> {} }:

let
  l1ne = import ./lib.nix { inherit pkgs; };

  # ✓ Valid: min <= start <= max
  validService = l1ne.mkService {
    name = "valid";
    package = pkgs.hello;
    port = 8080;
    instances = {
      min = 2;
      max = 10;
      start = 5;
    };
  };

  # ✗ Invalid: start > max (uncomment to test)
  # invalidStartTooHigh = l1ne.mkService {
  #   name = "invalid-start";
  #   package = pkgs.hello;
  #   port = 8081;
  #   instances = {
  #     min = 2;
  #     max = 10;
  #     start = 15;  # ERROR: start > max
  #   };
  # };

  # ✗ Invalid: min > max (uncomment to test)
  # invalidMinMax = l1ne.mkService {
  #   name = "invalid-minmax";
  #   package = pkgs.hello;
  #   port = 8082;
  #   instances = {
  #     min = 10;
  #     max = 5;   # ERROR: max < min
  #     start = 7;
  #   };
  # };

  # ✗ Invalid: max > 64 (L1NE limit) (uncomment to test)
  # invalidMaxTooHigh = l1ne.mkService {
  #   name = "invalid-max";
  #   package = pkgs.hello;
  #   port = 8083;
  #   instances = {
  #     min = 1;
  #     max = 100;  # ERROR: exceeds L1NE limit (64)
  #     start = 50;
  #   };
  # };

  # ✗ Invalid: port out of range (uncomment to test)
  # invalidPort = l1ne.mkService {
  #   name = "invalid-port";
  #   package = pkgs.hello;
  #   port = 80;  # ERROR: port < 1024 (reserved)
  #   instances = {
  #     min = 1;
  #     max = 1;
  #     start = 1;
  #   };
  # };

in
# Check all assertions and return service
if l1ne.checkAssertions (validService.assertions)
then { success = true; service = validService; }
else throw "Assertions failed"
