#!/usr/bin/env bats
# testing/layer0_build_library.bats
#
# Layer 0 — configure.sh build-library Tests (T-095 through T-097)
#
# Tests the volume ingestion pipeline subcommand (Phase 16, D-013).
# No running services required — purely filesystem and shell.
#
# Run: bats testing/layer0_build_library.bats

load 'helpers'

setup_file() {
    command -v jq       &>/dev/null || { echo "ERROR: jq required" >&3; return 1; }
    command -v sha256sum &>/dev/null || { echo "ERROR: sha256sum required" >&3; return 1; }
}

setup() {
    # Fresh temp dirs per test
    SOURCE_DIR=$(mktemp -d)
    OUTPUT_DIR=$(mktemp -d)/test-lib
    export SOURCE_DIR OUTPUT_DIR
}

teardown() {
    [[ -d "$SOURCE_DIR" ]] && find "$SOURCE_DIR" -maxdepth 1 -type f -delete && rmdir "$SOURCE_DIR" 2>/dev/null || true
    [[ -d "$OUTPUT_DIR" ]] && find "$OUTPUT_DIR" -maxdepth 2 -type f -delete && find "$OUTPUT_DIR" -type d | sort -r | xargs rmdir 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# T-095 — Happy path: builds all four expected outputs
# ---------------------------------------------------------------------------

@test "T-095: build-library produces manifest.yaml, documents/, metadata.json, checksums.txt" {
    echo "# Test document one" > "$SOURCE_DIR/doc1.md"
    echo "Second document."   > "$SOURCE_DIR/doc2.txt"

    run bash "$PROJECT_ROOT/scripts/configure.sh" build-library \
        --source  "$SOURCE_DIR" \
        --name    my-test-lib \
        --version 1.0.0 \
        --author  tester \
        --license MIT \
        --output  "$OUTPUT_DIR"

    [ "$status" -eq 0 ]
    [ -f "$OUTPUT_DIR/manifest.yaml" ]
    [ -d "$OUTPUT_DIR/documents" ]
    [ -f "$OUTPUT_DIR/metadata.json" ]
    [ -f "$OUTPUT_DIR/checksums.txt" ]

    # manifest.yaml has correct name and version
    grep -q 'name: "my-test-lib"'  "$OUTPUT_DIR/manifest.yaml"
    grep -q 'version: "1.0.0"'     "$OUTPUT_DIR/manifest.yaml"
    grep -q 'localhost'             "$OUTPUT_DIR/manifest.yaml"

    # Both source files were copied
    [ -f "$OUTPUT_DIR/documents/doc1.md" ]
    [ -f "$OUTPUT_DIR/documents/doc2.txt" ]

    # metadata.json is valid JSON with file_count=2
    jq -e '.file_count == 2' "$OUTPUT_DIR/metadata.json" > /dev/null
}

# ---------------------------------------------------------------------------
# T-096 — checksums.txt verifies cleanly with sha256sum -c
# ---------------------------------------------------------------------------

@test "T-096: checksums.txt verifies clean with sha256sum -c" {
    echo "Content for checksum test." > "$SOURCE_DIR/readme.md"

    bash "$PROJECT_ROOT/scripts/configure.sh" build-library \
        --source  "$SOURCE_DIR" \
        --name    checksum-test-lib \
        --version 0.1.0 \
        --output  "$OUTPUT_DIR"

    # Run sha256sum -c from the package root so relative paths resolve
    run bash -c "cd '$OUTPUT_DIR' && sha256sum -c checksums.txt"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

# ---------------------------------------------------------------------------
# T-097 — Validation: missing --source or bad --name exits non-zero
# ---------------------------------------------------------------------------

@test "T-097: build-library exits non-zero on missing --source" {
    run bash "$PROJECT_ROOT/scripts/configure.sh" build-library \
        --name my-lib --version 1.0.0 --output "$OUTPUT_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"--source is required"* ]]
}

@test "T-097b: build-library exits non-zero on invalid --name format" {
    echo "text" > "$SOURCE_DIR/doc.md"
    run bash "$PROJECT_ROOT/scripts/configure.sh" build-library \
        --source "$SOURCE_DIR" --name "Bad Name!" --version 1.0.0 --output "$OUTPUT_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"kebab-case"* ]]
}
