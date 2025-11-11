#!/bin/bash
set -e

source dev-container-features-test-lib

check "fish version" fish  --version

reportResults
