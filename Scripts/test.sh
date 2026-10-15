#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$PROJECT_DIR/Tests/ReleaseTests.py"
python3 "$PROJECT_DIR/Tests/ReleaseWorkflowTests.py"
python3 "$PROJECT_DIR/Tests/integration.py"
python3 "$PROJECT_DIR/Tests/LaunchSecurityTests.py"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$PROJECT_DIR/build/module-cache" \
  "$PROJECT_DIR/Sources/ClearZip/ArchiveEngine.swift" "$PROJECT_DIR/Sources/ClearZip/ArchiveFileSystem.swift" \
  "$PROJECT_DIR/Tests/CancellationTests.swift" \
  -o "$PROJECT_DIR/build/cancellation-tests"
"$PROJECT_DIR/build/cancellation-tests"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$PROJECT_DIR/build/module-cache" \
  "$PROJECT_DIR/Sources/ClearZip/ArchiveEngine.swift" "$PROJECT_DIR/Sources/ClearZip/ArchiveFileSystem.swift" \
  "$PROJECT_DIR/Tests/SourceReplacementTests.swift" -o "$PROJECT_DIR/build/source-replacement-tests"
"$PROJECT_DIR/build/source-replacement-tests"
python3 "$PROJECT_DIR/Tests/zip64.py"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$PROJECT_DIR/build/module-cache" \
  "$PROJECT_DIR/Sources/Shared/CompressionRequest.swift" "$PROJECT_DIR/Tests/CompressionRequestTests.swift" \
  -o "$PROJECT_DIR/build/finder-request-tests"
"$PROJECT_DIR/build/finder-request-tests"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$PROJECT_DIR/build/module-cache" \
  "$PROJECT_DIR/Sources/Shared/CompressionRequest.swift" "$PROJECT_DIR/Sources/Shared/FinderRequestQueue.swift" \
  "$PROJECT_DIR/Tests/FinderQueueTests.swift" -o "$PROJECT_DIR/build/finder-queue-tests"
"$PROJECT_DIR/build/finder-queue-tests"
