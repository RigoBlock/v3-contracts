#!/bin/bash

# Skip installation if explicitly requested (for CI with cached LCOV)
if [[ "$LCOV_SKIP_INSTALL" == "true" ]]; then
  if command -v lcov &> /dev/null; then
    echo "✅ lcov found in cache, skipping installation"
    exit 0
  else
    echo "⚠️  lcov not found despite skip flag, proceeding with installation"
  fi
fi

if ! command -v lcov &> /dev/null; then
  echo "lcov not found, installing..."
  if [[ "$OSTYPE" == "darwin"* ]]; then
    brew install lcov
  elif [[ "$OSTYPE" == "linux"* ]]; then
    sudo apt-get update && sudo apt-get install -y lcov
  else
    echo "Unsupported OS for auto-install. Please install lcov manually."
    exit 1
  fi
else
  echo "✅ lcov already available"
fi