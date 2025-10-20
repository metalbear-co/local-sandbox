#!/bin/bash
set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTEGRATION_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OPERATOR_DIR="$(cd "${INTEGRATION_DIR}/../operator" && pwd)"

# Get current year and next year
CURRENT_YEAR=$(date +%Y)
NEXT_YEAR=$((CURRENT_YEAR + 1))

# Default dates (current year to next year)
DEFAULT_VALID_FROM="${CURRENT_YEAR}-01-01 00:00:00 UTC"
DEFAULT_VALID_TO="${NEXT_YEAR}-01-01 00:00:00 UTC"

# Date configuration (can be overridden by command-line args)
VALID_FROM="${1:-$DEFAULT_VALID_FROM}"
VALID_TO="${2:-$DEFAULT_VALID_TO}"

# License configuration with defaults
ORGANIZATION="${3:-Company}"
LICENSE_TYPE="${4:-enterprise}"
MAX_SEATS="${5:-2137}"

# Issuer configuration
ISSUER_ORG="Metalbear"
ISSUER_CN="Metalbear License"

# Output files (issuer already exists, we only generate the license)
ISSUER_FILE="${SCRIPT_DIR}/license-issuer.pem"
LICENSE_FILE="${SCRIPT_DIR}/company-license.pem"

echo "Configuration:"
echo "  Valid From: ${VALID_FROM}"
echo "  Valid To: ${VALID_TO}"
echo "  Organization: ${ORGANIZATION}"
echo "  License Type: ${LICENSE_TYPE}"
echo "  Max Seats: ${MAX_SEATS}"
echo ""

echo "Building license-gen..."
cd "${OPERATOR_DIR}"
cargo build --bin license-gen --features="generation" --release

if [ $? -ne 0 ]; then
    echo "Build failed!"
    exit 1
fi

BINARY="${OPERATOR_DIR}/target/release/license-gen"

# Only create issuer if it doesn't exist
if [ ! -f "${ISSUER_FILE}" ]; then
    echo "Creating issuer certificate..."
    "${BINARY}" create-issuer \
        -o "${ISSUER_ORG}" \
        -c "${ISSUER_CN}" \
        --valid-from "${VALID_FROM}" \
        --valid-to "${VALID_TO}" \
        > "${ISSUER_FILE}"
    
    if [ $? -ne 0 ]; then
        echo "Failed to create issuer certificate!"
        exit 1
    fi
    echo "Issuer certificate created: ${ISSUER_FILE}"
else
    echo "Using existing issuer certificate: ${ISSUER_FILE}"
fi

echo "Creating license..."
"${BINARY}" create-license \
    --organization "${ORGANIZATION}" \
    --valid-from "${VALID_FROM}" \
    --valid-to "${VALID_TO}" \
    --issuer-path "${ISSUER_FILE}" \
    --license-type "${LICENSE_TYPE}" \
    --max-seats ${MAX_SEATS} \
    > "${LICENSE_FILE}"

if [ $? -ne 0 ]; then
    echo "Failed to create license!"
    exit 1
fi

echo "License created: ${LICENSE_FILE}"
echo ""
echo "Generated files:"
echo "  Issuer: ${ISSUER_FILE}"
echo "  License: ${LICENSE_FILE}"
