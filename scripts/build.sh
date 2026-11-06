#!/bin/sh
# Release build of dirconproxy, signed with a stable identifier so macOS keeps its privacy grants.
# Ad-hoc signing ("-") is used unless SIGN_IDENTITY names a certificate.
set -e
cd "$(dirname "$0")/.."
swift build -c release
codesign --force --sign "${SIGN_IDENTITY:--}" --identifier com.iremezoff.dirconproxy --options runtime .build/release/dirconproxy
echo "built .build/release/dirconproxy"
