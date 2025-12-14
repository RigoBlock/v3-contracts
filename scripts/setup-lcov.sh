#!/bin/bash
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
fi