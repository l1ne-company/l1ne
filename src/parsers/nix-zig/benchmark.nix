{ pkgs ? import <nixpkgs> {} }:

let
  # Use exact Zig 0.15.1 from flake
  zigFromTarball = pkgs.stdenv.mkDerivation {
    pname = "zig";
    version = "0.15.1";

    src = pkgs.fetchurl {
      url = "https://ziglang.org/download/0.15.1/zig-x86_64-linux-0.15.1.tar.xz";
      sha256 = "sha256-xhxdpu3uoUylHs1eRSDG9Bie9SUDg9sz0BhIKTv6/gU=";
    };

    dontConfigure = true;
    dontBuild = true;
    dontStrip = true;

    installPhase = ''
      mkdir -p $out
      cp -r ./* $out/
      mkdir -p $out/bin
      ln -s $out/zig $out/bin/zig
    '';
  };

  # Zig parser benchmark
  zigBenchmark = pkgs.stdenv.mkDerivation {
    name = "zig-nix-parser-benchmark";
    src = ../../..;

    nativeBuildInputs = [ zigFromTarball ];

    buildPhase = ''
      runHook preBuild

      # Set up Zig cache directories in $TMPDIR
      export HOME=$TMPDIR
      export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
      export ZIG_LOCAL_CACHE_DIR=$TMPDIR/zig-local-cache
      mkdir -p $ZIG_GLOBAL_CACHE_DIR $ZIG_LOCAL_CACHE_DIR

      # Run benchmark and capture output
      mkdir -p results
      zig build bench-auto \
        -Doptimize=ReleaseFast \
        --cache-dir $ZIG_LOCAL_CACHE_DIR \
        --global-cache-dir $ZIG_GLOBAL_CACHE_DIR \
        > results/output.txt 2>&1 || true

      # Copy JSON results if generated
      if [ -f benchmark_results.json ]; then
        cp benchmark_results.json results/
      fi

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out/results
      cp -r results/* $out/results/ || true

      runHook postInstall
    '';
  };

  # Rust rnix-parser reference result (from manual benchmarking)
  # Run manually: cd /home/toga/code/l1ne-company/rnix-parser && nix develop -c cargo bench --bench all-packages
  rustReferenceResult = pkgs.writeText "rust-reference.txt" ''
    all-packages/all-packages
                            time:   [31.359 ms 32.855 ms 34.456 ms]
                            thrpt:  [22.216 MiB/s 23.299 MiB/s 24.410 MiB/s]
  '';

in
{
  inherit zigBenchmark;

  # Comparison report with Rust reference
  comparison = pkgs.stdenv.mkDerivation {
    name = "nix-parser-comparison";
    buildInputs = [ pkgs.gnugrep pkgs.gawk pkgs.bc ];
    unpackPhase = "true";

    buildPhase = ''
      mkdir -p $out/zig
      cp -r ${zigBenchmark}/results/* $out/zig/

      # Generate comparison report
      {
        echo "════════════════════════════════════════════════════════════════"
        echo "  Nix Parser Benchmark Comparison"
        echo "════════════════════════════════════════════════════════════════"
        echo ""

        echo "Zig Parser:"
        ${pkgs.gnugrep}/bin/grep -A3 "all-packages/all-packages" ${zigBenchmark}/results/output.txt

        echo ""
        echo "────────────────────────────────────────────────────────────────"
        echo ""
        echo "Rust rnix-parser (reference):"
        cat ${rustReferenceResult}

        echo ""
        echo "════════════════════════════════════════════════════════════════"
        echo "  Performance Analysis"
        echo "════════════════════════════════════════════════════════════════"
        echo ""

        # Calculate speedup
        ZIG_TIME=$(${pkgs.gnugrep}/bin/grep "time:" ${zigBenchmark}/results/output.txt | ${pkgs.gawk}/bin/awk '{print $4}' | tr -d '[]')
        RUST_TIME="32.855"  # Reference result

        SPEEDUP=$(echo "scale=2; $RUST_TIME / $ZIG_TIME" | ${pkgs.bc}/bin/bc)

        echo "Zig:          $ZIG_TIME ms"
        echo "Rust rnix:    $RUST_TIME ms (reference)"
        echo ""
        echo "Speedup:      ''${SPEEDUP}x faster ⚡"
        echo ""
      } | tee $out/comparison.txt
    '';

    installPhase = "true";
  };

  # Shell for manual benchmarking
  benchShell = pkgs.mkShell {
    buildInputs = with pkgs; [
      zig
      cargo
      rustc
      bc
      gnugrep
      gawk
    ];

    shellHook = ''
      echo "Nix Parser Benchmark Environment"
      echo ""
      echo "Commands:"
      echo "  cd /home/toga/code/l1ne-company/l1ne"
      echo "  zig build bench-auto    # Run Zig benchmark"
      echo ""
      echo "  cd /home/toga/code/l1ne-company/rnix-parser"
      echo "  cargo bench --bench all-packages  # Run Rust benchmark"
      echo ""
    '';
  };
}
