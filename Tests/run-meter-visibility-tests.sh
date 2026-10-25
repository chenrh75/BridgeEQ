#!/bin/zsh
set -eu
cd "${0:A:h:h}"
test_build_dir=$(mktemp -d /tmp/bridgeeq-meter-tests.XXXXXX)
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
cat HeadphoneEQ/ContentView.swift Tests/MeterVisibilityTests.swift > "$test_build_dir/MeterVisibility.swift"
sources=(HeadphoneEQ/*.swift)
sources=(${sources:#HeadphoneEQ/ContentView.swift})
sources=(${sources:#HeadphoneEQ/HeadphoneEQApp.swift})
xcrun swiftc -O -parse-as-library -module-cache-path "$PWD/build/test-module-cache" \
    "${sources[@]}" "$test_build_dir/MeterVisibility.swift" -o "$test_build_dir/MeterVisibilityTests"
"$test_build_dir/MeterVisibilityTests"
