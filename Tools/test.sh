#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
PYTHONPATH=Tools python3 -m unittest discover -s Tests/Python -v
if command -v dotnet >/dev/null 2>&1; then
  dotnet run --project Tests/Core/Yardman.Core.Tests.csproj --configuration Release
elif command -v mcs >/dev/null 2>&1 && command -v mono >/dev/null 2>&1; then
  mkdir -p .artifacts
  mcs -langversion:7.2 -out:.artifacts/core-tests.exe Assets/Yardman/Domain/*.cs Assets/Yardman/Streaming/*.cs Assets/Yardman/Simulation/*.cs Assets/Yardman/Content/*.cs Tests/Core/Program.cs
  mono .artifacts/core-tests.exe
else
  echo "C# tests require .NET 8 SDK or Mono; Python tests alone do not certify the core." >&2
  exit 3
fi
